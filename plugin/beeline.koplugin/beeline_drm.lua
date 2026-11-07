-- beeline_drm.lua — Embedded ACSM Fulfillment & DRM Manager for Beeline
-- Handles Adobe & ByteBooks ADEPT activation (Anonymous default & ByteBooks account)
-- and direct ACSM -> EPUB/PDF fulfillment. Passwords are NEVER stored.

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local State = require(plugin_path .. "beeline_state")

-- Resolve base directory of the plugin to configure package.path for submodules
local info = debug.getinfo(1, "S")
local plugin_root = (info and info.source and info.source:match("^@(.*[/\\])")) or "./"
plugin_root = plugin_root:gsub("[/\\]+$", "")

-- Ensure plugin root is in package.path
local extra_paths = {
    plugin_root .. "/?.lua",
}
for _, p in ipairs(extra_paths) do
    if not package.path:find(p, 1, true) then
        package.path = p .. ";" .. package.path
    end
end

local adobe = require("beeline_adobe_core")
local fulfillment = require("beeline_adobe_fulfillment")
local naming = require("beeline_adobe_naming")
local xml = require("beeline_adobe_xml")

local ok_logger, logger = pcall(require, "logger")
local log = ok_logger and logger or {
    info = function(...) print("[INFO]", ...) end,
    warn = function(...) print("[WARN]", ...) end,
    err = function(...) print("[ERR]", ...) end,
}

local M = {}

local function _isActivationError(err)
    if type(err) ~= "string" then return false end
    return err:find("E_ADEPT_USER_AUTH", 1, true) ~= nil
        or err:find("E_ADEPT_DISTRIBUTOR_AUTH", 1, true) ~= nil
        or err:find("E_ADEPT_REQUEST_EXPIRED", 1, true) ~= nil
        or err:find("E_ADEPT", 1, true) ~= nil
end

-- ---------------------------------------------------------------------------
-- Activation Lifecycle
-- ---------------------------------------------------------------------------

--- Restores activation from State, or nil if none saved
function M.restoreActivation()
    local saved = State.getDrmActivation()
    if not saved then return nil end
    local restored, err = adobe.restoreActivation(saved)
    if not restored then
        log.warn("beeline_drm: could not restore saved activation: " .. tostring(err))
        State.clearDrmActivation()
        return nil
    end
    return restored
end

--- Generates a random device serial if none exists in state
function M.getOrCreateDeviceSerial()
    local serial = State.getDrmDeviceSerial()
    if serial and serial ~= "" then return serial end

    math.randomseed(os.time() + math.floor(os.clock() * 100000))
    local hex = {}
    for i = 1, 8 do
        table.insert(hex, string.format("%02x", math.random(0, 255)))
    end
    serial = "BLN-" .. table.concat(hex):upper()
    State.setDrmDeviceSerial(serial)
    return serial
end

--- Performs Anonymous ADEPT activation against Adobe's default servers
function M.createAnonymousActivation()
    local serial = M.getOrCreateDeviceSerial()
    log.info("beeline_drm: creating anonymous ADEPT activation (serial=" .. tostring(serial) .. ")")

    local auth_info, authErr = adobe.getAuthenticationServiceInfo()
    if not auth_info then
        return nil, "Could not fetch authentication service info: " .. tostring(authErr)
    end

    local creds, signInErr = adobe.signIn("anonymous", "", "", auth_info.certificate)
    if not creds then
        return nil, "Anonymous sign-in failed: " .. tostring(signInErr)
    end

    local device_uuid, fingerprintOrErr = adobe.activate(creds.user, creds.deviceKey, creds.pkcs12, serial)
    if not device_uuid then
        return nil, "Device registration failed: " .. tostring(fingerprintOrErr)
    end

    local fingerprint = fingerprintOrErr
    local serialized, serializeErr = adobe.serializeActivation(creds, device_uuid, fingerprint, auth_info.certificate, creds.activationURL)
    if not serialized then
        return nil, "Serialization failed: " .. tostring(serializeErr)
    end

    State.saveDrmActivation(serialized, "anonymous", "")
    log.info("beeline_drm: anonymous activation successful (uuid=" .. tostring(device_uuid) .. ")")

    return {
        creds = creds,
        deviceUUID = device_uuid,
        fingerprint = fingerprint,
        authCert = auth_info.certificate,
    }
end

