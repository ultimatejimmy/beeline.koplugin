-- spec/test_beeline_epub_roundtrip.lua — End-to-end EPUB roundtrip with real Archiver & OpenSSL crypto

local bit = require("bit")
local ffi = require("ffi")

package.loaded["logger"] = {
    info = function(...) end,
    warn = function(...) end,
    err = function(...) end,
}

local squash_root = os.getenv("SQUASHFS_ROOT") or "/home/jimmy/squashfs-root"
local ko_paths = {
    squash_root .. "/usr/lib/koreader/?.lua",
    squash_root .. "/usr/lib/koreader/?/init.lua",
    squash_root .. "/usr/lib/koreader/common/?.lua",
    squash_root .. "/usr/lib/koreader/common/?/init.lua",
}
for _, kp in ipairs(ko_paths) do
    package.path = package.path .. ";" .. kp
end

package.loaded["socket.http"] = { request = function() return "", 200, {} end }
package.loaded["ssl.https"] = { request = function() return "", 200, {} end }
package.loaded["ltn12"] = { source = { string = function() end }, sink = { table = function() end } }
package.loaded["socket"] = {}
package.loaded["socketutil"] = {
    USER_AGENT = "KOReader",
    file_sink = function() return function() return 1 end end,
    table_sink = function() return function() return 1 end end,
    set_timeout = function() end,
    reset_timeout = function() end,
}

local ko_cpaths = {
    squash_root .. "/usr/lib/koreader/?.so",
    squash_root .. "/usr/lib/koreader/common/?.so",
    squash_root .. "/usr/lib/koreader/libs/?.so",
}
for _, cp in ipairs(ko_cpaths) do
    package.cpath = package.cpath .. ";" .. cp
end

-- Stub non-FFI UI/storage modules not needed for EPUB roundtrip
package.loaded["datastorage"] = {
    getSettingsDir = function() return "/tmp" end,
    getDataDir = function() return "/tmp" end,
}

local function mkdir_p(p)
    os.execute("mkdir -p '" .. p .. "' 2>/dev/null")
end

-- Minimal lfs wrapper using POSIX/shell when libkoreader-lfs isn't on standard cpath
local ok_real_lfs, real_lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_real_lfs then
    local stub_lfs = {
        attributes = function(path, key)
            if not path then return nil end
            local is_dir = os.execute("test -d '" .. tostring(path) .. "' 2>/dev/null")
            if is_dir == 0 or is_dir == true then
                local res = { mode = "directory", modification = os.time() }
                return key and res[key] or res
            end
            local is_file = os.execute("test -f '" .. tostring(path) .. "' 2>/dev/null")
            if is_file == 0 or is_file == true then
                local f = io.open(path, "rb")
                local size = 0
                if f then
                    size = f:seek("end") or 0
                    f:close()
                end
                local res = { mode = "file", size = size, modification = os.time() }
                return key and res[key] or res
            end
            return nil
        end,
        mkdir = function(p)
            return os.execute("mkdir -p '" .. tostring(p) .. "'") == 0
        end,
        rmdir = function(p)
            return os.execute("rmdir '" .. tostring(p) .. "'") == 0
        end,
        dir = function(p)
            local pipe = io.popen("ls -1a '" .. tostring(p) .. "' 2>/dev/null")
            if not pipe then return function() return nil end end
            return function()
                local line = pipe:read("*l")
                if not line then pipe:close(); return nil end
                return line
            end
        end,
    }
    package.loaded["libs/libkoreader-lfs"] = stub_lfs
    package.loaded["lfs"] = stub_lfs
end

package.loaded["util"] = {
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
    template = function(fmt, ...) return string.format(fmt, ...) end,
    basename = function(p) return p:match("([^/\\]+)$") or p end,
}

package.loaded["apps/reader/readerui"] = { showReader = function() end, onClose = function() end }
package.loaded["apps/filemanager/filemanager"] = { openFile = function() end }
package.loaded["docsettings"] = {
    getSidecarDir = function(_, p) return p .. ".sdr" end,
    getSidecarFilename = function() return "metadata.epub.lua" end,
    open = function(_, p) return { doc_path = p, saveSetting = function() end, flush = function() end } end,
}
package.loaded["readhistory"] = { addItem = function() end }
package.loaded["ui/widget/booklist"] = { setBookInfoCacheProperty = function() end }

package.path = "plugin/beeline.koplugin/?.lua;" .. package.path

require("ffi/loadlib")
local Archiver = require("ffi/archiver")
local nativecrypto = require("beeline_adobe_nativecrypto")
local epub = require("beeline_adobe_epub")
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

