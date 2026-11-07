-- beeline_state.lua — Settings & Configuration Manager for Beeline

local M = {}

local function _getSettingsDir()
    local ok_ds, DS = pcall(require, "datastorage")
    local base = "/tmp"
    if ok_ds and DS and DS.getSettingsDir then
        local s = DS:getSettingsDir()
        if s and s ~= "" then base = s end
    end
    local dir = base .. "/beeline"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if ok_lfs and lfs and lfs.mkdir then
        pcall(lfs.mkdir, base)
        pcall(lfs.mkdir, dir)
    end
    pcall(os.execute, "mkdir -p " .. dir .. " 2>/dev/null")
    return dir
end

local function _settingsPath()
    return _getSettingsDir() .. "/settings.json"
end

local function _readJson(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()

    local ok_rj, rapidjson = pcall(require, "rapidjson")
    if ok_rj and rapidjson then
        local ok, data = pcall(rapidjson.decode, content)
        if ok and type(data) == "table" then return data end
    end
    local ok_j, json = pcall(require, "json")
    if ok_j and json then
        local ok, data = pcall(json.decode, content)
        if ok and type(data) == "table" then return data end
    end
    return nil
end

local function _writeJson(path, tbl)
    local raw = nil
    local ok_rj, rapidjson = pcall(require, "rapidjson")
    if ok_rj and rapidjson then
        pcall(function() raw = rapidjson.encode(tbl, { pretty = true }) end)
    end
    if not raw then
        local ok_j, json = pcall(require, "json")
        if ok_j and json then
            pcall(function() raw = json.encode(tbl) end)
        end
    end
    if not raw then
        -- Fallback minimal serialization
        local lines = { "{" }
        for k, v in pairs(tbl) do
            if type(v) == "string" then
                table.insert(lines, string.format('  "%s": "%s",', k, v:gsub('"', '\\"')))
            elseif type(v) == "boolean" or type(v) == "number" then
                table.insert(lines, string.format('  "%s": %s,', k, tostring(v)))
            end
        end
        table.insert(lines, "}")
        raw = table.concat(lines, "\n")
    end

    local f = io.open(path, "w")
    if f then
        f:write(raw)
        f:close()
        return true
    end
    return false
end

M.DEFAULT_WORKER_URL = "https://beeline.ultimatejimmy.workers.dev"
M.PAIRING_TTL = 15 * 60 -- 15 minutes session TTL
local CODE_CHARS = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"

local _cached_settings = nil

local function _generateRandomHex(num_bytes)
    num_bytes = num_bytes or 8
    math.randomseed(os.time() + math.floor(os.clock() * 100000))
    local hex = {}
    for i = 1, num_bytes do
        table.insert(hex, string.format("%02x", math.random(0, 255)))
    end
    return table.concat(hex)
end

function M.loadSettings()
    if _cached_settings then return _cached_settings end
    local s = _readJson(_settingsPath()) or {}

    -- Default inbox directory: KOReader home_dir/" Beeline" or data directory/" Beeline"
    if not s.inbox_dir or s.inbox_dir == "" or s.inbox_dir:match("/inbox$") or s.inbox_dir == "./inbox" or s.inbox_dir:match("/%s*[Ll]ibby$") then
        local home_dir = G_reader_settings and G_reader_settings:readSetting("home_dir")
        if home_dir and home_dir ~= "" then
            s.inbox_dir = home_dir .. "/ Beeline"
        else
            local ok_ds, DS = pcall(require, "datastorage")
            if ok_ds and DS and DS.getDataDir then
                s.inbox_dir = DS:getDataDir() .. "/ Beeline"
            else
                s.inbox_dir = "./ Beeline"
            end
        end
        _writeJson(_settingsPath(), s)
    end

    if not s.worker_url or s.worker_url == "" or s.worker_url == "https://nameless-grass-2b44.ultimatejimmy.workers.dev" then
        s.worker_url = M.DEFAULT_WORKER_URL
    end

    if s.auto_check_wifi == nil then
        s.auto_check_wifi = true
    end

    if s.background_sync == nil then
        s.background_sync = false
    end

    -- Persistent device identity
    if not s.device_id or s.device_id == "" then
        s.device_id = _generateRandomHex(8)
    end
    s.active_codes = s.active_codes or {}
    s.paired_browsers = s.paired_browsers or {}

    -- Migration: If paired_browsers is empty but active_codes has entries,
    -- preserve 1 paired browser entry (the latest non-pending code) and purge
    -- the unused historical ephemeral codes.
    local paired_count = 0
    for _ in pairs(s.paired_browsers) do paired_count = paired_count + 1 end
    if paired_count == 0 and s.active_codes then
        local latest_norm, latest_entry = nil, nil
        local cur_norm = s.pairing_code and s.pairing_code:upper():gsub("[%s%-]+", "")
        for norm, v in pairs(s.active_codes) do
            if norm ~= cur_norm and v and v.code then
                if not latest_entry or (v.created_at and v.created_at > (latest_entry.created_at or 0)) then
                    latest_norm = norm
                    latest_entry = v
                end
            end
        end
        if latest_norm and latest_entry then
            s.paired_browsers[latest_norm] = {
                code = latest_entry.code,
                paired_at = latest_entry.created_at or os.time(),
            }
            local cleaned_active = {}
            cleaned_active[latest_norm] = latest_entry
            if cur_norm then
                cleaned_active[cur_norm] = { code = s.pairing_code, created_at = s.code_created_at }
            end
            s.active_codes = cleaned_active
            _writeJson(_settingsPath(), s)
        end
    end

    -- Auto-generate or rotate pairing code if empty, legacy "BEE-", or expired
    local code_age = os.time() - (tonumber(s.code_created_at) or 0)
    local is_legacy = type(s.pairing_code) == "string" and s.pairing_code:match("^BEE%-") ~= nil
    if not s.pairing_code or s.pairing_code == "" or is_legacy or code_age >= M.PAIRING_TTL then
        s.pairing_code = M.generatePairingCode()
        _writeJson(_settingsPath(), s)
    end

    _cached_settings = s
    return s
end

function M.saveSettings(tbl)
    _cached_settings = tbl or _cached_settings or {}
    return _writeJson(_settingsPath(), _cached_settings)
end

function M.getDeviceId()
    local s = M.loadSettings()
    return s.device_id or ""
end

function M.isCodeExpired()
    local s = _cached_settings or M.loadSettings()
    local created = tonumber(s.code_created_at) or 0
    if created == 0 then return true end
    return (os.time() - created) >= M.PAIRING_TTL
end

function M.getCodeSecondsRemaining()
    local s = _cached_settings or M.loadSettings()
    local created = tonumber(s.code_created_at) or 0
    if created == 0 then return 0 end
    local remaining = M.PAIRING_TTL - (os.time() - created)
    return math.max(0, remaining)
end

function M.getPairingCode()
    local s = M.loadSettings()
    if M.isCodeExpired() then
        return M.generatePairingCode()
    end
    return s.pairing_code or ""
end

function M.getActiveCodes()
    local s = M.loadSettings()
    local list = {}
    local seen = {}

    if s.pairing_code and s.pairing_code ~= "" then
        table.insert(list, s.pairing_code)
        local n = s.pairing_code:upper():gsub("[%s%-]+", "")
        seen[n] = true
    end
    if s.paired_browsers then
        for norm, v in pairs(s.paired_browsers) do
            if not seen[norm] and v and v.code then
                table.insert(list, v.code)
                seen[norm] = true
            end
        end
    end
    if s.active_codes then
        for norm, v in pairs(s.active_codes) do
            if not seen[norm] and v and v.code then
                table.insert(list, v.code)
                seen[norm] = true
            end
        end
    end
    return list
end

function M.addPairedBrowser(code)
    if not code or code == "" then return end
    local s = M.loadSettings()
    local norm = code:upper():gsub("[%s%-]+", "")
    s.paired_browsers = s.paired_browsers or {}
    s.paired_browsers[norm] = {
        code = code,
        paired_at = os.time(),
    }
    s.active_codes = s.active_codes or {}
    s.active_codes[norm] = {
        code = code,
        created_at = os.time(),
    }
    M.saveSettings(s)
end

function M.getPairedBrowserCount()
    local s = M.loadSettings()
    local count = 0
    if s.paired_browsers then
        for _ in pairs(s.paired_browsers) do
            count = count + 1
        end
    end
    return count
end

function M.unpairAllDevices()
    local s = M.loadSettings()
    local old_device_id = s.device_id or ""
    s.device_id = _generateRandomHex(8)
    s.active_codes = {}
    s.paired_browsers = {}
    s.pairing_code = nil
    s.code_created_at = 0
    local new_code = M.generatePairingCode()
    M.saveSettings(s)
    return old_device_id, new_code
end

function M.setPairingCode(code)
    local s = M.loadSettings()
    s.pairing_code = (code or ""):upper():gsub("[%s%-]+", "")
    s.code_created_at = os.time()
    M.saveSettings(s)
end

function M.generatePairingCode()
    math.randomseed(os.time() + math.floor(os.clock() * 100000))
    local c = {}
    for i = 1, 6 do
        local idx = math.random(1, #CODE_CHARS)
        table.insert(c, CODE_CHARS:sub(idx, idx))
    end
    local code = string.format("%s%s%s-%s%s%s", c[1], c[2], c[3], c[4], c[5], c[6])
    local norm = (c[1]..c[2]..c[3]..c[4]..c[5]..c[6]):upper()
    local s = _cached_settings or {}
    s.pairing_code = code
    s.code_created_at = os.time()
    -- Only register the current active code for decryption; do not falsely mark as paired
    s.active_codes = s.active_codes or {}
    s.active_codes[norm] = {
        code = code,
        created_at = os.time(),
    }
    M.saveSettings(s)
    return code
end

function M.regeneratePairingCode()
    return M.generatePairingCode()
end

function M.getWorkerUrl()
    local s = M.loadSettings()
    return s.worker_url or ""
end

function M.setWorkerUrl(url)
    local s = M.loadSettings()
    -- Trim whitespace, newlines, and trailing slash
    s.worker_url = (url or ""):gsub("[\r\n\t ]+", ""):gsub("/+$", "")
    M.saveSettings(s)
end

function M.getInboxDir()
    local s = M.loadSettings()
    return s.inbox_dir
end

function M.setInboxDir(dir)
    local s = M.loadSettings()
    s.inbox_dir = dir
    M.saveSettings(s)
end

function M.getAutoCheckWifi()
    local s = M.loadSettings()
    return s.auto_check_wifi ~= false
end

function M.setAutoCheckWifi(enabled)
    local s = M.loadSettings()
    s.auto_check_wifi = (enabled == true)
    M.saveSettings(s)
end

function M.getBackgroundSync()
    local s = M.loadSettings()
    return s.background_sync == true
end

function M.setBackgroundSync(enabled)
    local s = M.loadSettings()
    s.background_sync = (enabled == true)
    M.saveSettings(s)
end

-- ---------------------------------------------------------------------------
-- ACSM / ADEPT DRM & Tracking State
-- ---------------------------------------------------------------------------

function M.getDrmConsentVersion()
    local s = M.loadSettings()
    return s.drm_consent_version
end

function M.setDrmConsentVersion(ver)
    local s = M.loadSettings()
    s.drm_consent_version = ver
    M.saveSettings(s)
end

function M.getDrmActivation()
    local s = M.loadSettings()
    return s.drm_activation
end

function M.saveDrmActivation(activation_blob, mode, email)
    local s = M.loadSettings()
    s.drm_activation = activation_blob
    s.drm_mode       = mode or "anonymous"
    s.drm_account_email = email or ""
    s.drm_updated_at = os.time()
    return M.saveSettings(s)
end

function M.getDrmAccountInfo()
    local s = M.loadSettings()
    return {
        activated = (s.drm_activation ~= nil),
        mode      = s.drm_mode or "anonymous",
        email     = s.drm_account_email or "",
        serial    = s.drm_device_serial or "",
        updated_at = s.drm_updated_at,
    }
end

function M.clearDrmActivation()
    local s = M.loadSettings()
    s.drm_activation = nil
    s.drm_mode       = "anonymous"
    s.drm_account_email = nil
    s.drm_updated_at = nil
    return M.saveSettings(s)
end

function M.getDrmMode()
    local s = M.loadSettings()
    return s.drm_mode or "anonymous"
end

function M.setDrmMode(mode)
    local s = M.loadSettings()
    s.drm_mode = mode or "anonymous"
    M.saveSettings(s)
end

function M.getDrmDeviceSerial()
    local s = M.loadSettings()
    return s.drm_device_serial
end

function M.setDrmDeviceSerial(serial)
    local s = M.loadSettings()
    s.drm_device_serial = serial
    M.saveSettings(s)
end

function M.getDrmDefaultLoanDays()
    local s = M.loadSettings()
    return tonumber(s.drm_default_loan_days) or 21
end

function M.setDrmDefaultLoanDays(days)
    local s = M.loadSettings()
    s.drm_default_loan_days = tonumber(days) or 21
    M.saveSettings(s)
end

function M.getDrmDeleteAcsmAfter()
    -- Always delete ACSM after fulfillment (automatic, not configurable)
    return true
end

function M.setDrmDeleteAcsmAfter(enabled)
    local s = M.loadSettings()
    s.drm_delete_acsm_after = true
    M.saveSettings(s)
end

function M.getDrmKeepEncrypted()
    -- Always keep ADEPT books encrypted on disk at rest (automatic, not configurable)
    return true
end

function M.setDrmKeepEncrypted(enabled)
    local s = M.loadSettings()
    s.drm_keep_encrypted = true
    M.saveSettings(s)
end

function M.getTrackedBooks()
    local s = M.loadSettings()
    return s.drm_tracked or {}
end

function M.getTrackedBook(path)
    if not path or path == "" then return nil end
    local s = M.loadSettings()
    if not s.drm_tracked then return nil end

    local ok_u, ffiUtil = pcall(require, "ffi/util")
    local norm_path = (ok_u and ffiUtil and ffiUtil.realpath and ffiUtil.realpath(path)) or path
    local basename = path:match("([^/\\]+)$")

    for _, item in ipairs(s.drm_tracked) do
        if item.path == path or item.path == norm_path then
            return item
        end
        if basename and item.path and item.path:match("([^/\\]+)$") == basename then
            return item
        end
    end
    return nil
end

function M.isBookAdept(path)
    local item = M.getTrackedBook(path)
    if item and item.is_adept ~= nil then
        return item.is_adept == true
    end
    return false
end

function M.trackBook(path, expires, title, extra)
    if not path or path == "" then return false end
    local s = M.loadSettings()
    s.drm_tracked = s.drm_tracked or {}
    
    local found = false
    for _, item in ipairs(s.drm_tracked) do
        if item.path == path then
            item.expires = expires
            item.title = title or item.title
            if type(extra) == "table" then
                for k, v in pairs(extra) do
                    item[k] = v
                end
            end
            found = true
            break
        end
    end
    if not found then
        local entry = {
            path = path,
            expires = expires,
            title = title or "",
            tracked_at = os.time(),
        }
        if type(extra) == "table" then
            for k, v in pairs(extra) do
                entry[k] = v
            end
        end
        table.insert(s.drm_tracked, entry)
    end
    return M.saveSettings(s)
end

function M.untrackBook(path)
    if not path or path == "" then return false end
    local s = M.loadSettings()
    if not s.drm_tracked then return true end
    local new_tracked = {}
    for _, item in ipairs(s.drm_tracked) do
        if item.path ~= path then
            table.insert(new_tracked, item)
        end
    end
    s.drm_tracked = new_tracked
    return M.saveSettings(s)
end

return M