--- Authorizes a ByteBooks ADEPT account with username & password
--- Note: Passwords are NEVER saved to disk or state!
function M.authorizeByteBooks(username, password)
    if not username or username == "" or not password or password == "" then
        return nil, "Missing username or password"
    end

    local serial = M.getOrCreateDeviceSerial()
    log.info("beeline_drm: authorizing ByteBooks account for " .. tostring(username))

    local auth_info, authErr = adobe.getAuthenticationServiceInfo()
    if not auth_info then
        return nil, "Could not reach ByteBooks authentication service: " .. tostring(authErr)
    end

    local method = "AdobeID"
    if auth_info.methods and #auth_info.methods > 0 then
        for _, m in ipairs(auth_info.methods) do
            if m.method and (m.method == "AdobeID" or m.method:lower():find("adobe", 1, true) or m.method:lower():find("bytebooks", 1, true)) then
                method = m.method
                break
            end
        end
    end

    local creds, signInErr = adobe.signIn(method, username, password, auth_info.certificate)
    if not creds then
        return nil, "ByteBooks authorization failed: " .. tostring(signInErr)
    end

    local device_uuid, fingerprintOrErr = adobe.activate(creds.user, creds.deviceKey, creds.pkcs12, serial)
    if not device_uuid then
        return nil, "Device registration failed: " .. tostring(fingerprintOrErr)
    end

    local fingerprint = fingerprintOrErr
    local serialized, serializeErr = adobe.serializeActivation(creds, device_uuid, fingerprint, auth_info.certificate, creds.activationURL)
    if not serialized then
        return nil, "Serialization failed: " .. tostring(serializeErr)
    end

    State.saveDrmActivation(serialized, "bytebooks", username)
    log.info("beeline_drm: ByteBooks authorization successful for " .. tostring(username))

    return {
        creds = creds,
        deviceUUID = device_uuid,
        fingerprint = fingerprint,
        authCert = auth_info.certificate,
    }
end

--- Deauthorizes device and clears persisted activation
function M.deauthorize()
    local saved = State.getDrmActivation()
    if saved then
        local restored = adobe.restoreActivation(saved)
        if restored and restored.creds and restored.deviceUUID and restored.fingerprint then
            pcall(adobe.deactivate, restored.creds, restored.deviceUUID, restored.fingerprint)
        end
    end
    State.clearDrmActivation()
    log.info("beeline_drm: device deauthorized")
    return true
end

--- Returns account information table
function M.getAccountInfo()
    return State.getDrmAccountInfo()
end

--- Ensures an active device activation exists (creates anonymous if none)
function M.ensureActivated(force_new)
    if not force_new then
        local existing = M.restoreActivation()
        if existing then
            return existing, true
        end
    end
    local created, err = M.createAnonymousActivation()
    return created, false, err
end

-- ---------------------------------------------------------------------------
-- ACSM Metadata & Output Path Helpers
-- ---------------------------------------------------------------------------

local function _firstMetadataValue(meta, key)
    if type(meta) ~= "table" then return nil end
    local raw = meta[key] or meta[key:gsub("^.-:", "")] or meta["adept:" .. key]
    if raw == nil then
        for k, v in pairs(meta) do
            if type(k) == "string" and (k == key or k:match(":" .. key:gsub("^.-:", "") .. "$")) then
                raw = v
                break
            end
        end
    end
    if type(raw) == "table" then return raw[1] end
    if type(raw) == "string" then return raw end
    return nil
end

local function _getField(t, name)
    if type(t) ~= "table" then return nil end
    local d = t[name] or t["adept:" .. name]
    if d ~= nil then return d end
    for k, v in pairs(t) do
        if type(k) == "string" and (k == name or k:match(":" .. name .. "$")) then
            return v
        end
    end
    return nil
end

function M.parseAcsmMetadata(acsm_path_or_content)
    local raw_data = acsm_path_or_content
    local f = io.open(acsm_path_or_content, "rb")
    if f then
        raw_data = f:read("*a")
        f:close()
    end

    if type(raw_data) ~= "string" or raw_data == "" then return nil end

    local ok, parsed = pcall(xml.deserialize, raw_data)
    if not ok or type(parsed) ~= "table" then return nil end

    local token = parsed.fulfillmentToken or parsed["adept:fulfillmentToken"]
    if not token then
        for k, v in pairs(parsed) do
            if type(k) == "string" and (k:match("fulfillmentToken$") or k:match("licenseToken$")) then
                token = v
                break
            end
        end
    end
    if not token or type(token) ~= "table" then return nil end

    local rii = _getField(token, "resourceItemInfo")
    if not rii then return nil end

    local resource = _getField(rii, "resource")
    local meta = _getField(rii, "metadata")
    local resource_item = _getField(rii, "resourceItem")
    local asset = resource_item and _getField(resource_item, "asset")

    -- Check licenseToken permissions duration
    local duration = nil
    local licenseToken = _getField(rii, "licenseToken")
    if licenseToken then
        local perms = _getField(licenseToken, "permissions")
        if perms then
            local display = _getField(perms, "display")
            if display then
                local dur = _getField(display, "duration")
                if type(dur) == "table" then dur = dur[1] end
                duration = tonumber(dur)
            end
        end
    end

    local purchase = _getField(token, "purchase")
    if type(purchase) == "table" then purchase = purchase[1] end

    return {
        title = _firstMetadataValue(meta, "dc:title"),
        creator = _firstMetadataValue(meta, "dc:creator"),
        identifier = _firstMetadataValue(meta, "dc:identifier"),
        publisher = _firstMetadataValue(meta, "dc:publisher"),
        language = _firstMetadataValue(meta, "dc:language"),
        subject = _firstMetadataValue(meta, "dc:subject"),
        description = _firstMetadataValue(meta, "dc:description"),
        resourceId = type(resource) == "table" and resource[1] or resource,
        format = _firstMetadataValue(meta, "dc:format") or (asset and (asset.assetType or _getField(asset, "assetType"))),
        duration = duration,
        purchase = purchase,
    }
