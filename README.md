# Beeline

Send ebooks and documents directly from your phone or computer to KOReader — wirelessly and end-to-end encrypted. No accounts, no cables, and no companion apps required on your sending device.

---

## How It Works

1. **Pair**: Open Beeline on your e-reader to see your pairing code or scan the QR code.
2. **Send**: Visit the web relay in any browser, enter your code, and drop your file. Files are encrypted client-side before upload.
3. **Read**: KOReader downloads and decrypts your books automatically over Wi-Fi.

```
[ Phone / PC Browser ] ──(Encrypts Client-Side)──► [ Ephemeral Relay ] ──(Pulls & Decrypts)──► [ KOReader Device ]
```

---

## Features

- **End-to-End Encrypted**: Files and filenames are encrypted in your browser using AES-256-GCM. The relay never sees your pairing code, filenames, or book contents.
- **Zero-Friction**: Works directly in any mobile or desktop web browser.
- **Automatic Sync**: KOReader automatically checks for incoming transfers when connecting to Wi-Fi.
- **Ephemeral & Private**: Files are deleted from the relay immediately upon download.
- **Self-Hostable**: Works out of the box with the default edge relay, or you can deploy your own on Cloudflare Workers in minutes.

---

## Quick Start

### 1. Install the Plugin

**Via Storefront (Recommended):**
Open KOReader → **Tools** → **Storefront** → **Plugins** → Search for **Beeline** → Tap **Install** → Restart KOReader.

**Manual Installation:**
Copy the `plugin/beeline.koplugin` folder to your KOReader `plugins/` directory:
- **Kobo**: `/mnt/onboard/.koreader/plugins/beeline.koplugin`
- **Kindle**: `/mnt/us/koreader/plugins/beeline.koplugin`
- **Android**: `/sdcard/koreader/plugins/beeline.koplugin`
- **Desktop (Linux)**: `~/.config/koreader/plugins/beeline.koplugin`

Restart KOReader.

### 2. Send a File

1. On your e-reader, open the top menu and tap **Tools** → **Beeline**.
2. Note your 6-character **Pairing Code** (or tap **Show QR Code**).
3. On your phone or computer, open the relay URL in your web browser:
   - Enter your Pairing Code (or scan the QR code with your phone).
   - Drag and drop your book (EPUB, PDF, MOBI, CBZ, etc.).
   - Click **Send to KOReader**.
4. On your e-reader, tap **Check for Incoming Files** (or let it auto-sync over Wi-Fi), then tap **Open Now** to start reading!

---

## Documentation & Wiki

For detailed guides and technical specifications, visit the [**Beeline Wiki**](https://github.com/ultimatejimmy/beeline.koplugin/wiki):

- [Installation & Gesture Bindings](https://github.com/ultimatejimmy/beeline.koplugin/wiki/1.-Installation)
- [Usage & Pairing Workflow](https://github.com/ultimatejimmy/beeline.koplugin/wiki/2.-Usage)
- [Supported Formats & Storage Organization](https://github.com/ultimatejimmy/beeline.koplugin/wiki/3.-File-Transfers-and-Formats)
- [Architecture & Cryptographic Security Model](https://github.com/ultimatejimmy/beeline.koplugin/wiki/4.-Architecture-and-Security)
- [Troubleshooting & Connection Verification](https://github.com/ultimatejimmy/beeline.koplugin/wiki/5.-Troubleshooting)
- [Plugin Settings Reference](https://github.com/ultimatejimmy/beeline.koplugin/wiki/6.-Settings)
- [Self-Hosting Your Own Cloudflare Worker](https://github.com/ultimatejimmy/beeline.koplugin/wiki/7.-Self-Hosting)
- [Development, Test Suites & Crypto Verification](https://github.com/ultimatejimmy/beeline.koplugin/wiki/8.-Development-and-Testing)

---

## License

[MIT](LICENSE)
