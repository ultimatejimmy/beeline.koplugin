-- spec/test_beeline_state.lua
-- Unit tests for beeline_state.lua pairing code rotation & paired browser retention

local squash_root = os.getenv("SQUASHFS_ROOT") or "/home/jimmy/squashfs-root"
package.path = squash_root .. "/usr/lib/koreader/common/?.lua;" .. squash_root .. "/usr/lib/koreader/common/?/init.lua;" .. "plugin/beeline.koplugin/?.lua;" .. package.path
package.cpath = squash_root .. "/usr/lib/koreader/common/?.so;" .. squash_root .. "/usr/lib/koreader/libs/?.so;" .. package.cpath

local tmp_dir = os.tmpname()
os.remove(tmp_dir)
os.execute("mkdir -p " .. tmp_dir)

-- Stub KOReader modules used by beeline_state.lua
package.preload["datastorage"] = function()
    return {
        getSettingsDir = function() return tmp_dir end,
        getDataDir = function() return tmp_dir end,
    }
end

local State = require("beeline_state")

-- 1. Initial load creates device_id and pairing_code
local s = State.loadSettings()
assert(type(s.device_id) == "string" and #s.device_id == 16, "device_id should be 16 hex chars")
assert(type(s.pairing_code) == "string" and #s.pairing_code == 7, "pairing_code should be XXX-XXX")

local orig_device_id = s.device_id
local first_code = s.pairing_code

-- 2. Mark a browser as paired
State.addPairedBrowser(first_code)
assert(State.getPairedBrowserCount() == 1, "paired browser count should be 1")

-- 3. Invalidate cache and call generatePairingCode() directly:
--    must NOT clobber device_id or paired_browsers
State._invalidateCache()
local second_code = State.generatePairingCode()
assert(second_code ~= "", "second_code should not be empty")
assert(State.getDeviceId() == orig_device_id, "device_id must be preserved across generatePairingCode()")
assert(State.getPairedBrowserCount() == 1, "paired_browsers must be preserved across generatePairingCode()")

-- 4. Stale (>24h) unpaired active_codes should be pruned, while paired_browsers and current code remain
local cur = State.loadSettings()
cur.active_codes["OLD111"] = { code = "OLD-111", created_at = os.time() - (25 * 3600) }
local first_norm = first_code:upper():gsub("[%s%-]+", "")
cur.active_codes[first_norm].created_at = os.time() - (48 * 3600)
State.saveSettings(cur)

State.generatePairingCode()
local after = State.loadSettings()
assert(after.active_codes["OLD111"] == nil, "stale unpaired code >24h should be pruned")
assert(after.active_codes[first_norm] ~= nil, "paired browser code must NEVER be pruned")

local active_list = State.getActiveCodes()
local found_paired = false
for _, c in ipairs(active_list) do
    if c == first_code then found_paired = true end
end
assert(found_paired, "getActiveCodes() must include paired browser code")

os.execute("rm -rf " .. tmp_dir)
print("SUCCESS: beeline_state pairing retention & pruning tests passed!")
