local epub = {}

local ffi = require("ffi")
local Archiver = require("ffi/archiver")
local DataStorage = require("datastorage")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or not lfs then ok_lfs, lfs = pcall(require, "lfs") end
local logger = require("logger")
local koutil = require("util")

local dom = require("beeline_adobe_dom")
local nativecrypto = require("beeline_adobe_nativecrypto")
local zlib = require("beeline_adobe_zlib")

local XMLENC = "http://www.w3.org/2001/04/xmlenc#"
local AES128_CBC = "http://www.w3.org/2001/04/xmlenc#aes128-cbc"
local AES128_CBC_UNCOMPRESSED = "http://ns.adobe.com/adept/xmlenc#aes128-cbc-uncompressed"

local CHUNK_SIZE = 65536 -- 64KB chunks for streaming decrypt
local WATERMARK_SCAN_BYTES = 16384
local FILE_IOFBF = 0

require("ffi/posix_h") -- FILE, fopen, fwrite, fclose, strerror
pcall(ffi.cdef, "int setvbuf(FILE *stream, char *buf, int mode, size_t size);")

local _libarchive = nil
local function getLibarchive()
    if _libarchive then
        return _libarchive
    end
    pcall(require, "ffi/loadlib")
    pcall(require, "ffi/libarchive_h")
    local ok, lib = pcall(function()
        if type(ffi.loadlib) == "function" then
            return ffi.loadlib("archive", "13")
        end
        return ffi.load("libarchive.so.13")
    end)
    if not ok or not lib then
        ok, lib = pcall(ffi.load, "archive")
    end
    if ok and lib then
        _libarchive = lib
        epub._libarchive = lib -- Anchor against LuaJIT GC
    end
    return _libarchive
end

