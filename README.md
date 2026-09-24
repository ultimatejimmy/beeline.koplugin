# Beeline

Beeline lets you easily send ebooks, PDFs, and library loan tokens (`.acsm`) from your computer or phone directly to KOReader on your e-reader.

It consists of two parts:
1. **Cloudflare Worker & Web Client (`worker/`)**: A single-file worker serving a clean web page where you drop files to send them. Files are stored temporarily in Cloudflare R2 or KV.
2. **KOReader Plugin (`plugin/beeline.koplugin/`)**: A KOReader plugin that connects to your worker, downloads incoming files, and saves them to your reader's inbox.

---

## How It Works

Beeline uses client-side encryption and strict device pairing so that neither Cloudflare nor unauthorized users can access your files or abuse the relay:

1. **Pairing Required**: Your e-reader must be paired before any file can be sent. When you open Beeline on KOReader or connect to Wi-Fi, KOReader registers an active pairing session with the relay using your device's Pairing Code (e.g. `BEE-482`).
2. **Web Verification**: When you enter your code on your phone or PC, the web page checks the relay. If your e-reader is not paired, file uploads are completely disabled. The worker rejects any upload attempt to an unpaired device with HTTP 403 Forbidden.
3. **End-to-End Encryption**: Once paired, you choose your file. Your browser derives an encryption key from your code using PBKDF2 (SHA-256 with 100,000 iterations) and encrypts both the file and its filename using AES-256-GCM.
4. **Zero-Knowledge Relay**: The encrypted file is uploaded to the worker, which routes it using a truncated device hash (`SHA-256(code + ":beeline-device-id")[0..16]`). The server never sees the raw code, the filename, or the file contents.
5. **Ephemeral Storage**: Files remain in temporary storage for up to 30 minutes. Once KOReader downloads the file, it is immediately deleted from the server.
6. **Local Decryption**: KOReader decrypts the payload locally using OpenSSL and places the original file in your inbox folder.

```
[ KOReader Device ] ──(Activates Pairing)──► [ Cloudflare Worker Relay ]
                                                       ▲
[ Phone / PC Browser ]                                 │
         │                                             │
         ├─ 1. Checks Pairing (Must be paired) ────────┤
         └─ 2. Encrypts client-side & Uploads ─────────┘
                                                       │
[ KOReader Device ] ◄────── 3. Downloads & Decrypts ───┘
         │
         ▼
  Saved to Inbox & Deleted from Relay
```

---

## OverDrive / Libby Terms of Service

Beeline is purely a file transfer utility. It does not contain any decryption code or tools for bypassing DRM. 

OverDrive allows borrowers to download `.acsm` license tokens directly from their website or app so they can be transferred to an e-reader. Beeline simply moves those tokens (or standard DRM-free EPUBs and PDFs) across your local network or the internet to your device, just like using an SFTP client or a USB cable.

When an `.acsm` file lands on your device:
- KOReader delegates it to whichever document handler or fulfillment tool you already have set up on your device.
- On devices with stock firmware integration (like Kobo Nickel or PocketBook), you can open the token in the device's native reader.

---

## Getting Started

### 1. Install the Plugin

Copy the `beeline/plugin/beeline.koplugin` directory into your KOReader `plugins/` directory:
- **Kobo / Kindle / Linux**: `<koreader-path>/plugins/beeline.koplugin`
- **Android**: `/sdcard/koreader/plugins/beeline.koplugin`

Restart KOReader.

### 2. Connect Your Devices

1. On your e-reader, open the top menu and tap **Tools** -> **Beeline** -> **Beeline Settings**.
2. Note your **Pairing Code** (e.g. `BEE-482`, or tap to generate a custom one).
3. The plugin comes configured with the default edge relay, or you can enter your own Worker URL under **Worker URL**.
4. On your phone or computer, open the relay URL in your web browser:
   - Enter your Pairing Code. The status badge will switch to **Paired with KOReader (Ready)**.
   - Drag and drop your file (or tap to select it).
   - Click **Send to KOReader**.

---

## Deploying Your Own Worker (Optional)

If you prefer to run your own private Cloudflare Worker instead of the default relay:

```bash
cd beeline/worker

# Install dependencies
npm install

# Create the R2 bucket for temporary file storage
npx wrangler r2 bucket create beeline-inbox

# Deploy to your Cloudflare account
npx wrangler deploy
```

Set your deployed URL in **Beeline Settings** on your e-reader.

---

## Receiving Files

- **Automatic Check**: When your e-reader wakes up and connects to Wi-Fi, Beeline automatically checks for incoming files after 5 seconds.
- **Manual Check**: You can check anytime by opening the top menu and tapping **Tools** -> **Beeline** -> **Check for Incoming Files**.
- **Prompt**: When a file arrives, KOReader asks whether you want to open it right away or leave it in your inbox folder.

---

## Testing

The project includes unit tests that verify encryption compatibility between Node.js / browser Web Crypto and KOReader's OpenSSL engine:

```bash
# Test the Worker endpoints and simulated uploads
node beeline/spec/test_worker_e2e.js

# Test OpenSSL decryption inside LuaJIT
wsl luajit beeline/spec/test_beeline_crypto.lua
```

---

## License

MIT License. Uses the bee icon from the Libbee project.
