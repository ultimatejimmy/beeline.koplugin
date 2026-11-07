-- spec/test_beeline_ephemeral.lua — Unit tests for Ephemeral ADEPT Decrypt-to-RAM

package.loaded["logger"] = package.loaded["logger"] or {
    info = function(...) end,
    warn = function(...) end,
    err = function(...) end,
}

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

local mock_ffi_util = {
    orderedPairs = function(t) return pairs(t) end,
}
package.loaded["ffi/util"] = package.loaded["ffi/util"] or mock_ffi_util
package.loaded["ffi.util"] = package.loaded["ffi.util"] or mock_ffi_util
package.loaded["ffi/posix_h"] = package.loaded["ffi/posix_h"] or {}
package.loaded["ffi.posix_h"] = package.loaded["ffi.posix_h"] or {}
package.loaded["ffi/archiver"] = package.loaded["ffi/archiver"] or {}
package.loaded["ffi.archiver"] = package.loaded["ffi.archiver"] or {}

local mock_lfs = {
    attributes = function(path, key)
        local f = io.open(path, "r")
        if f then
            f:close()
            local res = { mode = "file", size = 100 }
            return key and res[key] or res
        end
        if path:find("/tmp") or path:find("sdr") then
            local res = { mode = "directory" }
            return key and res[key] or res
        end
        return nil
    end,
    mkdir = function(p)
        if p and os.execute then pcall(os.execute, "mkdir -p '" .. tostring(p) .. "' 2>/dev/null") end
    end,
    dir = function(p)
        local pipe = io.popen("ls -1A '" .. p .. "' 2>/dev/null")
        if not pipe then return function() return nil end end
        return function()
            local line = pipe:read("*l")
            if not line then pipe:close(); return nil end
            return line
        end
    end,
}
package.loaded["lfs"] = package.loaded["lfs"] or mock_lfs
package.loaded["libs/libkoreader-lfs"] = package.loaded["libs/libkoreader-lfs"] or mock_lfs

package.loaded["datastorage"] = package.loaded["datastorage"] or {
    getSettingsDir = function() return "/tmp" end,
    getDataDir = function() return "/tmp" end,
}

local mock_reader_ui = {
    showReader = function(self, file)
        self._last_opened = file
        return true
    end,
    onClose = function(self)
        return true
    end,
}
package.loaded["apps/reader/readerui"] = mock_reader_ui

local mock_docsettings = {
    getSidecarDir = function(self, path)
        return path .. ".sdr"
    end,
    getSidecarFilename = function(path)
        return "metadata.epub.lua"
    end,
    open = function(self, path)
        return {
            saveSetting = function() end,
            flush = function() end,
            doc_path = path,
        }
    end,
}
package.loaded["docsettings"] = mock_docsettings

local mock_readhistory = {
    addItem = function(self, file)
        self._last_added = file
        return true
    end,
}
package.loaded["readhistory"] = mock_readhistory

local mock_booklist = {
    setBookInfoCacheProperty = function(file, k, v) end,
    setBookInfoCache = function(file, doc_settings) end,
}
package.loaded["ui/widget/booklist"] = mock_booklist

local plugin_dir = "plugin/beeline.koplugin"
package.path = plugin_dir .. "/?.lua;" .. package.path

local State = require("beeline_state")
local Ephemeral = require("beeline_ephemeral")

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

print("=== Running Beeline Ephemeral ADEPT Tests ===")

-- 1. State Settings: getDrmKeepEncrypted (permanently enforced true)
State.setDrmKeepEncrypted(true)
assert_true(State.getDrmKeepEncrypted() == true, "getDrmKeepEncrypted should default to true")

-- Attempting to disable must still enforce true per security design
State.setDrmKeepEncrypted(false)
assert_true(State.getDrmKeepEncrypted() == true, "getDrmKeepEncrypted must always enforce true")
print("✓ State keep_encrypted enforcement passed")

-- 2. State ADEPT tracking
local test_book = "/tmp/test_adept_book.epub"
local f_tb = io.open(test_book, "w")
if f_tb then f_tb:write("dummy adept content"); f_tb:close() end

State.trackBook(test_book, os.time() + 86400, "Test Book", {
    is_adept = true,
    format = "epub",
    encrypted_key = "abc123key==",
})
assert_true(State.isBookAdept(test_book) == true, "Book should be marked ADEPT in state")

local untracked_book = "/tmp/test_plain_book.epub"
assert_true(State.isBookAdept(untracked_book) == false, "Untracked book should not be ADEPT")
print("✓ State ADEPT book tracking passed")

-- 3. Ephemeral Detection
assert_true(Ephemeral.isAdeptEncrypted(test_book) == true, "Ephemeral.isAdeptEncrypted via state")
print("✓ Ephemeral ADEPT detection passed")

