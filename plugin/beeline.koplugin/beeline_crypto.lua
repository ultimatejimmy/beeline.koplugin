-- beeline_crypto.lua — OpenSSL EVP AES-256-GCM Decryptor & PBKDF2 for Beeline
-- Provides client-side Zero-Knowledge decryption matching the Web Crypto API.

local ffi = require("ffi")

local M = {}

local libcrypto = nil

local function initLibcrypto()
    if libcrypto then return libcrypto end

    -- Check if KOReader provides ffi.loadlib (soname version probe)
    if ffi.loadlib then
        local ok, lib = pcall(ffi.loadlib,
            "crypto", "60", "crypto", "59", "crypto", "58", "crypto", "57",
            "crypto", "56", "crypto", "55", "crypto", "54", "crypto", "53",
            "crypto", "52", "crypto", "51", "crypto", "50", "crypto", "48",
            "crypto", "47", "crypto", "46", "crypto", "45", "crypto", nil
        )
        if ok and lib then
            libcrypto = lib
            return libcrypto
        end
    end

    local candidate_names = {
        "crypto",
        "crypto.so.3",
        "crypto.so.1.1",
        "libcrypto.so.3",
        "libcrypto.so.1.1",
        "libcrypto.so.57",
        "libcrypto.so.56",
        "libcrypto.so.55",
        "libcrypto.so.52",
        "libcrypto.so.50",
        "libcrypto.so",
        "libs/libcrypto.so",
        "libs/libcrypto.so.57",
        "libs/libcrypto.so.55",
        "libcrypto.dylib",
    }

    for _, name in ipairs(candidate_names) do
        local ok, lib = pcall(ffi.load, name)
        if ok and lib then
            libcrypto = lib
            return libcrypto
        end
    end

    return nil
end

initLibcrypto()

pcall(ffi.cdef, [[
typedef struct evp_cipher_ctx_st EVP_CIPHER_CTX;
typedef struct evp_cipher_st EVP_CIPHER;
typedef struct env_md_st EVP_MD;

EVP_CIPHER_CTX *EVP_CIPHER_CTX_new(void);
void EVP_CIPHER_CTX_free(EVP_CIPHER_CTX *c);
const EVP_CIPHER *EVP_aes_256_gcm(void);
const EVP_MD *EVP_sha256(void);

int PKCS5_PBKDF2_HMAC(const char *pass, int passlen,
                       const unsigned char *salt, int saltlen, int iter,
                       const EVP_MD *digest,
                       int keylen, unsigned char *out);

int EVP_CIPHER_CTX_ctrl(EVP_CIPHER_CTX *ctx, int type, int arg, void *ptr);

int EVP_DecryptInit_ex(EVP_CIPHER_CTX *ctx, const EVP_CIPHER *cipher, void *impl,
                       const unsigned char *key, const unsigned char *iv);
int EVP_DecryptUpdate(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl,
                      const unsigned char *in, int inl);
int EVP_DecryptFinal_ex(EVP_CIPHER_CTX *ctx, unsigned char *outm, int *outl);

unsigned char *SHA256(const unsigned char *d, size_t n, unsigned char *md);
]])

local EVP_CTRL_GCM_SET_IVLEN = 9
local EVP_CTRL_GCM_SET_TAG   = 17

function M.isAvailable()
    return libcrypto ~= nil
end

local function normalizeCode(code)
    if type(code) ~= "string" then return "" end
    return code:upper():gsub("[%s%-]+", "")
end
M.normalizeCode = normalizeCode