local function rawDeflateStored(data)
    assert_true(#data <= 65535, "rawDeflateStored expects <= 65535 bytes")
    local len = #data
    local nlen = bit.bxor(len, 0xFFFF)
    return string.char(0x01, len % 256, math.floor(len / 256), nlen % 256, math.floor(nlen / 256)) .. data
end

local function adeptEncrypt(key, iv, plaintext)
    local ct, err = nativecrypto.aes_cbc_encrypt(key, iv, plaintext, false)
    assert_true(ct ~= nil, "aes_cbc_encrypt failed: " .. tostring(err))
    return iv .. ct
end

local function b64encode(data)
    local b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    return ((data:gsub(".", function(x)
        local r, byte = "", x:byte()
        for i = 8, 1, -1 do r = r .. (byte % 2^i - byte % 2^(i - 1) > 0 and "1" or "0") end
        return r
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
        if #x < 6 then return "" end
        local c = 0
        for i = 1, 6 do c = c + (x:sub(i, i) == "1" and 2^(6 - i) or 0) end
        return b:sub(c + 1, c + 1)
    end) .. ({ "", "==", "=" })[#data % 3 + 1])
end

print("=== Running Real Archiver EPUB ADEPT Roundtrip Tests ===")

local work_dir = "/tmp/beeline_roundtrip_test_" .. tostring(os.time())
mkdir_p(work_dir)

local aes_key = "0123456789abcdef" -- 16-byte AES-128 book key
local iv1 = "abcdef0123456789"
local iv2 = "1234567890fedcba"

-- Sample chapter with XML + multibyte text (exceeding 64 bytes so multiple blocks + PKCS#7 padding)
local chapter_plain = '<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Ch 1</title></head><body><p>' .. string.rep("Library loan chapter text! ", 40) .. "</p></body></html>"
-- Fake valid JPEG cover (exact byte sequence whose end could match or not match PKCS7 byte values)
local cover_plain = "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x01\x00`\x00`\x00\x00" .. string.rep("\xAB", 29) .. "\x04\x04\x04\x04\xFF\xD9"

local chapter_enc = adeptEncrypt(aes_key, iv1, rawDeflateStored(chapter_plain))
local cover_enc = adeptEncrypt(aes_key, iv2, cover_plain)

local opf_xml = [[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Roundtrip Loan</dc:title>
    <meta name="cover" content="cover-img"/>
  </metadata>
  <manifest>
    <item id="ch1" href="Text/chapter%201.xhtml" media-type="application/xhtml+xml"/>
    <item id="cover-img" href="Images/cover.jpg" media-type="image/jpeg"/>
  </manifest>
  <spine><itemref idref="ch1"/></spine>
</package>]]

local container_xml = [[<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]]

local fake_enc_b64 = b64encode(string.rep("\x55", 128))
local rights_xml = [[<?xml version="1.0" encoding="UTF-8"?>
<adept:rights xmlns:adept="http://ns.adobe.com/adept">
  <adept:licenseToken>
    <adept:encryptedKey>]] .. fake_enc_b64 .. [[</adept:encryptedKey>
  </adept:licenseToken>
</adept:rights>]]

local encryption_xml = [[<?xml version="1.0" encoding="UTF-8"?>
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
        <deenc:Compression Method="0" OriginalLength="]] .. tostring(#cover_plain) .. [["/>
      </enc:EncryptionProperty>
    </enc:EncryptionProperties>
    <enc:CipherData>
      <enc:CipherReference URI="OEBPS/Images/cover.jpg"/>
    </enc:CipherData>
  </enc:EncryptedData>
</encryption>]]

local function buildEpub(outPath, stageName, items)
    local stageDir = work_dir .. "/" .. stageName
    mkdir_p(stageDir)
    local w = Archiver.Writer:new()
    assert_true(w:open(outPath, "zip"), "Archiver.Writer should open " .. outPath)
    local mtime = os.time()
    for _, item in ipairs(items) do
        local rel, data = item[1], item[2]
        local full = stageDir .. "/" .. rel
        local parent = full:match("^(.*)/[^/]+$")
        if parent then mkdir_p(parent) end
        local f = io.open(full, "wb")
        assert_true(f ~= nil, "Failed to write staging file " .. full)
        f:write(data)
        f:close()
        w:addPath(rel, full, false, mtime)
        assert_true(w.err == nil, "addPath failed for " .. rel .. ": " .. tostring(w.err))
    end
    w:close()
    assert_true(w.err == nil, "Archiver.Writer closed with error: " .. tostring(w.err))
end

local encrypted_epub = work_dir .. "/encrypted_loan.epub"
local decrypted_epub = work_dir .. "/decrypted_loan.epub"

buildEpub(encrypted_epub, "stage_enc", {
    { "mimetype", "application/epub+zip" },
    { "META-INF/container.xml", container_xml },
    { "META-INF/rights.xml", rights_xml },
    { "META-INF/encryption.xml", encryption_xml },
    { "OEBPS/content.opf", opf_xml },
    { "OEBPS/Text/chapter 1.xhtml", chapter_enc },
    { "OEBPS/Images/cover.jpg", cover_enc },
})

-- 1. Ephemeral.isAdeptEncrypted ZIP probe (requires iterate() before extractToMemory())
assert_true(Ephemeral.isAdeptEncrypted(encrypted_epub) == true, "isAdeptEncrypted must detect ADEPT encrypted EPUB via Archiver probe")
print("✓ Real ZIP isAdeptEncrypted probe passed")

-- 2. epub.extractEncryptedKeyFromEpub
local got_b64, got_err = epub.extractEncryptedKeyFromEpub(encrypted_epub)
assert_eq(got_b64, fake_enc_b64, "extractEncryptedKeyFromEpub failed: " .. tostring(got_err))
print("✓ Real ZIP extractEncryptedKeyFromEpub passed")

-- 3. epub.decryptAdobeEpub full extraction, URL-decoded path match, streaming decrypt+inflate, Compression Method=0, repack & validation
local dec_ok, dec_err = epub.decryptAdobeEpub(encrypted_epub, decrypted_epub, aes_key)
assert_true(dec_ok ~= nil, "decryptAdobeEpub failed: " .. tostring(dec_err))
assert_eq(dec_ok.decryptedEntries, 2, "decryptAdobeEpub should decrypt both chapter and cover")

-- Inspect decrypted EPUB with Archiver.Reader
local r = Archiver.Reader:new()
assert_true(r:open(decrypted_epub), "Decrypted EPUB must open cleanly with Archiver.Reader")
local entries = {}
for entry in r:iterate() do
    entries[entry.path] = entry
end
assert_true(r.err == nil, "Archiver.Reader iterate error: " .. tostring(r.err))
assert_true(entries["META-INF/rights.xml"] == nil, "META-INF/rights.xml must be removed")
assert_true(entries["META-INF/encryption.xml"] == nil, "META-INF/encryption.xml must be removed when no non-ADEPT entries remain")
assert_true(entries["META-INF/container.xml"] ~= nil, "META-INF/container.xml must be preserved")
assert_eq(r:extractToMemory("OEBPS/Text/chapter 1.xhtml"), chapter_plain, "Decrypted+inflated chapter must match original byte-for-byte")
assert_eq(r:extractToMemory("OEBPS/Images/cover.jpg"), cover_plain, "Decrypted Compression=0 cover must match original byte-for-byte")
r:close()

-- Verify crengine (libs/libkoreader-cre) opens and renders the single-pass streamed EPUB
local ok_cre, cre = pcall(require, "libs/libkoreader-cre")
if ok_cre and cre then
    cre.initCache(work_dir .. "/cre_cache", 16 * 1024 * 1024, true, 1)
    cre.initHyphDict(squash_root .. "/usr/lib/koreader/data/hyph/")
    cre.registerFont(squash_root .. "/usr/lib/koreader/fonts/noto/NotoSerif-Regular.ttf")
    cre.regularizeRegisteredFontsWeights(false)
    cre.setAsPreferredFontWithBias("Noto Serif", 1)
    local doc = cre.newDocView(600, 800, 1)
    assert_true(doc:loadDocument(decrypted_epub, false) == true, "crengine must load streamed decrypted EPUB")
    doc:renderDocument()
    assert_true(doc:getPages() >= 1, "crengine must render at least 1 page from streamed decrypted EPUB")
    print("✓ Real crengine loadDocument & renderDocument passed")
end
print("✓ Real ZIP decryptAdobeEpub roundtrip passed")

-- 4. epub.extractCoverImage (Compression Method=0 + no double PKCS7 padding stripping)
local extracted_cover, ext = epub.extractCoverImage(encrypted_epub, aes_key)
assert_eq(ext, "jpg", "Cover extension should be jpg")
assert_eq(extracted_cover, cover_plain, "Extracted cover image must match original byte-for-byte")
print("✓ Real ZIP extractCoverImage passed")

-- 5. Truncated deflate stream rejection (must fail cleanly instead of writing truncated spine item)
local trunc_epub = work_dir .. "/truncated_loan.epub"
local trunc_decrypted = work_dir .. "/truncated_out.epub"
local bad_raw = rawDeflateStored(chapter_plain)
bad_raw = bad_raw:sub(1, #bad_raw - 50)
local bad_enc = adeptEncrypt(aes_key, iv1, bad_raw)

buildEpub(trunc_epub, "stage_trunc", {
    { "mimetype", "application/epub+zip" },
    { "META-INF/container.xml", container_xml },
    { "META-INF/encryption.xml", encryption_xml },
    { "OEBPS/Text/chapter 1.xhtml", bad_enc },
    { "OEBPS/Images/cover.jpg", cover_enc },
})

local bad_ok, bad_err = epub.decryptAdobeEpub(trunc_epub, trunc_decrypted, aes_key)
assert_true(not bad_ok, "Truncated deflate stream must fail decryptAdobeEpub cleanly")
assert_true(bad_err ~= nil, "Failed decryptAdobeEpub must return error reason")
local f_chk_trunc = io.open(trunc_decrypted, "rb")
assert_true(f_chk_trunc == nil, "Failed decryption must not leave partial output EPUB")
print("✓ Truncated deflate stream rejection passed")

os.execute("rm -rf '" .. work_dir .. "'")
print("=== ALL REAL ARCHIVER EPUB ROUNDTRIP TESTS PASSED ===")
