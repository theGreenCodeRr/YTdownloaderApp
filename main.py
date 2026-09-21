import os
import time
import asyncio
import uuid
import subprocess
import ssl
from fastapi import FastAPI, HTTPException, BackgroundTasks, Request, Header
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import re
import shutil
import zipfile

# MacOS SSL certificate bypass
try:
    _create_unverified_https_context = ssl._create_unverified_context
except AttributeError:
    pass
else:
    ssl._create_default_https_context = _create_unverified_https_context


app = FastAPI(title="Video Downloader")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

TEMP_STORAGE_DIR = "/var/www/ytdown"
os.makedirs(TEMP_STORAGE_DIR, exist_ok=True)

# We will store active downloads here for tracking
# { task_id: {"status": "processing" | "completed" | "failed", "filepath": str, "error": str, "progress": str} }
downloads = {}

# Keep track of recent downloads for the UI (mapped by client_id)
# { client_id: [ { task_id, title, thumbnail, format, status, timestamp }, ... ] }
recent_downloads = {}

# Keep track of cancelled tasks
cancel_flags = set()

templates = Jinja2Templates(directory="templates")

# Models
PREMIUM_PASSWORD = os.environ.get("PREMIUM_PASSWORD", "premium123")

class URLRequest(BaseModel):
    url: str

class ProcessRequest(BaseModel):
    url: str
    format_id: str
    title: str = "video"
    thumbnail: str = ""

class ProcessPlaylistRequest(BaseModel):
    url: str
    password: str
    format_id: str
    title: str = "playlist"

# Helper functions
import ctypes

def format_bytes(b):
    if b is None: return "0 B"
    if b < 1024: return f"{b} B"
    elif b < 1024**2: return f"{b/1024:.1f} KiB"
    elif b < 1024**3: return f"{b/1024**2:.1f} MiB"
    else: return f"{b/1024**3:.1f} GiB"

def drop_os_cache(filepath: str):
    """
    Forcefully evict a file from the Linux OS Page Cache.
    This prevents RAM usage from ballooning when internet speed > HDD write speed.
    """
    if not os.path.exists(filepath):
        return
        
    try:
        # Load libc
        libc = ctypes.CDLL(None)
        if not hasattr(libc, 'posix_fadvise'):
            libc = ctypes.CDLL("libc.so.6")
            
        POSIX_FADV_DONTNEED = 4
        
        # Open file descriptor
        fd = os.open(filepath, os.O_RDONLY)
        try:
            # Tell kernel we don't need this file in RAM anymore
            libc.posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED)
        finally:
            os.close(fd)
    except Exception as e:
        print(f"Failed to drop cache for {filepath}: {e}")


