-- beeline_ephemeral.lua — Ephemeral ADEPT Decrypt-to-RAM Manager for Beeline
-- Keeps Adobe ADEPT books encrypted on disk at rest. Decrypts to volatile RAM
-- (/tmp / tmpfs) only during an active reading session, and shreds on close.
-- Automatically redirects .sdr sidecar, cover art, and ReadHistory to the master book.

local ffi = require("ffi")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or not lfs then ok_lfs, lfs = pcall(require, "lfs") end
local logger = require("logger")

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local ok_loc, Localization = pcall(require, plugin_path .. "localization_beeline")
if not ok_loc or not Localization then
    ok_loc, Localization = pcall(require, "localization_beeline")
end
local _ = function(key, ...)
    if ok_loc and Localization then
        return Localization:t(key, ...)
    end
    return key
end
local State = require(plugin_path .. "beeline_state")
local DRM = require(plugin_path .. "beeline_drm")
local epub = require(plugin_path .. "beeline_adobe_epub")
local nativecrypto = require(plugin_path .. "beeline_adobe_nativecrypto")

local M = {}

-- Session tracking:
-- _ephem_to_master[temp_path]   = master_path
-- _master_to_ephem[master_path] = temp_path
local _ephem_to_master = {}
local _master_to_ephem = {}
local _ephem_refs = {}
local _reader_owned = {}
local _warm_cached = {}
local _hooks_installed = false

local EPHEMERAL_RAM_HEADROOM_BYTES = 16 * 1024 * 1024 -- keep >= 16 MB free on /tmp tmpfs
local MAX_RAM_EPHEMERAL_BYTES = 16 * 1024 * 1024 -- never place large books (>16 MB) on RAM tmpfs

local function shellQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function normalizeZipPath(path)
    if type(path) ~= "string" then return "" end
    local clean = path:gsub("\\", "/"):gsub("^%./+", ""):gsub("^/+", ""):gsub("//+", "/")
    return clean
end

local function isValidEpubArchive(file_path)
    local ok_arch, Archiver = pcall(require, "ffi/archiver")
    if not ok_arch or not Archiver or not Archiver.Reader or type(Archiver.Reader.open) ~= "function" then
        -- Headless unit test without Archiver implementation
        return true
    end
    local reader = Archiver.Reader:new()
    if not reader:open(file_path) then
        return false
    end
    local has_container = false
    for entry in reader:iterate() do
        if entry.mode == "file" and normalizeZipPath(entry.path):lower() == "meta-inf/container.xml" then
            has_container = true
            break
        end
    end
    local err = reader.err
    reader:close()
    return has_container and (err == nil)
end

-- ---------------------------------------------------------------------------
-- Ephemeral Path & Orphan Management
-- ---------------------------------------------------------------------------

local function getCandidateDirs()
    local ok_ds, DS = pcall(require, "datastorage")
    local base = nil
    if ok_ds and DS then
        if type(DS.getFullDataDir) == "function" then
            local ok_f, full = pcall(DS.getFullDataDir, DS)
            if ok_f and type(full) == "string" and full ~= "" and full ~= "." then
                base = full
            end
        end
        if not base and type(DS.getDataDir) == "function" then
            base = DS:getDataDir()
        end
    end
    if not base or base == "" then
        base = "/tmp"
    elseif base == "." and lfs and type(lfs.currentdir) == "function" then
        local cwd = lfs.currentdir()
        if type(cwd) == "string" and cwd ~= "" then
            base = cwd
        end
    end
    local cache_dir = base .. "/cache/beeline.koplugin/ephemeral"
    return {
        ram = { "/tmp", "/dev/shm" },
        extra = { "/var/tmp" },
        cache = cache_dir,
    }
end

local function getFfiUtil()
    local ok_fu, ffiutil = pcall(require, "ffi/util")
    if ok_fu and ffiutil and type(ffiutil.df) == "function" then
        return ffiutil
    end
    local legacy = package.loaded["ffi/ffiutil"]
    if legacy and type(legacy.df) == "function" then
        return legacy
    end
    return nil
end

