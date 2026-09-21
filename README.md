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

* **Universal Platform Support:** Download videos from YouTube, Facebook, and many other websites supported by `yt-dlp`.
* **Full Playlist Downloads:** Instantly fetch an entire playlist and download it as a bundled ZIP archive. Includes transparent progress tracking.
* **Download Management:** Features a built-in "Recent Downloads" tracking and the ability to **Cancel** ongoing downloads dynamically to save server resources.
* **Advanced Audio Extraction:** Download videos directly as high-quality audio files (**MP3**, **Lossless WAV**, or **Lossless FLAC**) via server-side FFmpeg processing.
* **Resource Optimized (Zero Memory Leaks):** Designed to run efficiently on low-memory VPS environments by isolating each playlist video into a completely separate memory context. It uses explicit Linux Kernel OS Cache flushing (`posix_fadvise`) to ensure massive files stream straight to disk without blowing up RAM.
* **Stability Guardrails:** Includes Hard limits on active concurrent downloads (Semaphore limited to 3) and Disk Space validation (>2GB free space) to ensure the server never crashes.
* **Anti-IP Block Support:** Seamlessly supports `cookies.txt` for bypassing platform IP blocks (frequent for VPS/Data Center deployments).
* **Automated Cleanup:** Automatically purges temporary video files from the server after they are downloaded, and executes a full startup sweep when the server boots.

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
```json
// Request
{
  "url": "https://youtube.com/playlist?list=...",
  "password": "premium123", // Required for playlist endpoint
  "format_id": "audio-mp3",
  "title": "Playlist Title"
}
```

### 4. Poll Download Status
`GET /api/status/{task_id}`
```json
// Response
{
  "task_id": "uuid-...",
  "status": "processing", // "processing" | "completed" | "failed"
  "error": null,
  "progress": "45.2%" // For playlists: "[Video 2/10] Title - 45.2%"
}
```

### 5. Download the File
`GET /api/download/{task_id}?title=SafeFilename`
This endpoint streams the file in chunks and automatically deletes it from the server when finished.

### 6. Cancel a Download
`POST /api/cancel/{task_id}`

---

## 🚀 Quick Start (Docker)

The easiest way to run the application is using Docker and Docker Compose.

### 1. Build and Run
```bash
docker compose up --build -d
```

### 2. Access the App
http://localhost:8000

---

## 🛠 Manual Installation (Without Docker)

### 1. Install Dependencies
Make sure you have Python 3.11+ and `ffmpeg` installed on your system.
```bash
pip install -r requirements.txt
```

### 2. Run the Server
```bash
uvicorn main:app --host 0.0.0.0 --port 8000
```

---

## 🍪 Bypassing IP Blocks (cookies.txt)

If your deployment server's IP address gets blocked by the platform:
1. Export a `cookies.txt` file from your desktop browser.
2. Place the `cookies.txt` file directly in the root directory.
3. Restart the server/container. The app will automatically detect and use it.