def download_video_sync(task_id: str, url: str, format_id: str, output_path: str, client_id: str = None):
    """
    Synchronous download function meant to be run in a separate thread.
    """
    is_audio_only = format_id.startswith('audio-')
    cmd = ['yt-dlp', '--newline', '--no-colors', '--no-playlist', '--no-check-certificate', '--no-cache-dir', '--limit-rate', '50M']
    cmd.extend(['-o', output_path])
    
    if is_audio_only:
        audio_codec = format_id.split('-')[1] # mp3, wav, flac
        cmd.extend(['-f', 'bestaudio/best', '-x', '--audio-format', audio_codec, '--audio-quality', '192'])
    else:
        cmd.extend(['-f', f'{format_id}+bestaudio/b', '--merge-output-format', 'mp4'])
        
    if os.path.exists("cookies.txt"):
        cmd.extend(['--cookies', 'cookies.txt'])
        
    cmd.append(url)
    
    # Wrap the yt-dlp command in a bash shell with a hard virtual memory limit of ~1.5GB (1500000 KB)
    cmd_str = " ".join([f"'{c}'" if ' ' in c or '*' in c else c for c in cmd])
    safe_cmd = ['bash', '-c', f'ulimit -v 1500000; exec {cmd_str}']
    
    try:
        # Run yt-dlp via subprocess with a strict context manager to guarantee pipe cleanup
        env = os.environ.copy()
        env["TMPDIR"] = TEMP_STORAGE_DIR
        with subprocess.Popen(safe_cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env) as process:
            progress_regex = re.compile(r'\[download\]\s+([\d\.]+%?)')
            
            for line in process.stdout:
                if task_id in cancel_flags:
                    process.terminate()
                    raise Exception("Download cancelled by user")
                    
                match = progress_regex.search(line)
                if match:
                    downloads[task_id]["progress"] = match.group(1)
            
            process.wait()
            
        if process.returncode != 0 and task_id not in cancel_flags:
            raise Exception(f"yt-dlp failed with return code {process.returncode}")
        
        # Audio extraction changes the file extension, so we must search for the final file
        base_path = os.path.splitext(output_path)[0]
        possible_files = [f for f in os.listdir(TEMP_STORAGE_DIR) if f.startswith(os.path.basename(base_path))]
        
        if possible_files:
            # Found the completed file
            actual_path = os.path.join(TEMP_STORAGE_DIR, possible_files[0])
            
            # Immediately force Linux to drop this file from RAM to prevent Page Cache ballooning
            drop_os_cache(actual_path)
            
            downloads[task_id]["filepath"] = actual_path
            downloads[task_id]["status"] = "completed"
            
            # Update history status
            if client_id and client_id in recent_downloads:
                for idx, item in enumerate(recent_downloads[client_id]):
                    if item["task_id"] == task_id:
                        recent_downloads[client_id][idx]["status"] = "completed"
                        break
        else:
            downloads[task_id]["status"] = "failed"
            downloads[task_id]["error"] = "Output file not found after download."
            if client_id and client_id in recent_downloads:
                for idx, item in enumerate(recent_downloads[client_id]):
                    if item["task_id"] == task_id:
                        recent_downloads[client_id][idx]["status"] = "failed"
                        break

    except Exception as e:
        err_msg = str(e)
        if task_id in cancel_flags:
            err_msg = "Download cancelled by user"
            
        downloads[task_id]["status"] = "failed"
        downloads[task_id]["error"] = err_msg
        if client_id and client_id in recent_downloads:
            for idx, item in enumerate(recent_downloads[client_id]):
                if item["task_id"] == task_id:
                    recent_downloads[client_id][idx]["status"] = "failed"
                    break
    finally:
        cancel_flags.discard(task_id)


# Background task to clean up old files periodically
async def periodic_cleanup():
    while True:
        try:
            now = time.time()
            for filename in os.listdir(TEMP_STORAGE_DIR):
                filepath = os.path.join(TEMP_STORAGE_DIR, filename)
                if os.path.isfile(filepath):
                    # Delete files older than 24 hours (86400 seconds)
                    if now - os.path.getmtime(filepath) > 86400:
                        os.remove(filepath)
                        print(f"Cleaned up old file: {filepath}")
        except Exception as e:
            print(f"Cleanup error: {e}")
        
        # Run cleanup every hour
        await asyncio.sleep(3600)

@app.on_event("startup")
async def startup_event():
    asyncio.create_task(periodic_cleanup())

import json

