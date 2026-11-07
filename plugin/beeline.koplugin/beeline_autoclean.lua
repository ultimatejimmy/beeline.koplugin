-- beeline_autoclean.lua — Auto-Delete Expired Loans Manager for Beeline
-- Automatically deletes fulfilled book files when loan due date has passed
-- (with a 1-day grace period). Preserves the .sdr sidecar directory.
-- A book without a tracked expiry is NEVER deleted.

local logger = require("logger")

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local ok_state, State = pcall(require, plugin_path .. "beeline_state")
if not ok_state or not State then
    ok_state, State = pcall(require, "beeline_state")
end

local M = {}

local SECONDS_PER_DAY = 24 * 60 * 60

function M.date_ordinal(year, month, day)
    if month <= 2 then
        year = year - 1
        month = month + 12
    end
    return 365 * year
        + math.floor(year / 4)
        - math.floor(year / 100)
        + math.floor(year / 400)
        + math.floor((153 * (month - 3) + 2) / 5)
        + day
end

--- Check if an expiration date has exceeded the grace period.
--- Default grace period is 1 day (grace_days = 1).
--- @param expire number|string Expiration timestamp or date string ("YYYY-MM-DD...")
--- @param now_timestamp number|nil Current unix timestamp (defaults to os.time())
--- @param grace_days number|nil Grace period in days (defaults to 1)
--- @return boolean True if expired past grace period
function M.isPastGracePeriod(expire, now_timestamp, grace_days)
    if not expire then return false end
    local grace = (type(grace_days) == "number" and grace_days >= 0) and grace_days or 1
    local now_ts = now_timestamp or os.time()

    if type(expire) == "number" then
        local grace_seconds = grace * SECONDS_PER_DAY
        return now_ts >= (expire + grace_seconds)
    end

    if type(expire) == "string" then
        -- Handle ISO timestamps like 2026-11-06T03:31:45-05:00 or 2026-11-06
        local year, month, day = expire:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
        if year then
            year, month, day = tonumber(year), tonumber(month), tonumber(day)
            local now = os.date("!*t", now_ts)
            local diff_days = M.date_ordinal(year, month, day) - M.date_ordinal(now.year, now.month, now.day)
            return diff_days <= -grace
        end
    end

    return false
end

--- Checks whether a book file is actively opened in KOReader's ReaderUI.
--- @param file_path string
--- @return boolean
local function isDocumentOpen(file_path)
    if not file_path or file_path == "" then return false end
    local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_rui and ReaderUI and ReaderUI.instance and ReaderUI.instance.document then
        local open_file = ReaderUI.instance.document.file
        if open_file == file_path then
            return true
        end
        local ok_eph, Ephemeral = pcall(require, plugin_path .. "beeline_ephemeral")
        if ok_eph and Ephemeral and Ephemeral.getMasterPath then
            if Ephemeral.getMasterPath(open_file) == file_path then
                return true
            end
        end
    end
    return false
end

M.isDocumentOpen = isDocumentOpen

--- Safely removes a book file while preserving KOReader's .sdr sidecar directory
--- (so reading progress, bookmarks, and highlights remain intact).
--- Refuses to remove the file if it is currently open in ReaderUI.
--- @param file_path string
--- @return boolean success, string|nil error_message
function M.removeFileAndSidecar(file_path)
    if not file_path or file_path == "" then return false, "No file path provided" end

    -- Guard: never delete a file that is actively open in ReaderUI
    if isDocumentOpen(file_path) then
        logger.warn("beeline autoclean: cannot remove file while open in ReaderUI: " .. tostring(file_path))
        return false, "File is currently open in reader"
    end

    -- Remove book file only; preserve .sdr sidecar directory
    pcall(os.remove, file_path)

    -- Clean up any associated ephemeral reading session
    pcall(function()
        local ok_eph, Ephemeral = pcall(require, plugin_path .. "beeline_ephemeral")
        if ok_eph and Ephemeral then
            Ephemeral.cleanupSession(file_path)
        end
    end)

    -- Invalidate KOReader caches and history safely
    pcall(function()
        local ok_ev, Event = pcall(require, "ui/event")
        local ok_uim, UIManager = pcall(require, "ui/uimanager")
        if ok_ev and Event and ok_uim and UIManager and UIManager.broadcastEvent then
            UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", file_path))
        end
    end)
    pcall(function()
        local ok_rh, ReadHistory = pcall(require, "readhistory")
        if ok_rh and ReadHistory and type(ReadHistory.fileDeleted) == "function" then
            ReadHistory:fileDeleted(file_path)
        end
    end)
    pcall(function()
        local ok_rc, ReadCollection = pcall(require, "readcollection")
        if ok_rc and ReadCollection and type(ReadCollection.removeItem) == "function" then
            ReadCollection:removeItem(file_path)
        end
    end)

    return true
end

--- Run autoclean pass over all tracked books in State
--- Deletes books whose loan expiry is past grace period (1 day).
--- @param now_ts number|nil Optional timestamp for testing
--- @return number cleaned_count
function M.cleanExpiredBooks(now_ts)
    if not State then return 0 end
    local tracked = State.getTrackedBooks()
    if not tracked or #tracked == 0 then return 0 end

    local cleaned = 0
    local to_remove = {}

    for _, item in ipairs(tracked) do
        local path = item.path
        local expires = item.expires
        if path and expires then
            if M.isPastGracePeriod(expires, now_ts, 1) then
                if not isDocumentOpen(path) then
                    local ok, err = M.removeFileAndSidecar(path)
                    if ok then
                        table.insert(to_remove, path)
                        cleaned = cleaned + 1
                        logger.info("beeline autoclean: cleaned expired book: " .. tostring(path))
                    else
                        logger.warn("beeline autoclean: failed to remove " .. tostring(path) .. ": " .. tostring(err))
                    end
                else
                    logger.info("beeline autoclean: skipping currently open book: " .. tostring(path))
                end
            end
        end
    end

    for _, path in ipairs(to_remove) do
        State.untrackBook(path)
    end

    return cleaned
end

return M
