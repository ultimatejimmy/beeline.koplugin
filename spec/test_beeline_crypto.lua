package.path = "plugin/beeline.koplugin/?.lua;beeline/plugin/beeline.koplugin/?.lua;" .. package.path

local crypto = require("beeline_crypto")
assert(crypto.isAvailable(), "Crypto must be available")

local hash = crypto.getDeviceHash("BEE-742")
print("Lua Device Hash:", hash)
assert(hash == "a77efcd7daac7dd3", "Device hash must match Node.js SHA-256 output!")
assert(crypto.getDeviceHash("bee742") == "a77efcd7daac7dd3", "Hyphenless code must match!")

-- Read test_envelope.bin
local f = io.open("spec/test_envelope.bin", "rb") or io.open("beeline/spec/test_envelope.bin", "rb")
assert(f, "test_envelope.bin not found")
local envelope = f:read("*a")
f:close()

-- Test 1: Decrypt with formatted pairing code
local result, err = crypto.decryptEnvelope(envelope, "BEE-742")
assert(result, "Decryption failed: " .. tostring(err))
print("Decrypted filename:", result.metadata.filename)
print("Decrypted data:", result.data)

assert(result.metadata.filename == "test_loan.acsm", "Filename mismatch")
assert(result.data == "<?xml version=\"1.0\"?><fulfillmentToken>test_content</fulfillmentToken>", "Data mismatch")

-- Test 2: Decrypt without hyphens / with lowercase & spaces in pairing code
local result2 = crypto.decryptEnvelope(envelope, " bee 742 ")
assert(result2 and result2.metadata.filename == "test_loan.acsm", "Normalization failed")
local result3 = crypto.decryptEnvelope(envelope, "bee742")
assert(result3 and result3.metadata.filename == "test_loan.acsm", "Hyphenless decryption failed")

-- Test 3: Decrypt with WRONG pairing code (must fail tag check)
local wrong_result, wrong_err = crypto.decryptEnvelope(envelope, "BEE-999")
assert(wrong_result == nil, "Wrong key must NOT succeed")
print("Expected failure on wrong key:", wrong_err)

-- Test 4: Tampered ciphertext (must fail tag check)
local tampered = envelope:sub(1, 40) .. string.char(bit.bxor(envelope:byte(41), 1)) .. envelope:sub(42)
local tamp_result, tamp_err = crypto.decryptEnvelope(tampered, "BEE-742")
assert(tamp_result == nil, "Tampered ciphertext must fail authentication")
print("Expected failure on tampered data:", tamp_err)

pcall(os.remove, "beeline/spec/test_envelope.bin")
print("ALL CRYPTO SPEC TESTS PASSED!")
