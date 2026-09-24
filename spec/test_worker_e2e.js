import worker from "../worker/worker.js";
import crypto from "node:crypto";
import fs from "node:fs";

async function run() {
  console.log("=== BEELINE WORKER PAIRING & E2E TEST ===");

  const env = {}; // Uses in-memory store fallback

  // 1. Health Ping
  const pingReq = new Request("https://beeline.example.com/api/ping");
  const pingResp = await worker.fetch(pingReq, env);
  const pingData = await pingResp.json();
  console.log("1. /api/ping ->", pingData);
  if (!pingData.ok || pingData.service !== "beeline-worker") {
    throw new Error("Ping failed!");
  }

  // 2. Web UI HTML test
  const htmlReq = new Request("https://beeline.example.com/");
  const htmlResp = await worker.fetch(htmlReq, env);
  const html = await htmlResp.text();
  console.log("2. GET / status ->", htmlResp.status, "HTML bytes:", html.length);
  if (!html.includes("Beeline") || !html.includes("KOReader Pairing Code")) {
    throw new Error("HTML missing Beeline markup");
  }

  // 3. Test UNPAIRED state (Pairing code: BEE-900)
  const pairingCode = "BEE-900";
  const normalizedCode = pairingCode.toUpperCase().replace(/[\s-]/g, "");
  const hash = crypto.createHash("sha256").update(normalizedCode + ":beeline-device-id").digest("hex");
  const deviceId = hash.substring(0, 16);
  console.log("Device ID:", deviceId);

  // Check pairing for unpaired device
  const pairCheckReq1 = new Request(`https://beeline.example.com/api/pair?device=${deviceId}`);
  const pairCheckResp1 = await worker.fetch(pairCheckReq1, env);
  const pairCheckData1 = await pairCheckResp1.json();
  console.log("3a. Unpaired check ->", pairCheckData1);
  if (pairCheckData1.paired !== false) {
    throw new Error("Device should not be paired yet!");
  }

  // Try uploading to unpaired device (MUST BE REJECTED with 403)
  const dummyPayload = Buffer.from(new Uint8Array(50));
  const badUploadReq = new Request("https://beeline.example.com/api/upload", {
    method: "POST",
    headers: {
      "Content-Type": "application/octet-stream",
      "X-Device-Id": deviceId,
    },
    body: dummyPayload,
  });
  const badUploadResp = await worker.fetch(badUploadReq, env);
  console.log("3b. Unpaired upload rejection status ->", badUploadResp.status);
  if (badUploadResp.status !== 403) {
    throw new Error("Upload to unpaired device must be rejected with HTTP 403 Forbidden!");
  }

  // 4. Register pairing from KOReader (POST /api/pair)
  const registerPairReq = new Request("https://beeline.example.com/api/pair", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Device-Id": deviceId,
    }
  });
  const registerPairResp = await worker.fetch(registerPairReq, env);
  const registerPairData = await registerPairResp.json();
  console.log("4. Register device pairing ->", registerPairData);
  if (!registerPairData.ok || !registerPairData.paired) {
    throw new Error("Failed to register device pairing!");
  }

  // Verify pairing is now ACTIVE
  const pairCheckReq2 = new Request(`https://beeline.example.com/api/pair?device=${deviceId}`);
  const pairCheckResp2 = await worker.fetch(pairCheckReq2, env);
  const pairCheckData2 = await pairCheckResp2.json();
  console.log("5. Verified active pairing ->", pairCheckData2);
  if (pairCheckData2.paired !== true) {
    throw new Error("Device should now be verified as paired!");
  }

  // 6. Now perform authenticated upload of encrypted book
  const filename = "War_and_Peace.epub";
  const dummyEpubContent = Buffer.from("PK\x03\x04DummyEpubContentForTesting12345");

  const salt = crypto.randomBytes(16);
  const iv = crypto.randomBytes(12);
  const key = crypto.pbkdf2Sync(pairingCode, salt, 100000, 32, "sha256");

  const headerObj = {
    filename: filename,
    size: dummyEpubContent.length,
    mime: "application/epub+zip",
    timestamp: Date.now()
  };
  const headerBuf = Buffer.from(JSON.stringify(headerObj));
  const lenBuf = Buffer.alloc(4);
  lenBuf.writeUInt32BE(headerBuf.length, 0);

  const plaintext = Buffer.concat([lenBuf, headerBuf, dummyEpubContent]);
  const cipher = crypto.createCipheriv("aes-256-gcm", key, iv);
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const tag = cipher.getAuthTag();

  const envelope = Buffer.concat([salt, iv, ciphertext, tag]);

  const uploadReq = new Request("https://beeline.example.com/api/upload", {
    method: "POST",
    headers: {
      "Content-Type": "application/octet-stream",
      "X-Device-Id": deviceId,
    },
    body: envelope,
  });
  const uploadResp = await worker.fetch(uploadReq, env);
  const uploadData = await uploadResp.json();
  console.log("6. Upload after pairing ->", uploadData);
  if (!uploadData.ok || !uploadData.id) {
    throw new Error("Upload failed: " + JSON.stringify(uploadData));
  }
  const fileId = uploadData.id;

  // 7. Query inbox
  const inboxReq = new Request(`https://beeline.example.com/api/inbox?device=${deviceId}`);
  const inboxResp = await worker.fetch(inboxReq, env);
  const inboxData = await inboxResp.json();
  console.log("7. /api/inbox ->", inboxData);
  if (!inboxData.ok || inboxData.files.length !== 1 || inboxData.files[0].id !== fileId) {
    throw new Error("Inbox listing failed!");
  }

  // 8. Download file
  const dlReq = new Request(`https://beeline.example.com/api/download?id=${fileId}&device=${deviceId}`);
  const dlResp = await worker.fetch(dlReq, env);
  const downloadedBytes = Buffer.from(await dlResp.arrayBuffer());
  console.log("8. /api/download -> HTTP", dlResp.status, "bytes:", downloadedBytes.length);
  if (downloadedBytes.length !== envelope.length || !downloadedBytes.equals(envelope)) {
    throw new Error("Downloaded bytes do not match uploaded envelope!");
  }

  // 9. Delete file
  const delReq = new Request(`https://beeline.example.com/api/download?id=${fileId}&device=${deviceId}`, {
    method: "DELETE"
  });
  const delResp = await worker.fetch(delReq, env);
  const delData = await delResp.json();
  console.log("9. DELETE /api/download ->", delData);
  if (!delData.ok || !delData.deleted) {
    throw new Error("Deletion failed!");
  }

  // =========================================================================
  // 10. Single-Use Pairing & Multi-Browser Pairing Tests
  // =========================================================================
  console.log("\n--- Testing Single-Use Pairing & Multi-Browser Pairing ---");
  const koreaderDeviceId = "koreader-device-778899aabbcc";
  const code1 = "K9B-4X2";
  const norm1 = code1.toUpperCase().replace(/[\s-]/g, "");
  const codeHash1 = crypto.createHash("sha256").update(norm1 + ":beeline-pairing").digest("hex");

  // 10a. KOReader registers code 1
  const regCodeReq1 = new Request("https://beeline.example.com/api/pair", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      action: "register_code",
      codeHash: codeHash1,
      deviceId: koreaderDeviceId,
    })
  });
  const regCodeResp1 = await worker.fetch(regCodeReq1, env);
  const regCodeData1 = await regCodeResp1.json();
  console.log("10a. Register code 1 ->", regCodeData1);
  if (!regCodeData1.ok || !regCodeData1.registered) {
    throw new Error("Failed to register code 1!");
  }

  // 10b. Browser 1 claims code 1 (First claim: MUST SUCCEED)
  const claimReq1 = new Request("https://beeline.example.com/api/pair", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      action: "claim_code",
      codeHash: codeHash1,
    })
  });
  const claimResp1 = await worker.fetch(claimReq1, env);
  const claimData1 = await claimResp1.json();
  console.log("10b. Browser 1 claims code 1 ->", claimResp1.status, claimData1);
  if (claimResp1.status !== 200 || !claimData1.ok || claimData1.deviceId !== koreaderDeviceId) {
    throw new Error("Browser 1 failed to claim code 1!");
  }

  // 10c-1. Check code status via check_code
  const checkCodeReq = new Request("https://beeline.example.com/api/pair", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "check_code", codeHash: codeHash1 })
  });
  const checkCodeResp = await worker.fetch(checkCodeReq, env);
  const checkCodeData = await checkCodeResp.json();
  console.log("10c-1. Check code 1 status ->", checkCodeData);
  if (!checkCodeData.ok || !checkCodeData.claimed) {
    throw new Error("Check code 1 should report claimed: true!");
  }

  // 10c-2. KOReader re-registers code 1 (must preserve claimed: true!)
  const reRegCodeReq1 = new Request("https://beeline.example.com/api/pair", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      action: "register_code",
      codeHash: codeHash1,
      deviceId: koreaderDeviceId,
    })
  });
  const reRegResp1 = await worker.fetch(reRegCodeReq1, env);
  const reRegData1 = await reRegResp1.json();
  console.log("10c-2. Re-register code 1 ->", reRegData1);
  if (!reRegData1.ok || !reRegData1.claimed) {
    throw new Error("Re-registering code 1 MUST return claimed: true and preserve claimed state!");
  }

  // 10c-3. Browser 2 tries to claim code 1 after re-registration (MUST STILL BE REJECTED with 409)
  const claimReq2 = new Request("https://beeline.example.com/api/pair", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      action: "claim_code",
      codeHash: codeHash1,
    })
  });
  const claimResp2 = await worker.fetch(claimReq2, env);
  const claimData2 = await claimResp2.json();
  console.log("10c-3. Browser 2 re-claims code 1 ->", claimResp2.status, claimData2);
  if (claimResp2.status !== 409) {
    throw new Error("Second claim of same code must be rejected with HTTP 409 even after re-registration!");
  }

  // 10d. KOReader generates and registers code 2 for the SAME device
  const code2 = "P4W-7N1";
  const norm2 = code2.toUpperCase().replace(/[\s-]/g, "");
  const codeHash2 = crypto.createHash("sha256").update(norm2 + ":beeline-pairing").digest("hex");

  const regCodeReq2 = new Request("https://beeline.example.com/api/pair", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      action: "register_code",
      codeHash: codeHash2,
      deviceId: koreaderDeviceId,
    })
  });
  const regCodeResp2 = await worker.fetch(regCodeReq2, env);
  const regCodeData2 = await regCodeResp2.json();
  console.log("10d. Register code 2 ->", regCodeData2);
  if (!regCodeData2.ok || !regCodeData2.registered) {
    throw new Error("Failed to register code 2!");
  }

  // 10e. Browser 2 claims code 2 (MUST SUCCEED)
  const claimReq3 = new Request("https://beeline.example.com/api/pair", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      action: "claim_code",
      codeHash: codeHash2,
    })
  });
  const claimResp3 = await worker.fetch(claimReq3, env);
  const claimData3 = await claimResp3.json();
  console.log("10e. Browser 2 claims code 2 ->", claimResp3.status, claimData3);
  if (claimResp3.status !== 200 || !claimData3.ok || claimData3.deviceId !== koreaderDeviceId) {
    throw new Error("Browser 2 failed to claim code 2!");
  }

  // 10f. Both browsers upload to the same deviceId using their respective codes
  // Browser 1 upload
  const b1UploadReq = new Request("https://beeline.example.com/api/upload", {
    method: "POST",
    headers: {
      "Content-Type": "application/octet-stream",
      "X-Device-Id": koreaderDeviceId,
    },
    body: Buffer.from(new Uint8Array(60)),
  });
  const b1UploadResp = await worker.fetch(b1UploadReq, env);
  const b1UploadData = await b1UploadResp.json();
  console.log("10f. Browser 1 upload ->", b1UploadData);
  if (!b1UploadData.ok) throw new Error("Browser 1 upload failed!");

  // Browser 2 upload
  const b2UploadReq = new Request("https://beeline.example.com/api/upload", {
    method: "POST",
    headers: {
      "Content-Type": "application/octet-stream",
      "X-Device-Id": koreaderDeviceId,
    },
    body: Buffer.from(new Uint8Array(70)),
  });
  const b2UploadResp = await worker.fetch(b2UploadReq, env);
  const b2UploadData = await b2UploadResp.json();
  console.log("10g. Browser 2 upload ->", b2UploadData);
  if (!b2UploadData.ok) throw new Error("Browser 2 upload failed!");

  // 10h. KOReader queries inbox for koreaderDeviceId and sees BOTH files
  const multiInboxReq = new Request(`https://beeline.example.com/api/inbox?device=${koreaderDeviceId}`);
  const multiInboxResp = await worker.fetch(multiInboxReq, env);
  const multiInboxData = await multiInboxResp.json();
  console.log("10h. KOReader inbox with 2 paired browsers ->", multiInboxData);
  if (!multiInboxData.ok || multiInboxData.files.length !== 2) {
    throw new Error("KOReader inbox should have exactly 2 incoming files from the 2 paired browsers!");
  }

  // =========================================================================
  // 11. Explicit Unpairing on KOReader (Disconnect All Browsers)
  // =========================================================================
  console.log("\n--- Testing Explicit Unpairing on KOReader ---");
  const unpairReq = new Request("https://beeline.example.com/api/pair", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      action: "unpair_device",
      deviceId: koreaderDeviceId,
    })
  });
  const unpairResp = await worker.fetch(unpairReq, env);
  const unpairData = await unpairResp.json();
  console.log("11a. Explicit unpair device ->", unpairData);
  if (!unpairData.ok || !unpairData.unpaired) {
    throw new Error("Failed to unpair device!");
  }

  // 11b. Verify device is now UNPAIRED
  const pairCheckReq3 = new Request(`https://beeline.example.com/api/pair?device=${koreaderDeviceId}`);
  const pairCheckResp3 = await worker.fetch(pairCheckReq3, env);
  const pairCheckData3 = await pairCheckResp3.json();
  console.log("11b. Unpaired device status check ->", pairCheckData3);
  if (pairCheckData3.paired !== false) {
    throw new Error("Device should be unpaired after revocation!");
  }

  // 11c. Subsequent uploads from previously paired browser must be rejected (403)
  const rejectedUploadReq = new Request("https://beeline.example.com/api/upload", {
    method: "POST",
    headers: {
      "Content-Type": "application/octet-stream",
      "X-Device-Id": koreaderDeviceId,
    },
    body: Buffer.from(new Uint8Array(60)),
  });
  const rejectedUploadResp = await worker.fetch(rejectedUploadReq, env);
  console.log("11c. Upload after explicit unpair -> HTTP", rejectedUploadResp.status);
  if (rejectedUploadResp.status !== 403) {
    throw new Error("Upload from revoked device must be rejected with 403!");
  }

  console.log("=== ALL PAIRING ENFORCEMENT & E2E TESTS PASSED! ===");
}

run().catch(err => {
  console.error("Test error:", err);
  process.exit(1);
});
