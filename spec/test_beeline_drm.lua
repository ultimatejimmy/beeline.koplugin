-- spec/test_beeline_drm.lua — Unit tests for Beeline DRM & ACSM fulfillment

-- Stub logger if not in KOReader environment
package.loaded["logger"] = package.loaded["logger"] or {
    info = function(...) end,
    warn = function(...) end,
    err = function(...) end,
}

-- Probe KOReader directory to include common Lua libraries (like socket.http, mime, etc.)
local squash_root = os.getenv("SQUASHFS_ROOT") or "/home/jimmy/squashfs-root"
local ko_paths = {
    squash_root .. "/usr/lib/koreader/common/?.lua",
    squash_root .. "/usr/lib/koreader/common/?/init.lua",
    "/usr/lib/koreader/common/?.lua",
    "/usr/lib/koreader/common/?/init.lua",
}
for _, kp in ipairs(ko_paths) do
    package.path = kp .. ";" .. package.path
end
local ko_cpaths = {
    squash_root .. "/usr/lib/koreader/common/?.so",
    squash_root .. "/usr/lib/koreader/common/socket/?.so",
    "/usr/lib/koreader/common/?.so",
    "/usr/lib/koreader/common/socket/?.so",
}
for _, cp in ipairs(ko_cpaths) do
    package.cpath = cp .. ";" .. package.cpath
end

-- Stub KOReader environment & network modules when running standalone
package.loaded["socket.http"] = package.loaded["socket.http"] or {
    request = function() return "", 200, {} end,
}
package.loaded["ssl.https"] = package.loaded["ssl.https"] or {
    request = function() return "", 200, {} end,
}
package.loaded["ltn12"] = package.loaded["ltn12"] or {
    source = { string = function() end },
    sink = { table = function() end },
}
package.loaded["socket"] = package.loaded["socket"] or {}
package.loaded["socketutil"] = package.loaded["socketutil"] or {
    USER_AGENT = "KOReader",
    file_sink = function(handle)
        return function(chunk, err)
            if chunk and handle then handle:write(chunk) end
            return 1
        end
    end,
    table_sink = function(t)
        return function(chunk, err)
            if chunk then table.insert(t, chunk) end
            return 1
        end
    end,
    set_timeout = function() end,
    reset_timeout = function() end,
}

