import os
import time
import asyncio
import uuid
import subprocess
import mimetypes
import unicodedata
import hmac
import ipaddress
import signal
import socket
import tempfile
import threading
from collections import defaultdict, deque
from contextlib import contextmanager
from typing import List, Optional
from urllib.parse import quote, urlsplit
from fastapi import FastAPI, HTTPException, BackgroundTasks, Request, Header, Depends
from fastapi.responses import StreamingResponse
from fastapi.templating import Jinja2Templates
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import re
import shutil
import zipfile

from storage import Store


def _env_bool(name: str, default: bool = False) -> bool:
    return os.environ.get(name, str(default)).strip().lower() in ("1", "true", "yes", "on")


# =============================================================================
# Configuration (everything can be overridden with environment variables)
# =============================================================================

# Temporary media files. Wiped of orphans on startup, so never put anything else here.
TEMP_STORAGE_DIR = os.environ.get("TEMP_STORAGE_DIR", "/var/www/ytdown")
os.makedirs(TEMP_STORAGE_DIR, exist_ok=True)

# SQLite database holding tasks + history (must NOT live inside TEMP_STORAGE_DIR)
DB_PATH = os.environ.get("DB_PATH", os.path.join("data", "ytdown.db"))

# How long a finished file stays on the server after it was first served,
# so the user can re-download it from "Recent Downloads" (or a mobile browser can retry).
SERVE_GRACE_SECONDS = int(os.environ.get("SERVE_GRACE_SECONDS", "600"))
# Finished files that are never downloaded are removed after this long
FILE_TTL_SECONDS = int(os.environ.get("FILE_TTL_SECONDS", "86400"))
# History rows are kept this long (default: 24 hours)
HISTORY_TTL_SECONDS = int(os.environ.get("HISTORY_TTL_SECONDS", "86400"))

# Maximum size of any single download or playlist ZIP archive (default: 200 GB)
MAX_DOWNLOAD_GB = int(os.environ.get("MAX_DOWNLOAD_GB", "400"))
MAX_DOWNLOAD_BYTES = MAX_DOWNLOAD_GB * 1024 * 1024 * 1024
MAX_PLAYLIST_ITEMS = int(os.environ.get("MAX_PLAYLIST_ITEMS", "500"))
BLOCK_PRIVATE_URLS = _env_bool("BLOCK_PRIVATE_URLS", True)

# Trusted reverse proxies whose X-Forwarded-For / CF-Connecting-IP headers are honored
FORWARDED_ALLOW_IPS = os.environ.get("FORWARDED_ALLOW_IPS", "127.0.0.1,172.16.0.0/12,192.168.1.0/24")

# Max seconds to wait for yt-dlp metadata extraction
INFO_TIMEOUT_SECONDS = int(os.environ.get("INFO_TIMEOUT_SECONDS", "120"))

# Premium password for multi-video (playlist) ZIP downloads. No insecure default:
# if it's not set, playlist ZIP downloads are disabled.
PREMIUM_PASSWORD = os.environ.get("PREMIUM_PASSWORD", "").strip()

# CORS: the web UI is served from the same origin and native mobile apps are not
# affected by CORS, so by default NO cross-origin browser access is allowed.
# Set e.g. ALLOWED_ORIGINS="https://myapp.com,https://admin.myapp.com" if needed.
ALLOWED_ORIGINS = [o.strip() for o in os.environ.get("ALLOWED_ORIGINS", "").split(",") if o.strip()]

# TLS verification for yt-dlp is ON by default. Only disable for broken corporate proxies.
YTDLP_NO_CHECK_CERTIFICATE = _env_bool("YTDLP_NO_CHECK_CERTIFICATE", False)

# cookies.txt for login-only content (first existing file wins)
COOKIES_FILE_CANDIDATES = [os.environ.get("COOKIES_FILE"), os.path.join("secrets", "cookies.txt"), "cookies.txt"]

# Rate limits: "<requests>/<seconds>" per client IP. Use "0/1" to disable a limit.
def _parse_limit(value: str, default: str):
    try:
        count, seconds = (value or default).split("/")
        return int(count), int(seconds)
    except ValueError:
        count, seconds = default.split("/")
        return int(count), int(seconds)

RATE_LIMIT_INFO = _parse_limit(os.environ.get("RATE_LIMIT_INFO"), "30/60")
RATE_LIMIT_PROCESS = _parse_limit(os.environ.get("RATE_LIMIT_PROCESS"), "10/60")
RATE_LIMIT_PLAYLIST = _parse_limit(os.environ.get("RATE_LIMIT_PLAYLIST"), "5/3600")
RATE_LIMIT_PASSWORD_FAILS = _parse_limit(os.environ.get("RATE_LIMIT_PASSWORD_FAILS"), "5/900")
MAX_ACTIVE_TASKS_PER_IP = int(os.environ.get("MAX_ACTIVE_TASKS_PER_IP", "3"))


app = FastAPI(title="Video Downloader")

if ALLOWED_ORIGINS:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=ALLOWED_ORIGINS,
        allow_credentials=False,  # the API doesn't use cookies
        allow_methods=["GET", "POST"],
        allow_headers=["Content-Type", "X-Client-ID"],
    )


@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    response.headers.setdefault("Referrer-Policy", "strict-origin-when-cross-origin")
    response.headers.setdefault("X-Frame-Options", "DENY")
    return response


store = Store(DB_PATH)

# Live, in-memory state of RUNNING tasks only (progress changes many times per second).
# { task_id: {"status", "progress", "percent", "error", "client_ip"} }
# Finished tasks live in SQLite (see storage.py).
downloads = {}

# Keep track of cancelled tasks
cancel_flags = set()

# Keep references to delayed-deletion tasks so they are not garbage collected
_pending_deletions = {}

# Number of queued/running tasks per client IP
_active_by_ip = defaultdict(int)

_server_info = {"yt_dlp_version": None}

templates = Jinja2Templates(directory="templates")

# Models
class URLRequest(BaseModel):
    url: str

class ProcessRequest(BaseModel):
    url: str
    format_id: str
    title: str = "video"
    thumbnail: str = ""

class PlaylistItem(BaseModel):
    url: str
    title: str = ""
    index: Optional[int] = None  # 1-based position inside the original playlist

class ProcessPlaylistRequest(BaseModel):
    url: str
    password: str
    format_id: str
    title: str = "playlist"
    # Optional: only download these entries. If omitted/empty, the entire playlist is downloaded.
    items: Optional[List[PlaylistItem]] = None

# =============================================================================
# Rate limiting (in-memory sliding window, per client IP)
# =============================================================================