# API Endpoints
@app.post("/api/info")
async def fetch_formats(req: URLRequest):
    cmd = ['yt-dlp', '-J', '--no-check-certificate', '--flat-playlist', '--no-cache-dir']
    if os.path.exists("cookies.txt"):
        cmd.extend(['--cookies', 'cookies.txt'])
    cmd.append(req.url)

    try:
        def extract():
            env = os.environ.copy()
            env["TMPDIR"] = TEMP_STORAGE_DIR
            output = subprocess.check_output(cmd, text=True, env=env)
            return json.loads(output)
        
        info = await asyncio.to_thread(extract)
        
        # Check if it's a playlist
        if info.get('_type') == 'playlist':
            entries = []
            for entry in info.get('entries', []):
                if entry:
                    entries.append({
                        "url": entry.get('url') or entry.get('webpage_url'),
                        "title": entry.get('title', 'Unknown Title'),
                        "duration": entry.get('duration'),
                    })
            playlist_formats = [
                {"id": "best", "ext": "mp4", "res": "Best", "note": "Best quality available", "size_str": "Auto"},
                {"id": "bestvideo[height<=1080]+bestaudio/best", "ext": "mp4", "res": "1080p", "note": "Up to 1080p", "size_str": "Auto"},
                {"id": "bestvideo[height<=720]+bestaudio/best", "ext": "mp4", "res": "720p", "note": "Up to 720p", "size_str": "Auto"},
                {"id": "bestvideo[height<=480]+bestaudio/best", "ext": "mp4", "res": "480p", "note": "Up to 480p", "size_str": "Auto"},
                {"id": "audio-mp3", "ext": "mp3", "res": "Audio", "note": "High Quality MP3", "size_str": "Auto"}
            ]
            return {
                "is_playlist": True,
                "title": info.get('title', 'YouTube Playlist'),
                "entries": entries,
                "formats": playlist_formats
            }
        
        # It's a single video
        formats_list = []
        for f in info.get('formats', []):
            if f.get('vcodec', 'none') != 'none':
                filesize = f.get('filesize') or f.get('filesize_approx')
                formats_list.append({
                    "id": f.get('format_id'),
                    "ext": f.get('ext', '?'),
                    "res": f.get('resolution', 'audio'),
                    "note": f.get('format_note', ''),
                    "size_str": format_bytes(filesize),
                })
                
        # Inject Advanced Audio Formats
        formats_list.insert(0, {"id": "audio-mp3", "ext": "mp3", "res": "Audio", "note": "High Quality MP3", "size_str": "Auto"})
        formats_list.insert(1, {"id": "audio-wav", "ext": "wav", "res": "Audio", "note": "Lossless WAV", "size_str": "Auto"})
        formats_list.insert(2, {"id": "audio-flac", "ext": "flac", "res": "Audio", "note": "Lossless FLAC", "size_str": "Auto"})
        
        return {
            "is_playlist": False,
            "title": info.get('title', 'video'),
            "thumbnail": info.get('thumbnail', ''),
            "formats": formats_list
        }
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=500, detail="Failed to fetch video info via yt-dlp CLI")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/process")
async def process_video(req: ProcessRequest, background_tasks: BackgroundTasks, x_client_id: str = Header(default="anonymous")):
    task_id = str(uuid.uuid4())
    output_path = os.path.join(TEMP_STORAGE_DIR, f"{task_id}.mp4")
    
    downloads[task_id] = {
        "status": "processing",
        "filepath": output_path,
        "error": None,
        "progress": "0%"
    }
    
    if x_client_id not in recent_downloads:
        recent_downloads[x_client_id] = []
        
    # Save to history
    recent_downloads[x_client_id].insert(0, {
        "task_id": task_id,
        "title": req.title,
        "thumbnail": req.thumbnail,
        "format": req.format_id,
        "status": "processing",
        "timestamp": time.time()
    })
    # Cap history at 50 per client
    if len(recent_downloads[x_client_id]) > 50:
        recent_downloads[x_client_id].pop()
    
    # Spawn background task
    background_tasks.add_task(download_video_sync, task_id, req.url, req.format_id, output_path, x_client_id)
    
    return {"task_id": task_id}