local mock_sha2 = {
    hex2bin = function(hex)
        return (hex:gsub("..", function(cc) return string.char(tonumber(cc, 16) or 0) end))
    end,
    bin2hex = function(bin)
        return (bin:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
    end,
    md5 = function(s) return string.rep("a", 32) end,
    sha256 = function(s) return string.rep("b", 64) end,
    base642bin = function(s) return s end,
    bin2base64 = function(s) return s end,
}
package.loaded["ffi/sha2"] = package.loaded["ffi/sha2"] or mock_sha2
package.loaded["ffi.sha2"] = package.loaded["ffi.sha2"] or mock_sha2

package.loaded["util"] = package.loaded["util"] or {
    fixUtf8 = function(s) return s end,
    tableShallowCopy = function(t) local c = {} for k,v in pairs(t) do c[k]=v end return c end,
    readFromFile = function(p)
        local f = io.open(p, "rb")
        if not f then return nil end
        local d = f:read("*a")
        f:close()
        return d
    end,
    writeToFile = function(d, p)
        local f = io.open(p, "wb")
        if not f then return false end
        f:write(d)
        f:close()
        return true
    end,
}

local mock_lfs = {
    attributes = function(path)
        local f = io.open(path, "r")
        if f then f:close() return { mode = "file" } end
        return nil
    end,
    mkdir = function(p)
        if p and os.execute then pcall(os.execute, "mkdir -p " .. tostring(p) .. " 2>/dev/null") end
    end,
    dir = function() return function() return nil end end,
}
package.loaded["lfs"] = package.loaded["lfs"] or mock_lfs
package.loaded["libs/libkoreader-lfs"] = package.loaded["libs/libkoreader-lfs"] or mock_lfs

local mock_ffi_util = {
    orderedPairs = function(t) return pairs(t) end,
}
package.loaded["ffi/util"] = package.loaded["ffi/util"] or mock_ffi_util
package.loaded["ffi.util"] = package.loaded["ffi.util"] or mock_ffi_util

package.loaded["ffi/posix_h"] = package.loaded["ffi/posix_h"] or {}
package.loaded["ffi.posix_h"] = package.loaded["ffi.posix_h"] or {}

package.loaded["datastorage"] = package.loaded["datastorage"] or {
    getSettingsDir = function() return "/tmp" end,
    getDataDir = function() return "/tmp" end,
}

package.loaded["ffi/archiver"] = package.loaded["ffi/archiver"] or {}
package.loaded["ffi.archiver"] = package.loaded["ffi.archiver"] or {}

local plugin_dir = "plugin/beeline.koplugin"
package.path = plugin_dir .. "/?.lua;" .. package.path

local State = require("beeline_state")
local DRM = require("beeline_drm")
local Autoclean = require("beeline_autoclean")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected '%s', got '%s'", msg or "assertion failed", tostring(expected), tostring(actual)))
    end
end

local function assert_true(cond, msg)
    if not cond then
        error(msg or "expected true, got false")
    end
end

print("=== Running Beeline DRM & Autoclean Tests ===")

-- 1. ACSM Metadata parsing
local sample_acsm = [[
<fulfillmentToken fulfillmentType="loan" auth="user" xmlns="http://ns.adobe.com/adept">
  <distributor>urn:uuid:f1227b83-f91b-4f30-9ae2-0f65ffeea9ac</distributor>
  <operatorURL>https://acsepub.contentreserve.com/fulfillment</operatorURL>
  <transaction>Test-12345</transaction>
  <purchase>2026-11-05T21:31:45-05:00</purchase>
  <expiration>2026-11-06T03:31:45-05:00</expiration>
  <resourceItemInfo>
    <resource>urn:uuid:f0ec2524-cf4c-4059-a685-8ce809079166</resource>
    <resourceItem>1</resourceItem>
    <metadata>
      <dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">The Test Book</dc:title>
      <dc:creator xmlns:dc="http://purl.org/dc/elements/1.1/">Sample Author</dc:creator>
      <dc:publisher xmlns:dc="http://purl.org/dc/elements/1.1/">Sample Publisher</dc:publisher>
      <dc:identifier xmlns:dc="http://purl.org/dc/elements/1.1/">9780000000000</dc:identifier>
      <dc:format xmlns:dc="http://purl.org/dc/elements/1.1/">application/epub+zip</dc:format>
    </metadata>
    <licenseToken>
      <resource>urn:uuid:f0ec2524-cf4c-4059-a685-8ce809079166</resource>
      <permissions>
        <display>
          <duration>1209600</duration>
        </display>
      </permissions>
    </licenseToken>
  </resourceItemInfo>
</fulfillmentToken>
]]

local meta = DRM.parseAcsmMetadata(sample_acsm)
assert_true(meta ~= nil, "ACSM metadata should parse")
assert_eq(meta.title, "The Test Book", "Title match")
assert_eq(meta.creator, "Sample Author", "Author match")
assert_eq(meta.format, "application/epub+zip", "Format match")
assert_eq(meta.duration, 1209600, "Duration match (14 days)")
print("✓ ACSM metadata parsing passed")

-- 2. Expiry calculation with duration and fallback
local exp = DRM.extractLoanExpiry(meta)
assert_true(type(exp) == "number" and exp > 0, "Expiry timestamp should be valid number")

local fallback_meta = { title = "No duration" }
local fallback_exp = DRM.extractLoanExpiry(fallback_meta, 21)
local now = os.time()
local diff_days = math.floor((fallback_exp - now) / 86400)
assert_eq(diff_days, 21, "Fallback expiry should be default days")
print("✓ Expiry calculation & fallback passed")

-- 3. Path derivation
local path = DRM.deriveFinalBookPath("/tmp", meta)
assert_true(path:match("%.epub$") ~= nil, "Should derive .epub extension")
assert_true(path:find("The_Test_Book") ~= nil or path:find("The Test Book") ~= nil, "Should contain book title")
print("✓ Book path derivation passed")

-- 4. State management (Consent, Mode, Settings)
State.setDrmConsentVersion(1)
assert_eq(State.getDrmConsentVersion(), 1, "Consent version")

State.setDrmMode("anonymous")
assert_eq(State.getDrmMode(), "anonymous", "Mode setting")

State.setDrmDefaultLoanDays(14)
assert_eq(State.getDrmDefaultLoanDays(), 14, "Default loan days")

State.setDrmDeleteAcsmAfter(true)
assert_true(State.getDrmDeleteAcsmAfter(), "Delete acsm setting")

local serial = DRM.getOrCreateDeviceSerial()
assert_true(serial ~= nil and serial:match("^BLN%-") ~= nil, "Device serial generation")
print("✓ State & Serial management passed")

-- 5. Book tracking
local dummy_path = "/tmp/test_book_tracked.epub"
State.trackBook(dummy_path, now + 1000, "Test Book")
local tracked = State.getTrackedBooks()
local found = false
for _, t in ipairs(tracked) do
    if t.path == dummy_path then found = true end
end
assert_true(found, "Tracked book should be saved")

State.untrackBook(dummy_path)
local found_after = false
for _, t in ipairs(State.getTrackedBooks()) do
    if t.path == dummy_path then found_after = true end
end
assert_true(not found_after, "Untracked book should be removed")
print("✓ Book tracking & untracking passed")

-- 6. Autoclean logic (Grace period calculation)
-- Expiry in future -> not past grace period
assert_true(not Autoclean.isPastGracePeriod(now + 86400, now, 1), "Future loan should not be past grace")
-- Expiry now -> within grace period of 1 day -> not past grace period
assert_true(not Autoclean.isPastGracePeriod(now, now, 1), "Loan expiring now should still be in grace period")
-- Expiry 2 days ago -> past 1-day grace period
assert_true(Autoclean.isPastGracePeriod(now - (2 * 86400), now, 1), "Loan expired 2 days ago should be past grace period")
print("✓ Autoclean grace period calculations passed")

print("=== ALL DRM & AUTOCLEAN TESTS PASSED ===")
