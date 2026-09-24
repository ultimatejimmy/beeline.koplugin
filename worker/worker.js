/**
 * Beeline — Zero-Trust Cloudflare Worker & Web Client
 * 
 * Provides an end-to-end encrypted, ephemeral transfer relay to send
 * .acsm tokens, EPUBs, PDFs, and documents from phone/PC to KOReader.
 */

const RETENTION_MS = 24 * 60 * 60 * 1000; // 24 hours ephemeral file TTL
const PAIRING_TTL_MS = 15 * 60 * 1000; // 15 minutes pairing code claim window

// In-memory fallback if neither R2 nor KV is configured
const memoryStore = new Map();

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // Handle CORS preflight
    if (request.method === "OPTIONS") {
      return handleCors();
    }

    try {
      if (url.pathname === "/" || url.pathname === "/index.html") {
        return handleWebUi(request);
      }

      if (url.pathname === "/api/ping") {
        return jsonResponse({ ok: true, service: "beeline-worker", version: "1.1.0" });
      }

      // Pairing verification and registration
      if (url.pathname === "/api/pair" && request.method === "POST") {
        return await handlePairRegister(request, env);
      }

      if (url.pathname === "/api/pair" && request.method === "GET") {
        return await handlePairCheck(url, env);
      }

      if (url.pathname === "/api/upload" && request.method === "POST") {
        return await handleUpload(request, env);
      }

      if (url.pathname === "/api/inbox" && request.method === "GET") {
        return await handleInbox(url, env);
      }

      if (url.pathname === "/api/download" && request.method === "GET") {
        return await handleDownload(url, env);
      }

      if (url.pathname === "/api/download" && request.method === "DELETE") {
        return await handleDelete(url, env);
      }

      return new Response("Not Found", { status: 404 });
    } catch (err) {
      return jsonResponse({ ok: false, error: err.message || String(err) }, 500);
    }
  }
};

function handleCors() {
  return new Response(null, {
    status: 204,
    headers: {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, X-Device-Id, Authorization",
      "Access-Control-Max-Age": "86400",
    }
  });
}

function jsonResponse(data, status = 200, headers = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Access-Control-Allow-Origin": "*",
      ...headers,
    }
  });
}

// ---------------------------------------------------------------------------
// Pairing State Helpers (Permanent until explicitly unpaired)
// ---------------------------------------------------------------------------

async function getDevicePairingInfo(deviceId, env) {
  if (!deviceId) return { paired: false };
  const key = `pair/${deviceId.toLowerCase()}`;

  if (env.BEELINE_BUCKET) {
    const obj = await env.BEELINE_BUCKET.get(key);
    return { paired: (obj !== null) };
  } else if (env.BEELINE_KV) {
    const val = await env.BEELINE_KV.get(key);
    return { paired: (val !== null) };
  } else {
    const item = memoryStore.get(key);
    return { paired: (item !== undefined && item !== null) };
  }
}

async function isDevicePaired(deviceId, env) {
  const info = await getDevicePairingInfo(deviceId, env);
  return info.paired;
}

async function registerDevicePairing(deviceId, env) {
  const key = `pair/${deviceId.toLowerCase()}`;
  const now = Date.now();

  if (env.BEELINE_BUCKET) {
    await env.BEELINE_BUCKET.put(key, new ArrayBuffer(0), {
      customMetadata: {
        pairedAt: String(now),
        permanent: "true",
      }
    });
  } else if (env.BEELINE_KV) {
    // Permanent storage: no expirationTtl
    await env.BEELINE_KV.put(key, "paired");
  } else {
    memoryStore.set(key, { pairedAt: now, permanent: true });
  }

  return null;
}

async function unregisterDevicePairing(deviceId, env) {
  const devKey = `pair/${deviceId.toLowerCase()}`;
  const prefix = `inbox/${deviceId.toLowerCase()}/`;

  if (env.BEELINE_BUCKET) {
    await env.BEELINE_BUCKET.delete(devKey);
    const list = await env.BEELINE_BUCKET.list({ prefix });
    for (const obj of list.objects) {
      await env.BEELINE_BUCKET.delete(obj.key);
    }
  } else if (env.BEELINE_KV) {
    await env.BEELINE_KV.delete(devKey);
    const list = await env.BEELINE_KV.list({ prefix });
    for (const key of list.keys) {
      await env.BEELINE_KV.delete(key.name);
    }
  } else {
    memoryStore.delete(devKey);
    for (const k of Array.from(memoryStore.keys())) {
      if (k.startsWith(prefix)) memoryStore.delete(k);
    }
  }
}

// ---------------------------------------------------------------------------
// Single-Use Code Registration & Claiming
// ---------------------------------------------------------------------------

async function getPairingCodeEntry(codeHash, env) {
  const codeKey = `code/${codeHash.toLowerCase()}`;
  let record = null;
  if (env.BEELINE_BUCKET) {
    const obj = await env.BEELINE_BUCKET.get(codeKey);
    if (obj) {
      try {
        record = JSON.parse(await obj.text());
      } catch (_) {}
    }
  } else if (env.BEELINE_KV) {
    const val = await env.BEELINE_KV.get(codeKey);
    if (val) {
      try {
        record = JSON.parse(val);
      } catch (_) {}
    }
  } else {
    record = memoryStore.get(codeKey);
  }
  return record;
}