function M.sha256Hex(str)
    if not libcrypto then return nil, "libcrypto unavailable" end
    local md = ffi.new("unsigned char[32]")
    libcrypto.SHA256(str, #str, md)
    local hex = {}
    for i = 0, 31 do
        table.insert(hex, string.format("%02x", md[i]))
    end
    return table.concat(hex)
end

--- Computes the 64-hex registration hash for single-use pairing code:
-- codeHash = SHA-256(normalizedCode + ":beeline-pairing")
function M.getCodeHash(pairing_code)
    local code = normalizeCode(pairing_code)
    if code == "" then return nil, "Empty pairing code" end
    return M.sha256Hex(code .. ":beeline-pairing")
end

--- Computes the 16-hex device routing identifier from the user's pairing code:
-- deviceHash = SHA-256(code + ":beeline-device-id")[1..16]
function M.getDeviceHash(pairing_code)
    if not libcrypto then return nil, "libcrypto unavailable" end
    local code = normalizeCode(pairing_code)
    if code == "" then return nil, "Empty pairing code" end

    local input = code .. ":beeline-device-id"
    local md = ffi.new("unsigned char[32]")
    libcrypto.SHA256(input, #input, md)

    local hex = {}
    for i = 0, 7 do -- 8 bytes = 16 hex chars
        table.insert(hex, string.format("%02x", md[i]))
    end
    return table.concat(hex)
end

--- Derives a 32-byte (256-bit) AES key using PBKDF2 (SHA-256, 100,000 iterations)
function M.deriveKey(pairing_code, salt_bytes)
    if not libcrypto then return nil, "libcrypto unavailable" end
    local code = normalizeCode(pairing_code)
    if code == "" then return nil, "Empty pairing code" end
    if not salt_bytes or #salt_bytes < 16 then return nil, "Invalid salt" end

    local key_buf = ffi.new("unsigned char[32]")
    local salt_buf = ffi.new("unsigned char[16]", salt_bytes)

    local ret = libcrypto.PKCS5_PBKDF2_HMAC(
        code,
        #code,
        salt_buf,
        16,
        100000,
        libcrypto.EVP_sha256(),
        32,
        key_buf
    )

    if ret <= 0 then
        return nil, "PBKDF2 key derivation failed"
    end

    return ffi.string(key_buf, 32)
end

local function parseJson(raw)
    local ok_rj, rapidjson = pcall(require, "rapidjson")
    if ok_rj and rapidjson then
        local ok, res = pcall(rapidjson.decode, raw)
        if ok and type(res) == "table" then return res end
    end
    local ok_j, json = pcall(require, "json")
    if ok_j and json then
        local ok, res = pcall(json.decode, raw)
        if ok and type(res) == "table" then return res end
    end
    -- Minimal fallback parser for { "filename": "...", "size": ... }
    local fn = raw:match('"filename"%s*:%s*"([^"]+)"')
    local sz = tonumber(raw:match('"size"%s*:%s*(%d+)')) or 0
    local mime = raw:match('"mime"%s*:%s*"([^"]+)"')
    if fn then
        return { filename = fn, size = sz, mime = mime }
    end
    return nil
end

--- Decrypts a binary envelope generated by Beeline Web Client:
-- [16B salt][12B iv][ciphertext][16B tag]
-- Plaintext format: [4B big-endian header length][JSON header][file bytes]
function M.decryptEnvelope(envelope_bytes, pairing_code)
    if not libcrypto then return nil, "libcrypto unavailable" end
    if type(envelope_bytes) ~= "string" or #envelope_bytes < 48 then
        return nil, "Invalid envelope (too short)"
    end

    local salt = envelope_bytes:sub(1, 16)
    local iv = envelope_bytes:sub(17, 28)
    local ciphertext_and_tag = envelope_bytes:sub(29)

    if #ciphertext_and_tag < 17 then
        return nil, "Invalid ciphertext format"
    end

    local tag = ciphertext_and_tag:sub(-16)
    local ciphertext = ciphertext_and_tag:sub(1, -17)

    -- Derive key
    local key, key_err = M.deriveKey(pairing_code, salt)
    if not key then return nil, key_err end

    local ctx = libcrypto.EVP_CIPHER_CTX_new()
    if ctx == nil then
        return nil, "Failed to create EVP_CIPHER_CTX"
    end

    local cipher = libcrypto.EVP_aes_256_gcm()
    local ok = (libcrypto.EVP_DecryptInit_ex(ctx, cipher, nil, nil, nil) > 0)
    if not ok then
        libcrypto.EVP_CIPHER_CTX_free(ctx)
        return nil, "EVP_DecryptInit_ex failed"
    end

    -- Set IV length (12 bytes)
    libcrypto.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, 12, nil)

    -- Set Key and IV
    local key_ptr = ffi.cast("const unsigned char *", key)
    local iv_ptr = ffi.cast("const unsigned char *", iv)
    if libcrypto.EVP_DecryptInit_ex(ctx, nil, nil, key_ptr, iv_ptr) <= 0 then
        libcrypto.EVP_CIPHER_CTX_free(ctx)
        return nil, "EVP_DecryptInit_ex (key/iv) failed"
    end

    -- Decrypt ciphertext
    local out_buf = ffi.new("unsigned char[?]", #ciphertext + 16)
    local outl = ffi.new("int[1]")
    local cipher_ptr = ffi.cast("const unsigned char *", ciphertext)

    if libcrypto.EVP_DecryptUpdate(ctx, out_buf, outl, cipher_ptr, #ciphertext) <= 0 then
        libcrypto.EVP_CIPHER_CTX_free(ctx)
        return nil, "EVP_DecryptUpdate failed"
    end
    local decrypted_len = outl[0]

    -- Set expected authentication tag
    local tag_ptr = ffi.cast("void *", ffi.cast("const unsigned char *", tag))
    libcrypto.EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, 16, tag_ptr)

    -- Finalize and verify tag
    local final_outl = ffi.new("int[1]")
    local ret = libcrypto.EVP_DecryptFinal_ex(ctx, out_buf + decrypted_len, final_outl)
    libcrypto.EVP_CIPHER_CTX_free(ctx)

    if ret <= 0 then
        return nil, "Decryption authentication failed: wrong pairing code or corrupt file"
    end

    decrypted_len = decrypted_len + final_outl[0]
    local plaintext = ffi.string(out_buf, decrypted_len)

    if #plaintext < 5 then
        return nil, "Decrypted payload corrupted (too short)"
    end

    -- Read 4-byte big-endian header length
    local b1, b2, b3, b4 = plaintext:byte(1, 4)
    local header_len = (b1 * 16777216) + (b2 * 65536) + (b3 * 256) + b4

    if #plaintext < (4 + header_len) then
        return nil, "Invalid header length in decrypted payload"
    end

    local header_json = plaintext:sub(5, 4 + header_len)
    local file_data = plaintext:sub(5 + header_len)

    local meta = parseJson(header_json) or {
        filename = "received_book.bin",
        size = #file_data,
    }

    return {
        metadata = meta,
        data = file_data,
    }
end

return M