local function isRamPath(path, cache_dir)
    if type(path) ~= "string" then return false end
    if cache_dir and path:sub(1, #cache_dir) == cache_dir then
        return false
    end
    return path:match("^/tmp/") ~= nil or path:match("^/dev/shm/") ~= nil
end

local function ensureCacheDir(cache_dir)
    if lfs.attributes(cache_dir, "mode") ~= "directory" then
        pcall(os.execute, "mkdir -p " .. shellQuote(cache_dir) .. " 2>/dev/null")
    end
    return lfs.attributes(cache_dir, "mode") == "directory"
end

--- Resolves the directory for volatile ephemeral files (prefers /tmp ramdisk when space allows)
local function getEphemeralDir(required_bytes, master_path)
    local dirs = getCandidateDirs()
    local req = tonumber(required_bytes) or 0
    local ffiutil = getFfiUtil()
    local has_df = ffiutil ~= nil
    local needed = req + EPHEMERAL_RAM_HEADROOM_BYTES

    -- Large books (e.g. picture books) must skip RAM tmpfs so they don't trigger ENOSPC/short write
    -- or starve KOReader's image renderer of RAM.
    if req <= MAX_RAM_EPHEMERAL_BYTES then
        for _, dir in ipairs(dirs.ram) do
            if lfs.attributes(dir, "mode") == "directory" then
                if has_df then
                    local ok_df, _, free_bytes = pcall(ffiutil.df, dir)
                    if ok_df and type(free_bytes) == "number" and free_bytes >= needed then
                        return dir
                    end
                elseif req == 0 then
                    return dir
                end
            end
        end
    end

    -- Fallback to KOReader cache directory if RAM tmpfs is unavailable, lacks headroom, or book is large
    local cache_dir = dirs.cache
    if ensureCacheDir(cache_dir) then
        return cache_dir
    end

    -- Secondary persistent fallback alongside the master book if cache_dir could not be created
    if type(master_path) == "string" then
        local master_dir = master_path:match("^(.*)[/\\][^/\\]+$")
        if master_dir and master_dir ~= "" and not isRamPath(master_dir .. "/", cache_dir) then
            local sibling_cache = master_dir .. "/.beeline_ephemeral"
            if ensureCacheDir(sibling_cache) then
                return sibling_cache
            end
        end
    end

    for _, dir in ipairs(dirs.extra) do
        if lfs.attributes(dir, "mode") == "directory" then
            return dir
        end
    end
    return "/tmp"
end

local function deterministicHashHex(str)
    local h = 5381
    for i = 1, #str do
        h = (h * 33 + str:byte(i)) % 0x100000000
    end
    return string.format("%08x", h)
end

--- Generates a deterministic ephemeral file path (preserves KOReader cr3cache hits across sessions)
local function generateEphemeralPath(master_path, required_bytes, force_dir)
    local dir = force_dir or getEphemeralDir(required_bytes, master_path)
    local filename = master_path and (master_path:match("([^/\\]+)$") or "book.epub") or "book.epub"
    local base, ext = filename:match("^(.+)(%..+)$")
    base = base or filename
    ext = ext or (master_path and master_path:match("(%.[^%.]+)$") or ".epub")

    -- Sanitize filesystem-hostile characters while keeping book title readable
    base = base:gsub('[/\\:*?"<>|]', "_")

    local hash_hex = deterministicHashHex(tostring(master_path or "") .. ":" .. tostring(required_bytes or 0))
    local candidate = string.format("%s/bln_ephem_%s_%s%s", dir, base, hash_hex, ext)
    if not _ephem_to_master[candidate] then
        return candidate
    end

    -- Fallback salt only if the deterministic path is already actively open
    math.randomseed(os.time() + math.floor(os.clock() * 100000))
    local rand_hex = string.format("%04x", math.random(0, 0xFFFF))
    return string.format("%s/bln_ephem_%s_%s_%s%s", dir, base, hash_hex, rand_hex, ext)
end

--- Shreds and unlinks a file (wipes first blocks before removing)
local function secureRemove(file_path)
    if not file_path or file_path == "" then return false end
    if lfs.attributes(file_path, "mode") ~= "file" then return false end

    -- Overwrite first 64KB with zeroes if possible to shred in-memory/cache buffers
    local f = io.open(file_path, "r+b")
    if f then
        local size = f:seek("end") or 0
        local wipe_len = math.min(size, 65536)
        if wipe_len > 0 then
            f:seek("set", 0)
            f:write(string.rep("\0", wipe_len))
        end
        f:close()
    end
    return pcall(os.remove, file_path)
end

local function sanitizeReaderSettings()
    if not G_reader_settings or type(G_reader_settings.readSetting) ~= "function" then
        return
    end
    local function isVolatilePath(p)
        if type(p) ~= "string" or p == "" then return false end
        return p == "/tmp" or p == "/dev/shm" or p == "/var/tmp"
            or p:match("^/tmp/bln_ephem_") ~= nil
            or p:match("^/dev/shm/bln_ephem_") ~= nil
            or p:match("bln_ephem_") ~= nil
            or p:match("/cache/beeline%.koplugin/ephemeral") ~= nil
    end

    local lastfile = G_reader_settings:readSetting("lastfile")
    if isVolatilePath(lastfile) and not _ephem_to_master[lastfile] then
        local replacement = M._last_master_path
        if replacement and lfs.attributes(replacement, "mode") == "file" then
            G_reader_settings:saveSetting("lastfile", replacement)
        elseif type(G_reader_settings.delSetting) == "function" then
            G_reader_settings:delSetting("lastfile")
        else
            G_reader_settings:saveSetting("lastfile", nil)
        end
    end

    local lastdir = G_reader_settings:readSetting("lastdir")
    if isVolatilePath(lastdir) then
        local fallback_dir = G_reader_settings:readSetting("home_dir")
        if M._last_master_path then
            local ok_u, util = pcall(require, "util")
            if ok_u and util and util.splitFilePathName then
                local master_dir = util.splitFilePathName(M._last_master_path)
                if master_dir and lfs.attributes(master_dir, "mode") == "directory" then
                    fallback_dir = master_dir
                end
            end
        end
        if fallback_dir and fallback_dir ~= "" then
            G_reader_settings:saveSetting("lastdir", fallback_dir)
        elseif type(G_reader_settings.delSetting) == "function" then
            G_reader_settings:delSetting("lastdir")
        end
    end
end

--- Cleans up all orphaned ephemeral files from previous crashes or ungraceful reboots
function M.cleanupAllOrphans()
    local dirs = getCandidateDirs()
    local all_dirs = {}
    local seen = {}
    for _, d in ipairs(dirs.ram) do
        if not seen[d] then seen[d] = true; table.insert(all_dirs, d) end
    end
    for _, d in ipairs(dirs.extra) do
        if not seen[d] then seen[d] = true; table.insert(all_dirs, d) end
    end
    if dirs.cache and not seen[dirs.cache] then
        seen[dirs.cache] = true
        table.insert(all_dirs, dirs.cache)
    end

    local cleaned = 0
    for _, dir in ipairs(all_dirs) do
        if dir and lfs.attributes(dir, "mode") == "directory" then
            local ok, iter, dir_obj = pcall(lfs.dir, dir)
            if ok and iter then
                for entry in iter, dir_obj do
                    if entry:match("^bln_ephem_") then
                        local full = dir .. "/" .. entry
                        -- Never delete a file currently registered in an active session
                        if not _ephem_to_master[full] then
                            secureRemove(full)
                            cleaned = cleaned + 1
                        end
                    end
                end
            end
        end
    end

    if epub and type(epub.cleanupWorkDirs) == "function" then
        local has_active = (next(_ephem_to_master) ~= nil)
        pcall(epub.cleanupWorkDirs, has_active and 3600 or 0)
    end

    pcall(sanitizeReaderSettings)

    if cleaned > 0 then
        logger.info("beeline_ephemeral: cleaned " .. cleaned .. " orphaned session files")
    end
    return cleaned
end

-- ---------------------------------------------------------------------------
-- ADEPT Encryption Detection
-- ---------------------------------------------------------------------------

--- Checks whether a file on disk is ADEPT-encrypted (EPUB or PDF)
function M.isAdeptEncrypted(file_path)
    if not file_path or file_path == "" then return false end
    if M.isEphemeralPath(file_path) then return false end
    if lfs.attributes(file_path, "mode") ~= "file" then return false end

    -- 1. Check if tracked in Beeline State
    if State.isBookAdept(file_path) then
        return true
    end

    -- 2. Inspect file header
    local f = io.open(file_path, "rb")
    if not f then return false end
    local magic = f:read(10) or ""
    f:close()

    local isPdf = magic:sub(1, 5) == "%PDF-"
    local isZip = magic:sub(1, 4) == "PK" .. string.char(0x03, 0x04)

    if isZip then
        -- Quick probe for EPUB: iterate entries first (Archiver.Reader:seek requires iteration)
        local ok_arch, Archiver = pcall(require, "ffi/archiver")
        if ok_arch and Archiver and Archiver.Reader and type(Archiver.Reader.open) == "function" then
            local reader = Archiver.Reader:new()
            if reader:open(file_path) then
                local rights_entry = nil
                local enc_entry = nil
                for entry in reader:iterate() do
                    if entry.mode == "file" then
                        local norm = normalizeZipPath(entry.path):lower()
                        if norm == "meta-inf/rights.xml" then
                            rights_entry = entry.path
                            break
                        elseif norm == "meta-inf/encryption.xml" then
                            enc_entry = entry.path
                        end
                    end
                end
                local has_rights = (rights_entry ~= nil)
                local has_adept_enc = false
                if not has_rights and enc_entry then
                    local enc_xml = reader:extractToMemory(enc_entry)
                    if enc_xml and (
                        enc_xml:find("http://ns.adobe.com/adept", 1, true)
                        or enc_xml:find("xmlns:adept", 1, true)
                        or enc_xml:find("http://www.w3.org/2001/04/xmlenc#aes128-cbc", 1, true)
                        or enc_xml:find("http://ns.adobe.com/adept/xmlenc#aes128-cbc-uncompressed", 1, true)
                    ) then
                        has_adept_enc = true
                    end
                end
                reader:close()
                if has_rights or has_adept_enc then
                    return true
                end
            end
        end
    elseif isPdf then
        -- Quick probe for PDF: check for Adobe DRM dictionary
        local f_pdf = io.open(file_path, "rb")
        if f_pdf then
            local chunk = f_pdf:read(32768) or ""
            f_pdf:close()
            if chunk:find("/Adobe%.APS") or chunk:find("/adept") then
                return true
            end
        end
    end

    return false
end

--- Returns the master persistent path for an ephemeral or normal document path
function M.getMasterPath(doc_path)
    if not doc_path or doc_path == "" then return doc_path end
    return _ephem_to_master[doc_path] or doc_path
end

--- Checks if a path is currently an active ephemeral reading file
function M.isEphemeralPath(doc_path)
    if not doc_path then return false end
    return _ephem_to_master[doc_path] ~= nil
end

-- ---------------------------------------------------------------------------
-- Session Lifecycle (Prepare & Cleanup)
-- ---------------------------------------------------------------------------

--- Decrypts master book into volatile RAM (/tmp) or cache and registers reading session
function M.prepareSession(master_path, opts)
    if not master_path or master_path == "" then
        return nil, "No master path provided"
    end

    local isPdf = (master_path:lower():match("%.pdf$") ~= nil)

    -- Return existing active session only if non-empty and valid
    local existing_temp = _master_to_ephem[master_path]
    if existing_temp then
        local attr = lfs.attributes(existing_temp)
        local valid = attr and attr.mode == "file" and (attr.size == nil or attr.size > 0)
        if valid and not isPdf then
            valid = isValidEpubArchive(existing_temp)
        end
        if valid then
            return existing_temp
        end
        logger.warn("beeline_ephemeral: discarding stale/corrupt cached session " .. tostring(existing_temp))
        M.cleanupSession(existing_temp)
    end

    local tracked = State.getTrackedBook(master_path)
    local has_cached_key = (not isPdf) and tracked and type(tracked.book_key_hex) == "string" and tracked.book_key_hex ~= ""
    local activation = nil
    if not has_cached_key then
        activation = DRM.restoreActivation()
        if not activation or not activation.creds then
            return nil, "Device ADEPT activation missing; please activate in Beeline settings"
        end
    end

    -- Reclaim any stale orphaned temp files before allocating space for a new session
    M.cleanupAllOrphans()

    local master_attr = lfs.attributes(master_path)
    local master_size = (master_attr and master_attr.size) or 0
    local required_bytes = master_size > 0 and math.floor(master_size * 2.5) or 0
    local temp_path = generateEphemeralPath(master_path, required_bytes)
    logger.info("beeline_ephemeral: preparing session " .. tostring(master_path) .. " -> " .. tostring(temp_path))

    local book_title = (tracked and tracked.title and tracked.title ~= "" and tracked.title)
        or (master_path:match("([^/\\]+)$") or master_path):gsub("%.[^%.]+$", "")

    local prog_toast = nil
    local status_msg = nil
    local show_ui = (opts and opts.show_ui == true)
    local ok_uim, UIManager = pcall(require, "ui/uimanager")
    if show_ui then
        local ok_bui, BeelineUI = pcall(require, plugin_path .. "beeline_ui")
        if not ok_bui or not BeelineUI then
            ok_bui, BeelineUI = pcall(require, "beeline_ui")
        end
        if ok_bui and BeelineUI and type(BeelineUI.showProgressToast) == "function" then
            pcall(function()
                prog_toast = BeelineUI.showProgressToast(_("Opening Book"), book_title, "bee", 0.05)
            end)
        else
            local ok_im, InfoMessage = pcall(require, "ui/widget/infomessage")
            if ok_uim and ok_im and UIManager and InfoMessage and type(UIManager.show) == "function" then
                pcall(function()
                    status_msg = InfoMessage:new{ text = _("Decrypting book…"), timeout = 0 }
                    UIManager:show(status_msg)
                    if type(UIManager.forceRePaint) == "function" then
                        UIManager:forceRePaint()
                    end
                end)
            end
        end
    end

    local function onDecryptProgress(stage_or_frac, maybe_frac)
        if not prog_toast then return end
        local frac = (type(maybe_frac) == "number" and maybe_frac)
            or (type(stage_or_frac) == "number" and stage_or_frac)
        if frac then
            prog_toast:updateProgress(frac)
        end
    end

    local function runDecryption(target_path)
        return pcall(function()
            if isPdf then
                local pdf = require("beeline_adobe_pdf")
                local encKey = tracked and tracked.encrypted_key
                return pdf.decryptAdobePdf(master_path, target_path, nil, activation.creds.licenseKey, encKey, onDecryptProgress)
            else
                -- 1. Resolve book key
                local bookKey = nil
                if has_cached_key then
                    local util = require("beeline_adobe_util")
                    bookKey = util.hex.decode(tracked.book_key_hex)
                elseif tracked and tracked.encrypted_key then
                    local fulfillment = require("beeline_adobe_fulfillment")
                    bookKey = fulfillment.decryptBookKey(tracked.encrypted_key, activation.creds.licenseKey)
                else
                    -- Extract from rights.xml
                    local encKey = epub.extractEncryptedKeyFromEpub(master_path)
                    if encKey then
                        local fulfillment = require("beeline_adobe_fulfillment")
                        bookKey = fulfillment.decryptBookKey(encKey, activation.creds.licenseKey)
                    end
                end

                if not bookKey then
                    return nil, "Could not derive book decryption key from license"
                end

                return epub.decryptAdobeEpub(master_path, target_path, bookKey, onDecryptProgress)
            end
        end)
    end

    local ok_dec, dec_res, dec_err = runDecryption(temp_path)

    -- If writing to RAM tmpfs failed (e.g., ENOSPC / short write), retry once in persistent cache
    local dirs = getCandidateDirs()
    if (not ok_dec or not dec_res) and isRamPath(temp_path, dirs.cache) then
        local first_err = not ok_dec and tostring(dec_res) or tostring(dec_err or "decryption failed")
        secureRemove(temp_path)
        if ensureCacheDir(dirs.cache) then
            local cache_path = generateEphemeralPath(master_path, required_bytes, dirs.cache)
            logger.warn("beeline_ephemeral: RAM session prep failed (" .. first_err .. "); retrying in cache: " .. tostring(cache_path))
            temp_path = cache_path
            if prog_toast then
                pcall(function() prog_toast:updateProgress(0.05) end)
            end
            ok_dec, dec_res, dec_err = runDecryption(temp_path)
        end
    end

    if prog_toast then
        pcall(function()
            if ok_dec and dec_res then
                prog_toast:updateProgress(1.0)
            end
            prog_toast:close()
        end)
        prog_toast = nil
    end
    if status_msg and ok_uim and UIManager and type(UIManager.close) == "function" then
        pcall(function() UIManager:close(status_msg) end)
    end

    if not ok_dec or not dec_res then
        secureRemove(temp_path)
        local err_msg = not ok_dec and tostring(dec_res) or tostring(dec_err or "decryption failed")
        logger.err("beeline_ephemeral: session prep failed: " .. err_msg)
        return nil, err_msg
    end

    local out_attr = lfs.attributes(temp_path)
    if not out_attr or out_attr.mode ~= "file" or (out_attr.size ~= nil and out_attr.size == 0) then
        secureRemove(temp_path)
        logger.err("beeline_ephemeral: decrypted session output is missing or empty")
        return nil, "Decrypted book output was empty"
    end

    -- Register session mappings
    _ephem_to_master[temp_path]   = master_path
    _master_to_ephem[master_path] = temp_path
    if required_bytes > MAX_RAM_EPHEMERAL_BYTES and not isRamPath(temp_path, dirs.cache) then
        _warm_cached[temp_path] = true
    end

    logger.info("beeline_ephemeral: session ready at " .. tostring(temp_path))
    return temp_path
end

--- Closes session, shreds ephemeral RAM copy, and clears mappings
function M.cleanupSession(path)
    if not path or path == "" then return end

    local temp_path = nil
    local master_path = nil

    if _ephem_to_master[path] then
        temp_path = path
        master_path = _ephem_to_master[path]
    elseif _master_to_ephem[path] then
        master_path = path
        temp_path = _master_to_ephem[path]
    elseif path:find("bln_ephem_") then
        temp_path = path
    end

    if temp_path then
        logger.info("beeline_ephemeral: terminating session for " .. tostring(temp_path))
        secureRemove(temp_path)
        _ephem_to_master[temp_path] = nil
        _ephem_refs[temp_path] = nil
        _reader_owned[temp_path] = nil
        _warm_cached[temp_path] = nil
    end
    if master_path then
        M._last_master_path = master_path
        _master_to_ephem[master_path] = nil
    end
end

--- Terminates all active and warm-cached ephemeral sessions (called on KOReader exit)
function M.cleanupAllSessions()
    local to_clean = {}
    for temp_path in pairs(_ephem_to_master) do
        table.insert(to_clean, temp_path)
    end
    for _, temp_path in ipairs(to_clean) do
        M.cleanupSession(temp_path)
    end
    return M.cleanupAllOrphans()
end

-- ---------------------------------------------------------------------------
-- Sidecar Pre-Population (Cover Art & Metadata)
-- ---------------------------------------------------------------------------

--- Populates .sdr sidecar with cover.jpg and metadata.epub.lua so File Manager displays
--- complete cover and metadata without needing to decrypt the book
function M.populateSidecar(outputPath, acsm_meta, cover_data, cover_ext)
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds or not DocSettings then return end

    local sidecar_dir = DocSettings:getSidecarDir(outputPath, "doc")
    local ok_lfs, klfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, klfs = pcall(require, "lfs") end
    if klfs and klfs.mkdir then
        pcall(klfs.mkdir, sidecar_dir)
    end
    pcall(os.execute, "mkdir -p '" .. sidecar_dir .. "' 2>/dev/null")

    -- 1. Save cover image (valid image format only)
    local function isKnownImage(bytes)
        if not bytes or #bytes < 4 then return false end
        if bytes:byte(1) == 0xFF and bytes:byte(2) == 0xD8 and bytes:byte(3) == 0xFF then
            return true, "jpg"
        end
        if bytes:byte(1) == 0x89 and bytes:byte(2) == 0x50 and bytes:byte(3) == 0x4E and bytes:byte(4) == 0x47 then
            return true, "png"
        end
        if bytes:sub(1, 4) == "GIF8" then
            return true, "gif"
        end
        if #bytes >= 12 and bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP" then
            return true, "webp"
        end
        return false
    end

    if cover_data and #cover_data > 0 then
        local isValid, detectedExt = isKnownImage(cover_data)
        if isValid then
            cover_ext = detectedExt or cover_ext or "jpg"
            local cover_path = sidecar_dir .. "/cover." .. cover_ext
            local f = io.open(cover_path, "wb")
            if f then
                f:write(cover_data)
                f:close()
            end
        else
            logger.warn("beeline_ephemeral: skipping cover image with unrecognized format")
        end
    end

    -- Sanitize sidecar: remove any corrupt or ciphertext cover files
    if klfs and klfs.dir then
        pcall(function()
            for fname in klfs.dir(sidecar_dir) do
                if fname:match("^cover%.") then
                    local fpath = sidecar_dir .. "/" .. fname
                    local f = io.open(fpath, "rb")
                    if f then
                        local head = f:read(16) or ""
                        f:close()
                        if not isKnownImage(head) then
                            logger.info("beeline_ephemeral: removing corrupt cover file " .. fpath)
                            os.remove(fpath)
                        end
                    end
                end
            end
        end)
    end

    -- 2. Populate metadata.epub.lua
    if acsm_meta then
        local doc_settings = DocSettings:open(outputPath)
        if doc_settings and doc_settings.saveSetting then
            local props = {
                title = acsm_meta.title or "Book",
                authors = acsm_meta.creator or "",
                description = acsm_meta.description or "",
                language = acsm_meta.language or "en",
            }
            doc_settings:saveSetting("doc_props", props)
            pcall(function() doc_settings:flush() end)
        end
    end
end

-- ---------------------------------------------------------------------------
-- KOReader Transparent Lifecycle Hooks
-- ---------------------------------------------------------------------------

--- Installs hooks into ReaderUI, FileManager, DocumentRegistry, DocSettings, ReadHistory, and BookList
function M.installHooks()
    if _hooks_installed then return end

    -- 1. Hook FileManager:openFile & showFiles
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FileManager and FileManager.openFile then
        local orig_fm_openFile = FileManager.openFile
        FileManager.openFile = function(self_fm, file, provider, doc_caller_callback, aux_caller_callback, after_open_callback)
            if file and State.getDrmKeepEncrypted() and M.isAdeptEncrypted(file) then
                local temp_file, err = M.prepareSession(file, { show_ui = true })
                if temp_file then
                    _reader_owned[temp_file] = true
                    return orig_fm_openFile(self_fm, temp_file, provider, doc_caller_callback, aux_caller_callback, after_open_callback)
                else
                    logger.err("beeline_ephemeral: FileManager could not decrypt ADEPT book: " .. tostring(err))
                    local ok_uim, UIManager = pcall(require, "ui/uimanager")
                    local ok_im, InfoMessage = pcall(require, "ui/widget/infomessage")
                    if ok_uim and ok_im and UIManager and InfoMessage then
                        UIManager:show(InfoMessage:new{
                            text = _("Could not open ADEPT book:\n%s", tostring(err))
                        })
                    end
                    return
                end
            end
            return orig_fm_openFile(self_fm, file, provider, doc_caller_callback, aux_caller_callback, after_open_callback)
        end

        local orig_showFiles = FileManager.showFiles
        if orig_showFiles then
            FileManager.showFiles = function(self_fm, path, focused_file, selected_files)
                if focused_file then
                    local res_focus = M.getMasterPath(focused_file)
                    if res_focus ~= focused_file then
                        focused_file = res_focus
                        local ok_u, util = pcall(require, "util")
                        if ok_u and util and util.splitFilePathName then
                            path = util.splitFilePathName(res_focus)
                        end
                    end
                elseif path and (path == "/tmp" or path:match("^/tmp/bln_ephem_")) and M._last_master_path then
                    local ok_u, util = pcall(require, "util")
                    if ok_u and util and util.splitFilePathName then
                        path, focused_file = util.splitFilePathName(M._last_master_path)
                    end
                end
                return orig_showFiles(self_fm, path, focused_file, selected_files)
            end
        end
        logger.info("beeline_ephemeral: FileManager hooks installed")
    end

    -- 1b. Hook FileChooser:changeToPath to prevent switching to /tmp on book exit
    local ok_fc, FileChooser = pcall(require, "ui/widget/filechooser")
    if ok_fc and FileChooser and FileChooser.changeToPath then
        local orig_changeToPath = FileChooser.changeToPath
        FileChooser.changeToPath = function(self_fc, path, focused_path)
            if focused_path then
                local res_focus = M.getMasterPath(focused_path)
                if res_focus ~= focused_path then
                    focused_path = res_focus
                    local ok_u, util = pcall(require, "util")
                    if ok_u and util and util.splitFilePathName then
                        path = util.splitFilePathName(res_focus)
                    end
                end
            end
            if path and (path == "/tmp" or path:match("^/tmp/bln_ephem_") or path:match("/bln_ephem_")) and M._last_master_path then
                local ok_u, util = pcall(require, "util")
                if ok_u and util and util.splitFilePathName then
                    path, focused_path = util.splitFilePathName(M._last_master_path)
                end
            end
            return orig_changeToPath(self_fc, path, focused_path)
        end
        logger.info("beeline_ephemeral: FileChooser hooks installed")
    end

    -- 1c. Hook G_reader_settings to prevent saving /tmp or ephemeral files as lastdir / lastfile
    if G_reader_settings and G_reader_settings.saveSetting then
        local orig_saveSetting = G_reader_settings.saveSetting
        G_reader_settings.saveSetting = function(self_s, key, value)
            if key == "lastdir" and value and (value == "/tmp" or value:match("bln_ephem_")) then
                if M._last_master_path then
                    local ok_u, util = pcall(require, "util")
                    if ok_u and util and util.splitFilePathName then
                        value = util.splitFilePathName(M._last_master_path)
                    else
                        return
                    end
                else
                    return
                end
            elseif key == "lastfile" and value and (value:match("bln_ephem_")) then
                if M._last_master_path then
                    value = M._last_master_path
                else
                    return
                end
            end
            return orig_saveSetting(self_s, key, value)
        end
    end

    -- 2. Hook DocumentRegistry:openDocument
    local ok_dr, DocumentRegistry = pcall(require, "document/documentregistry")
    if ok_dr and DocumentRegistry and DocumentRegistry.openDocument then
        local orig_openDocument = DocumentRegistry.openDocument
        DocumentRegistry.openDocument = function(self_dr, file, provider)
            if file and State.getDrmKeepEncrypted() and M.isAdeptEncrypted(file) then
                local temp_file, err = M.prepareSession(file, { show_ui = false })
                if temp_file then
                    local doc, open_err = orig_openDocument(self_dr, temp_file, provider)
                    if not doc then
                        if not _reader_owned[temp_file] and (_ephem_refs[temp_file] or 0) <= 0 then
                            M.cleanupSession(temp_file)
                        end
                        return nil, open_err
                    end
                    if not _reader_owned[temp_file] and type(doc) == "table" and not doc._beeline_close_wrapped then
                        _ephem_refs[temp_file] = (_ephem_refs[temp_file] or 0) + 1
                        local orig_doc_close = doc.close
                        doc._beeline_close_wrapped = true
                        doc.close = function(self_doc, ...)
                            local res = nil
                            if type(orig_doc_close) == "function" then
                                res = orig_doc_close(self_doc, ...)
                            end
                            local rem = (_ephem_refs[temp_file] or 1) - 1
                            _ephem_refs[temp_file] = rem
                            if rem <= 0 and not _reader_owned[temp_file] then
                                M.cleanupSession(temp_file)
                            end
                            return res
                        end
                    end
                    return doc, open_err
                else
                    logger.err("beeline_ephemeral: DocumentRegistry could not decrypt ADEPT book: " .. tostring(err))
                    return nil, err or "Failed to decrypt ADEPT book"
                end
            end
            return orig_openDocument(self_dr, file, provider)
        end
        logger.info("beeline_ephemeral: DocumentRegistry hooks installed")
    end

    -- 3. Hook ReaderUI:showReader, switchDocument & onClose
    local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_rui and ReaderUI and ReaderUI.showReader then
        local orig_showReader = ReaderUI.showReader
        ReaderUI.showReader = function(self_rui, file, provider, seamless, is_provider_forced, after_open_callback)
            -- Handle call with dot (ReaderUI.showReader(file, ...)) vs colon (ReaderUI:showReader(file, ...))
            if type(self_rui) == "string" then
                after_open_callback = is_provider_forced
                is_provider_forced = seamless
                seamless = provider
                provider = file
                file = self_rui
                self_rui = ReaderUI
            end
            if file and State.getDrmKeepEncrypted() and M.isAdeptEncrypted(file) then
                local temp_file, err = M.prepareSession(file, { show_ui = true })
                if temp_file then
                    _reader_owned[temp_file] = true
                    return orig_showReader(self_rui, temp_file, provider, seamless, is_provider_forced, after_open_callback)
                else
                    logger.err("beeline_ephemeral: could not open ADEPT book: " .. tostring(err))
                    local ok_uim, UIManager = pcall(require, "ui/uimanager")
                    local ok_im, InfoMessage = pcall(require, "ui/widget/infomessage")
                    if ok_uim and ok_im and UIManager and InfoMessage then
                        UIManager:show(InfoMessage:new{
                            text = _("Could not open ADEPT book:\n%s", tostring(err))
                        })
                    end
                    return
                end
            end
            return orig_showReader(self_rui, file, provider, seamless, is_provider_forced, after_open_callback)
        end

        if ReaderUI.switchDocument then
            local orig_switchDocument = ReaderUI.switchDocument
            ReaderUI.switchDocument = function(self_rui, file, ...)
                if file and State.getDrmKeepEncrypted() and M.isAdeptEncrypted(file) then
                    local temp_file, err = M.prepareSession(file, { show_ui = true })
                    if temp_file then
                        _reader_owned[temp_file] = true
                        return orig_switchDocument(self_rui, temp_file, ...)
                    else
                        logger.err("beeline_ephemeral: switchDocument could not decrypt ADEPT book: " .. tostring(err))
                        local ok_uim, UIManager = pcall(require, "ui/uimanager")
                        local ok_im, InfoMessage = pcall(require, "ui/widget/infomessage")
                        if ok_uim and ok_im and UIManager and InfoMessage then
                            UIManager:show(InfoMessage:new{
                                text = _("Could not open ADEPT book:\n%s", tostring(err))
                            })
                        end
                        return nil
                    end
                end
                return orig_switchDocument(self_rui, file, ...)
            end
        end

        local orig_onClose = ReaderUI.onClose
        ReaderUI.onClose = function(self_rui, full_refresh)
            local current_file = self_rui.document and self_rui.document.file
            local master_file = current_file and M.getMasterPath(current_file)
            if master_file and master_file ~= current_file then
                M._last_master_path = master_file
            end
            if current_file then
                _reader_owned[current_file] = nil
                _ephem_refs[current_file] = nil
            end
            local res = orig_onClose(self_rui, full_refresh)
            if current_file and M.isEphemeralPath(current_file) then
                if _warm_cached[current_file] then
                    logger.info("beeline_ephemeral: keeping large book session warm in cache: " .. tostring(current_file))
                else
                    M.cleanupSession(current_file)
                end
            end
            return res
        end

        local orig_showFileManager = ReaderUI.showFileManager
        if orig_showFileManager then
            ReaderUI.showFileManager = function(self_rui, file, selected_files)
                local resolved = (file and M.getMasterPath(file)) or M._last_master_path
                if (not resolved or resolved == "" or resolved:match("bln_ephem_") or resolved == "/tmp") and M._last_master_path then
                    resolved = M._last_master_path
                end
                return orig_showFileManager(self_rui, resolved, selected_files)
            end
        end

        local orig_onHome = ReaderUI.onHome
        if orig_onHome then
            ReaderUI.onHome = function(self_rui)
                local current_file = self_rui.document and self_rui.document.file
                local master_file = current_file and M.getMasterPath(current_file)
                if master_file and master_file ~= current_file then
                    M._last_master_path = master_file
                    self_rui:onClose()
                    self_rui:showFileManager(master_file)
                    return true
                end
                return orig_onHome(self_rui)
            end
        end
        logger.info("beeline_ephemeral: ReaderUI hooks installed")
    end

    -- 4. Hook DocSettings:getSidecarDir & getSidecarFilename & open
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if ok_ds and DocSettings then
        local orig_getSidecarDir = DocSettings.getSidecarDir
        DocSettings.getSidecarDir = function(self_ds, doc_path, force_location)
            local resolved = M.getMasterPath(doc_path)
            return orig_getSidecarDir(self_ds, resolved, force_location)
        end

        local orig_getSidecarFilename = DocSettings.getSidecarFilename
        DocSettings.getSidecarFilename = function(doc_path)
            local resolved = M.getMasterPath(doc_path)
            return orig_getSidecarFilename(resolved)
        end

        local orig_open = DocSettings.open
        DocSettings.open = function(self_ds, doc_path)
            local resolved = M.getMasterPath(doc_path)
            return orig_open(self_ds, resolved)
        end
        logger.info("beeline_ephemeral: DocSettings hooks installed")
    end

    -- 5. Hook ReadHistory:addItem & updateLastBookTime
    local ok_rh, ReadHistory = pcall(require, "readhistory")
    if ok_rh and ReadHistory and ReadHistory.addItem then
        local orig_addItem = ReadHistory.addItem
        ReadHistory.addItem = function(self_rh, file, ts, no_flush)
            local resolved = M.getMasterPath(file)
            return orig_addItem(self_rh, resolved, ts, no_flush)
        end
        logger.info("beeline_ephemeral: ReadHistory hooks installed")
    end

    -- 6. Hook BookList cache
    local ok_bl, BookList = pcall(require, "ui/widget/booklist")
    if ok_bl and BookList and BookList.setBookInfoCacheProperty then
        local orig_setProp = BookList.setBookInfoCacheProperty
        BookList.setBookInfoCacheProperty = function(file, prop_name, prop_value)
            local resolved = M.getMasterPath(file)
            return orig_setProp(resolved, prop_name, prop_value)
        end
        local orig_setCache = BookList.setBookInfoCache
        if orig_setCache then
            BookList.setBookInfoCache = function(file, doc_settings)
                local resolved = M.getMasterPath(file)
                return orig_setCache(resolved, doc_settings)
            end
        end
        logger.info("beeline_ephemeral: BookList hooks installed")
    end

    _hooks_installed = true
end

-- Export internals for test verification
M._getEphemeralDir = getEphemeralDir
M._generateEphemeralPath = generateEphemeralPath
M._secureRemove = secureRemove
M._sanitizeReaderSettings = sanitizeReaderSettings
M._ephem_to_master = _ephem_to_master
M._master_to_ephem = _master_to_ephem
M._ephem_refs = _ephem_refs
M._reader_owned = _reader_owned

-- Auto-install hooks on require so protection is immediate
pcall(M.installHooks)

return M