async function registerPairingCodeEntry(codeHash, deviceId, env) {
  const codeKey = `code/${codeHash.toLowerCase()}`;
  const now = Date.now();

  const existing = await getPairingCodeEntry(codeHash, env);
  if (existing && existing.claimed) {
    // Crucial: If already claimed by a browser, NEVER reset claimed back to false!
    return {
      deviceId: existing.deviceId || deviceId.toLowerCase(),
      claimed: true,
      createdAt: existing.createdAt || now,
      expiresAt: existing.expiresAt || (now + PAIRING_TTL_MS),
      claimedAt: existing.claimedAt || now
    };
  }

  const record = {
    deviceId: deviceId.toLowerCase(),
    claimed: false,
    createdAt: (existing && existing.createdAt) || now,
    expiresAt: now + PAIRING_TTL_MS,
  };

  if (env.BEELINE_BUCKET) {
    await env.BEELINE_BUCKET.put(codeKey, JSON.stringify(record), {
      customMetadata: {
        deviceId: record.deviceId,
        claimed: "false",
        expiresAt: String(record.expiresAt),
      }
    });
  } else if (env.BEELINE_KV) {
    await env.BEELINE_KV.put(codeKey, JSON.stringify(record), {
      expirationTtl: Math.floor(PAIRING_TTL_MS / 1000)
    });
  } else {
    memoryStore.set(codeKey, record);
  }

  await registerDevicePairing(deviceId, env);
  return record;
}

async function claimPairingCodeEntry(codeHash, env) {
  const codeKey = `code/${codeHash.toLowerCase()}`;
  const now = Date.now();

  const record = await getPairingCodeEntry(codeHash, env);

  if (!record) {
    return { ok: false, status: 404, error: "Pairing code not found or expired. Generate a new code on your KOReader." };
  }

  if (record.expiresAt && record.expiresAt < now) {
    return { ok: false, status: 404, error: "Pairing code has expired. Generate a new code on your KOReader." };
  }

  if (record.claimed) {
    return { ok: false, status: 409, error: "This pairing code has already been used. Please generate a new code on your KOReader." };
  }

  record.claimed = true;
  record.claimedAt = now;

  if (env.BEELINE_BUCKET) {
    await env.BEELINE_BUCKET.put(codeKey, JSON.stringify(record), {
      customMetadata: {
        deviceId: record.deviceId,
        claimed: "true",
        expiresAt: String(record.expiresAt || (now + PAIRING_TTL_MS)),
      }
    });
  } else if (env.BEELINE_KV) {
    const ttlSeconds = Math.max(60, Math.floor(((record.expiresAt || (now + PAIRING_TTL_MS)) - now) / 1000));
    await env.BEELINE_KV.put(codeKey, JSON.stringify(record), {
      expirationTtl: ttlSeconds
    });
  } else {
    memoryStore.set(codeKey, record);
  }

  await registerDevicePairing(record.deviceId, env);
  return { ok: true, deviceId: record.deviceId };
}

// Handler for KOReader calling POST /api/pair
async function handlePairRegister(request, env) {
  let body = null;
  try {
    body = await request.json();
  } catch (_) {}

  // 1) Single-use code registration by KOReader
  if (body && body.action === "register_code") {
    const codeHash = (body.codeHash || "").toLowerCase();
    const deviceId = (body.deviceId || "").toLowerCase();
    if (!codeHash || !/^[a-f0-9]{64}$/.test(codeHash)) {
      return jsonResponse({ ok: false, error: "Missing or invalid codeHash" }, 400);
    }
    if (!deviceId || !/^[a-zA-Z0-9_-]{8,64}$/.test(deviceId)) {
      return jsonResponse({ ok: false, error: "Missing or invalid deviceId" }, 400);
    }
    const record = await registerPairingCodeEntry(codeHash, deviceId, env);
    return jsonResponse({ ok: true, registered: true, device: record.deviceId, claimed: !!record.claimed });
  }

  // 1b) Single-use code check (status polling)
  if (body && body.action === "check_code") {
    const codeHash = (body.codeHash || "").toLowerCase();
    if (!codeHash || !/^[a-f0-9]{64}$/.test(codeHash)) {
      return jsonResponse({ ok: false, error: "Missing or invalid codeHash" }, 400);
    }
    const record = await getPairingCodeEntry(codeHash, env);
    if (!record) {
      return jsonResponse({ ok: false, found: false, error: "Code not found" }, 404);
    }
    return jsonResponse({
      ok: true,
      found: true,
      claimed: !!record.claimed,
      expired: !!(record.expiresAt && record.expiresAt < Date.now()),
      device: record.deviceId
    });
  }

  // 2) Single-use code claim by Web Browser
  if (body && body.action === "claim_code") {
    const codeHash = (body.codeHash || "").toLowerCase();
    if (!codeHash || !/^[a-f0-9]{64}$/.test(codeHash)) {
      return jsonResponse({ ok: false, error: "Missing or invalid codeHash" }, 400);
    }
    const res = await claimPairingCodeEntry(codeHash, env);
    if (!res.ok) {
      return jsonResponse({ ok: false, error: res.error }, res.status || 400);
    }
    return jsonResponse({ ok: true, paired: true, deviceId: res.deviceId });
  }

  // 3) Unpair / revoke device from KOReader
  if (body && body.action === "unpair_device") {
    const deviceId = (body.deviceId || "").toLowerCase();
    if (!deviceId || !/^[a-zA-Z0-9_-]{8,64}$/.test(deviceId)) {
      return jsonResponse({ ok: false, error: "Missing or invalid deviceId" }, 400);
    }
    await unregisterDevicePairing(deviceId, env);
    return jsonResponse({ ok: true, unpaired: true, device: deviceId });
  }

  // 4) Legacy / fallback direct device pairing (or test runner)
  let deviceId = request.headers.get("X-Device-Id");
  if (!deviceId && body) {
    deviceId = body.device || body.deviceId;
  }

  if (!deviceId || !/^[a-zA-Z0-9_-]{8,64}$/i.test(deviceId)) {
    return jsonResponse({ ok: false, error: "Missing or invalid device ID" }, 400);
  }

  const expiresAt = await registerDevicePairing(deviceId, env);
  return jsonResponse({ ok: true, paired: true, device: deviceId.toLowerCase(), expiresAt });
}