def download_playlist_sync(task_id: str, url: str, format_id: str, output_zip_path: str, client_id: str = None):
    task_dir = os.path.join(TEMP_STORAGE_DIR, task_id)
    os.makedirs(task_dir, exist_ok=True)
    is_audio_only = format_id.startswith('audio-')

    try:
        cmd = ['yt-dlp', '-J', '--no-check-certificate', '--flat-playlist', '--no-cache-dir']
        if os.path.exists("cookies.txt"):
            cmd.extend(['--cookies', 'cookies.txt'])
        cmd.append(url)
        
        downloads[task_id]["progress"] = "Fetching playlist details..."
        env = os.environ.copy()
        env["TMPDIR"] = TEMP_STORAGE_DIR
        output = subprocess.check_output(cmd, text=True, env=env)
        playlist_info = json.loads(output)
            
        # extract_flat sometimes returns 'entries' as an iterator, make sure to convert it
        entries = list(playlist_info.get('entries', [])) if playlist_info else []
        if not entries:
            raise Exception("No videos found in playlist")
            
        # 2. Ensure initial zip file exists (empty)
        with zipfile.ZipFile(output_zip_path, 'w', compression=zipfile.ZIP_DEFLATED) as zipf:
            pass 

        # 3. Iterate over entries
        for index, entry in enumerate(entries):
            if task_id in cancel_flags:
                raise Exception("Download cancelled by user")
                
            video_url = entry.get('url') or entry.get('webpage_url')
            if not video_url:
                v_id = entry.get('id')
                if v_id:
                    video_url = f"https://www.youtube.com/watch?v={v_id}"
                else:
                    continue

            video_title = entry.get('title', f"Video_{index+1}")

            cmd = ['yt-dlp', '--newline', '--no-colors', '--no-check-certificate', '--no-playlist', '--no-cache-dir', '--limit-rate', '50M']
            cmd.extend(['-o', os.path.join(task_dir, '%(title)s.%(ext)s')])
            
            if is_audio_only:
                audio_codec = format_id.split('-')[1]
                cmd.extend(['-f', 'bestaudio/best', '-x', '--audio-format', audio_codec, '--audio-quality', '192'])
            else:
                if format_id == 'best':
                    cmd.extend(['-f', 'bestvideo+bestaudio/best', '--merge-output-format', 'mp4'])
                else:
                    cmd.extend(['-f', format_id, '--merge-output-format', 'mp4'])
                    
            if os.path.exists("cookies.txt"):
                cmd.extend(['--cookies', 'cookies.txt'])
                
            cmd.append(video_url)

            cmd_str = " ".join([f"'{c}'" if ' ' in c or '*' in c else c for c in cmd])
            safe_cmd = ['bash', '-c', f'ulimit -v 1500000; exec {cmd_str}']

            try:
                # Run yt-dlp via subprocess to absolutely guarantee NO memory leaks 
                # (yt-dlp Python API retains extractor caches in memory)
                env = os.environ.copy()
                env["TMPDIR"] = TEMP_STORAGE_DIR
                with subprocess.Popen(safe_cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env) as process:
                    progress_regex = re.compile(r'\[download\]\s+([\d\.]+%?)')
                    
                    for line in process.stdout:
                        if task_id in cancel_flags:
                            process.terminate()
                            raise Exception("Download cancelled by user")
                            
                        match = progress_regex.search(line)
                        if match:
                            percent_str = match.group(1)
                            downloads[task_id]["progress"] = f"[Video {index + 1}/{len(entries)}] {video_title} - {percent_str}"
                    
                    process.wait()
                    
                if process.returncode != 0 and task_id not in cancel_flags:
                    print(f"Failed to download {video_title}, return code {process.returncode}")
                    continue
                
                # Audio extraction changes the file extension, so we must search for the final file
                # It is located in task_dir
                possible_files = [f for f in os.listdir(task_dir) if f.startswith(entry.get('title', f"Video_{index+1}"))]
                if possible_files:
                    actual_path = os.path.join(task_dir, possible_files[0])
                    drop_os_cache(actual_path)
                
            except Exception as e:
                if task_id in cancel_flags:
                    raise Exception("Download cancelled by user")
                # If a single video fails (e.g. unavailable), log it and continue
                print(f"Exception during {video_title}: {e}")
                continue

        # After all videos are downloaded, zip them ONCE
        # This prevents O(N^2) disk writes and stops the OS Page Cache from ballooning RAM usage
        downloads[task_id]["progress"] = "Compressing videos into zip archive..."
        subprocess.run(['zip', '-b', TEMP_STORAGE_DIR, '-j', '-r', output_zip_path, task_dir], check=True, stdout=subprocess.DEVNULL)


        if os.path.exists(output_zip_path) and os.path.getsize(output_zip_path) > 22: # > 22 bytes means not an empty zip
            downloads[task_id]["status"] = "completed"
            downloads[task_id]["filepath"] = output_zip_path
            
            if client_id and client_id in recent_downloads:
                for idx, item in enumerate(recent_downloads[client_id]):
                    if item["task_id"] == task_id:
                        recent_downloads[client_id][idx]["status"] = "completed"
                        break
        else:
            raise Exception("Failed to create zip file or playlist was empty")

    except Exception as e:
        err_msg = str(e)
        if task_id in cancel_flags:
            err_msg = "Download cancelled by user"
            
        downloads[task_id]["status"] = "failed"
        downloads[task_id]["error"] = err_msg
        if client_id and client_id in recent_downloads:
            for idx, item in enumerate(recent_downloads[client_id]):
                if item["task_id"] == task_id:
                    recent_downloads[client_id][idx]["status"] = "failed"
                    break
    finally:
        cancel_flags.discard(task_id)
        if os.path.exists(task_dir):
            shutil.rmtree(task_dir, ignore_errors=True)

