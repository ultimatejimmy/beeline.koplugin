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

-- 2. Expiry calculation with duration, until, and purchase (no expiry)
local exp = DRM.extractLoanExpiry(meta)
assert_true(type(exp) == "number" and exp > 0, "Expiry timestamp should be valid number")

local until_license_xml = [[
<licenseToken xmlns="http://ns.adobe.com/adept">
  <permissions>
    <display>
      <until>2026-12-01T23:59:59Z</until>
    </display>
  </permissions>
</licenseToken>
]]
local until_exp = DRM.extractLoanExpiry({ title = "Until Loan" }, until_license_xml)
assert_true(type(until_exp) == "number" and until_exp > 0, "Expiry timestamp from <until> should be valid number")

local purchase_acsm = [[
<fulfillmentToken fulfillmentType="buy" auth="user" xmlns="http://ns.adobe.com/adept">
  <resourceItemInfo>
    <resource>urn:uuid:00000000-0000-0000-0000-000000000001</resource>
    <metadata>
      <dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">Purchased Book</dc:title>
    </metadata>
    <licenseToken>
      <permissions>
        <display/>
      </permissions>
    </licenseToken>
  </resourceItemInfo>
</fulfillmentToken>
]]
local purchase_exp = DRM.extractLoanExpiry(purchase_acsm)
assert_eq(purchase_exp, nil, "Purchased ACSM without duration/until should have nil expiry")
local now = os.time()
print("✓ Expiry calculation (duration, until, and purchase nil) passed")

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

-- 7. encryption.xml namespace, compression Method="0", and URI parsing
local epub = require("beeline_adobe_epub")
local sample_enc_xml = [[<?xml version="1.0" encoding="UTF-8"?>
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
            xmlns:enc="http://www.w3.org/2001/04/xmlenc#"
            xmlns:deenc="http://ns.adobe.com/digitaleditions/enc">
  <enc:EncryptedData>
    <enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
    <enc:CipherData>
      <enc:CipherReference URI="OEBPS/Text/chapter%201.xhtml"/>
    </enc:CipherData>
  </enc:EncryptedData>
  <enc:EncryptedData>
    <enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
    <enc:EncryptionProperties>
      <enc:EncryptionProperty>
        <deenc:Compression Method="0" OriginalLength="1234"/>
      </enc:EncryptionProperty>
    </enc:EncryptionProperties>
    <enc:CipherData>
      <enc:CipherReference URI="OEBPS/Images/cover.jpg"/>
    </enc:CipherData>
  </enc:EncryptedData>
  <enc:EncryptedData>
    <enc:EncryptionMethod Algorithm="http://ns.adobe.com/adept/xmlenc#aes128-cbc-uncompressed"/>
    <enc:CipherData>
      <enc:CipherReference URI="OEBPS/Images/inline.png"/>
    </enc:CipherData>
  </enc:EncryptedData>
  <enc:EncryptedData>
    <enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
    <enc:CipherData>
      <enc:CipherReference URI="OEBPS/Fonts/obfuscated.ttf"/>
    </enc:CipherData>
  </enc:EncryptedData>
</encryption>]]

local parsed_enc = epub._parseEncryptionXml(sample_enc_xml)
assert_true(parsed_enc.encrypted["OEBPS/Text/chapter%201.xhtml"] == true, "Prefixed enc:EncryptedData URI should be flagged for decrypt+inflate")
assert_true(parsed_enc.encryptedForceNoDecomp["OEBPS/Images/cover.jpg"] == true, "Compression Method=0 should map to encryptedForceNoDecomp")
assert_true(parsed_enc.encryptedForceNoDecomp["OEBPS/Images/inline.png"] == true, "aes128-cbc-uncompressed should map to encryptedForceNoDecomp")
assert_true(parsed_enc.rewrittenXml ~= nil and parsed_enc.rewrittenXml:find("obfuscated.ttf") ~= nil, "Non-ADEPT EncryptedData (font obfuscation) must be preserved")
assert_true(parsed_enc.rewrittenXml:find("chapter%%201%.xhtml") == nil, "Stripped ADEPT EncryptedData must not remain in rewrittenXml")
print("✓ encryption.xml namespace & compression Method=0 parsing passed")

-- 8. Streaming rawInflater lifecycle (complete vs truncated/corrupt stream, no double-free)
local zlib = require("beeline_adobe_zlib")
local plain_msg = "Beeline raw deflate verification payload 1234567890"
local plen = #plain_msg
local lo = plen % 256
local hi = math.floor(plen / 256)
local bit = require("bit")
local nlen = bit.bxor(plen, 0xFFFF)
local nlo = nlen % 256
local nhi = math.floor(nlen / 256)
local raw_deflate = string.char(0x01, lo, hi, nlo, nhi) .. plain_msg