// Handler for Web Client calling GET /api/pair?device=<hash>
async function handlePairCheck(url, env) {
  const deviceId = (url.searchParams.get("device") || "").toLowerCase();
  if (!deviceId || !/^[a-zA-Z0-9_-]{8,64}$/.test(deviceId)) {
    return jsonResponse({ ok: false, error: "Missing or invalid device parameter" }, 400);
  }

  const info = await getDevicePairingInfo(deviceId, env);
  return jsonResponse({
    ok: true,
    device: deviceId,
    paired: info.paired,
    expired: info.expired || false,
    expiresAt: info.expiresAt || null,
  });
}

// ---------------------------------------------------------------------------
// File Upload & Storage
// ---------------------------------------------------------------------------

async function handleUpload(request, env) {
  const deviceId = request.headers.get("X-Device-Id");
  if (!deviceId || !/^[a-zA-Z0-9_-]{8,64}$/i.test(deviceId)) {
    return jsonResponse({ ok: false, error: "Missing or invalid X-Device-Id header" }, 400);
  }

  // Security enforcement: Reject upload if device is not currently paired
  const paired = await isDevicePaired(deviceId, env);
  if (!paired) {
    return jsonResponse({
      ok: false,
      error: "Device is not paired to KOReader. Please open Beeline on your e-reader first to activate pairing."
    }, 403);
  }

  const payload = await request.arrayBuffer();
  if (!payload || payload.byteLength < 44) { // 16B salt + 12B IV + 16B tag minimum
    return jsonResponse({ ok: false, error: "Payload too small to be a valid encrypted envelope" }, 400);
  }

  const now = Date.now();
  const fileId = `file_${now}_${Math.random().toString(36).substring(2, 8)}`;
  const key = `inbox/${deviceId.toLowerCase()}/${fileId}`;
  const metadata = {
    id: fileId,
    deviceId: deviceId.toLowerCase(),
    size: payload.byteLength,
    uploadedAt: now,
    expiresAt: now + RETENTION_MS,
  };

  if (env.BEELINE_BUCKET) {
    await env.BEELINE_BUCKET.put(key, payload, {
      customMetadata: {
        id: fileId,
        size: String(payload.byteLength),
        uploadedAt: String(now),
        expiresAt: String(now + RETENTION_MS),
      }
    });
  } else if (env.BEELINE_KV) {
    await env.BEELINE_KV.put(key, payload, {
      expirationTtl: Math.floor(RETENTION_MS / 1000),
      metadata,
    });
  } else {
    memoryStore.set(key, { payload, metadata });
  }

  return jsonResponse({
    ok: true,
    id: fileId,
    size: payload.byteLength,
    expiresAt: now + RETENTION_MS,
  }, 201);
}

async function handleInbox(url, env) {
  const deviceId = (url.searchParams.get("device") || "").toLowerCase();
  if (!deviceId || !/^[a-zA-Z0-9_-]{8,64}$/.test(deviceId)) {
    return jsonResponse({ ok: false, error: "Missing or invalid device parameter" }, 400);
  }

  // Reading inbox also refreshes pairing heartbeat
  await registerDevicePairing(deviceId, env);

  const prefix = `inbox/${deviceId}/`;
  const items = [];
  const now = Date.now();

  if (env.BEELINE_BUCKET) {
    const list = await env.BEELINE_BUCKET.list({ prefix });
    for (const obj of list.objects) {
      const meta = obj.customMetadata || {};
      const expiresAt = Number(meta.expiresAt || 0);
      const fileId = meta.id || obj.key.replace(prefix, "");

      if (expiresAt > 0 && expiresAt < now) {
        await env.BEELINE_BUCKET.delete(obj.key);
      } else {
        items.push({
          id: fileId,
          size: obj.size,
          uploadedAt: Number(meta.uploadedAt || now),
          expiresAt: expiresAt || (now + RETENTION_MS),
        });
      }
    }
  } else if (env.BEELINE_KV) {
    const list = await env.BEELINE_KV.list({ prefix });
    for (const key of list.keys) {
      const meta = key.metadata || {};
      items.push({
        id: meta.id || key.name.replace(prefix, ""),
        size: meta.size || 0,
        uploadedAt: meta.uploadedAt || now,
        expiresAt: meta.expiresAt || (now + RETENTION_MS),
      });
    }
  } else {
    for (const [k, v] of memoryStore.entries()) {
      if (k.startsWith(prefix)) {
        if (v.metadata.expiresAt < now) {
          memoryStore.delete(k);
        } else {
          items.push({
            id: v.metadata.id,
            size: v.metadata.size,
            uploadedAt: v.metadata.uploadedAt,
            expiresAt: v.metadata.expiresAt,
          });
        }
      }
    }
  }

  return jsonResponse({ ok: true, files: items });
}

