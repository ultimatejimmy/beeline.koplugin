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
local _hooks_installed = false

-- ---------------------------------------------------------------------------
-- Ephemeral Path & Orphan Management
-- ---------------------------------------------------------------------------

--- Resolves the directory for volatile ephemeral files (prefers /tmp ramdisk)
local function getEphemeralDir()
    local ok_ds, DS = pcall(require, "datastorage")
    local candidates = {
        "/tmp",
        "/dev/shm",
        "/var/tmp",
    }
    for _, dir in ipairs(candidates) do
        if lfs.attributes(dir, "mode") == "directory" then
            return dir
        end
    end
    -- Fallback to KOReader cache directory if /tmp is not available
    local base = (ok_ds and DS and DS.getDataDir and DS:getDataDir()) or "/tmp"
    local cache_dir = base .. "/cache/beeline.koplugin/ephemeral"
    pcall(os.execute, "mkdir -p '" .. cache_dir .. "' 2>/dev/null")
    return cache_dir
end

--- Generates a unique ephemeral file path in volatile RAM
local function generateEphemeralPath(master_path)
    local dir = getEphemeralDir()
    local filename = master_path and (master_path:match("([^/\\]+)$") or "book.epub") or "book.epub"
    local base, ext = filename:match("^(.+)(%..+)$")
    base = base or filename
    ext = ext or (master_path and master_path:match("(%.[^%.]+)$") or ".epub")

    -- Sanitize filesystem-hostile characters while keeping book title readable
    base = base:gsub('[/\\:*?"<>|]', "_")

    -- Keep a short hex salt to guarantee uniqueness if opened multiple times concurrently
    math.randomseed(os.time() + math.floor(os.clock() * 100000))
    local rand_hex = string.format("%04x", math.random(0, 0xFFFF))
    return string.format("%s/bln_ephem_%s_%s%s", dir, base, rand_hex, ext)
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

--- Cleans up all orphaned ephemeral files from previous crashes or ungraceful reboots
function M.cleanupAllOrphans()
    local dir = getEphemeralDir()
    if not dir or lfs.attributes(dir, "mode") ~= "directory" then return 0 end

    local cleaned = 0
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
        -- Quick probe for EPUB: check if rights.xml or adept encryption.xml exists
        local ok_arch, Archiver = pcall(require, "ffi/archiver")
        if ok_arch and Archiver and Archiver.Reader then
            local reader = Archiver.Reader:new()
            if reader:open(file_path) then
                local has_rights = (reader:extractToMemory("META-INF/rights.xml") ~= nil)
                local has_adept_enc = false
                if not has_rights then
                    local enc_xml = reader:extractToMemory("META-INF/encryption.xml")
                    if enc_xml and (enc_xml:find("http://ns.adobe.com/adept", 1, true) or enc_xml:find("xmlns:adept", 1, true)) then
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

--- Decrypts master book into volatile RAM (/tmp) and registers reading session
function M.prepareSession(master_path)
    if not master_path or master_path == "" then
        return nil, "No master path provided"
    end

    -- Return existing active session if already opened
    if _master_to_ephem[master_path] and lfs.attributes(_master_to_ephem[master_path], "mode") == "file" then
        return _master_to_ephem[master_path]
    end

    local activation = DRM.restoreActivation()
    if not activation or not activation.creds then
        return nil, "Device ADEPT activation missing; please activate in Beeline settings"
    end

    local temp_path = generateEphemeralPath(master_path)
    logger.info("beeline_ephemeral: preparing session " .. tostring(master_path) .. " -> " .. tostring(temp_path))

    local isPdf = (master_path:lower():match("%.pdf$") ~= nil)

    local ok_dec, dec_res, dec_err = pcall(function()
        if isPdf then
            local pdf = require("beeline_adobe_pdf")
            local tracked = State.getTrackedBook(master_path)
            local encKey = tracked and tracked.encrypted_key
            return pdf.decryptAdobePdf(master_path, temp_path, nil, activation.creds.licenseKey, encKey)
        else
            -- 1. Resolve book key
            local bookKey = nil
            local tracked = State.getTrackedBook(master_path)
            if tracked and tracked.book_key_hex then
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

            return epub.decryptAdobeEpub(master_path, temp_path, bookKey)
        end
    end)

    if not ok_dec or not dec_res then
        secureRemove(temp_path)
        local err_msg = not ok_dec and tostring(dec_res) or tostring(dec_err or "decryption failed")
        logger.err("beeline_ephemeral: session prep failed: " .. err_msg)
        return nil, err_msg
    end

    -- Register session mappings
    _ephem_to_master[temp_path]   = master_path
    _master_to_ephem[master_path] = temp_path

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
    end
    if master_path then
        M._last_master_path = master_path
        _master_to_ephem[master_path] = nil
    end
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
                local temp_file, err = M.prepareSession(file)
                if temp_file then
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
                local temp_file, err = M.prepareSession(file)
                if temp_file then
                    return orig_openDocument(self_dr, temp_file, provider)
                else
                    logger.err("beeline_ephemeral: DocumentRegistry could not decrypt ADEPT book: " .. tostring(err))
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
                local temp_file, err = M.prepareSession(file)
                if temp_file then
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
                    local temp_file, err = M.prepareSession(file)
                    if temp_file then
                        return orig_switchDocument(self_rui, temp_file, ...)
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
            local res = orig_onClose(self_rui, full_refresh)
            if current_file and M.isEphemeralPath(current_file) then
                M.cleanupSession(current_file)
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
M._ephem_to_master = _ephem_to_master
M._master_to_ephem = _master_to_ephem

-- Auto-install hooks on require so protection is immediate
pcall(M.installHooks)

return M