class RateLimiter:
    def __init__(self):
        self._hits = defaultdict(deque)
        self._lock = threading.Lock()

    def _prune(self, key: str, window: int, now: float):
        q = self._hits[key]
        while q and q[0] <= now - window:
            q.popleft()
        return q

    def count(self, key: str, window: int) -> int:
        with self._lock:
            return len(self._prune(key, window, time.monotonic()))

    def add(self, key: str):
        with self._lock:
            self._hits[key].append(time.monotonic())

    def hit(self, key: str, limit: int, window: int) -> Optional[int]:
        """Record a request. Returns seconds to wait if the limit is exceeded, else None."""
        if limit <= 0:
            return None
        with self._lock:
            now = time.monotonic()
            q = self._prune(key, window, now)
            if len(q) >= limit:
                return int(q[0] + window - now) + 1
            q.append(now)
            return None

    def retry_after(self, key: str, window: int) -> int:
        with self._lock:
            q = self._prune(key, window, time.monotonic())
            return int(q[0] + window - time.monotonic()) + 1 if q else 1

    def cleanup(self, max_window: int = 86400):
        with self._lock:
            now = time.monotonic()
            for key in list(self._hits.keys()):
                q = self._hits[key]
                while q and q[0] <= now - max_window:
                    q.popleft()
                if not q:
                    del self._hits[key]

limiter = RateLimiter()

def _parse_ip(value: Optional[str]) -> Optional[str]:
    if not value:
        return None
    try:
        return str(ipaddress.ip_address(value.strip()))
    except ValueError:
        return None


def _build_trusted_proxies(raw: str):
    trust_all = False
    ips = set()
    networks = []
    literals = {"testclient"}  # allow Starlette TestClient in automated tests
    for entry in (raw or "").split(","):
        item = entry.strip()
        if not item:
            continue
        if item == "*":
            trust_all = True
            continue
        if "/" in item:
            try:
                networks.append(ipaddress.ip_network(item, strict=False))
                continue
            except ValueError:
                pass
        try:
            ips.add(ipaddress.ip_address(item))
        except ValueError:
            literals.add(item)
    return trust_all, ips, networks, literals


_TRUST_ALL_PROXIES, _TRUSTED_PROXY_IPS, _TRUSTED_PROXY_NETWORKS, _TRUSTED_PROXY_LITERALS = _build_trusted_proxies(
    FORWARDED_ALLOW_IPS
)


def _is_trusted_proxy(host: Optional[str]) -> bool:
    if _TRUST_ALL_PROXIES or host is None:
        return True
    if host in _TRUSTED_PROXY_LITERALS:
        return True
    try:
        addr = ipaddress.ip_address(host.split("%", 1)[0])
    except ValueError:
        return False
    return addr in _TRUSTED_PROXY_IPS or any(addr in net for net in _TRUSTED_PROXY_NETWORKS)


def client_ip(request: Request) -> str:
    peer = request.client.host if request.client else None
    if _is_trusted_proxy(peer):
        # Behind Cloudflare -> Nginx Proxy -> Docker:
        # CF-Connecting-IP holds the original visitor IP; X-Forwarded-For's leftmost
        # entry or X-Real-IP are checked next before falling back to request.client.host.
        candidates = [
            request.headers.get("cf-connecting-ip"),
            (request.headers.get("x-forwarded-for") or "").split(",")[0],
            request.headers.get("x-real-ip"),
        ]
        for candidate in candidates:
            parsed = _parse_ip(candidate)
            if parsed:
                return parsed
    return peer or "unknown"

def rate_limit(bucket: str, limit_window):
    limit, window = limit_window

    async def dependency(request: Request):
        retry = limiter.hit(f"{bucket}:{client_ip(request)}", limit, window)
        if retry:
            raise HTTPException(
                status_code=429,
                detail=f"Too many requests. Please wait {retry} seconds and try again.",
                headers={"Retry-After": str(retry)},
            )
    return Depends(dependency)

def check_active_limit(ip: str):
    if MAX_ACTIVE_TASKS_PER_IP > 0 and _active_by_ip[ip] >= MAX_ACTIVE_TASKS_PER_IP:
        raise HTTPException(
            status_code=429,
            detail=f"You already have {_active_by_ip[ip]} downloads in progress. Please wait for one to finish.",
        )

# --- Guardrails and Concurrency ---
# Limit active downloads to 3 simultaneously to prevent CPU/RAM exhaustion
download_semaphore = asyncio.Semaphore(3)

def check_disk_space():
    """Ensures there is at least 2GB of free space on the temporary storage drive."""
    total, used, free = shutil.disk_usage(TEMP_STORAGE_DIR)
    if free < 2 * 1024 * 1024 * 1024: # 2 GiB
        raise HTTPException(
            status_code=507, 
            detail="Server has insufficient storage space to process this request right now. Please try again later."
        )

# Helper functions
import ctypes

def format_bytes(b):
    if b is None: return "Unknown"
    if b < 1024: return f"{b} B"
    elif b < 1024**2: return f"{b/1024:.1f} KiB"
    elif b < 1024**3: return f"{b/1024**2:.1f} MiB"
    else: return f"{b/1024**3:.1f} GiB"

def find_cookies_file() -> Optional[str]:
    for path in COOKIES_FILE_CANDIDATES:
        if path and os.path.isfile(path) and os.path.getsize(path) > 0:
            return path
    return None

@contextmanager
def yt_dlp_command(*args):
    """
    Build a yt-dlp command line. If a cookies.txt exists, each yt-dlp process gets its
    OWN private copy: yt-dlp rewrites the cookie file on exit, and several concurrent
    downloads writing the same file can corrupt it. This also lets the original be
    mounted read-only.
    """
    cmd = ['yt-dlp', '--no-cache-dir', '--no-warnings']
    if YTDLP_NO_CHECK_CERTIFICATE:
        cmd.append('--no-check-certificate')

    cookie_copy = None
    source = find_cookies_file()
    if source:
        fd, cookie_copy = tempfile.mkstemp(prefix="ytd-cookies-", suffix=".txt")  # created with 0600
        os.close(fd)
        shutil.copyfile(source, cookie_copy)
        cmd.extend(['--cookies', cookie_copy])
    try:
        yield cmd + list(args)
    finally:
        if cookie_copy:
            try:
                os.remove(cookie_copy)
            except OSError:
                pass

def yt_dlp_env():
    env = os.environ.copy()
    env["TMPDIR"] = TEMP_STORAGE_DIR
    env["PYTHONIOENCODING"] = "utf-8"
    return env

LOGIN_HINTS = ("registered users", "login", "log in", "sign in", "cookies", "private", "age-restricted",
               "confirm your age", "not a bot", "authentication", "members-only")