local inf_ok, inf_err = zlib.rawInflater()
assert_true(inf_ok ~= nil, "rawInflater should initialize: " .. tostring(inf_err))
local out_chunks = {}
local up_ok, up_err = inf_ok:update(raw_deflate, #raw_deflate, function(ptr, len)
    local ffi = require("ffi")
    out_chunks[#out_chunks + 1] = ffi.string(ptr, len)
    return true
end)
assert_true(up_ok == true, "Valid raw deflate update should succeed: " .. tostring(up_err))
assert_true(inf_ok:isFinished() == true, "Valid complete deflate stream must reach Z_STREAM_END")
assert_true(inf_ok:finalize() == true, "finalize() must return true on completed stream")
assert_eq(table.concat(out_chunks), plain_msg, "Inflated payload must match original")
-- Calling finalize() twice must be safe (no C double-free)
assert_true(inf_ok:finalize() == true, "Repeated finalize() must be idempotent")

local trunc_deflate = raw_deflate:sub(1, #raw_deflate - 10)
local inf_bad = zlib.rawInflater()
assert_true(inf_bad ~= nil, "Second rawInflater should initialize")
local bad_ok = inf_bad:update(trunc_deflate, #trunc_deflate, function() return true end)
assert_true(bad_ok == true, "Incomplete input alone does not error during update")
assert_true(inf_bad:isFinished() == false, "Truncated stream must not report finished")
assert_true(inf_bad:finalize() == false, "finalize() must return false on truncated stream")

local inf_corrupt = zlib.rawInflater()
local corrupt_data = string.char(0x06, 0x00, 0xFF, 0xAA, 0xBB) -- invalid reserved BTYPE=11
local c_ok, c_err = inf_corrupt:update(corrupt_data, #corrupt_data, function() return true end)
assert_true(c_ok == nil and c_err ~= nil, "Corrupt deflate stream must fail cleanly")
assert_true(inf_corrupt:finalize() == false, "finalize() after error must not double-free and must return false")
print("✓ Streaming rawInflater lifecycle & double-free safety passed")

-- 9. ByteBooks authorize lowercase fallback on User does not exist
local adobe = require("beeline_adobe_core")
local orig_getInfo = adobe.getAuthenticationServiceInfo
local orig_signIn = adobe.signIn
local orig_activate = adobe.activate
local orig_serialize = adobe.serializeActivation

local signInAttempts = {}
adobe.getAuthenticationServiceInfo = function()
    return {
        certificate = "TEST_CERT",
        methods = { { method = "AdobeID", name = "Adobe ID" } },
    }
end
adobe.signIn = function(method, user, pass, cert)
    table.insert(signInAttempts, { method = method, user = user, pass = pass })
    if user == "Jimmy@Example.com" then
        return nil, "Server returned error: E_AUTH_FAILED http://adeactivate.adobe.com/adept/SignInDirect username User%20does%20not%20exist"
    end
    if user == "jimmy@example.com" then
        return { user = "urn:uuid:user1", deviceKey = { key = string.rep("k", 16) }, pkcs12 = "p12" }
    end
    return nil, "unexpected user: " .. tostring(user)
end
adobe.activate = function()
    return "urn:uuid:dev1", "fp1"
end
adobe.serializeActivation = function(creds, uuid, fp)
    return { deviceKey = "dk", privateLicenseKey = "pk", user = creds.user, pkcs12 = creds.pkcs12, deviceUUID = uuid, fingerprint = fp }
end

local auth_res, auth_err = DRM.authorizeByteBooks(" Jimmy@Example.com ", "Secret123")
assert_true(auth_res ~= nil, "Lowercase retry should succeed: " .. tostring(auth_err))
assert_eq(#signInAttempts, 2, "Should attempt exact email first, then lowercase fallback")
assert_eq(signInAttempts[1].method, "AdobeID", "Method should be AdobeID")
assert_eq(signInAttempts[1].user, "Jimmy@Example.com", "First attempt should trim spaces")
assert_eq(signInAttempts[2].user, "jimmy@example.com", "Second attempt should lowercase email")
assert_eq(State.getDrmAccountInfo().email, "jimmy@example.com", "Persisted email should reflect successful lowercase login")

adobe.getAuthenticationServiceInfo = orig_getInfo
adobe.signIn = orig_signIn
adobe.activate = orig_activate
adobe.serializeActivation = orig_serialize
State.clearDrmActivation()
print("✓ ByteBooks lowercase email retry passed")

print("=== ALL DRM & AUTOCLEAN TESTS PASSED ===")
