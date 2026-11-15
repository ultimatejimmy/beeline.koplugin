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

local mock_df_free = {}
local mock_ffi_util = {
    orderedPairs = function(t) return pairs(t) end,
    df = function(dir)
        local free = mock_df_free[dir]
        if free ~= nil then
            return 100 * 1024 * 1024, free
        end
        return 100 * 1024 * 1024, 64 * 1024 * 1024
    end,
}
package.loaded["ffi/util"] = package.loaded["ffi/util"] or mock_ffi_util
package.loaded["ffi.util"] = package.loaded["ffi.util"] or mock_ffi_util
package.loaded["ffi/posix_h"] = package.loaded["ffi/posix_h"] or {}
package.loaded["ffi.posix_h"] = package.loaded["ffi.posix_h"] or {}
package.loaded["ffi/archiver"] = package.loaded["ffi/archiver"] or {}
package.loaded["ffi.archiver"] = package.loaded["ffi.archiver"] or {}

local mock_lfs = {
    attributes = function(path, key)
        if path and (os.execute("test -d '" .. tostring(path) .. "' 2>/dev/null") == 0 or path:match("%.sdr$")) then
            local res = { mode = "directory", modification = os.time() }
            return key and res[key] or res
        end
        local f = io.open(path, "rb")
        if f then
            local size = f:seek("end") or 0
            f:close()
            local res = { mode = "file", size = size, modification = os.time() }
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

local mock_doc_registry = {
    _orig_calls = 0,
    openDocument = function(self, file, provider)
        self._orig_calls = self._orig_calls + 1
        return {
            file = file,
            closed = false,
            close = function(doc_self)
                doc_self.closed = true
            end,
        }
    end,
}
package.loaded["document/documentregistry"] = mock_doc_registry

local reader_settings_store = {}
G_reader_settings = {
    readSetting = function(self, key)
        return reader_settings_store[key]
    end,
    saveSetting = function(self, key, val)
        reader_settings_store[key] = val
    end,
    delSetting = function(self, key)
        reader_settings_store[key] = nil
    end,
}

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

-- 9. State atomic write & .bak recovery + pairing persistence
State.saveDrmActivation({ deviceKey = "testkey123", user = "urn:uuid:test" }, "anonymous", "")
local before_dev_id = State.getDeviceId()
local claim_code = State.getPairingCode()
State.markPairingClaimed(claim_code)
local count_before = State.getPairedBrowserCount()
assert_true(count_before >= 1, "markPairingClaimed should persist a paired browser")

-- Perform one more write so .bak holds the previous complete snapshot
State.saveDrmActivation({ deviceKey = "testkey123", user = "urn:uuid:test", rev = 2 }, "anonymous", "")
local spath = State._settingsPath()
-- Corrupt primary settings file as would happen during forced power-off
local f_corrupt = io.open(spath, "wb")
assert_true(f_corrupt ~= nil, "Should open settings file to simulate corruption")
f_corrupt:write("{corrupt truncated json")
f_corrupt:close()

State._invalidateCache()
assert_eq(State.getDeviceId(), before_dev_id, "device_id must recover from .bak after primary corruption")
assert_eq(State.getPairedBrowserCount(), count_before, "paired_browsers count must recover from .bak")
local rec_act = State.getDrmActivation()
assert_true(type(rec_act) == "table" and rec_act.deviceKey == "testkey123", "drm_activation must recover from .bak")
os.remove(spath)
os.remove(spath .. ".bak")
State._invalidateCache()
print("✓ State atomic write & .bak recovery passed")

-- 10. Space-aware ephemeral directory selection (RAM headroom fallback)
mock_df_free["/tmp"] = 4 * 1024 * 1024 -- only 4 MB free (< 12 MB headroom + book)
mock_df_free["/dev/shm"] = 2 * 1024 * 1024
local fallback_dir = Ephemeral._getEphemeralDir(5 * 1024 * 1024)
assert_true(fallback_dir:find("cache/beeline%.koplugin/ephemeral") ~= nil, "Should fall back to persistent cache when RAM lacks headroom, got: " .. tostring(fallback_dir))
mock_df_free["/tmp"] = nil
mock_df_free["/dev/shm"] = nil
os.execute("rm -rf /tmp/cache 2>/dev/null")
print("✓ Space-aware ephemeral directory fallback passed")

-- 11. DocumentRegistry:openDocument no ciphertext fallthrough & doc:close cleanup
-- 11a. Failing ADEPT decryption must NOT fall through to orig_openDocument
local fail_master = "/tmp/test_adept_fail.epub"
local f_fm = io.open(fail_master, "wb")
f_fm:write("PK\x03\x04dummy-adept")
f_fm:close()
State.trackBook(fail_master, os.time() + 86400, "Fail Book", {
    is_adept = true,
    format = "epub",
    encrypted_key = "not-valid-base64-key",
})
mock_doc_registry._orig_calls = 0
local fail_doc, fail_err = mock_doc_registry:openDocument(fail_master)
assert_true(fail_doc == nil, "Failed ADEPT open must return nil document")
assert_true(fail_err ~= nil, "Failed ADEPT open must return an error reason")
assert_eq(mock_doc_registry._orig_calls, 0, "Failed ADEPT open must NOT fall through to orig_openDocument")
State.untrackBook(fail_master)
os.remove(fail_master)

-- 11b. Transient DocumentRegistry:openDocument (BookInfoManager / CoverBrowser) cleans up on doc:close()
local tran_master = "/tmp/test_adept_transient.epub"
local tran_ephem = "/tmp/bln_ephem_transient_test.epub"
local f_tm = io.open(tran_master, "wb"); f_tm:write("master"); f_tm:close()
local f_te = io.open(tran_ephem, "wb"); f_te:write("decrypted-epub"); f_te:close()
State.trackBook(tran_master, os.time() + 86400, "Transient Book", { is_adept = true, format = "epub" })
Ephemeral._master_to_ephem[tran_master] = tran_ephem
Ephemeral._ephem_to_master[tran_ephem] = tran_master
Ephemeral._reader_owned[tran_ephem] = nil
Ephemeral._ephem_refs[tran_ephem] = nil

local tdoc = mock_doc_registry:openDocument(tran_master)
assert_true(tdoc ~= nil and tdoc.file == tran_ephem, "DocumentRegistry should open decrypted ephemeral file")
assert_eq(Ephemeral._ephem_refs[tran_ephem], 1, "Transient open should increment ephemeral ref count")
tdoc:close()
assert_true(tdoc.closed == true, "Original doc.close should run")
assert_true(Ephemeral._ephem_to_master[tran_ephem] == nil, "Transient doc:close should clean up _ephem_to_master")
assert_true(Ephemeral._master_to_ephem[tran_master] == nil, "Transient doc:close should clean up _master_to_ephem")
local f_te_chk = io.open(tran_ephem, "rb")
assert_true(f_te_chk == nil, "Transient ephemeral file must be deleted on doc:close")
State.untrackBook(tran_master)
os.remove(tran_master)
print("✓ DocumentRegistry non-fallthrough & transient doc:close cleanup passed")

-- 12. G_reader_settings volatile path sanitization
local fake_home = "/tmp/beeline_home"
os.execute("mkdir -p '" .. fake_home .. "' 2>/dev/null")
reader_settings_store["home_dir"] = fake_home
reader_settings_store["lastfile"] = "/tmp/bln_ephem_crashed_book.epub"
reader_settings_store["lastdir"] = "/tmp"
Ephemeral._last_master_path = nil
Ephemeral._sanitizeReaderSettings()
assert_true(reader_settings_store["lastfile"] == nil, "Stale ephemeral lastfile should be cleared")
assert_eq(reader_settings_store["lastdir"], fake_home, "Volatile lastdir should reset to home_dir when no master path")
reader_settings_store["lastdir"] = "/tmp/bln_ephem_dir"
local restore_dir = "/tmp/beeline_master_dir"
os.execute("mkdir -p '" .. restore_dir .. "' 2>/dev/null")
local restore_master = restore_dir .. "/loan.epub"
local f_rm = io.open(restore_master, "wb"); f_rm:write("epub"); f_rm:close()
Ephemeral._last_master_path = restore_master
reader_settings_store["lastfile"] = "/tmp/bln_ephem_crashed_book.epub"
Ephemeral._sanitizeReaderSettings()
assert_eq(reader_settings_store["lastfile"], restore_master, "Stale ephemeral lastfile should restore to master path when present")
assert_eq(reader_settings_store["lastdir"], fake_home, "When util.splitFilePathName unavailable fallback uses home_dir")
os.remove(restore_master)
os.execute("rmdir '" .. restore_dir .. "' '" .. fake_home .. "' 2>/dev/null")
print("✓ G_reader_settings volatile path sanitization passed")

-- 13. Large-book & short-write fallback tests
-- 13a. Large book (e.g. 91.9 MB) bypasses /tmp even when /tmp reports ample free space
mock_df_free["/tmp"] = 512 * 1024 * 1024
mock_df_free["/dev/shm"] = 512 * 1024 * 1024
local large_dir = Ephemeral._getEphemeralDir(92 * 1024 * 1024)
assert_true(large_dir:find("cache/beeline%.koplugin/ephemeral") ~= nil, "Large books (>16 MB) must route to persistent cache, got: " .. tostring(large_dir))
mock_df_free["/tmp"] = nil
mock_df_free["/dev/shm"] = nil

-- 13b. When ffi/util.df is unavailable and required_bytes > 0, fall back to cache instead of /tmp
local orig_df = mock_ffi_util.df
mock_ffi_util.df = nil
local no_df_dir = Ephemeral._getEphemeralDir(5 * 1024 * 1024)
assert_true(no_df_dir:find("cache/beeline%.koplugin/ephemeral") ~= nil, "Unknown free space with required_bytes > 0 must fall back to cache, got: " .. tostring(no_df_dir))
mock_ffi_util.df = orig_df

-- 13c. If RAM decryption fails (e.g. 'short write'), prepareSession retries in cache and succeeds
local retry_master = "/tmp/test_short_write_retry.epub"
local f_rw = io.open(retry_master, "wb")
f_rw:write("PK\x03\x04dummy-adept-retry")
f_rw:close()
State.trackBook(retry_master, os.time() + 86400, "Retry Book", {
    is_adept = true,
    format = "epub",
    book_key_hex = "00112233445566778899aabbccddeeff",
})
local epub_mod = require("beeline_adobe_epub")
local orig_decrypt = epub_mod.decryptAdobeEpub
local attempted_paths = {}
epub_mod.decryptAdobeEpub = function(_, out_path, _)
    table.insert(attempted_paths, out_path)
    if not out_path:find("cache/beeline%.koplugin/ephemeral") then
        return nil, "short write"
    end
    local f_out = io.open(out_path, "wb")
    assert_true(f_out ~= nil, "Failed to write fallback cache output: " .. tostring(out_path))
    -- Minimal valid ZIP local file header + EOCD so isValidEpubArchive accepts it if checked
    f_out:write("PK\x03\x04dummy-decrypted-epub")
    f_out:close()
    return { outputPath = out_path, decryptedEntries = 1 }
end
mock_df_free["/tmp"] = 64 * 1024 * 1024
local retry_ephem, retry_err = Ephemeral.prepareSession(retry_master)
epub_mod.decryptAdobeEpub = orig_decrypt
mock_df_free["/tmp"] = nil
assert_true(retry_ephem ~= nil, "prepareSession should recover from RAM short write via cache fallback, err: " .. tostring(retry_err))
assert_true(retry_ephem:find("cache/beeline%.koplugin/ephemeral") ~= nil, "Recovered session should reside in cache dir, got: " .. tostring(retry_ephem))
assert_eq(#attempted_paths, 2, "Should attempt RAM path first then retry once in cache")
Ephemeral.cleanupSession(retry_ephem)
State.untrackBook(retry_master)
os.remove(retry_master)
os.execute("rm -rf /tmp/cache 2>/dev/null")
print("✓ Large-book cache routing & short-write fallback passed")

print("=== ALL EPHEMERAL ADEPT TESTS PASSED ===")