def extract_yt_dlp_error(output: str) -> str:
    """Return the most useful 'ERROR:' line from yt-dlp output (or a generic message)."""
    errors = [line.strip() for line in (output or "").splitlines() if line.strip().startswith("ERROR:")]
    if not errors:
        return "Failed to process this link. It may be private, region-locked, or unsupported."

    msg = errors[-1][len("ERROR:"):].strip()
    # Strip the "[extractor] id:" prefix, it's noise for end users
    msg = re.sub(r'^\[[^\]]+\]\s*[^:]*:\s*', '', msg) or msg
    # yt-dlp appends long "use --cookies-from-browser ..." CLI advice that doesn't apply to web users
    msg = re.split(r'\s*(?:Use --cookies|See\s+https://github\.com/yt-dlp)', msg)[0].strip()
    if "Unsupported URL" in msg:
        return "This website or link is not supported."
    msg = msg[:300]

    if any(h in msg.lower() for h in LOGIN_HINTS):
        if find_cookies_file():
            msg += " (The server's login cookies may have expired. The administrator needs to refresh cookies.txt.)"
        else:
            msg += " (This content requires a logged-in account. The administrator can enable it by adding a cookies.txt file.)"
    return msg

def sanitize_filename(name: str, default: str = "video") -> str:
    """
    Make a filename safe for every OS while KEEPING non-English characters
    (Japanese, Bengali, Arabic, emoji, ...). Only characters that are illegal in
    file names are removed.
    """
    name = unicodedata.normalize("NFC", name or "")
    name = re.sub(r'[\x00-\x1f\x7f<>:"/\\|?*]', '', name)
    name = re.sub(r'\s+', ' ', name).strip(' .')
    # Keep the name below ~180 bytes (filesystems usually allow 255 bytes, and
    # a Japanese/Bengali character takes 3 bytes in UTF-8)
    while len(name.encode('utf-8')) > 180:
        name = name[:-1]
    return name or default

def content_disposition(filename: str) -> str:
    """
    Build a Content-Disposition header that works with Unicode file names.
    HTTP headers must be latin-1, so we send an ASCII fallback in `filename=`
    and the real UTF-8 name in `filename*=` (RFC 6266 / RFC 5987). All modern
    browsers use the UTF-8 version.
    """
    stem, ext = os.path.splitext(filename)
    ascii_stem = unicodedata.normalize('NFKD', stem).encode('ascii', 'ignore').decode('ascii')
    ascii_stem = re.sub(r'[^A-Za-z0-9 ._()\-]', '', ascii_stem)
    ascii_stem = re.sub(r'\s+', ' ', ascii_stem).strip(' .')
    if not ascii_stem:
        ascii_stem = "download"
    ascii_name = f"{ascii_stem}{ext}"
    return f"attachment; filename=\"{ascii_name}\"; filename*=UTF-8''{quote(filename, safe='')}"

# =============================================================================
# Task state helpers
# =============================================================================

def set_progress(task_id: str, progress: str, percent: Optional[float] = None):
    """In-memory only: called many times per second."""
    live = downloads.get(task_id)
    if live is not None:
        live["progress"] = progress
        if percent is not None:
            live["percent"] = percent

def finish_task(task_id: str, status: str, **fields):
    """Persist a final state (completed / failed)."""
    fields["finished_at"] = time.time()
    store.update_task(task_id, status=status, **fields)
    live = downloads.get(task_id)
    if live is not None:
        live["status"] = status
        live["error"] = fields.get("error")
        if status == "completed":
            live["percent"] = 100.0

def fail_task(task_id: str, error: str):
    finish_task(task_id, "failed", error=error)

def task_view(task_id: str) -> Optional[dict]:
    """Merge the persisted task with live progress (if it's still running)."""
    task = store.get_task(task_id)
    if not task:
        return None
    live = downloads.get(task_id)
    if task["status"] == "processing" and live:
        task["progress"] = live.get("progress", "0%")
        task["percent"] = live.get("percent", 0.0)
    elif task["status"] == "completed":
        task["progress"] = task.get("note") or "100%"
        task["percent"] = 100.0
    else:
        task["progress"] = task.get("note") or ""
        task["percent"] = 0.0
    return task

def register_task(task_id: str, ip: str, client_id: str, **fields):
    store.create_task(task_id, client_id=client_id, status="processing", **fields)
    store.trim_client_history(client_id, keep=50)
    downloads[task_id] = {"status": "processing", "progress": "Waiting in queue...", "percent": 0.0,
                          "error": None, "client_ip": ip}
    _active_by_ip[ip] += 1

def release_task(task_id: str):
    """Called once a task is finished (any outcome) to free in-memory resources."""
    live = downloads.pop(task_id, None)
    cancel_flags.discard(task_id)
    if live:
        ip = live.get("client_ip")
        _active_by_ip[ip] = max(0, _active_by_ip[ip] - 1)
        if _active_by_ip[ip] == 0:
            _active_by_ip.pop(ip, None)

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


PROGRESS_REGEX = re.compile(r'\[download\]\s+([\d\.]+)%')
POSTPROCESS_MARKERS = ('[Merger]', '[ExtractAudio]', '[VideoConvertor]', '[FixupM3u8]', '[FixupM4a]', '[ffmpeg]')
ALLOWED_AUDIO_FORMATS = {'audio-mp3', 'audio-wav', 'audio-flac', 'audio-m4a', 'audio-opus'}
FORMAT_ID_RE = re.compile(r'^[A-Za-z0-9._\-]{1,64}$')