@app.post("/api/process_playlist")
async def process_playlist(req: ProcessPlaylistRequest, background_tasks: BackgroundTasks, x_client_id: str = Header(default="anonymous")):
    if req.password != PREMIUM_PASSWORD:
        raise HTTPException(status_code=401, detail="Invalid premium password")
        
    task_id = str(uuid.uuid4())
    output_zip_path = os.path.join(TEMP_STORAGE_DIR, f"{task_id}.zip")
    
    downloads[task_id] = {
        "status": "processing",
        "filepath": output_zip_path,
        "error": None,
        "progress": "0%",
        "media_type": "application/zip",
        "filename": f"{req.title}.zip"
    }
    
    if x_client_id not in recent_downloads:
        recent_downloads[x_client_id] = []
        
    recent_downloads[x_client_id].insert(0, {
        "task_id": task_id,
        "title": req.title,
        "thumbnail": "",
        "format": req.format_id,
        "status": "processing",
        "timestamp": time.time()
    })
    
    if len(recent_downloads[x_client_id]) > 50:
        recent_downloads[x_client_id].pop()
    
    background_tasks.add_task(download_playlist_sync, task_id, req.url, req.format_id, output_zip_path, x_client_id)
    
    return {"task_id": task_id}

@app.get("/api/recent")
async def get_recent(x_client_id: str = Header(default="anonymous")):
    return {"recent": recent_downloads.get(x_client_id, [])}

@app.get("/api/status/{task_id}")
async def get_status(task_id: str):
    if task_id not in downloads:
        raise HTTPException(status_code=404, detail="Task not found")
    
    return {
        "task_id": task_id,
        "status": downloads[task_id]["status"],
        "error": downloads[task_id]["error"],
        "progress": downloads[task_id].get("progress", "0%")
    }

@app.post("/api/cancel/{task_id}")
async def cancel_download(task_id: str):
    if task_id not in downloads:
        raise HTTPException(status_code=404, detail="Task not found")
    
    if downloads[task_id]["status"] == "processing":
        cancel_flags.add(task_id)
        return {"status": "cancelling"}
    else:
        return {"status": "already_finished"}

def delete_file_after_response(filepath: str, task_id: str):
    """Callback to delete the file after it has been served."""
    try:
        if os.path.exists(filepath):
            os.remove(filepath)
            print(f"Deleted file after stream: {filepath}")
    except Exception as e:
        print(f"Error deleting file {filepath}: {e}")
    finally:
        if task_id in downloads:
            del downloads[task_id]

@app.get("/api/download/{task_id}")
async def download_file(task_id: str, title: str = "video", background_tasks: BackgroundTasks = None):
    if task_id not in downloads:
        raise HTTPException(status_code=404, detail="Task not found")
    
    task_info = downloads[task_id]
    if task_info["status"] != "completed":
        raise HTTPException(status_code=400, detail="Download not completed yet")
    
    filepath = task_info["filepath"]
    if not os.path.exists(filepath):
        raise HTTPException(status_code=404, detail="File not found on server")
    
    safe_title = "".join(c for c in title if c.isalnum() or c in (' ', '.', '_', '-')).rstrip()
    
    media_type = task_info.get("media_type", "video/mp4")
    ext = ".zip" if media_type == "application/zip" else ".mp4"
    filename = task_info.get("filename", f"{safe_title}{ext}")
    
    background_tasks.add_task(delete_file_after_response, filepath, task_id)
    
    return FileResponse(
        path=filepath,
        filename=filename,
        media_type=media_type
    )

# Frontend Serving
@app.get("/")
async def serve_frontend(request: Request):
    return templates.TemplateResponse(request=request, name="index.html", context={"request": request})

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