-- 4. Path resolution & bidirectional session mapping
local ephem_path = Ephemeral._generateEphemeralPath(test_book)
assert_true(ephem_path:find("bln_ephem_") ~= nil, "Generated path should match bln_ephem_ pattern")
assert_true(ephem_path:find("%.epub$") ~= nil, "Generated path should retain .epub extension")

Ephemeral._ephem_to_master[ephem_path] = test_book
Ephemeral._master_to_ephem[test_book] = ephem_path

assert_eq(Ephemeral.getMasterPath(ephem_path), test_book, "getMasterPath for ephemeral path should resolve to master book")
assert_eq(Ephemeral.getMasterPath(test_book), test_book, "getMasterPath for master book should resolve to itself")
assert_eq(Ephemeral.getMasterPath("/books/other.epub"), "/books/other.epub", "getMasterPath for unmapped path resolves to itself")
assert_true(Ephemeral.isEphemeralPath(ephem_path) == true, "isEphemeralPath for ephemeral path")
assert_true(Ephemeral.isEphemeralPath(test_book) == false, "isEphemeralPath for master path")
print("✓ Path resolution & bidirectional session mapping passed")

-- 5. Transparent Hook Redirection
Ephemeral.installHooks()

-- Test DocSettings redirection
local sdr_dir = mock_docsettings:getSidecarDir(ephem_path)
assert_eq(sdr_dir, test_book .. ".sdr", "DocSettings:getSidecarDir should redirect ephemeral to master .sdr")

local sdr_fn = mock_docsettings.getSidecarFilename(ephem_path)
assert_eq(sdr_fn, "metadata.epub.lua", "DocSettings:getSidecarFilename")

local doc_obj = mock_docsettings:open(ephem_path)
assert_eq(doc_obj.doc_path, test_book, "DocSettings:open should redirect ephemeral to master book")

-- Test ReadHistory redirection
mock_readhistory:addItem(ephem_path)
assert_eq(mock_readhistory._last_added, test_book, "ReadHistory:addItem should record master book, not ephemeral")
print("✓ Transparent Hook Redirection (DocSettings & ReadHistory) passed")

-- 6. Cleanup session
local dummy_ephem = "/tmp/bln_ephem_dummy_test.epub"
local f = io.open(dummy_ephem, "w")
if f then f:write("sample content"); f:close() end

Ephemeral._ephem_to_master[dummy_ephem] = "/tmp/master_dummy.epub"
Ephemeral._master_to_ephem["/tmp/master_dummy.epub"] = dummy_ephem

Ephemeral.cleanupSession(dummy_ephem)
assert_true(Ephemeral._ephem_to_master[dummy_ephem] == nil, "Ephemeral session mapping should be cleared")
assert_true(Ephemeral._master_to_ephem["/tmp/master_dummy.epub"] == nil, "Master session mapping should be cleared")
print("✓ Ephemeral cleanup session passed")

-- 7. Autoclean integration check
local Autoclean = require("beeline_autoclean")
assert_true(type(Autoclean.cleanExpiredBooks) == "function", "Autoclean function present")
print("✓ Autoclean integration check passed")

-- 8. Sidecar cover art validation & sanitization
local test_sidecar_book = "/tmp/test_cover_book.epub"
local test_sidecar_dir = test_sidecar_book .. ".sdr"
os.execute("mkdir -p " .. test_sidecar_dir)

-- Write invalid/corrupt cover
local bad_cover = test_sidecar_dir .. "/cover.jpg"
local f_bad = io.open(bad_cover, "wb")
f_bad:write("CorruptNonImageCiphertextDataHere1234567890")
f_bad:close()

-- Populate sidecar with valid JPEG
local valid_jpeg = "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x01\x00`\x00`\x00\x00\xFF\xDB"
Ephemeral.populateSidecar(test_sidecar_book, { title = "Test Book" }, valid_jpeg, "jpg")

local f_chk = io.open(bad_cover, "rb")
assert_true(f_chk ~= nil, "Valid cover should be written")
local chk_head = f_chk:read(3)
f_chk:close()
assert_eq(chk_head, "\xFF\xD8\xFF", "Cover must have valid JPEG magic bytes")

-- Test that corrupt cover data is rejected and bad files sanitized
local bad_cover2 = test_sidecar_dir .. "/cover.png"
local f_bad2 = io.open(bad_cover2, "wb")
f_bad2:write("bad data")
f_bad2:close()
Ephemeral.populateSidecar(test_sidecar_book, { title = "Test Book" }, "bad data not image", "jpg")
local f_chk2 = io.open(bad_cover2, "rb")
assert_true(f_chk2 == nil, "Corrupt cover files must be sanitized from sidecar")

os.remove(bad_cover)
os.remove(test_sidecar_book .. ".sdr/metadata.epub.lua")
os.remove(test_sidecar_book)
os.execute("rmdir " .. test_sidecar_dir .. " 2>/dev/null")
print("✓ Sidecar cover validation and sanitization passed")

print("=== ALL EPHEMERAL ADEPT TESTS PASSED ===")
