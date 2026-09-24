import crypto from "node:crypto";
import fs from "node:fs";

import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

async function run() {
  const code = "BEE-742";
  const normalizedCode = code.toUpperCase().replace(/[\s-]/g, "");
  const filename = "test_loan.acsm";
  const fileContent = Buffer.from("<?xml version=\"1.0\"?><fulfillmentToken>test_content</fulfillmentToken>");

  // 1. Device routing ID
  const hash = crypto.createHash("sha256").update(normalizedCode + ":beeline-device-id").digest("hex");
  const deviceId = hash.substring(0, 16);
  console.log("Device ID (16 hex):", deviceId);

  // 2. Encryption
  const salt = crypto.randomBytes(16);
  const iv = crypto.randomBytes(12);

  // PBKDF2 100,000 iterations SHA-256
  const key = crypto.pbkdf2Sync(normalizedCode, salt, 100000, 32, "sha256");

  const headerObj = {
    filename: filename,
    size: fileContent.length,
    mime: "application/vnd.adobe.adept+xml",
    timestamp: Date.now()
  };
  const headerBuf = Buffer.from(JSON.stringify(headerObj));
  const lenBuf = Buffer.alloc(4);
  lenBuf.writeUInt32BE(headerBuf.length, 0);

  const plaintext = Buffer.concat([lenBuf, headerBuf, fileContent]);

  const cipher = crypto.createCipheriv("aes-256-gcm", key, iv);
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const tag = cipher.getAuthTag();

  const envelope = Buffer.concat([salt, iv, ciphertext, tag]);

  const targetPath = path.join(__dirname, "test_envelope.bin");
  fs.writeFileSync(targetPath, envelope);
  console.log("Generated test_envelope.bin at", targetPath);
}

run();