def _terminate_process(process):
    """Terminate yt-dlp and any child processes (ffmpeg/deno) in its process group."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except Exception:
        try:
            process.terminate()
        except Exception:
            pass


def validate_format_id(format_id: str) -> str:
    fmt = (format_id or "").strip()
    playlist_ids = {f["id"] for f in PLAYLIST_FORMATS}
    if fmt == 'best' or fmt in ALLOWED_AUDIO_FORMATS or fmt in playlist_ids or FORMAT_ID_RE.fullmatch(fmt):
        return fmt
    raise HTTPException(status_code=400, detail="Invalid format selection.")


def build_format_args(format_id: str):
    """Translate a UI format id into yt-dlp format arguments."""
    if format_id.startswith('audio-'):
        audio_codec = format_id.split('-', 1)[1] # mp3, wav, flac
        if audio_codec not in ('mp3', 'wav', 'flac', 'm4a', 'opus'):
            audio_codec = 'mp3'
        return ['-f', 'bestaudio/best', '-x', '--audio-format', audio_codec, '--audio-quality', '192']
    if format_id == 'best':
        return ['-f', 'bv*+ba/b', '--merge-output-format', 'mp4']
    if '/' in format_id or '[' in format_id or '+' in format_id:
        # Already a full yt-dlp format selector (used by playlist qualities)
        return ['-f', format_id, '--merge-output-format', 'mp4']
    # A specific format picked by the user. Some platforms (YouTube) serve video
    # without audio, others (Facebook, TikTok, Vimeo...) serve combined streams,
    # so try: chosen + best audio -> chosen alone -> best available.
    return ['-f', f'{format_id}+ba/{format_id}/b', '--merge-output-format', 'mp4']


def download_video_sync(task_id: str, url: str, format_id: str, output_path: str):
    """
    Synchronous download function meant to be run in a separate thread.
    """
    args = ['--newline', '--no-colors', '--no-playlist', '--limit-rate', '50M',
            '--max-filesize', f'{MAX_DOWNLOAD_GB}G', '-o', output_path]
    args += build_format_args(format_id)
    args.extend(['--', url])
    
    try:
        # Run yt-dlp via subprocess with a strict context manager to guarantee pipe cleanup
        tail = []
        with yt_dlp_command(*args) as cmd, \
             subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                              encoding='utf-8', errors='replace', env=yt_dlp_env(),
                              start_new_session=True) as process:
            for line in process.stdout:
                if task_id in cancel_flags:
                    _terminate_process(process)
                    raise Exception("Download cancelled by user")

                tail.append(line)
                if len(tail) > 50:
                    tail.pop(0)

                match = PROGRESS_REGEX.search(line)
                if match:
                    set_progress(task_id, f"{match.group(1)}%", float(match.group(1)))
                elif line.startswith(POSTPROCESS_MARKERS):
                    set_progress(task_id, "Processing (merging / converting)...")
            
            process.wait()
            
        if process.returncode != 0 and task_id not in cancel_flags:
            raise Exception(extract_yt_dlp_error("".join(tail)))
        
        # Audio extraction changes the file extension, so we must search for the final file
        base_name = os.path.basename(os.path.splitext(output_path)[0])
        possible_files = [
            f for f in os.listdir(TEMP_STORAGE_DIR)
            if f.startswith(base_name) and not f.endswith(('.part', '.ytdl', '.temp')) and '.part-' not in f
        ]
        
        if possible_files:
            # Found the completed file (prefer the largest one if leftovers exist)
            possible_files.sort(key=lambda f: os.path.getsize(os.path.join(TEMP_STORAGE_DIR, f)), reverse=True)
            actual_path = os.path.join(TEMP_STORAGE_DIR, possible_files[0])
            if os.path.getsize(actual_path) > MAX_DOWNLOAD_BYTES:
                _remove_path(actual_path)
                fail_task(task_id, f"Download exceeded the {MAX_DOWNLOAD_GB} GB limit.")
                return

            # Immediately force Linux to drop this file from RAM to prevent Page Cache ballooning
            drop_os_cache(actual_path)
            finish_task(task_id, "completed", filepath=actual_path)
        else:
            fail_task(task_id, "Output file not found after download.")

    except Exception as e:
        err_msg = str(e)
        if task_id in cancel_flags:
            err_msg = "Download cancelled by user"
        fail_task(task_id, err_msg)

async def run_queued(task_id: str, worker, *args):
    """Wait in queue for a semaphore slot, run the blocking worker in a thread, then clean up."""
    try:
        if task_id in cancel_flags:
            fail_task(task_id, "Cancelled before starting")
            return
        set_progress(task_id, "Waiting in queue...")
        async with download_semaphore:
            if task_id in cancel_flags:
                fail_task(task_id, "Cancelled before starting")
                return
            set_progress(task_id, "0%")
            await asyncio.to_thread(worker, task_id, *args)
    except Exception as e:
        fail_task(task_id, f"Unexpected error: {e}")
    finally:
        release_task(task_id)

# =============================================================================
# Cleanup / file lifecycle
# =============================================================================

def _remove_path(path: str):
    try:
        if os.path.isdir(path):
            shutil.rmtree(path, ignore_errors=True)
        elif os.path.exists(path):
            os.remove(path)
    except OSError as e:
        print(f"Failed to remove {path}: {e}")

def expire_task(task_id: str, filepath: Optional[str]):
    if filepath:
        _remove_path(filepath)
    store.update_task(task_id, status="expired")

def _sweep_storage(remove_all_orphans: bool):
    """
    Delete files that no longer belong to a completed task. On startup every orphan
    is removed (partial downloads of interrupted tasks); periodically only orphans
    older than FILE_TTL_SECONDS are removed (running downloads must be left alone).
    """
    now = time.time()
    keep = set()
    for task in store.tasks_with_status("completed"):
        path = task.get("filepath")
        reference_time = task.get("finished_at") or task.get("created_at") or now
        if not path or not os.path.exists(path):
            store.update_task(task["task_id"], status="expired")
        elif now - reference_time > FILE_TTL_SECONDS:
            expire_task(task["task_id"], path)
            print(f"Cleaned up old file: {path}")
        else:
            keep.add(os.path.abspath(path))

    running = set(downloads.keys())
    for name in os.listdir(TEMP_STORAGE_DIR):
        path = os.path.join(TEMP_STORAGE_DIR, name)
        if os.path.abspath(path) in keep:
            continue
        if any(name.startswith(tid) for tid in running):
            continue
        if remove_all_orphans or now - os.path.getmtime(path) > FILE_TTL_SECONDS:
            _remove_path(path)

# Background task to clean up old files periodically
async def periodic_cleanup():
    while True:
        try:
            await asyncio.to_thread(_sweep_storage, False)
            store.purge_older_than(time.time() - HISTORY_TTL_SECONDS)
            limiter.cleanup()
        except Exception as e:
            print(f"Cleanup error: {e}")
        
        # Run cleanup every hour
        await asyncio.sleep(3600)

def _read_yt_dlp_version():
    try:
        _server_info["yt_dlp_version"] = subprocess.run(
            ['yt-dlp', '--version'], capture_output=True, text=True, timeout=30
        ).stdout.strip() or None
    except Exception:
        _server_info["yt_dlp_version"] = None

@app.on_event("startup")
async def startup_event():
    if not PREMIUM_PASSWORD:
        print("WARNING: PREMIUM_PASSWORD is not set - playlist ZIP downloads are DISABLED.")
    elif PREMIUM_PASSWORD == "premium123" or len(PREMIUM_PASSWORD) < 8:
        print("WARNING: PREMIUM_PASSWORD is weak. Please use a long random password.")
    if not ALLOWED_ORIGINS:
        print("CORS: cross-origin browser requests are disabled (set ALLOWED_ORIGINS to allow some).")
    print(f"Cookies file: {find_cookies_file() or 'none (login-only content will not work)'}")

    # Downloads that were running when the server stopped can never finish
    interrupted = store.mark_interrupted("Interrupted because the server restarted. Please try again.")
    if interrupted:
        print(f"Startup: marked {interrupted} interrupted task(s) as failed.")

    # Keep finished files that can still be downloaded, wipe partial/orphaned files.
    # This prevents orphaned files from accumulating if the server crashes unexpectedly
    try:
        await asyncio.to_thread(_sweep_storage, True)
        print("Startup cleanup: removed orphaned temporary files.")
    except Exception as e:
        print(f"Startup cleanup error: {e}")

    # Re-schedule deletions that were pending (file already served) before the restart
    now = time.time()
    for task in store.tasks_with_status("completed"):
        if task.get("served_at"):
            delay = max(0, task["served_at"] + SERVE_GRACE_SECONDS - now)
            _pending_deletions[task["task_id"]] = asyncio.create_task(
                _delayed_delete(task["filepath"], task["task_id"], delay)
            )

    asyncio.create_task(asyncio.to_thread(_read_yt_dlp_version))
    asyncio.create_task(periodic_cleanup())

import json

def _format_resolution(f: dict) -> str:
    height = f.get('height')
    if height:
        fps = f.get('fps')
        return f"{height}p{int(fps) if fps and fps > 30 else ''}"
    res = f.get('resolution')
    if res and res != 'audio only':
        return res
    return f.get('format_note') or f.get('format_id') or 'Video'

def build_video_formats(info: dict) -> list:
    """Build the list of selectable formats for a single video, best quality first."""
    raw_formats = info.get('formats') or []
    # Multi-video posts (e.g. some X/Instagram posts) keep formats on the first entry
    if not raw_formats and info.get('entries'):
        first = next((e for e in info['entries'] if e), None) or {}
        raw_formats = first.get('formats') or []

    video_formats = []
    for f in raw_formats:
        vcodec = f.get('vcodec')
        ext = f.get('ext', '?')
        if vcodec == 'none' or ext in ('mhtml',):
            continue  # audio-only or storyboard
        # Some extractors don't report codecs at all; keep those unless clearly audio
        if vcodec is None and f.get('acodec') not in (None, 'none') and not f.get('height') and not f.get('width'):
            continue
        filesize = f.get('filesize') or f.get('filesize_approx')
        note_parts = [p for p in [f.get('format_note'), (f.get('vcodec') or '').split('.')[0] or None] if p]
        video_formats.append({
            "id": f.get('format_id'),
            "ext": 'mp4',  # everything is merged/remuxed into mp4
            "res": _format_resolution(f),
            "note": " · ".join(dict.fromkeys(note_parts)),
            "size_str": format_bytes(filesize),
            "kind": "video",
            "_sort": (f.get('height') or 0, f.get('tbr') or 0, filesize or 0),
        })

    # Highest quality first, and keep only the best format per resolution label
    video_formats.sort(key=lambda x: x["_sort"], reverse=True)
    seen = set()
    deduped = []
    for f in video_formats:
        if f["res"] in seen:
            continue
        seen.add(f["res"])
        f.pop("_sort", None)
        deduped.append(f)

    formats_list = [{"id": "best", "ext": "mp4", "res": "Best", "note": "Best quality available (recommended)", "size_str": "Auto", "kind": "video"}]
    formats_list.extend(deduped)
    # Inject Advanced Audio Formats
    formats_list.extend([
        {"id": "audio-mp3", "ext": "mp3", "res": "Audio", "note": "High Quality MP3", "size_str": "Auto", "kind": "audio"},
        {"id": "audio-wav", "ext": "wav", "res": "Audio", "note": "Lossless WAV", "size_str": "Auto", "kind": "audio"},
        {"id": "audio-flac", "ext": "flac", "res": "Audio", "note": "Lossless FLAC", "size_str": "Auto", "kind": "audio"},
    ])
    return formats_list

PLAYLIST_FORMATS = [
    {"id": "best", "ext": "mp4", "res": "Best", "note": "Best quality available", "size_str": "Auto", "kind": "video"},
    {"id": "bv*[height<=1080]+ba/b[height<=1080]/b", "ext": "mp4", "res": "1080p", "note": "Up to 1080p", "size_str": "Auto", "kind": "video"},
    {"id": "bv*[height<=720]+ba/b[height<=720]/b", "ext": "mp4", "res": "720p", "note": "Up to 720p", "size_str": "Auto", "kind": "video"},
    {"id": "bv*[height<=480]+ba/b[height<=480]/b", "ext": "mp4", "res": "480p", "note": "Up to 480p", "size_str": "Auto", "kind": "video"},
    {"id": "audio-mp3", "ext": "mp3", "res": "Audio", "note": "High Quality MP3", "size_str": "Auto", "kind": "audio"}
]

def _entry_url(entry: dict) -> Optional[str]:
    url = entry.get('webpage_url') or entry.get('url')
    if url and not url.startswith(('http://', 'https://')):
        url = None
    if not url:
        v_id = entry.get('id')
        if v_id and (entry.get('ie_key') or '').lower().startswith('youtube'):
            url = f"https://www.youtube.com/watch?v={v_id}"
        else:
            url = entry.get('url') or None
    return url

def _entry_thumbnail(entry: dict) -> str:
    if entry.get('thumbnail'):
        return entry['thumbnail']
    thumbs = entry.get('thumbnails') or []
    if thumbs:
        return thumbs[-1].get('url') or ''
    return ''

def _is_disallowed_ip(ip_str: str) -> bool:
    try:
        ip = ipaddress.ip_address(ip_str.split("%", 1)[0])
    except ValueError:
        return False
    return (
        ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_multicast
        or ip.is_reserved
        or ip.is_unspecified
    )


def validate_url(url: str, resolve_dns: bool = False) -> str:
    url = (url or "").strip()
    if not re.match(r'^https?://', url, re.IGNORECASE) or len(url) > 2048:
        raise HTTPException(status_code=400, detail="Please enter a valid link starting with http:// or https://")

    parsed = urlsplit(url)
    hostname = parsed.hostname
    if parsed.scheme.lower() not in ("http", "https") or not hostname:
        raise HTTPException(status_code=400, detail="Please enter a valid link starting with http:// or https://")

    if BLOCK_PRIVATE_URLS:
        host_lower = hostname.lower().rstrip(".")
        if host_lower in ("localhost", "localhost.localdomain") or host_lower.endswith((".local", ".internal", ".lan")):
            raise HTTPException(status_code=400, detail="Links to private or local network addresses are not allowed.")

        if _parse_ip(hostname.split("%", 1)[0]) is not None:
            if _is_disallowed_ip(hostname):
                raise HTTPException(status_code=400, detail="Links to private or local network addresses are not allowed.")
        elif resolve_dns:
            try:
                infos = socket.getaddrinfo(hostname, None, type=socket.SOCK_STREAM)
            except socket.gaierror:
                infos = []
            for info in infos:
                addr = info[4][0]
                if _is_disallowed_ip(addr):
                    raise HTTPException(status_code=400, detail="Links to private or local network addresses are not allowed.")

    return url


def run_info_extraction(url: str) -> dict:
    url = validate_url(url, resolve_dns=True)
    try:
        with yt_dlp_command('-J', '--flat-playlist', '--', url) as cmd:
            result = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace',
                                    env=yt_dlp_env(), timeout=INFO_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="The website took too long to respond. Please try again.")
    if result.returncode != 0 or not result.stdout.strip():
        raise HTTPException(status_code=422, detail=extract_yt_dlp_error(result.stderr or result.stdout))
    return json.loads(result.stdout)


# API Endpoints
@app.get("/api/health")
async def health():
    """Liveness + capability info (used by the Docker healthcheck and the web UI)."""
    return {
        "status": "ok",
        "yt_dlp_version": _server_info["yt_dlp_version"],
        "js_runtime": bool(shutil.which("deno") or shutil.which("node")),
        "cookies_loaded": find_cookies_file() is not None,
        "premium_enabled": bool(PREMIUM_PASSWORD),
        "max_download_gb": MAX_DOWNLOAD_GB,
        "active_downloads": len(downloads),
    }

@app.post("/api/info")
async def fetch_formats(req: URLRequest, _rl: None = rate_limit("info", RATE_LIMIT_INFO)):
    url = validate_url(req.url)

    try:
        info = await asyncio.to_thread(run_info_extraction, url)
        
        # Check if it's a playlist
        if info.get('_type') == 'playlist':
            entries = []
            for idx, entry in enumerate(info.get('entries') or []):
                if entry:
                    entry_url = _entry_url(entry)
                    if not entry_url:
                        continue
                    entries.append({
                        "index": idx + 1,
                        "url": entry_url,
                        "title": entry.get('title') or f"Video {idx + 1}",
                        "duration": entry.get('duration'),
                        "thumbnail": _entry_thumbnail(entry),
                    })
            return {
                "is_playlist": True,
                "title": info.get('title') or 'Playlist',
                "uploader": info.get('uploader') or info.get('channel'),
                "extractor": info.get('extractor_key') or info.get('extractor'),
                "entries": entries,
                "formats": PLAYLIST_FORMATS
            }
        
        # It's a single video
        return {
            "is_playlist": False,
            "title": info.get('title') or 'video',
            "thumbnail": info.get('thumbnail') or _entry_thumbnail(info),
            "duration": info.get('duration'),
            "uploader": info.get('uploader') or info.get('channel'),
            "view_count": info.get('view_count'),
            "extractor": info.get('extractor_key') or info.get('extractor'),
            "formats": build_video_formats(info)
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/process")
async def process_video(req: ProcessRequest, request: Request, background_tasks: BackgroundTasks,
                        x_client_id: str = Header(default="anonymous"),
                        _rl: None = rate_limit("process", RATE_LIMIT_PROCESS)):
    url = validate_url(req.url, resolve_dns=True)
    format_id = validate_format_id(req.format_id)
    ip = client_ip(request)
    check_active_limit(ip)
    check_disk_space()
    
    task_id = str(uuid.uuid4())
    output_path = os.path.join(TEMP_STORAGE_DIR, f"{task_id}.%(ext)s")
    
    # Save to history (persisted)
    register_task(task_id, ip, x_client_id[:64], kind="video", title=req.title[:500],
                  thumbnail=req.thumbnail[:2048], format_id=format_id[:200], url=url)
    
    # Spawn background task
    background_tasks.add_task(run_queued, task_id, download_video_sync, url, format_id, output_path)
    
    return {"task_id": task_id}

def download_playlist_sync(task_id: str, url: str, format_id: str, output_zip_path: str,
                           items: Optional[List[dict]] = None):
    task_dir = os.path.join(TEMP_STORAGE_DIR, task_id)
    os.makedirs(task_dir, exist_ok=True)

    try:
        if items:
            # The user picked specific videos from the playlist
            entries = items
        else:
            set_progress(task_id, "Fetching playlist details...")
            playlist_info = run_info_extraction(url)
            # extract_flat sometimes returns 'entries' as an iterator, make sure to convert it
            entries = []
            for idx, entry in enumerate(list(playlist_info.get('entries') or [])):
                if entry and _entry_url(entry):
                    entries.append({"url": _entry_url(entry), "title": entry.get('title'), "index": idx + 1})

        if not entries:
            raise Exception("No videos found in playlist")
        if len(entries) > MAX_PLAYLIST_ITEMS:
            raise Exception(f"Playlist has too many videos ({len(entries)}). Maximum allowed is {MAX_PLAYLIST_ITEMS}.")

        total = len(entries)
        failed_titles = []
        media_count = 0
        pad = max(2, len(str(max((e.get('index') or 0) for e in entries) or total)))

        # Iterate over entries
        for position, entry in enumerate(entries):
            if task_id in cancel_flags:
                raise Exception("Download cancelled by user")

            if shutil.disk_usage(TEMP_STORAGE_DIR).free < 2 * 1024 * 1024 * 1024:
                raise Exception("Server ran out of free disk space.")

            video_url = entry.get('url')
            if not video_url:
                continue
            video_url = validate_url(video_url, resolve_dns=True)

            video_title = entry.get('title') or f"Video {position + 1}"
            number = entry.get('index') or (position + 1)

            args = ['--newline', '--no-colors', '--no-playlist', '--limit-rate', '50M',
                    '--max-filesize', f'{MAX_DOWNLOAD_GB}G']
            # Number files so they stay in playlist order. `.150B` truncates long titles by bytes,
            # which prevents "File name too long" errors for Japanese/Bengali titles.
            args += ['-o', os.path.join(task_dir, f'{str(number).zfill(pad)} - %(title).150B.%(ext)s')]
            args += build_format_args(format_id)
            args.extend(['--', video_url])

            try:
                # Run yt-dlp via subprocess to absolutely guarantee NO memory leaks 
                # (yt-dlp Python API retains extractor caches in memory)
                with yt_dlp_command(*args) as cmd, \
                     subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                      encoding='utf-8', errors='replace', env=yt_dlp_env(),
                                      start_new_session=True) as process:
                    for line in process.stdout:
                        if task_id in cancel_flags:
                            _terminate_process(process)
                            raise Exception("Download cancelled by user")
                            
                        match = PROGRESS_REGEX.search(line)
                        if match:
                            pct = float(match.group(1))
                            set_progress(task_id, f"[Video {position + 1}/{total}] {video_title} - {pct:.1f}%",
                                         round(((position + pct / 100) / total) * 100, 1))
                        elif line.startswith(POSTPROCESS_MARKERS):
                            set_progress(task_id, f"[Video {position + 1}/{total}] {video_title} - processing...")
                    
                    process.wait()
                    
                if process.returncode != 0 and task_id not in cancel_flags:
                    print(f"Failed to download {video_title}, return code {process.returncode}")
                    failed_titles.append(video_title)
                else:
                    # Pack each video into the ZIP immediately and delete the source file
                    # right away so peak disk usage stays 1x instead of 2x.
                    # ZIP_STORED: video/audio is already compressed, deflating only burns CPU for ~0% gain.
                    with zipfile.ZipFile(output_zip_path, 'a', zipfile.ZIP_STORED, allowZip64=True) as zipf:
                        for root, _, files in os.walk(task_dir):
                            for file in sorted(files):
                                file_path = os.path.join(root, file)
                                if file.endswith(('.part', '.ytdl', '.temp')) or '.part-' in file:
                                    _remove_path(file_path)
                                    continue
                                current_zip_size = os.path.getsize(output_zip_path) if os.path.exists(output_zip_path) else 0
                                if current_zip_size + os.path.getsize(file_path) > MAX_DOWNLOAD_BYTES:
                                    _remove_path(file_path)
                                    raise Exception(f"Playlist exceeded the maximum allowed size of {MAX_DOWNLOAD_GB} GB.")
                                zipf.write(file_path, arcname=file)
                                media_count += 1
                                drop_os_cache(file_path)
                                _remove_path(file_path)

                    drop_os_cache(output_zip_path)
                    if os.path.exists(output_zip_path) and os.path.getsize(output_zip_path) > MAX_DOWNLOAD_BYTES:
                        raise Exception(f"Playlist exceeded the maximum allowed size of {MAX_DOWNLOAD_GB} GB.")

            except HTTPException as e:
                print(f"Blocked URL during playlist {video_title}: {e.detail}")
                failed_titles.append(video_title)
                continue
            except Exception as e:
                if task_id in cancel_flags or "maximum allowed size" in str(e) or "free disk space" in str(e):
                    raise
                # If a single video fails (e.g. unavailable), log it and continue
                print(f"Exception during {video_title}: {e}")
                failed_titles.append(video_title)
                continue
            finally:
                # Clean out any partial files before the next video starts
                for root, _, files in os.walk(task_dir):
                    for file in files:
                        _remove_path(os.path.join(root, file))

        if media_count > 0:
            if failed_titles:
                # Leave a note inside the zip so the user knows what was skipped
                skipped_path = os.path.join(task_dir, "_skipped_videos.txt")
                with open(skipped_path, "w", encoding="utf-8") as fh:
                    fh.write("These videos could not be downloaded (private, removed or region-locked):\n\n")
                    fh.write("\n".join(failed_titles))
                with zipfile.ZipFile(output_zip_path, 'a', zipfile.ZIP_STORED, allowZip64=True) as zipf:
                    zipf.write(skipped_path, arcname="_skipped_videos.txt")
                _remove_path(skipped_path)
                drop_os_cache(output_zip_path)

            note = f"Done. {len(failed_titles)} of {total} video(s) could not be downloaded." if failed_titles else None
            finish_task(task_id, "completed", filepath=output_zip_path, note=note)
        else:
            raise Exception("None of the selected videos could be downloaded.")

    except Exception as e:
        err_msg = str(e)
        if task_id in cancel_flags:
            err_msg = "Download cancelled by user"
        fail_task(task_id, err_msg)
        if os.path.exists(output_zip_path):
            _remove_path(output_zip_path)
    finally:
        if os.path.exists(task_dir):
            shutil.rmtree(task_dir, ignore_errors=True)

@app.post("/api/process_playlist")
async def process_playlist(req: ProcessPlaylistRequest, request: Request, background_tasks: BackgroundTasks,
                           x_client_id: str = Header(default="anonymous"),
                           _rl: None = rate_limit("playlist", RATE_LIMIT_PLAYLIST)):
    if not PREMIUM_PASSWORD:
        raise HTTPException(status_code=503, detail="Playlist downloads are not enabled on this server.")

    ip = client_ip(request)
    fail_key = f"pwfail:{ip}"
    fail_limit, fail_window = RATE_LIMIT_PASSWORD_FAILS
    if fail_limit > 0 and limiter.count(fail_key, fail_window) >= fail_limit:
        retry = limiter.retry_after(fail_key, fail_window)
        raise HTTPException(status_code=429, detail=f"Too many wrong passwords. Try again in {retry} seconds.",
                            headers={"Retry-After": str(retry)})
    # Constant-time comparison to avoid timing attacks
    if not hmac.compare_digest(req.password.encode("utf-8"), PREMIUM_PASSWORD.encode("utf-8")):
        limiter.add(fail_key)
        raise HTTPException(status_code=401, detail="Invalid premium password")

    url = validate_url(req.url, resolve_dns=True)
    format_id = validate_format_id(req.format_id)
    if req.items and len(req.items) > MAX_PLAYLIST_ITEMS:
        raise HTTPException(status_code=400, detail=f"Too many videos selected (maximum {MAX_PLAYLIST_ITEMS}).")

    items = []
    for raw_item in (req.items or []):
        item_dict = raw_item.model_dump() if hasattr(raw_item, "model_dump") else raw_item.dict()
        if item_dict.get("url"):
            item_dict["url"] = validate_url(item_dict["url"], resolve_dns=False)
            items.append(item_dict)

    check_active_limit(ip)
    check_disk_space()
        
    task_id = str(uuid.uuid4())
    output_zip_path = os.path.join(TEMP_STORAGE_DIR, f"{task_id}.zip")

    display_title = req.title[:500]
    if items:
        display_title = f"{display_title} ({len(items)} selected)"
    
    register_task(task_id, ip, x_client_id[:64], kind="playlist", title=display_title,
                  thumbnail="", format_id=format_id[:200], url=url, media_type="application/zip")
    
    background_tasks.add_task(run_queued, task_id, download_playlist_sync, url, format_id, output_zip_path, items)
    
    return {"task_id": task_id}

@app.get("/api/recent")
async def get_recent(x_client_id: str = Header(default="anonymous")):
    recent = await asyncio.to_thread(store.recent_for_client, x_client_id[:64], 50, HISTORY_TTL_SECONDS)
    return {"recent": recent}

async def _clear_recent_impl(x_client_id: str):
    removed = await asyncio.to_thread(store.clear_client_history, x_client_id[:64])
    for row in removed:
        pending = _pending_deletions.pop(row["task_id"], None)
        if pending and not pending.done():
            pending.cancel()
        if row.get("filepath"):
            await asyncio.to_thread(_remove_path, row["filepath"])
    return {"cleared": len(removed)}

@app.post("/api/recent/clear")
async def clear_recent_post(x_client_id: str = Header(default="anonymous")):
    return await _clear_recent_impl(x_client_id)

@app.delete("/api/recent")
async def clear_recent_delete(x_client_id: str = Header(default="anonymous")):
    return await _clear_recent_impl(x_client_id)

@app.get("/api/status/{task_id}")
async def get_status(task_id: str):
    task = task_view(task_id)
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    
    return {
        "task_id": task_id,
        "status": task["status"],
        "error": task["error"],
        "progress": task["progress"],
        "percent": task["percent"],
    }

@app.post("/api/cancel/{task_id}")
async def cancel_download(task_id: str, x_client_id: str = Header(default="anonymous")):
    task = store.get_task(task_id)
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    if (
        task.get("client_id") not in (None, "", "anonymous")
        and x_client_id != "anonymous"
        and task["client_id"] != x_client_id[:64]
    ):
        raise HTTPException(status_code=403, detail="Not authorized to cancel this download.")
    
    if task["status"] == "processing" and task_id in downloads:
        cancel_flags.add(task_id)
        return {"status": "cancelling"}
    else:
        return {"status": "already_finished"}

def _delete_file_now(filepath: str, task_id: str):
    expire_task(task_id, filepath)
    print(f"Deleted served file: {filepath}")

async def _delayed_delete(filepath: str, task_id: str, delay: float = SERVE_GRACE_SECONDS):
    try:
        await asyncio.sleep(delay)
        await asyncio.to_thread(_delete_file_now, filepath, task_id)
    finally:
        _pending_deletions.pop(task_id, None)

async def schedule_file_deletion(filepath: str, task_id: str):
    """
    Callback run after the file has finished streaming. Keeps the file for SERVE_GRACE_SECONDS
    so mobile browsers or retries can resume/re-download. The served timestamp is persisted
    after streaming ends so the grace timer doesn't expire during long transfers.
    """
    if task_id in _pending_deletions:
        return
    if SERVE_GRACE_SECONDS <= 0:
        _delete_file_now(filepath, task_id)
        return
    store.update_task(task_id, served_at=time.time())
    _pending_deletions[task_id] = asyncio.create_task(_delayed_delete(filepath, task_id))


def _parse_byte_range(range_header: str, file_size: int):
    match = re.fullmatch(r'bytes=(\d*)-(\d*)', (range_header or "").strip())
    if not match or file_size <= 0:
        raise HTTPException(
            status_code=416,
            detail="Requested range not satisfiable",
            headers={"Content-Range": f"bytes */{file_size}"},
        )
    start_str, end_str = match.groups()
    if start_str == "" and end_str == "":
        raise HTTPException(
            status_code=416,
            detail="Requested range not satisfiable",
            headers={"Content-Range": f"bytes */{file_size}"},
        )
    if start_str == "":
        suffix = int(end_str)
        if suffix <= 0:
            raise HTTPException(
                status_code=416,
                detail="Requested range not satisfiable",
                headers={"Content-Range": f"bytes */{file_size}"},
            )
        start = max(0, file_size - suffix)
        end = file_size - 1
    else:
        start = int(start_str)
        if start >= file_size:
            raise HTTPException(
                status_code=416,
                detail="Requested range not satisfiable",
                headers={"Content-Range": f"bytes */{file_size}"},
            )
        end = int(end_str) if end_str else file_size - 1
        if end < start:
            raise HTTPException(
                status_code=416,
                detail="Requested range not satisfiable",
                headers={"Content-Range": f"bytes */{file_size}"},
            )
        end = min(end, file_size - 1)
    return start, end


@app.get("/api/download/{task_id}")
async def download_file(task_id: str, request: Request, background_tasks: BackgroundTasks, title: str = None):
    task = store.get_task(task_id)
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    if task["status"] == "expired":
        raise HTTPException(status_code=410, detail="This file has expired. Please download it again.")
    if task["status"] != "completed":
        raise HTTPException(status_code=400, detail="Download not completed yet")
    
    filepath = task["filepath"]
    if not filepath or not os.path.exists(filepath):
        store.update_task(task_id, status="expired")
        raise HTTPException(status_code=410, detail="This file has expired. Please download it again.")

    # Cancel any pending deletion timer while a new transfer/resume is running;
    # schedule_file_deletion will re-arm it once streaming finishes.
    pending = _pending_deletions.pop(task_id, None)
    if pending and not pending.done():
        pending.cancel()

    # Use the real extension of the produced file (mp4, mp3, wav, flac, zip ...)
    ext = os.path.splitext(filepath)[1] or ".mp4"
    media_type = task.get("media_type") or mimetypes.guess_type(f"file{ext}")[0] or "application/octet-stream"
    # Keep non-English characters (Japanese, Bengali, ...) in the file name
    filename = f"{sanitize_filename(task.get('title') or title or 'video')}{ext}"

    file_size = os.path.getsize(filepath)
    range_header = request.headers.get("range")
    if range_header:
        start, end = _parse_byte_range(range_header, file_size)
        status_code = 206
    else:
        start = 0
        end = max(0, file_size - 1)
        status_code = 200

    content_length = (end - start + 1) if file_size > 0 else 0
    headers = {
        # RFC 5987 encoding: plain `filename="日本語.mp4"` crashes because HTTP headers must be latin-1
        "Content-Disposition": content_disposition(filename),
        "Content-Length": str(content_length),
        "Accept-Ranges": "bytes",
        "Cache-Control": "no-store",
        "X-Accel-Buffering": "no",
    }
    if status_code == 206:
        headers["Content-Range"] = f"bytes {start}-{end}/{file_size}"

    background_tasks.add_task(schedule_file_deletion, filepath, task_id)

    def stream_file_and_drop_cache(path: str, offset: int, length: int, chunk_size=1024*1024):
        """Yields file chunks in [offset, offset + length) and prevents OS page cache bloat."""
        try:
            with open(path, "rb") as f:
                if offset > 0:
                    f.seek(offset)
                remaining = length
                bytes_sent = 0
                while remaining > 0:
                    chunk = f.read(min(chunk_size, remaining))
                    if not chunk:
                        break
                    yield chunk
                    remaining -= len(chunk)
                    bytes_sent += len(chunk)

                    # Every ~100MB sent over the network, force the kernel to drop the file from RAM
                    if bytes_sent >= 100 * 1024 * 1024:
                        drop_os_cache(path)
                        bytes_sent = 0
        finally:
            # Final sweep to ensure the file is dropped from cache once finished or aborted
            drop_os_cache(path)

    return StreamingResponse(
        stream_file_and_drop_cache(filepath, start, content_length),
        status_code=status_code,
        media_type=media_type,
        headers=headers
    )

# Frontend Serving
@app.get("/")
async def serve_frontend(request: Request):
    return templates.TemplateResponse(request=request, name="index.html", context={"request": request})

@app.get("/privacy")
async def serve_privacy(request: Request):
    return templates.TemplateResponse(request=request, name="privacy.html", context={"request": request})

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
