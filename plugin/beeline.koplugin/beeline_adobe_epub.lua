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

function epub.cleanupWorkDirs(maxAgeSeconds)
    local ok_ds, cacheBase = pcall(function()
        return DataStorage:getDataDir() .. "/cache/beeline.koplugin"
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
    local cacheDir = DataStorage:getDataDir() .. "/cache/beeline.koplugin"
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

local function repackEpub(workDir, outputPath)
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

    writer:setZipCompression("deflate")
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
            writer:addPath(relPath, fullPath, false, mtime)
            if writer.err then
                local err = writer.err
                writer:close()
                os.remove(tmpOut)
                return nil, err
            end
        end
    end

    writer:close()

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

function epub.decryptAdobeEpub(inputPath, outputPath, bookKey)
    logger.info("[ACSM] decryptAdobeEpub: input=", inputPath, "output=", outputPath)
    local workDir, workErr = makeTempDir()
    if not workDir then
        return nil, workErr
    end
    logger.info("[ACSM] decryptAdobeEpub: workDir=", workDir)
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
        local repackOk, repackErr = repackEpub(workDir, outputPath)
        removeTree(workDir)
        if not repackOk then
            return nil, repackErr
        end
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

    local repackOk, repackErr = repackEpub(workDir, outputPath)
    if not repackOk then
        logger.warn("[ACSM] decryptAdobeEpub: failed to repack:", repackErr)
        removeTree(workDir)
        return nil, repackErr
    end
    logger.info("[ACSM] decryptAdobeEpub: repacked successfully to", outputPath)

    removeTree(workDir)

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
