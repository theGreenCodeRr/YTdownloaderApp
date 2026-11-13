# 🎥 Web Video Downloader

A modern, fast, and robust self-hosted backend application for downloading videos from YouTube, Facebook, and hundreds of other platforms, built with **Python (FastAPI)** and **yt-dlp**.

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Python](https://img.shields.io/badge/python-3.11%2B-blue)
![Docker](https://img.shields.io/badge/docker-ready-blue)

---

## 🌐 Live Demo

You can test the functionality of this application before installing it yourself:
👉 **[Test the Live Demo Here](https://yt.quantumsofts.com/)**

---

## ✨ Features

* **Universal Platform Support:** Download videos from YouTube, Facebook, and many other websites supported by `yt-dlp` (with Deno JS runtime and `curl-cffi` impersonation included in Docker).
* **Selective & Full Playlist Downloads:** Browse playlist entries, check only the videos you want (or select all), and download them as a bundled ZIP archive with transparent progress tracking.
* **Persistent Download History (SQLite):** Tasks and per-client download history are stored in SQLite (`storage.py`) so history survives restarts and rebuilds.
* **Unicode-Safe Filenames:** Non-English titles (Japanese, Bengali, Arabic, emojis, etc.) are preserved cleanly using RFC 5987 (`filename*=UTF-8''...`) `Content-Disposition` headers.
* **Advanced Audio Extraction:** Download videos directly as high-quality audio files (**MP3**, **Lossless WAV**, or **Lossless FLAC**) via server-side FFmpeg processing.
* **Resource Optimized (Zero Memory Leaks):** Designed to run efficiently on low-memory VPS environments by isolating each playlist video into a completely separate memory context. It uses explicit Linux Kernel OS Cache flushing (`posix_fadvise`) to ensure massive files stream straight to disk without blowing up RAM.
* **Stability & Security Guardrails:** Enforces concurrent download limits (Semaphore of 3), disk space validation (>2 GiB free), per-IP sliding-window rate limits, password brute-force lockout, strict default CORS, and TLS verification enabled by default.
* **Login-Only Content Support:** Safely supports `cookies.txt` (copied per subprocess and optionally mounted read-only at `./secrets/cookies.txt`).
* **Automated Cleanup:** Purges temporary files after `SERVE_GRACE_SECONDS` (default 600s) post-download, sweeps orphaned files on startup, and expires old records periodically.

---

## 📱 Mobile App API Reference

This backend is fully documented for consumption by mobile applications (React Native, Flutter, Swift, Kotlin).

### 1. Fetch Video/Playlist Metadata
`POST /api/info`
```json
// Request
{
  "url": "https://youtube.com/watch?v=..."
}

// Response (Single Video)
{
  "is_playlist": false,
  "title": "Video Title",
  "thumbnail": "url...",
  "duration": 360,
  "uploader": "Channel Name",
  "view_count": 10000,
  "formats": [
    { "id": "audio-mp3", "ext": "mp3", "res": "Audio", "note": "High Quality MP3", "size_str": "Auto" },
    { "id": "best", "ext": "mp4", "res": "1080p", "note": "", "size_str": "45.0 MiB" }
  ]
}
```

### 2. Start Single Video Download
`POST /api/process`
Headers: `x-client-id: <unique-device-id>`
```json
// Request
{
  "url": "https://youtube.com/watch?v=...",
  "format_id": "best",
  "title": "Video Title",
  "thumbnail": "url..."
}

// Response
{
  "task_id": "uuid-..."
}
```

### 3. Start Playlist Download
`POST /api/process_playlist`
Headers: `x-client-id: <unique-device-id>`
Requires `PREMIUM_PASSWORD` to be configured on the server; otherwise returns `503 Service Unavailable`. Repeated wrong passwords trigger a `429 Too Many Requests` lockout.
```json
// Request
{
  "url": "https://youtube.com/playlist?list=...",
  "password": "your-premium-password", // Required for playlist endpoint
  "format_id": "audio-mp3",
  "title": "Playlist Title",
  // Optional: only download these videos. Omit (or null) to download the entire playlist.
  "items": [
    { "url": "https://www.youtube.com/watch?v=...", "title": "Video 3", "index": 3 },
    { "url": "https://www.youtube.com/watch?v=...", "title": "Video 7", "index": 7 }
  ]
}
```

### 4. Poll Download Status
`GET /api/status/{task_id}`
```json
// Response
{
  "task_id": "uuid-...",
  "status": "processing", // "processing" | "completed" | "failed" | "expired"
  "error": null,
  "progress": "45.2%", // For playlists: "[Video 2/10] Title - 45.2%"
  "percent": 45.2
}
```

### 5. Download the File
`GET /api/download/{task_id}`
This endpoint streams the file in chunks. The file name is sent RFC 5987-encoded (`filename*=UTF-8''...`), so non-English titles (Japanese, Bengali, ...) are preserved. The file is removed from the server `SERVE_GRACE_SECONDS` (default 600) after it is first served. Once expired or removed, requests return `410 Gone`.

### 6. Cancel a Download
`POST /api/cancel/{task_id}`

### 7. Health & Capabilities
`GET /api/health`
```json
// Response
{
  "status": "ok",
  "yt_dlp_version": "2026.xx.xx",
  "js_runtime": true,
  "cookies_loaded": false,
  "premium_enabled": true,
  "active_downloads": 0
}
```

### Error & Rate-Limit Responses
- `410 Gone`: File has expired or already been cleaned up after serving.
- `429 Too Many Requests`: Per-IP rate limit exceeded (`RATE_LIMIT_INFO`, `RATE_LIMIT_PROCESS`, `RATE_LIMIT_PLAYLIST`, `MAX_ACTIVE_TASKS_PER_IP`, or `RATE_LIMIT_PASSWORD_FAILS`). Includes a `Retry-After` header.
- `503 Service Unavailable`: Playlist endpoint called when `PREMIUM_PASSWORD` is unset.

---

## 🚀 Quick Start (Docker)

The easiest way to run the application is using Docker and Docker Compose.

### 1. Configure Environment (`.env`)
Copy `.env.example` to `.env` in the same directory as `docker-compose.yml` (on your deployment server, `/opt/deployments/ytdown/.env`) and customize it:
```bash
cp .env.example .env
chmod 600 .env
```
Key variables:
- `PREMIUM_PASSWORD`: Password for multi-video / playlist ZIP downloads. Leave empty to disable playlist ZIPs (single videos still work).
- `ALLOWED_ORIGINS`: Comma-separated browser origins allowed via CORS. Leave empty to restrict to same-origin (native mobile apps are unaffected).
- `FORWARDED_ALLOW_IPS`: Reverse proxy IP(s) or CIDR (default `127.0.0.1`) so Uvicorn `--proxy-headers` reads the real visitor IP from `X-Forwarded-For` for rate limiting.
- `RATE_LIMIT_INFO`, `RATE_LIMIT_PROCESS`, `RATE_LIMIT_PLAYLIST`, `RATE_LIMIT_PASSWORD_FAILS`, `MAX_ACTIVE_TASKS_PER_IP`: Per-IP rate limits (`<count>/<seconds>`, `0/1` disables a limit).
- `SERVE_GRACE_SECONDS`, `FILE_TTL_SECONDS`, `HISTORY_TTL_SECONDS`: File and history retention windows.
- `DB_PATH`, `TEMP_STORAGE_DIR`, `COOKIES_FILE`: Paths for SQLite DB, temporary media, and optional cookies.
- `YTDLP_NO_CHECK_CERTIFICATE`: `false` by default (TLS verification enabled). Set `true` only behind an intercepting proxy.

### 2. Server Folder Layout
- `/var/www/ytdown` — Temporary media storage (swept of orphaned files on startup).
- `/var/www/ytdown-data` — Persistent SQLite database (`ytdown.db`), automatically created/mounted at `/app/data` so history survives rebuilds.
- `/opt/deployments/ytdown/secrets/cookies.txt` (or `./secrets/cookies.txt` next to `docker-compose.yml`) — Optional cookies file mounted read-only at `/app/secrets`.

### 3. Build and Run
```bash
docker compose up --build -d
```

### 4. Access the App
http://localhost:8000

---

## 🛠 Manual Installation (Without Docker)

### 1. Install Dependencies
Make sure you have Python 3.11+, `ffmpeg`, and a JS runtime (`deno` or `node`) installed on your system.
```bash
pip install -r requirements.txt
```

### 2. Run the Server
```bash
TEMP_STORAGE_DIR=./tmp DB_PATH=./data/ytdown.db uvicorn main:app --host 0.0.0.0 --port 8000
```

---

## 🍪 Bypassing IP Blocks & Login-Only Content (`cookies.txt`)

If your server's IP gets blocked or you need login-only/private posts (e.g., Facebook/Instagram):
1. Export a `cookies.txt` file from your desktop browser.
2. Place it at `./secrets/cookies.txt` next to `docker-compose.yml` (mounted read-only at `/app/secrets/cookies.txt`) or set `COOKIES_FILE`. Each `yt-dlp` process uses an isolated temporary copy so concurrent downloads cannot corrupt it.
3. Restart the server/container (or simply place the file in `./secrets/cookies.txt`—it is checked per request).
