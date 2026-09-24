package.path = "beeline/plugin/beeline.koplugin/?.lua;" .. package.path

local crypto = require("beeline_crypto")
assert(crypto.isAvailable(), "Crypto must be available")

local f = io.open("beeline/spec/downloaded_envelope.bin", "rb")
assert(f, "downloaded_envelope.bin not found")
local envelope = f:read("*a")
f:close()

local result, err = crypto.decryptEnvelope(envelope, "BEE-900")
assert(result, "Decryption of downloaded envelope failed: " .. tostring(err))

print("Decrypted filename:", result.metadata.filename)
print("Decrypted size:", result.metadata.size)
print("Decrypted data:", result.data)

assert(result.metadata.filename == "War_and_Peace.epub", "Filename mismatch")
assert(result.data == "PK\x03\x04DummyEpubContentForTesting12345", "Data mismatch")

print("SUCCESS: Full End-to-End Cryptographic & Worker Round-Trip Verified!")