async function handleDownload(url, env) {
  const deviceId = (url.searchParams.get("device") || "").toLowerCase();
  const fileId = url.searchParams.get("id");
  if (!deviceId || !fileId) {
    return jsonResponse({ ok: false, error: "Missing device or id parameter" }, 400);
  }

  const key = `inbox/${deviceId}/${fileId}`;

  if (env.BEELINE_BUCKET) {
    const obj = await env.BEELINE_BUCKET.get(key);
    if (!obj) {
      return jsonResponse({ ok: false, error: "File not found or expired" }, 404);
    }
    return new Response(obj.body, {
      headers: {
        "Content-Type": "application/octet-stream",
        "Content-Length": String(obj.size),
        "Access-Control-Allow-Origin": "*",
      }
    });
  } else if (env.BEELINE_KV) {
    const data = await env.BEELINE_KV.get(key, { type: "arrayBuffer" });
    if (!data) {
      return jsonResponse({ ok: false, error: "File not found or expired" }, 404);
    }
    return new Response(data, {
      headers: {
        "Content-Type": "application/octet-stream",
        "Content-Length": String(data.byteLength),
        "Access-Control-Allow-Origin": "*",
      }
    });
  } else {
    const item = memoryStore.get(key);
    if (!item) {
      return jsonResponse({ ok: false, error: "File not found or expired" }, 404);
    }
    return new Response(item.payload, {
      headers: {
        "Content-Type": "application/octet-stream",
        "Content-Length": String(item.payload.byteLength),
        "Access-Control-Allow-Origin": "*",
      }
    });
  }
}

async function handleDelete(url, env) {
  const deviceId = (url.searchParams.get("device") || "").toLowerCase();
  const fileId = url.searchParams.get("id");
  if (!deviceId || !fileId) {
    return jsonResponse({ ok: false, error: "Missing device or id parameter" }, 400);
  }

  const key = `inbox/${deviceId}/${fileId}`;

  if (env.BEELINE_BUCKET) {
    await env.BEELINE_BUCKET.delete(key);
  } else if (env.BEELINE_KV) {
    await env.BEELINE_KV.delete(key);
  } else {
    memoryStore.delete(key);
  }

  return jsonResponse({ ok: true, deleted: true });
}

// ---------------------------------------------------------------------------
// Embedded Web UI
// ---------------------------------------------------------------------------

const BEE_ICON_DATA_URI = "data:image/png;base64,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";