local function formatArchiveWriteError(libarchive, wr, outputPath, prefix)
    local parts = {}
    if prefix and prefix ~= "" then
        parts[#parts + 1] = prefix
    end
    if libarchive and wr ~= nil then
        local ok_es, err_ptr = pcall(libarchive.archive_error_string, wr)
        if ok_es and err_ptr ~= nil then
            local msg = ffi.string(err_ptr)
            if msg ~= "" then
                parts[#parts + 1] = msg
            end
        end
    end
    local errno = ffi.errno()
    if errno and errno ~= 0 then
        local ok_str, os_msg = pcall(function() return ffi.string(ffi.C.strerror(errno)) end)
        if ok_str and os_msg and os_msg ~= "" then
            parts[#parts + 1] = os_msg
        end
    end
    if outputPath then
        parts[#parts + 1] = "(" .. tostring(outputPath) .. ")"
    end
    if #parts == 0 then
        return "short write"
    end
    return table.concat(parts, ": ")
end

local function removeTree(path)
    if not path or path == "" or lfs.attributes(path, "mode") ~= "directory" then
        return
    end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local child = path .. "/" .. entry
            local mode = lfs.attributes(child, "mode")
            if mode == "directory" then
                removeTree(child)
            else
                os.remove(child)
            end
        end
    end
    lfs.rmdir(path)
end

local function urlDecode(str)
    if type(str) ~= "string" then return str end
    return (str:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function normalizeZipPath(path)
    if type(path) ~= "string" then return nil end
    local clean = path:gsub("\\", "/")
    clean = clean:gsub("^%./+", ""):gsub("^/+", ""):gsub("//+", "/")
    if clean == "" or clean == ".." or clean:match("^%.%./") or clean:match("/%.%./") or clean:match("/%.%.$") then
        return nil
    end
    return clean
end

local function hasUncompressedMethod(encDataNode, encDataNsMap)
    local propsNode, propsNsMap = dom.firstElement(encDataNode, encDataNsMap, "EncryptionProperties")
    if not propsNode then
        return false
    end
    for _, propChild in ipairs(propsNode._children or {}) do
        if propChild._type == "ELEMENT" then
            local propNsMap = dom.nsMapFor(propChild, propsNsMap)
            local _, propName = dom.resolveNodeName(propChild, propNsMap)
            if propName == "EncryptionProperty" then
                local compNode = dom.firstElement(propChild, propNsMap, "Compression")
                if compNode and compNode._attr and tostring(compNode._attr.Method or "") == "0" then
                    return true
                end
                if propChild._attr and tostring(propChild._attr.Method or "") == "0" then
                    return true
                end
            end
        end
    end
    return false
end

local function parseEncryptionXml(encryptionXml)
    local root = dom.parse(encryptionXml)
    if not root then
        return {
            encrypted = {},
            encryptedForceNoDecomp = {},
            rewrittenXml = nil,
        }
    end
    local rootNsMap = dom.nsMapFor(root, { [""] = "urn:oasis:names:tc:opendocument:xmlns:container" })

    local encrypted = {}
    local encryptedForceNoDecomp = {}
    local remainingEncryptedData = 0
    local keptChildren = {}

    for _, child in ipairs(root._children or {}) do
        if child._type ~= "ELEMENT" then
            keptChildren[#keptChildren + 1] = child
        else
            local childNsMap = dom.nsMapFor(child, rootNsMap)
            local childNs, childName = dom.resolveNodeName(child, childNsMap)
            if childNs == XMLENC and childName == "EncryptedData" then
                local methodNode = dom.firstElement(child, childNsMap, "EncryptionMethod", XMLENC)
                local cipherDataNode, cipherDataNsMap = dom.firstElement(child, childNsMap, "CipherData", XMLENC)
                local cipherRefNode = cipherDataNode and dom.firstElement(cipherDataNode, cipherDataNsMap, "CipherReference", XMLENC)

                local algorithm = methodNode and methodNode._attr and methodNode._attr.Algorithm or nil
                local uri = cipherRefNode and cipherRefNode._attr and cipherRefNode._attr.URI or nil

                if uri and algorithm == AES128_CBC then
                    if hasUncompressedMethod(child, childNsMap) then
                        encryptedForceNoDecomp[uri] = true
                    else
                        encrypted[uri] = true
                    end
                elseif uri and algorithm == AES128_CBC_UNCOMPRESSED then
                    encryptedForceNoDecomp[uri] = true
                else
                    keptChildren[#keptChildren + 1] = child
                    remainingEncryptedData = remainingEncryptedData + 1
                end
            else
                keptChildren[#keptChildren + 1] = child
            end
        end
    end

    root._children = keptChildren

    local rewrittenXml = nil
    if remainingEncryptedData > 0 then
        rewrittenXml = '<?xml version="1.0" encoding="UTF-8"?>\n' .. dom.serializeNode(root)
    end

    return {
        encrypted = encrypted,
        encryptedForceNoDecomp = encryptedForceNoDecomp,
        rewrittenXml = rewrittenXml,
    }
end

local function stripPkcs7Held(buf, len)
    if len < 1 then
        return nil, "Invalid PKCS#7 padding"
    end
    local pad = tonumber(buf[len - 1])
    if not pad or pad < 1 or pad > 16 or pad > len then
        return nil, "Invalid PKCS#7 padding"
    end
    for i = len - pad, len - 1 do
        if tonumber(buf[i]) ~= pad then
            return nil, "Invalid PKCS#7 padding"
        end
    end
    return len - pad
end

local function setLuaFileBuffer(file, size)
    if not file or type(file.setvbuf) ~= "function" then
        return
    end
    pcall(file.setvbuf, file, "full", size)
end

local function openBufferedOutput(path, size)
    local stream = ffi.C.fopen(path, "wb")
    if stream == nil then
        return nil, "Cannot create temp file: " .. ffi.string(ffi.C.strerror(ffi.errno()))
    end
    ffi.gc(stream, ffi.C.fclose)
    ffi.C.setvbuf(stream, nil, FILE_IOFBF, size)

    local writer = {}

    function writer:write(ptr, len)
        if len <= 0 then
            return true
        end
        local written = tonumber(ffi.C.fwrite(ptr, 1, len, stream))
        if written ~= len then
            return nil, "short write"
        end
        return true
    end

    function writer:close()
        if stream == nil then
            return true
        end
        ffi.gc(stream, nil)
        local rc = ffi.C.fclose(stream)
        stream = nil
        if rc ~= 0 then
            return nil, "close failed"
        end
        return true
    end

    return writer
end

--- Decrypt an Adobe ADEPT encrypted file in-place using streaming.
-- Reads the input in CHUNK_SIZE chunks, decrypts via streaming AES-CBC,
-- optionally inflates via streaming zlib, and writes to a temp file.
-- Peak memory: ~2 × CHUNK_SIZE regardless of file size.
local function decryptAdeptEntryFile(fullPath, bookKey, noDecomp)
    local inFile, inErr = io.open(fullPath, "rb")
    if not inFile then
        return nil, "Cannot open encrypted file: " .. tostring(inErr)
    end
    setLuaFileBuffer(inFile, CHUNK_SIZE)

    local tmpPath = fullPath .. ".dec"
    local outWriter, outErr = openBufferedOutput(tmpPath, CHUNK_SIZE)
    if not outWriter then
        inFile:close()
        return nil, outErr
    end

    -- Create streaming decryptor (zero IV, no padding — we handle PKCS7 manually)
    local decryptor, decErr = nativecrypto.aes_cbc_decryptor(bookKey, string.rep("\0", 16), true)
    if not decryptor then
        inFile:close()
        outWriter:close()
        os.remove(tmpPath)
        return nil, "Failed to create decryptor: " .. tostring(decErr)
    end

    -- Optionally create streaming inflater
    local inflater = nil
    if not noDecomp then
        local infErr
        inflater, infErr = zlib.rawInflater()
        if not inflater then
            inFile:close()
            outWriter:close()
            os.remove(tmpPath)
            return nil, "Failed to create inflater: " .. tostring(infErr)
        end
    end

    -- We need to:
    -- 1. Skip the first 16 bytes of decrypted output (random prefix)
    -- 2. Strip PKCS7 padding from the final block
    -- Strategy: skip first 16, hold back last 16 for PKCS7 check.
    -- Held bytes are flushed when new data arrives (proving they aren't final).
    local skipRemaining = 16 -- bytes to skip from start of decrypted stream
    local held = ffi.new("uint8_t[16]")
    local heldLen = 0

    local function writeThrough(ptr, len)
        if len <= 0 then
            return true
        end
        if inflater then
            return inflater:update(ptr, len, function(outPtr, outLen)
                return outWriter:write(outPtr, outLen)
            end)
        end
        return outWriter:write(ptr, len)
    end

    local function processDecrypted(ptr, len)
        -- Skip the first 16 bytes of the decrypted stream
        if skipRemaining > 0 then
            if len <= skipRemaining then
                skipRemaining = skipRemaining - len
                return true
            end
            ptr = ptr + skipRemaining
            len = len - skipRemaining
            skipRemaining = 0
        end

        -- Flush previously held bytes (they're not the final block since more data arrived)
        if heldLen > 0 then
            local ok, err = writeThrough(held, heldLen)
            if not ok then
                return nil, err
            end
            heldLen = 0
        end

        -- Hold back the last 16 bytes of this chunk for PKCS7 stripping
        if len <= 16 then
            ffi.copy(held, ptr, len)
            heldLen = len
            return true
        end
        ffi.copy(held, ptr + len - 16, 16)
        heldLen = 16

        return writeThrough(ptr, len - 16)
    end

    -- Read and process chunks
    local readErr = nil
    while true do
        local chunk = inFile:read(CHUNK_SIZE)
        if not chunk then
            break
        end

        local ok, updateErr = decryptor:update(chunk, processDecrypted)
        if not ok then
            readErr = "decrypt update failed: " .. tostring(updateErr)
            break
        end
    end
    inFile:close()

    if not readErr then
        -- Finalize decryption
        local ok, finErr = decryptor:finalize(processDecrypted)
        if not ok then
            readErr = "decrypt finalize failed: " .. tostring(finErr)
        end
    end

    if not readErr then
        -- Strip PKCS7 from held bytes and write remainder
        local strippedLen, pkcsErr = stripPkcs7Held(held, heldLen)
        if not strippedLen then
            readErr = "PKCS7 strip failed: " .. tostring(pkcsErr)
        elseif strippedLen > 0 then
            local ok, err = writeThrough(held, strippedLen)
            if not ok then
                readErr = "final write failed: " .. tostring(err)
            end
        end
    end

    if inflater then
        local infOk = inflater:finalize()
        if not readErr and not infOk then
            readErr = "Truncated deflate stream"
        end
    end
    local closeOk, closeErr = outWriter:close()
    if not readErr and not closeOk then
        readErr = "close failed: " .. tostring(closeErr)
    end

    if readErr then
        os.remove(tmpPath)
        return nil, readErr
    end

    -- Replace original with decrypted version
    os.remove(fullPath)
    local ok, renameErr = os.rename(tmpPath, fullPath)
    if not ok then
        os.remove(tmpPath)
        return nil, "Failed to rename decrypted file: " .. tostring(renameErr)
    end

    return true
end

local function getFullDataDir()
    if DataStorage and type(DataStorage.getFullDataDir) == "function" then
        local ok, full = pcall(DataStorage.getFullDataDir, DataStorage)
        if ok and type(full) == "string" and full ~= "" and full ~= "." then
            return full
        end
    end
    local base = (DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or "/tmp"
    if base == "." and lfs and type(lfs.currentdir) == "function" then
        local cwd = lfs.currentdir()
        if type(cwd) == "string" and cwd ~= "" then
            return cwd
        end
    end
    return base
end

function epub.cleanupWorkDirs(maxAgeSeconds)
    local ok_ds, cacheBase = pcall(function()
        return getFullDataDir() .. "/cache/beeline.koplugin"
    end)
    if not ok_ds or not cacheBase or lfs.attributes(cacheBase, "mode") ~= "directory" then
        return 0
    end
    local now = os.time()
    local maxAge = maxAgeSeconds or 3600
    local cleaned = 0
    local ok_dir, iter, dir_obj = pcall(lfs.dir, cacheBase)
    if ok_dir and iter then
        for entry in iter, dir_obj do
            if entry:match("^epub%-work%-") or entry == "epub_work" then
                local full = cacheBase .. "/" .. entry
                local attr = lfs.attributes(full)
                if attr and attr.mode == "directory" then
                    local age = now - (attr.modification or 0)
                    if maxAge <= 0 or age >= maxAge then
                        removeTree(full)
                        cleaned = cleaned + 1
                    end
                end
            end
        end
    end
    return cleaned
end

local function makeTempDir()
    local cacheDir = getFullDataDir() .. "/cache/beeline.koplugin"
    if lfs.attributes(cacheDir, "mode") ~= "directory" then
        local ok, err = lfs.mkdir(cacheDir)
        if not ok and lfs.attributes(cacheDir, "mode") ~= "directory" then
            return nil, "Failed to create cache dir: " .. cacheDir .. ": " .. tostring(err)
        end
    end

    -- Sweep abandoned work directories older than 1 hour (and legacy epub_work)
    pcall(epub.cleanupWorkDirs, 3600)

    local timestamp = tostring(os.time())
    local random = tostring(math.random(100000, 999999))
    local lastErr
    for i = 1, 999 do
        local tmpDir = cacheDir .. "/epub-work-" .. timestamp .. "-" .. random .. "-" .. tostring(i)
        local ok, err = lfs.mkdir(tmpDir)
        if ok then
            return tmpDir
        end
        lastErr = err
    end
    return nil, "Failed to create unique EPUB temp dir: " .. tostring(lastErr)
end

local function ensureDir(path)
    if not path or path == "" or lfs.attributes(path, "mode") == "directory" then
        return true
    end

    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and lfs.attributes(parent, "mode") ~= "directory" then
        local ok, err = ensureDir(parent)
        if not ok then
            return nil, err
        end
    end

    local ok, err = lfs.mkdir(path)
    if not ok and lfs.attributes(path, "mode") ~= "directory" then
        return nil, err
    end
    return true
end

local function listFiles(workDir)
    local files = {}
    local function walk(dir, relBase)
        for entry in lfs.dir(dir) do
            if entry ~= "." and entry ~= ".." then
                local fullPath = dir .. "/" .. entry
                local relPath = relBase ~= "" and (relBase .. "/" .. entry) or entry
                local mode = lfs.attributes(fullPath, "mode")
                if mode == "directory" then
                    walk(fullPath, relPath)
                elseif mode == "file" then
                    files[#files + 1] = relPath
                end
            end
        end
    end
    walk(workDir, "")

    table.sort(files)
    return files
end

local function validateRepackedEpub(epubPath)
    local reader = Archiver.Reader:new()
    if not reader:open(epubPath) then
        return nil, reader.err or "Could not reopen repacked EPUB"
    end
    local containerPath = nil
    local entryCount = 0
    for entry in reader:iterate() do
        entryCount = entryCount + 1
        local norm = normalizeZipPath(entry.path)
        if norm and norm:lower() == "meta-inf/container.xml" and entry.mode == "file" then
            containerPath = entry.path
        end
    end
    local readErr = reader.err
    local hasContainer = false
    if not readErr and containerPath then
        local xmlData = reader:extractToMemory(containerPath)
        if xmlData and #xmlData > 0 then
            hasContainer = true
        end
        readErr = reader.err
    end
    reader:close()
    if readErr then
        return nil, "Repacked EPUB validation failed: " .. tostring(readErr)
    end
    if entryCount == 0 or not hasContainer then
        return nil, "Repacked EPUB is missing META-INF/container.xml"
    end
    return true
end

local ALREADY_COMPRESSED_EXTS = {
    jpg = true, jpeg = true, png = true, gif = true, webp = true,
    avif = true, jp2 = true, woff = true, woff2 = true, ttf = true,
    otf = true, mp3 = true, m4a = true, mp4 = true, ogg = true, opus = true,
    svgz = true, zip = true, gz = true,
}

local function shouldStoreWithoutDeflate(relPath, noCompressSet)
    if noCompressSet then
        if noCompressSet[relPath] or noCompressSet[relPath:lower()] then
            return true
        end
    end
    local ext = relPath:match("%.([^%.]+)$")
    if ext and ALREADY_COMPRESSED_EXTS[ext:lower()] then
        return true
    end
    return false
end

local function repackEpub(workDir, outputPath, noCompressSet)
    local tmpOut = outputPath .. ".tmp"
    os.remove(tmpOut)

    local writer = Archiver.Writer:new({})
    if not writer:open(tmpOut, "epub") then
        return nil, writer.err or "Could not open EPUB writer"
    end

    local mtime = os.time()
    local mimetype = koutil.readFromFile(workDir .. "/mimetype", "rb")
    if not mimetype or mimetype == "" then
        mimetype = "application/epub+zip"
    end

    writer:setZipCompression("store")
    if not writer:addFileFromMemory("mimetype", mimetype, mtime) then
        writer:close()
        os.remove(tmpOut)
        return nil, writer.err or "Could not write mimetype"
    end
    os.remove(workDir .. "/mimetype")

    local currentComp = "store"
    local files, listErr = listFiles(workDir)
    if not files then
        writer:close()
        os.remove(tmpOut)
        return nil, listErr
    end

    for _, relPath in ipairs(files) do
        if relPath ~= "mimetype" then
            local fullPath = workDir .. "/" .. relPath
            if lfs.attributes(fullPath, "mode") ~= "file" then
                writer:close()
                os.remove(tmpOut)
                return nil, "Missing repack input: " .. relPath
            end
            local wantComp = shouldStoreWithoutDeflate(relPath, noCompressSet) and "store" or "deflate"
            if wantComp ~= currentComp then
                writer:setZipCompression(wantComp)
                currentComp = wantComp
            end
            writer:addPath(relPath, fullPath, false, mtime)
            if writer.err then
                local err = writer.err
                writer:close()
                os.remove(tmpOut)
                return nil, err
            end
            -- Delete each staging file as soon as it is written to tmpOut to halve peak disk usage
            os.remove(fullPath)
        end
    end

    writer:close()
    if writer.err then
        local err = writer.err
        os.remove(tmpOut)
        return nil, err
    end

    local validOk, validErr = validateRepackedEpub(tmpOut)
    if not validOk then
        os.remove(tmpOut)
        return nil, validErr
    end

    os.remove(outputPath)
    local renOk, renErr = os.rename(tmpOut, outputPath)
    if not renOk then
        os.remove(tmpOut)
        return nil, "Failed to finalize EPUB: " .. tostring(renErr)
    end
    return true
end

local function extractEpub(inputPath, workDir)
    local reader = Archiver.Reader:new()
    if not reader:open(inputPath) then
        return nil, reader.err or "Could not open EPUB archive"
    end

    for entry in reader:iterate() do
        if entry.mode == "file" then
            local normPath = normalizeZipPath(entry.path)
            if not normPath then
                reader:close()
                return nil, "Unsafe EPUB entry path: " .. tostring(entry.path)
            end
            local fullPath = workDir .. "/" .. normPath
            local parent = fullPath:match("^(.*)/[^/]+$")
            if parent and parent ~= "" then
                local ok, err = ensureDir(parent)
                if not ok then
                    reader:close()
                    return nil, err
                end
            end
            local ok = reader:extractToPath(entry.path, fullPath)
            if not ok then
                reader:close()
                return nil, reader.err or ("Could not extract " .. entry.path)
            end
        end
    end

    local readErr = reader.err
    reader:close()
    if readErr then
        return nil, "EPUB read error: " .. tostring(readErr)
    end
    return true
end

-- Watermarks and rights metadata are intentionally preserved per guardrails
local function stripAdeptWatermarks(workDir)
    return 0
end

local function stripAdeptWatermarksFromText(text)
    return text, 0
end

local function buildEncryptionLookup(uriSet)
    local map = {}
    for uri in pairs(uriSet or {}) do
        map[uri] = uri
        local norm = normalizeZipPath(uri)
        if norm then
            map[norm] = uri
            map[norm:lower()] = uri
        end
        local dec = normalizeZipPath(urlDecode(uri))
        if dec then
            map[dec] = uri
            map[dec:lower()] = uri
        end
    end
    return map
end

local function matchEncryptedUri(map, rawPath, normPath, lowerPath)
    return map[rawPath]
        or (normPath and map[normPath])
        or (lowerPath and map[lowerPath])
        or (normPath and map[urlDecode(normPath)])
        or (lowerPath and map[urlDecode(lowerPath)])
end

local function writeArchiveBuffer(libarchive, wr, outputPath, ptr, len)
    if len <= 0 then
        return true
    end
    local written = tonumber(libarchive.archive_write_data(wr, ptr, len))
    if not written or written ~= len then
        return nil, formatArchiveWriteError(libarchive, wr, outputPath, "short write")
    end
    return true
end

local function writeMemoryEntryToArchive(libarchive, wr, outputPath, entryPath, content, mtime, compMethod, setCompFn)
    local okComp, compErr = setCompFn(compMethod)
    if not okComp then
        return nil, compErr
    end
    local entry = libarchive.archive_entry_new()
    if entry == nil then
        return nil, "Could not allocate archive_entry"
    end
    libarchive.archive_entry_set_pathname(entry, entryPath)
    libarchive.archive_entry_set_filetype(entry, libarchive.AE_IFREG)
    libarchive.archive_entry_set_perm(entry, 420)
    libarchive.archive_entry_set_mtime(entry, mtime, 0)
    libarchive.archive_entry_set_size(entry, #content)
    local hdrRc = libarchive.archive_write_header(wr, entry)
    libarchive.archive_entry_free(entry)
    if hdrRc ~= libarchive.ARCHIVE_OK then
        return nil, formatArchiveWriteError(libarchive, wr, outputPath, "archive_write_header failed for " .. tostring(entryPath))
    end
    return writeArchiveBuffer(libarchive, wr, outputPath, content, #content)
end

local function streamDecryptEntryToArchive(libarchive, rd, wr, outputPath, readBuf, bookKey, noDecomp)
    local decryptor, decErr = nativecrypto.aes_cbc_decryptor(bookKey, string.rep("\0", 16), true)
    if not decryptor then
        return nil, "Failed to create decryptor: " .. tostring(decErr)
    end

    local inflater = nil
    if not noDecomp then
        local infErr
        inflater, infErr = zlib.rawInflater()
        if not inflater then
            return nil, "Failed to create inflater: " .. tostring(infErr)
        end
    end

    local skipRemaining = 16
    local held = ffi.new("uint8_t[16]")
    local heldLen = 0

    local function writeThrough(ptr, len)
        if len <= 0 then
            return true
        end
        if inflater then
            return inflater:update(ptr, len, function(outPtr, outLen)
                return writeArchiveBuffer(libarchive, wr, outputPath, outPtr, outLen)
            end)
        end
        return writeArchiveBuffer(libarchive, wr, outputPath, ptr, len)
    end

    local function processDecrypted(ptr, len)
        if skipRemaining > 0 then
            if len <= skipRemaining then
                skipRemaining = skipRemaining - len
                return true
            end
            ptr = ptr + skipRemaining
            len = len - skipRemaining
            skipRemaining = 0
        end

        if heldLen > 0 then
            local ok, err = writeThrough(held, heldLen)
            if not ok then
                return nil, err
            end
            heldLen = 0
        end

        if len <= 16 then
            ffi.copy(held, ptr, len)
            heldLen = len
            return true
        end
        ffi.copy(held, ptr + len - 16, 16)
        heldLen = 16

        return writeThrough(ptr, len - 16)
    end

    local readErr = nil
    while true do
        local n = tonumber(libarchive.archive_read_data(rd, readBuf, CHUNK_SIZE))
        if not n or n < 0 then
            readErr = "Archive read error while decrypting entry"
            break
        end
        if n == 0 then
            break
        end
        local ok, updateErr = decryptor:update(readBuf, n, processDecrypted)
        if not ok then
            readErr = "decrypt update failed: " .. tostring(updateErr)
            break
        end
    end

    if not readErr then
        local ok, finErr = decryptor:finalize(processDecrypted)
        if not ok then
            readErr = "decrypt finalize failed: " .. tostring(finErr)
        end
    end

    if not readErr then
        local strippedLen, pkcsErr = stripPkcs7Held(held, heldLen)
        if not strippedLen then
            readErr = "PKCS7 strip failed: " .. tostring(pkcsErr)
        elseif strippedLen > 0 then
            local ok, err = writeThrough(held, strippedLen)
            if not ok then
                readErr = "final write failed: " .. tostring(err)
            end
        end
    end

    if inflater then
        local infOk = inflater:finalize()
        if not readErr and not infOk then
            readErr = "Truncated deflate stream"
        end
    end

    if readErr then
        return nil, readErr
    end
    return true
end

--- Single-pass archive-to-archive streaming decryptor (zero intermediate workDir files on disk)
local function streamDecryptAdobeEpub(libarchive, inputPath, outputPath, bookKey, reportProgress)
    -- Clean up any legacy work directories left by older versions
    pcall(epub.cleanupWorkDirs, 0)

    -- 1. Probe encryption.xml and mimetype via Archiver.Reader
    local probe = Archiver.Reader:new()
    if not probe:open(inputPath) then
        return nil, probe.err or "Could not open EPUB archive"
    end
    local encXmlEntry = nil
    local mimetypeEntry = nil
    local totalFiles = 0
    for entry in probe:iterate() do
        if entry.mode == "file" then
            totalFiles = totalFiles + 1
            local norm = normalizeZipPath(entry.path)
            if not norm then
                probe:close()
                return nil, "Unsafe EPUB entry path: " .. tostring(entry.path)
            end
            local lower = norm:lower()
            if lower == "meta-inf/encryption.xml" then
                encXmlEntry = entry.path
            elseif lower == "mimetype" then
                mimetypeEntry = entry.path
            end
        end
    end
    if probe.err then
        local err = probe.err
        probe:close()
        return nil, "EPUB read error: " .. tostring(err)
    end

    local encryptionXml = encXmlEntry and probe:extractToMemory(encXmlEntry) or nil
    local mimetype = mimetypeEntry and probe:extractToMemory(mimetypeEntry) or nil
    probe:close()

    if not mimetype or mimetype == "" then
        mimetype = "application/epub+zip"
    end

    local parsed = nil
    local encDecompMap = {}
    local encNoDecompMap = {}
    if encryptionXml and encryptionXml ~= "" then
        parsed = parseEncryptionXml(encryptionXml)
        encDecompMap = buildEncryptionLookup(parsed.encrypted)
        encNoDecompMap = buildEncryptionLookup(parsed.encryptedForceNoDecomp)
    end
    reportProgress(0.15)

    -- Ensure parent directory of outputPath exists
    local outParent = outputPath:match("^(.*)/[^/]+$")
    if outParent and outParent ~= "" then
        ensureDir(outParent)
    end

    local tmpOut = outputPath .. ".tmp"
    os.remove(tmpOut)

    local rd = libarchive.archive_read_new()
    if rd == nil then
        return nil, "Could not allocate libarchive reader"
    end
    libarchive.archive_read_support_format_all(rd)
    libarchive.archive_read_support_filter_all(rd)
    if libarchive.archive_read_open_filename(rd, inputPath, CHUNK_SIZE) ~= libarchive.ARCHIVE_OK then
        local err = formatArchiveWriteError(libarchive, rd, inputPath, "Could not open input EPUB")
        libarchive.archive_free(rd)
        return nil, err
    end

    local wr = libarchive.archive_write_new()
    if wr == nil then
        libarchive.archive_read_close(rd)
        libarchive.archive_free(rd)
        return nil, "Could not allocate libarchive writer"
    end
    if libarchive.archive_write_set_format_by_name(wr, "zip") ~= libarchive.ARCHIVE_OK or
       libarchive.archive_write_open_filename(wr, tmpOut) ~= libarchive.ARCHIVE_OK then
        local err = formatArchiveWriteError(libarchive, wr, tmpOut, "Could not open EPUB writer")
        libarchive.archive_free(wr)
        libarchive.archive_read_close(rd)
        libarchive.archive_free(rd)
        os.remove(tmpOut)
        return nil, err
    end

    local currentComp = nil
    local function setZipComp(method)
        if method == currentComp then
            return true
        end
        local rc
        if method == "store" then
            rc = libarchive.archive_write_zip_set_compression_store(wr)
        else
            rc = libarchive.archive_write_zip_set_compression_deflate(wr)
        end
        if rc ~= libarchive.ARCHIVE_OK then
            return nil, formatArchiveWriteError(libarchive, wr, tmpOut, "setZipCompression failed")
        end
        currentComp = method
        return true
    end

    local function cleanupHandles()
        if wr ~= nil then
            libarchive.archive_write_close(wr)
            libarchive.archive_free(wr)
            wr = nil
        end
        if rd ~= nil then
            libarchive.archive_read_close(rd)
            libarchive.archive_free(rd)
            rd = nil
        end
    end

    local mtime = os.time()

    -- 2. Write mimetype first (stored uncompressed per EPUB spec)
    local mimeOk, mimeErr = writeMemoryEntryToArchive(libarchive, wr, tmpOut, "mimetype", mimetype, mtime, "store", setZipComp)
    if not mimeOk then
        cleanupHandles()
        os.remove(tmpOut)
        return nil, mimeErr
    end

    -- 3. Stream all entries in a single pass
    local inEntry = libarchive.archive_entry_new()
    local readBuf = ffi.new("uint8_t[?]", CHUNK_SIZE)
    local hasContainer = false
    local decryptCount = 0
    local forceNoDecompCount = 0
    local processedFiles = 0
    local streamErr = nil

    while true do
        local rc = libarchive.archive_read_next_header2(rd, inEntry)
        if rc == libarchive.ARCHIVE_EOF then
            break
        end
        if rc ~= libarchive.ARCHIVE_OK then
            streamErr = formatArchiveWriteError(libarchive, rd, inputPath, "EPUB read error")
            break
        end

        local ftype = libarchive.archive_entry_filetype(inEntry)
        if ftype == libarchive.AE_IFREG then
            processedFiles = processedFiles + 1
            local rawPathPtr = libarchive.archive_entry_pathname(inEntry)
            local rawPath = rawPathPtr ~= nil and ffi.string(rawPathPtr) or ""
            local normPath = normalizeZipPath(rawPath)
            if not normPath then
                streamErr = "Unsafe EPUB entry path: " .. tostring(rawPath)
                break
            end
            local lowerPath = normPath:lower()

            if lowerPath == "mimetype" or lowerPath == "meta-inf/rights.xml" then
                -- Skip: mimetype already written first; rights.xml stripped
            elseif lowerPath == "meta-inf/encryption.xml" then
                if parsed and parsed.rewrittenXml then
                    local okXml, errXml = writeMemoryEntryToArchive(
                        libarchive, wr, tmpOut, "META-INF/encryption.xml", parsed.rewrittenXml, mtime, "deflate", setZipComp
                    )
                    if not okXml then
                        streamErr = errXml
                        break
                    end
                end
            else
                if lowerPath == "meta-inf/container.xml" then
                    hasContainer = true
                end

                local isEncDecomp = parsed and matchEncryptedUri(encDecompMap, rawPath, normPath, lowerPath) ~= nil
                local isEncNoDecomp = parsed and not isEncDecomp and matchEncryptedUri(encNoDecompMap, rawPath, normPath, lowerPath) ~= nil
                local wantStore = isEncNoDecomp or shouldStoreWithoutDeflate(normPath, parsed and parsed.encryptedForceNoDecomp)
                local okComp, compErr = setZipComp(wantStore and "store" or "deflate")
                if not okComp then
                    streamErr = compErr
                    break
                end

                local outEntry = libarchive.archive_entry_new()
                libarchive.archive_entry_set_pathname(outEntry, normPath)
                libarchive.archive_entry_set_filetype(outEntry, libarchive.AE_IFREG)
                libarchive.archive_entry_set_perm(outEntry, 420)
                libarchive.archive_entry_set_mtime(outEntry, mtime, 0)
                if not isEncDecomp and not isEncNoDecomp then
                    local inSize = tonumber(libarchive.archive_entry_size(inEntry))
                    if inSize and inSize >= 0 then
                        libarchive.archive_entry_set_size(outEntry, inSize)
                    end
                end

                local hdrRc = libarchive.archive_write_header(wr, outEntry)
                libarchive.archive_entry_free(outEntry)
                if hdrRc ~= libarchive.ARCHIVE_OK then
                    streamErr = formatArchiveWriteError(libarchive, wr, tmpOut, "archive_write_header failed for " .. tostring(normPath))
                    break
                end

                if isEncDecomp or isEncNoDecomp then
                    local decOk, decErr = streamDecryptEntryToArchive(
                        libarchive, rd, wr, tmpOut, readBuf, bookKey, isEncNoDecomp
                    )
                    if not decOk then
                        streamErr = "Failed to decrypt " .. tostring(normPath) .. ": " .. tostring(decErr)
                        break
                    end
                    if isEncNoDecomp then
                        forceNoDecompCount = forceNoDecompCount + 1
                    else
                        decryptCount = decryptCount + 1
                    end
                    collectgarbage("step", 100)
                else
                    while true do
                        local n = tonumber(libarchive.archive_read_data(rd, readBuf, CHUNK_SIZE))
                        if not n or n < 0 then
                            streamErr = "EPUB read error on " .. tostring(normPath)
                            break
                        end
                        if n == 0 then
                            break
                        end
                        local wOk, wErr = writeArchiveBuffer(libarchive, wr, tmpOut, readBuf, n)
                        if not wOk then
                            streamErr = wErr
                            break
                        end
                    end
                    if streamErr then
                        break
                    end
                end
            end

            if totalFiles > 0 and (processedFiles % 4 == 0 or processedFiles == totalFiles) then
                reportProgress(0.15 + 0.80 * (processedFiles / totalFiles))
            end
        end
    end

    libarchive.archive_entry_free(inEntry)
    libarchive.archive_read_close(rd)
    libarchive.archive_free(rd)
    rd = nil

    local closeRc = libarchive.archive_write_close(wr)
    if not streamErr and closeRc ~= libarchive.ARCHIVE_OK then
        streamErr = formatArchiveWriteError(libarchive, wr, tmpOut, "Failed to close EPUB archive")
    end
    libarchive.archive_free(wr)
    wr = nil

    if streamErr then
        os.remove(tmpOut)
        return nil, streamErr
    end

    if not hasContainer then
        os.remove(tmpOut)
        return nil, "Repacked EPUB is missing META-INF/container.xml"
    end

    os.remove(outputPath)
    local renOk, renErr = os.rename(tmpOut, outputPath)
    if not renOk then
        os.remove(tmpOut)
        return nil, "Failed to finalize EPUB: " .. tostring(renErr)
    end

    reportProgress(1.0)
    if not parsed then
        return {
            outputPath = outputPath,
            decryptedEntries = 0,
            remainingEncryptionXml = false,
            strippedWatermarkFiles = 0,
            unencrypted = true,
        }
    end
    return {
        outputPath = outputPath,
        decryptedEntries = decryptCount + forceNoDecompCount,
        remainingEncryptionXml = parsed.rewrittenXml ~= nil,
        strippedWatermarkFiles = 0,
    }
end

function epub.decryptAdobeEpub(inputPath, outputPath, bookKey, progress_cb)
    local function reportProgress(frac)
        if progress_cb then
            pcall(progress_cb, frac)
        end
    end
    logger.info("[ACSM] decryptAdobeEpub: input=", inputPath, "output=", outputPath)

    local libarchive = getLibarchive()
    if libarchive then
        return streamDecryptAdobeEpub(libarchive, inputPath, outputPath, bookKey, reportProgress)
    end
    local workDir, workErr = makeTempDir()
    if not workDir then
        return nil, workErr
    end
    logger.info("[ACSM] decryptAdobeEpub: workDir=", workDir)
    reportProgress(0.10)
    local ok, err = extractEpub(inputPath, workDir)
    if not ok then
        logger.warn("[ACSM] decryptAdobeEpub: failed to extract epub:", err)
        removeTree(workDir)
        return nil, err
    end
    logger.info("[ACSM] decryptAdobeEpub: extracted, reading encryption.xml...")

    local encryptionPath = workDir .. "/META-INF/encryption.xml"
    local encryptionXml = koutil.readFromFile(encryptionPath, "rb")
    if not encryptionXml then
        logger.info("[ACSM] decryptAdobeEpub: no encryption.xml found — EPUB is not encrypted")
        os.remove(workDir .. "/META-INF/rights.xml")
        local watermarkFiles = stripAdeptWatermarks(workDir) or 0
        reportProgress(0.85)
        local repackOk, repackErr = repackEpub(workDir, outputPath, parsed.encryptedForceNoDecomp)
        removeTree(workDir)
        if not repackOk then
            return nil, repackErr
        end
        reportProgress(1.0)
        return {
            outputPath = outputPath,
            decryptedEntries = 0,
            remainingEncryptionXml = false,
            strippedWatermarkFiles = watermarkFiles,
            unencrypted = true,
        }
    end

    local parsed = parseEncryptionXml(encryptionXml)
    logger.info("[ACSM] decryptAdobeEpub: parsed encryption, decrypting entries...")
    reportProgress(0.25)

    local totalEncrypted = 0
    for _ in pairs(parsed.encrypted) do totalEncrypted = totalEncrypted + 1 end
    for _ in pairs(parsed.encryptedForceNoDecomp) do totalEncrypted = totalEncrypted + 1 end
    local doneEncrypted = 0

    local extractedFiles = listFiles(workDir) or {}
    local lowerFileMap = {}
    local exactFileMap = {}
    for _, fpath in ipairs(extractedFiles) do
        exactFileMap[fpath] = fpath
        lowerFileMap[fpath:lower()] = fpath
    end

    local function resolveEntryRelPath(uri)
        local norm = normalizeZipPath(uri)
        if norm and exactFileMap[norm] then
            return exactFileMap[norm]
        end
        local decoded = normalizeZipPath(urlDecode(uri))
        if decoded and exactFileMap[decoded] then
            return exactFileMap[decoded]
        end
        if norm and lowerFileMap[norm:lower()] then
            return lowerFileMap[norm:lower()]
        end
        if decoded and lowerFileMap[decoded:lower()] then
            return lowerFileMap[decoded:lower()]
        end
        return decoded or norm or uri
    end

    local decryptCount = 0
    for uri in pairs(parsed.encrypted) do
        local relPath = resolveEntryRelPath(uri)
        local fullPath = workDir .. "/" .. relPath
        local _decOk, decErr = decryptAdeptEntryFile(fullPath, bookKey, false)
        if not _decOk then
            removeTree(workDir)
            return nil, "Failed to decrypt " .. tostring(relPath) .. ": " .. tostring(decErr)
        end
        collectgarbage("step", 200)
        decryptCount = decryptCount + 1
        doneEncrypted = doneEncrypted + 1
        if totalEncrypted > 0 then
            reportProgress(0.25 + (0.60 * (doneEncrypted / totalEncrypted)))
        end
    end
    logger.info("[ACSM] decryptAdobeEpub: decrypted", decryptCount, "entries with decompression")

    local forceNoDecompCount = 0
    for uri in pairs(parsed.encryptedForceNoDecomp) do
        local relPath = resolveEntryRelPath(uri)
        local fullPath = workDir .. "/" .. relPath
        local _decOk, decErr = decryptAdeptEntryFile(fullPath, bookKey, true)
        if not _decOk then
            removeTree(workDir)
            return nil, "Failed to decrypt " .. tostring(relPath) .. ": " .. tostring(decErr)
        end
        collectgarbage("step", 200)
        forceNoDecompCount = forceNoDecompCount + 1
        doneEncrypted = doneEncrypted + 1
        if totalEncrypted > 0 then
            reportProgress(0.25 + (0.60 * (doneEncrypted / totalEncrypted)))
        end
    end
    logger.info("[ACSM] decryptAdobeEpub: decrypted", forceNoDecompCount, "entries without decompression")

    os.remove(workDir .. "/META-INF/rights.xml")
    if parsed.rewrittenXml then
        assert(koutil.writeToFile(parsed.rewrittenXml, encryptionPath))
    else
        os.remove(encryptionPath)
    end

    local watermarkFiles, watermarkErr = stripAdeptWatermarks(workDir)
    if not watermarkFiles then
        removeTree(workDir)
        return nil, watermarkErr
    end

    reportProgress(0.90)
    local repackOk, repackErr = repackEpub(workDir, outputPath, parsed.encryptedForceNoDecomp)
    if not repackOk then
        logger.warn("[ACSM] decryptAdobeEpub: failed to repack:", repackErr)
        removeTree(workDir)
        return nil, repackErr
    end
    logger.info("[ACSM] decryptAdobeEpub: repacked successfully to", outputPath)

    removeTree(workDir)
    reportProgress(1.0)

    return {
        outputPath = outputPath,
        decryptedEntries = (function()
            local count = 0
            for _ in pairs(parsed.encrypted) do
                count = count + 1
            end
            for _ in pairs(parsed.encryptedForceNoDecomp) do
                count = count + 1
            end
            return count
        end)(),
        remainingEncryptionXml = parsed.rewrittenXml ~= nil,
        strippedWatermarkFiles = watermarkFiles,
    }
end

--- Extracts the base64-encoded ADEPT encryptedKey from META-INF/rights.xml
function epub.extractEncryptedKeyFromEpub(inputPath)
    local reader = Archiver.Reader:new()
    if not reader:open(inputPath) then
        return nil, reader.err or "Could not open EPUB archive"
    end
    local rightsEntry = nil
    for entry in reader:iterate() do
        if entry.mode == "file" then
            local norm = normalizeZipPath(entry.path)
            if norm and norm:lower() == "meta-inf/rights.xml" then
                rightsEntry = entry.path
                break
            end
        end
    end
    local rightsXml = rightsEntry and reader:extractToMemory(rightsEntry) or nil
    reader:close()
    if not rightsXml or rightsXml == "" then
        return nil, "No rights.xml found"
    end
    local key = rightsXml:match("<[%w_:]*encryptedKey[^>]*>([^<]+)</[%w_:]*encryptedKey>")
    if key then
        return key:gsub("%s+", "")
    end
    return nil, "No encryptedKey found in rights.xml"
end

--- Attempts to extract and optionally decrypt the book cover image from an EPUB
function epub.extractCoverImage(inputPath, bookKey)
    local reader = Archiver.Reader:new()
    if not reader:open(inputPath) then
        return nil, reader.err or "Could not open EPUB archive"
    end

    local candidateEntry = nil
    local encXmlEntry = nil
    for entry in reader:iterate() do
        if entry.mode == "file" then
            local norm = normalizeZipPath(entry.path)
            local lower = (norm or entry.path):lower()
            if lower == "meta-inf/encryption.xml" then
                encXmlEntry = entry.path
            end
            if not candidateEntry and (lower:match("%.jpe?g$") or lower:match("%.png$")) and lower:match("cover") then
                candidateEntry = entry.path
            end
        end
    end

    if not candidateEntry then
        reader:close()
        return nil, "No cover image found"
    end

    local encryptedEntries = {}
    local forceNoDecomp = {}
    if encXmlEntry then
        local encXml = reader:extractToMemory(encXmlEntry)
        if encXml and encXml ~= "" then
            local parsed = parseEncryptionXml(encXml)
            if parsed then
                for k, v in pairs(parsed.encrypted or {}) do
                    encryptedEntries[k] = v
                    local n = normalizeZipPath(urlDecode(k))
                    if n then encryptedEntries[n:lower()] = v end
                end
                for k, v in pairs(parsed.encryptedForceNoDecomp or {}) do
                    forceNoDecomp[k] = v
                    local n = normalizeZipPath(urlDecode(k))
                    if n then forceNoDecomp[n:lower()] = v end
                end
            end
        end
    end

    local data = reader:extractToMemory(candidateEntry)
    reader:close()
    if not data or #data == 0 then
        return nil, "Failed to read cover data"
    end

    local ext = candidateEntry:lower():match("%.png$") and "png" or "jpg"
    local normCand = normalizeZipPath(candidateEntry)
    local candLower = normCand and normCand:lower() or candidateEntry:lower()
    local isEncrypted = encryptedEntries[candidateEntry] or encryptedEntries[candLower] or forceNoDecomp[candidateEntry] or forceNoDecomp[candLower]
    local needsDecomp = (encryptedEntries[candidateEntry] or encryptedEntries[candLower]) and not (forceNoDecomp[candidateEntry] or forceNoDecomp[candLower])

    if isEncrypted then
        if not bookKey or #bookKey == 0 then
            return nil, "Encrypted cover but no book key provided"
        end

        local decData, decErr = nativecrypto.aes_cbc_decrypt(bookKey, string.rep("\0", 16), data, true)
        if not decData or #decData <= 16 then
            return nil, "Failed to decrypt cover: " .. tostring(decErr)
        end

        -- 1. Discard 16-byte random prefix
        local body = decData:sub(17)

        -- 2. Strip PKCS#7 padding
        local pad = body:byte(-1)
        if pad and pad >= 1 and pad <= 16 and pad <= #body then
            local validPad = true
            for i = #body - pad + 1, #body do
                if body:byte(i) ~= pad then
                    validPad = false
                    break
                end
            end
            if validPad then
                body = body:sub(1, -1 - pad)
            end
        end

        -- 3. Decompress if needed (AES-128-CBC compressed entries)
        if needsDecomp then
            local inf, infErr = zlib.rawInflater()
            if not inf then
                return nil, "Failed to create inflater for cover: " .. tostring(infErr)
            end
            local chunks = {}
            local ok, updErr = inf:update(body, #body, function(ptr, len)
                table.insert(chunks, ffi.string(ptr, len))
                return true
            end)
            local finOk = inf:finalize()
            if not ok or not finOk then
                return nil, "Failed to inflate decrypted cover: " .. tostring(updErr or "truncated stream")
            end
            data = table.concat(chunks)
        else
            data = body
        end
    end

    -- Validate magic bytes so we never write corrupt/ciphertext data as an image
    local function detectImageExt(bytes)
        if not bytes or #bytes < 4 then return nil end
        if bytes:byte(1) == 0xFF and bytes:byte(2) == 0xD8 and bytes:byte(3) == 0xFF then
            return "jpg"
        end
        if bytes:byte(1) == 0x89 and bytes:byte(2) == 0x50 and bytes:byte(3) == 0x4E and bytes:byte(4) == 0x47 then
            return "png"
        end
        if bytes:sub(1, 4) == "GIF8" then
            return "gif"
        end
        if #bytes >= 12 and bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP" then
            return "webp"
        end
        return nil
    end

    local detectedExt = detectImageExt(data)
    if not detectedExt then
        return nil, "Cover data is not a recognized image format"
    end

    return data, detectedExt or ext
end

-- Export internal functions for testing (underscore-prefixed = internal API)
epub._parseEncryptionXml = parseEncryptionXml
epub._makeTempDir = makeTempDir
epub._removeTree = removeTree
epub._stripPkcs7Held = stripPkcs7Held
epub._stripAdeptWatermarksFromText = stripAdeptWatermarksFromText
epub._decryptAdeptEntryFile = decryptAdeptEntryFile

return epub