end

--- Extracts loan expiry timestamp (unix timestamp) from ACSM metadata or rights.xml
--- Fallback calculates (now + default_loan_days * 86400)
function M.extractLoanExpiry(acsm_path_or_meta, default_days)
    default_days = default_days or State.getDrmDefaultLoanDays()
    local now_ts = os.time()

    local meta = acsm_path_or_meta
    if type(acsm_path_or_meta) == "string" then
        meta = M.parseAcsmMetadata(acsm_path_or_meta)
    end

    if meta and meta.duration and meta.duration > 0 then
        -- Check if we can parse purchase timestamp
        local purchase_ts = nil
        if meta.purchase and type(meta.purchase) == "string" then
            local y, m, d, h, min, sec = meta.purchase:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
            if y then
                purchase_ts = os.time({
                    year = tonumber(y),
                    month = tonumber(m),
                    day = tonumber(d),
                    hour = tonumber(h),
                    min = tonumber(min),
                    sec = tonumber(sec),
                })
            end
        end
        local start = purchase_ts or now_ts
        return start + meta.duration
    end

    -- Fallback: now + default_days
    return now_ts + (default_days * 86400)
end

function M.deriveFinalBookPath(base_dir, acsm_meta)
    local ext = ".epub"
    if acsm_meta and acsm_meta.format then
        local fmt = acsm_meta.format
        if type(fmt) == "table" then fmt = fmt[1] end
        if fmt == "application/pdf" then ext = ".pdf" end
    end

    local title = (acsm_meta and acsm_meta.title) or "book"
    local safe_title = naming.sanitizeTitle(title) or title:gsub('[/\\:*?"<>|]', "_"):gsub("%s+", "_")
    if #safe_title > 60 then safe_title = safe_title:sub(1, 60) end

    local path = base_dir .. "/" .. safe_title .. ext
    local f = io.open(path, "r")
    if not f then return path end
    f:close()

    for i = 1, 999 do
        local candidate = base_dir .. "/" .. safe_title .. " (" .. i .. ")" .. ext
        local cf = io.open(candidate, "r")
        if not cf then return candidate end
        cf:close()
    end

    return path
end

-- ---------------------------------------------------------------------------
-- Fulfillment Engine
-- ---------------------------------------------------------------------------

--- Fulfills an ACSM file into a decrypted, ready-to-read EPUB or PDF
function M.fulfillAcsm(acsm_path, output_path, progress_fn)
    log.info("beeline_drm: fulfilling ACSM at " .. tostring(acsm_path) .. " -> " .. tostring(output_path))
    local activation, reused, act_err = M.ensureActivated(false)
    if not activation then
        return nil, act_err or "Could not initialize DRM activation"
    end

    local result, err = fulfillment.process(
        acsm_path,
        output_path,
        activation.creds,
        activation.deviceUUID,
        activation.fingerprint,
        activation.authCert,
        progress_fn
    )

    -- If fulfillment failed due to expired activation and we had reused one, retry once with fresh activation
    if not result and reused and _isActivationError(err) then
        log.warn("beeline_drm: saved activation failed with " .. tostring(err) .. ", retrying with fresh activation...")
        local acct = State.getDrmAccountInfo()
        if acct.mode == "anonymous" then
            M.deauthorize()
            local fresh_act, reused_fresh, fresh_err = M.ensureActivated(true)
            if fresh_act then
                result, err = fulfillment.process(
                    acsm_path,
                    output_path,
                    fresh_act.creds,
                    fresh_act.deviceUUID,
                    fresh_act.fingerprint,
                    fresh_act.authCert,
                    progress_fn
                )
            else
                return nil, fresh_err or "Activation renewal failed"
            end
        end
    end

    if not result then
        if err and err:find("E_LIC_ALREADY_FULFILLED_BY_ANOTHER_USER") then
            return nil, "ALREADY_FULFILLED"
        end
        log.err("beeline_drm: fulfillment failed: " .. tostring(err))
        return nil, err or "Fulfillment failed"
    end

    log.info("beeline_drm: successfully fulfilled book to " .. tostring(output_path))
    return true, output_path, result and result.trackedExtra
end

return M