function handleWebUi(request) {
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
  <title>Beeline — Send to KOReader</title>
  <script>
    (function() {
      try {
        var saved = localStorage.getItem("beeline_theme");
        var theme = saved || ((window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches) ? "light" : "dark");
        document.documentElement.setAttribute("data-theme", theme);
      } catch (_) {}
    })();
  </script>
  <style>
    :root {
      --bg: #0f172a;
      --card-bg: #1e293b;
      --card-border: #334155;
      --card-shadow: 0 20px 25px -5px rgba(0, 0, 0, 0.5), 0 8px 10px -6px rgba(0, 0, 0, 0.5);
      --primary: #f59e0b;
      --primary-hover: #d97706;
      --btn-send-text: #1e1e1e;
      --text: #f8fafc;
      --text-muted: #94a3b8;
      --input-bg: #0f172a;
      --input-border: #334155;
      --drop-bg: rgba(15, 23, 42, 0.5);
      --drop-hover-bg: rgba(245, 158, 11, 0.05);
      --badge-paired-bg: rgba(16, 185, 129, 0.15);
      --badge-paired-text: #34d399;
      --badge-paired-border: rgba(16, 185, 129, 0.3);
      --badge-unpaired-bg: rgba(239, 68, 68, 0.15);
      --badge-unpaired-text: #f87171;
      --badge-unpaired-border: rgba(239, 68, 68, 0.3);
      --badge-checking-bg: rgba(148, 163, 184, 0.15);
      --badge-checking-text: #94a3b8;
      --success: #10b981;
      --error: #ef4444;
      --progress-bg: #334155;
      --font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    }
    [data-theme="light"] {
      --bg: #f1f5f9;
      --card-bg: #ffffff;
      --card-border: #e2e8f0;
      --card-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.08), 0 8px 10px -6px rgba(0, 0, 0, 0.04);
      --primary: #d97706;
      --primary-hover: #b45309;
      --btn-send-text: #ffffff;
      --text: #0f172a;
      --text-muted: #64748b;
      --input-bg: #ffffff;
      --input-border: #cbd5e1;
      --drop-bg: #f8fafc;
      --drop-hover-bg: rgba(217, 119, 6, 0.08);
      --badge-paired-bg: #ecfdf5;
      --badge-paired-text: #047857;
      --badge-paired-border: #a7f3d0;
      --badge-unpaired-bg: #fef2f2;
      --badge-unpaired-text: #b91c1c;
      --badge-unpaired-border: #fecaca;
      --badge-checking-bg: #f1f5f9;
      --badge-checking-text: #475569;
      --success: #059669;
      --error: #dc2626;
      --progress-bg: #e2e8f0;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: var(--bg);
      color: var(--text);
      font-family: var(--font-family);
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      padding: 1.25rem;
      transition: background-color 0.2s ease, color 0.2s ease;
    }
    .container {
      background: var(--card-bg);
      border: 1px solid var(--card-border);
      border-radius: 1.25rem;
      padding: 2rem;
      width: 100%;
      max-width: 460px;
      box-shadow: var(--card-shadow);
      transition: background-color 0.2s ease, border-color 0.2s ease, box-shadow 0.2s ease;
    }
    .header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 1.25rem;
    }
    .header-main {
      display: flex;
      align-items: center;
      gap: 0.85rem;
    }
    .logo-badge {
      width: 44px;
      height: 44px;
      background: #fbbf24;
      border-radius: 0.75rem;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 5px;
      box-shadow: 0 4px 12px rgba(251, 191, 36, 0.35);
      flex-shrink: 0;
    }
    .logo-img {
      width: 100%;
      height: 100%;
      object-fit: contain;
      display: block;
    }
    .header-text h1 {
      font-size: 1.45rem;
      font-weight: 700;
      color: var(--text);
      letter-spacing: -0.02em;
    }
    .header-text p {
      font-size: 0.825rem;
      color: var(--text-muted);
      margin-top: 0.15rem;
    }
    .theme-toggle {
      background: var(--input-bg);
      border: 1px solid var(--card-border);
      border-radius: 0.55rem;
      width: 36px;
      height: 36px;
      display: flex;
      align-items: center;
      justify-content: center;
      cursor: pointer;
      color: var(--text-muted);
      transition: all 0.2s ease;
      flex-shrink: 0;
    }
    .theme-toggle:hover {
      color: var(--text);
      border-color: var(--primary);
    }
    .field-group {
      margin-bottom: 1.25rem;
    }
    .field-group label {
      display: block;
      font-size: 0.8rem;
      font-weight: 600;
      color: var(--text-muted);
      text-transform: uppercase;
      letter-spacing: 0.05em;
      margin-bottom: 0.45rem;
    }
    .pairing-input {
      width: 100%;
      background: var(--input-bg);
      border: 1px solid var(--input-border);
      border-radius: 0.65rem;
      color: var(--primary);
      font-size: 1.25rem;
      font-weight: 700;
      letter-spacing: 0.1em;
      padding: 0.75rem 1rem;
      text-transform: uppercase;
      text-align: center;
      transition: border-color 0.2s, background-color 0.2s;
    }
    .pairing-input:focus {
      outline: none;
      border-color: var(--primary);
    }
    .pairing-input::placeholder {
      color: var(--text-muted);
      opacity: 0.55;
      font-size: 0.95rem;
      font-weight: 400;
      letter-spacing: normal;
      text-transform: none;
    }
    .field-hint {
      font-size: 0.75rem;
      color: var(--text-muted);
      margin-top: 0.4rem;
      line-height: 1.35;
    }
    .pairing-status {
      margin-top: 0.5rem;
      font-size: 0.775rem;
      display: flex;
      align-items: center;
      justify-content: space-between;
      min-height: 1.25rem;
    }
    .pair-badge {
      display: inline-flex;
      align-items: center;
      gap: 0.35rem;
      padding: 0.2rem 0.6rem;
      border-radius: 9999px;
      font-weight: 600;
    }
    .pair-badge.paired {
      background: var(--badge-paired-bg);
      color: var(--badge-paired-text);
      border: 1px solid var(--badge-paired-border);
    }
    .pair-badge.unpaired {
      background: var(--badge-unpaired-bg);
      color: var(--badge-unpaired-text);
      border: 1px solid var(--badge-unpaired-border);
    }
    .pair-badge.checking {
      background: var(--badge-checking-bg);
      color: var(--badge-checking-text);
    }
    .btn-check-pair {
      background: none;
      border: none;
      color: var(--primary);
      font-size: 0.75rem;
      cursor: pointer;
      text-decoration: underline;
    }
    .drop-zone {
      border: 2px dashed var(--input-border);
      border-radius: 0.85rem;
      padding: 1.75rem 1rem;
      text-align: center;
      cursor: pointer;
      background: var(--drop-bg);
      transition: all 0.2s ease;
      margin-bottom: 1.25rem;
    }
    .drop-zone.active, .drop-zone:hover:not(.disabled) {
      border-color: var(--primary);
      background: var(--drop-hover-bg);
    }
    .drop-zone.disabled {
      opacity: 0.45;
      cursor: not-allowed;
      border-color: var(--card-border);
    }
    .drop-zone-text {
      font-size: 0.9rem;
      font-weight: 500;
      color: var(--text);
    }
    .drop-zone-hint {
      font-size: 0.75rem;
      color: var(--text-muted);
      margin-top: 0.35rem;
    }
    .file-input { display: none; }
    .file-card {
      display: none;
      background: var(--input-bg);
      border: 1px solid var(--card-border);
      border-radius: 0.65rem;
      padding: 0.75rem 1rem;
      margin-bottom: 1.25rem;
      align-items: center;
      justify-content: space-between;
    }
    .file-name {
      font-size: 0.85rem;
      font-weight: 600;
      color: var(--text);
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      max-width: 280px;
    }
    .file-size {
      font-size: 0.75rem;
      color: var(--text-muted);
      margin-top: 0.15rem;
    }
    .file-remove {
      background: none;
      border: none;
      color: var(--text-muted);
      font-size: 1.25rem;
      cursor: pointer;
      padding: 0.2rem 0.5rem;
    }
    .file-remove:hover { color: var(--error); }
    .btn-send {
      width: 100%;
      background: var(--primary);
      color: var(--btn-send-text);
      border: none;
      border-radius: 0.65rem;
      padding: 0.85rem;
      font-size: 0.95rem;
      font-weight: 700;
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 0.5rem;
      transition: background 0.2s;
    }
    .btn-send:hover:not(:disabled) {
      background: var(--primary-hover);
    }
    .btn-send:disabled {
      opacity: 0.45;
      cursor: not-allowed;
    }
    .status-msg {
      margin-top: 1rem;
      padding: 0.75rem;
      border-radius: 0.5rem;
      font-size: 0.825rem;
      display: none;
      text-align: center;
    }
    .status-success {
      background: var(--badge-paired-bg);
      border: 1px solid var(--badge-paired-border);
      color: var(--badge-paired-text);
    }
    .status-error {
      background: var(--badge-unpaired-bg);
      border: 1px solid var(--badge-unpaired-border);
      color: var(--badge-unpaired-text);
    }
    .footer {
      text-align: center;
      margin-top: 1.5rem;
      font-size: 0.75rem;
      color: var(--text-muted);
    }
    .progress-bar-container {
      width: 100%;
      height: 4px;
      background: var(--progress-bg);
      border-radius: 2px;
      margin-top: 0.75rem;
      overflow: hidden;
      display: none;
    }
    .progress-bar {
      width: 0%;
      height: 100%;
      background: var(--primary);
      transition: width 0.2s;
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <div class="header-main">
        <div class="logo-badge">
          <img src="${BEE_ICON_DATA_URI}" alt="Beeline" class="logo-img">
        </div>
        <div class="header-text">
          <h1>Beeline</h1>
          <p>Send files straight to KOReader</p>
        </div>
      </div>
      <button class="theme-toggle" id="themeToggle" title="Toggle theme" aria-label="Toggle theme"></button>
    </div>

    <div class="field-group">
      <label for="pairingCode">KOReader Pairing Code</label>
      <input type="text" id="pairingCode" class="pairing-input" placeholder="e.g. K9B-4X2" maxlength="12" autocomplete="off" autocorrect="off" autocapitalize="characters" spellcheck="false">
      <div class="field-hint">Hyphen is optional. Once paired, your browser stays connected permanently.</div>
      <div class="pairing-status" id="pairingStatus">
        <span class="pair-badge checking" id="pairBadge">Enter pairing code</span>
        <button class="btn-check-pair" id="btnCheckPair" style="display:none;">Re-check</button>
      </div>
    </div>

    <div class="drop-zone disabled" id="dropZone">
      <div class="drop-zone-text">Drop your ebook or ACSM file here</div>
      <div class="drop-zone-hint">or tap to select from device (.epub, .pdf, .acsm, .cbz)</div>
      <input type="file" id="fileInput" class="file-input" accept=".epub,.pdf,.acsm,.cbz,.fb2,.mobi,.txt" disabled>
    </div>

    <div class="file-card" id="fileCard">
      <div class="file-info">
        <div class="file-name" id="fileName">book.epub</div>
        <div class="file-size" id="fileSize">1.2 MB</div>
      </div>
      <button class="file-remove" id="fileRemove" title="Remove file">&times;</button>
    </div>

    <button id="sendBtn" class="btn-send" disabled>
      <span>Send to KOReader</span>
    </button>

    <div class="progress-bar-container" id="progressContainer">
      <div class="progress-bar" id="progressBar"></div>
    </div>

    <div class="status-msg" id="statusMsg"></div>

    <div class="footer">
      End-to-end encrypted. Ephemeral files auto-expire in 24 hours.
    </div>
  </div>

  <script>
    const themeToggle = document.getElementById("themeToggle");
    const sunSvg = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="5"></circle><line x1="12" y1="1" x2="12" y2="3"></line><line x1="12" y1="21" x2="12" y2="23"></line><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"></line><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"></line><line x1="1" y1="12" x2="3" y2="12"></line><line x1="21" y1="12" x2="23" y2="12"></line><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"></line><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"></line></svg>';
    const moonSvg = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"></path></svg>';

    function getInitialTheme() {
      const saved = localStorage.getItem("beeline_theme");
      if (saved) return saved;
      return (window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches) ? "light" : "dark";
    }

    function applyTheme(theme) {
      document.documentElement.setAttribute("data-theme", theme);
      localStorage.setItem("beeline_theme", theme);
      if (theme === "light") {
        themeToggle.innerHTML = moonSvg;
        themeToggle.title = "Switch to dark mode";
      } else {
        themeToggle.innerHTML = sunSvg;
        themeToggle.title = "Switch to light mode";
      }
    }

    applyTheme(getInitialTheme());

    themeToggle.addEventListener("click", () => {
      const current = document.documentElement.getAttribute("data-theme") || "dark";
      applyTheme(current === "dark" ? "light" : "dark");
    });

    const pairingInput = document.getElementById("pairingCode");
    const pairBadge = document.getElementById("pairBadge");
    const btnCheckPair = document.getElementById("btnCheckPair");
    const dropZone = document.getElementById("dropZone");
    const fileInput = document.getElementById("fileInput");
    const fileCard = document.getElementById("fileCard");
    const fileName = document.getElementById("fileName");
    const fileSize = document.getElementById("fileSize");
    const fileRemove = document.getElementById("fileRemove");
    const sendBtn = document.getElementById("sendBtn");
    const statusMsg = document.getElementById("statusMsg");
    const progressContainer = document.getElementById("progressContainer");
    const progressBar = document.getElementById("progressBar");

    let currentFile = null;
    let isPaired = false;
    let checkTimeout = null;

    function normalizeCode(str) {
      if (!str) return "";
      return str.toUpperCase().replace(/[^A-Z0-9]/g, "");
    }

    function formatCodeDisplay(str) {
      const norm = normalizeCode(str);
      if (norm.length === 6) {
        return norm.slice(0, 3) + "-" + norm.slice(3);
      }
      return str.toUpperCase().replace(/[^A-Z0-9-]/g, "");
    }

    function getSavedSession() {
      try {
        const raw = localStorage.getItem("beeline_session");
        if (raw) return JSON.parse(raw);
      } catch (_) {}
      return null;
    }

    function saveSession(deviceId, code) {
      const norm = normalizeCode(code);
      localStorage.setItem("beeline_session", JSON.stringify({ deviceId, code: norm }));
    }

    function clearSession() {
      localStorage.removeItem("beeline_session");
      pairingInput.value = "";
      setUnpairedState("Enter pairing code");
    }

    function getIncomingCode() {
      try {
        const url = new URL(window.location.href);
        const qCode = url.searchParams.get("code");
        if (qCode) return qCode;
      } catch (_) {}
      if (window.location.hash) {
        const h = window.location.hash.replace(/^#[/]*/, "");
        try {
          const hp = new URLSearchParams(h);
          const p = hp.get("code");
          if (p) return p;
        } catch (_) {}
        if (/^[A-Za-z0-9-]{4,12}$/.test(h)) return h;
      }
      return null;
    }

    async function checkDeviceStatus(deviceId) {
      try {
        const resp = await fetch("/api/pair?device=" + deviceId);
        const data = await resp.json();
        if (data.ok && data.paired) {
          setPairedState("Paired with KOReader (Ready)");
        } else {
          setUnpairedState("Device disconnected on KOReader. Enter new code.");
        }
      } catch (err) {
        setUnpairedState("Could not verify device connection");
      }
    }

    async function claimOrVerifyPairing(code) {
      const norm = normalizeCode(code);
      if (norm.length !== 6) return;

      pairBadge.textContent = "Connecting to KOReader...";
      pairBadge.className = "pair-badge checking";
      btnCheckPair.style.display = "none";

      const saved = getSavedSession();
      if (saved && saved.code === norm && saved.deviceId) {
        return await checkDeviceStatus(saved.deviceId);
      }

      // Claim single-use pairing code
      try {
        const codeHash = await sha256Hex(norm + ":beeline-pairing");
        const resp = await fetch("/api/pair", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ action: "claim_code", codeHash })
        });
        const data = await resp.json();

        if (resp.status === 200 && data.ok && data.deviceId) {
          saveSession(data.deviceId, norm);
          setPairedState("Paired with KOReader (Ready)");
        } else if (resp.status === 409) {
          setUnpairedState("This code has already been used. Please generate a new code on your KOReader.");
        } else if (resp.status === 404) {
          setUnpairedState("Code expired or not found. Check code or tap New Code on KOReader.");
        } else {
          setUnpairedState(data.error || "Pairing failed");
        }
      } catch (err) {
        // Fallback for direct device ID
        try {
          const fullHash = await sha256Hex(norm + ":beeline-device-id");
          const devId = fullHash.substring(0, 16);
          const r = await fetch("/api/pair?device=" + devId);
          const d = await r.json();
          if (d.ok && d.paired) {
            saveSession(devId, norm);
            return setPairedState("Paired with KOReader (Ready)");
          }
        } catch (_) {}
        setUnpairedState("Connection error during pairing");
      }
    }

    function setPairedState(message) {
      isPaired = true;
      pairBadge.textContent = message;
      pairBadge.className = "pair-badge paired";
      btnCheckPair.textContent = "Disconnect / New Code";
      btnCheckPair.style.display = "inline-block";
      dropZone.classList.remove("disabled");
      fileInput.disabled = false;
      hideStatus();
      updateSendState();
    }

    function setUnpairedState(message) {
      isPaired = false;
      pairBadge.textContent = message;
      pairBadge.className = "pair-badge unpaired";
      const hasSaved = getSavedSession() !== null;
      btnCheckPair.textContent = hasSaved ? "Disconnect" : "Re-check";
      btnCheckPair.style.display = hasSaved ? "inline-block" : "none";
      dropZone.classList.add("disabled");
      fileInput.disabled = true;
      updateSendState();
    }

    // Initialize state on load
    const urlCode = getIncomingCode();
    const savedSession = getSavedSession();

    if (urlCode) {
      const norm = normalizeCode(urlCode);
      const display = formatCodeDisplay(norm);
      pairingInput.value = display;
      if (norm.length === 6) {
        claimOrVerifyPairing(norm);
      }
    } else if (savedSession && savedSession.code) {
      pairingInput.value = formatCodeDisplay(savedSession.code);
      checkDeviceStatus(savedSession.deviceId);
    }

    pairingInput.addEventListener("input", (e) => {
      let raw = e.target.value;
      let norm = normalizeCode(raw);
      if (norm.length === 6 && !raw.includes("-")) {
        e.target.value = norm.slice(0, 3) + "-" + norm.slice(3);
      }

      clearTimeout(checkTimeout);
      if (norm.length === 6) {
        checkTimeout = setTimeout(() => claimOrVerifyPairing(norm), 300);
      } else if (norm.length > 0) {
        setUnpairedState("Enter 6-character code (" + norm.length + "/6)");
      } else {
        setUnpairedState("Enter pairing code");
      }
    });

    btnCheckPair.addEventListener("click", () => {
      const saved = getSavedSession();
      if (btnCheckPair.textContent.includes("Disconnect") || saved) {
        clearSession();
      } else {
        const norm = normalizeCode(pairingInput.value);
        if (norm.length === 6) claimOrVerifyPairing(norm);
      }
    });

    dropZone.addEventListener("click", () => {
      if (isPaired) fileInput.click();
    });

    fileInput.addEventListener("change", (e) => {
      if (e.target.files && e.target.files[0]) {
        selectFile(e.target.files[0]);
      }
    });

    ["dragenter", "dragover"].forEach(evt => {
      dropZone.addEventListener(evt, (e) => {
        if (!isPaired) return;
        e.preventDefault();
        e.stopPropagation();
        dropZone.classList.add("active");
      });
    });

    ["dragleave", "drop"].forEach(evt => {
      dropZone.addEventListener(evt, (e) => {
        if (!isPaired) return;
        e.preventDefault();
        e.stopPropagation();
        dropZone.classList.remove("active");
      });
    });

    dropZone.addEventListener("drop", (e) => {
      if (!isPaired) return;
      if (e.dataTransfer.files && e.dataTransfer.files[0]) {
        selectFile(e.dataTransfer.files[0]);
      }
    });

    fileRemove.addEventListener("click", () => {
      currentFile = null;
      fileInput.value = "";
      fileCard.style.display = "none";
      dropZone.style.display = "block";
      updateSendState();
    });

    function selectFile(file) {
      currentFile = file;
      fileName.textContent = file.name;
      fileSize.textContent = formatBytes(file.size);
      dropZone.style.display = "none";
      fileCard.style.display = "flex";
      hideStatus();
      updateSendState();
    }

    function updateSendState() {
      const hasFile = currentFile !== null;
      sendBtn.disabled = !(isPaired && hasFile);
    }

    function formatBytes(bytes) {
      if (bytes === 0) return "0 Bytes";
      const k = 1024;
      const sizes = ["Bytes", "KB", "MB", "GB"];
      const i = Math.floor(Math.log(bytes) / Math.log(k));
      return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + " " + sizes[i];
    }

    function showStatus(text, isError) {
      statusMsg.textContent = text;
      statusMsg.className = "status-msg " + (isError ? "status-error" : "status-success");
      statusMsg.style.display = "block";
    }

    function hideStatus() {
      statusMsg.style.display = "none";
    }

    // -----------------------------------------------------------------------
    // Zero-Trust Web Crypto Encryption
    // -----------------------------------------------------------------------

    async function sha256Hex(str) {
      const encoder = new TextEncoder();
      const hash = await crypto.subtle.digest("SHA-256", encoder.encode(str));
      return Array.from(new Uint8Array(hash)).map(b => b.toString(16).padStart(2, "0")).join("");
    }

    async function deriveKey(code, salt) {
      const encoder = new TextEncoder();
      const baseKey = await crypto.subtle.importKey(
        "raw",
        encoder.encode(code),
        "PBKDF2",
        false,
        ["deriveKey"]
      );
      return crypto.subtle.deriveKey(
        {
          name: "PBKDF2",
          salt: salt,
          iterations: 100000,
          hash: "SHA-256"
        },
        baseKey,
        { name: "AES-GCM", length: 256 },
        false,
        ["encrypt"]
      );
    }

    async function encryptFile(file, code) {
      const salt = crypto.getRandomValues(new Uint8Array(16));
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const key = await deriveKey(code, salt);

      const headerObj = {
        filename: file.name,
        size: file.size,
        mime: file.type || "application/octet-stream",
        timestamp: Date.now()
      };

      const headerJson = new TextEncoder().encode(JSON.stringify(headerObj));
      const fileBytes = new Uint8Array(await file.arrayBuffer());

      // Plaintext: [4-byte big-endian header length][header bytes][file bytes]
      const plaintext = new Uint8Array(4 + headerJson.length + fileBytes.length);
      const view = new DataView(plaintext.buffer);
      view.setUint32(0, headerJson.length, false);
      plaintext.set(headerJson, 4);
      plaintext.set(fileBytes, 4 + headerJson.length);

      // AES-GCM Encrypt
      const encryptedBuffer = await crypto.subtle.encrypt(
        { name: "AES-GCM", iv: iv },
        key,
        plaintext
      );

      // Envelope: [16B salt][12B iv][encrypted buffer (includes 16B tag)]
      const encryptedBytes = new Uint8Array(encryptedBuffer);
      const finalEnvelope = new Uint8Array(16 + 12 + encryptedBytes.length);
      finalEnvelope.set(salt, 0);
      finalEnvelope.set(iv, 16);
      finalEnvelope.set(encryptedBytes, 28);

      return finalEnvelope;
    }

    sendBtn.addEventListener("click", async () => {
      const session = getSavedSession();
      const normInput = normalizeCode(pairingInput.value);
      const codeToUse = (session && session.code) ? session.code : normInput;
      let deviceIdToUse = (session && session.deviceId) ? session.deviceId : null;

      if (!deviceIdToUse && codeToUse) {
        const fullHash = await sha256Hex(codeToUse + ":beeline-device-id");
        deviceIdToUse = fullHash.substring(0, 16);
      }

      if (!deviceIdToUse || !codeToUse || !currentFile || !isPaired) return;

      sendBtn.disabled = true;
      progressContainer.style.display = "block";
      progressBar.style.width = "30%";
      hideStatus();

      try {
        progressBar.style.width = "60%";
        const encryptedEnvelope = await encryptFile(currentFile, codeToUse);

        progressBar.style.width = "80%";
        const resp = await fetch("/api/upload", {
          method: "POST",
          headers: {
            "Content-Type": "application/octet-stream",
            "X-Device-Id": deviceIdToUse,
          },
          body: encryptedEnvelope
        });

        progressBar.style.width = "100%";
        const result = await resp.json();

        if (resp.ok && result.ok) {
          showStatus("Sent! File delivered to KOReader. Ready for next file.", false);
          currentFile = null;
          fileInput.value = "";
          fileCard.style.display = "none";
          dropZone.style.display = "block";
          sendBtn.textContent = "Send to KOReader";
          sendBtn.disabled = true;
        } else {
          showStatus("Upload rejected: " + (result.error || "Device not paired"), true);
          sendBtn.disabled = false;
        }
      } catch (err) {
        showStatus("Error: " + (err.message || String(err)), true);
        sendBtn.disabled = false;
      } finally {
        setTimeout(() => {
          progressContainer.style.display = "none";
          progressBar.style.width = "0%";
        }, 1200);
      }
    });
  </script>
</body>
</html>`;

  return new Response(html, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-cache, no-store, must-revalidate",
    }
  });
}
