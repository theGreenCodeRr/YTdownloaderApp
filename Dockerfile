FROM python:3.11-slim

WORKDIR /app

# Install ffmpeg which is required for yt-dlp to merge formats
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# yt-dlp needs a JavaScript runtime (Deno) to solve YouTube's player challenges.
# Without it many YouTube formats are missing or downloads fail.
COPY --from=denoland/deno:bin /deno /usr/local/bin/deno

# Make sure Unicode (Japanese, Bengali, ...) titles/filenames are handled as UTF-8
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONIOENCODING=utf-8 \
    PYTHONUNBUFFERED=1 \
    DB_PATH=/app/data/ytdown.db

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Mount points: SQLite database and (optional, read-only) cookies
RUN mkdir -p /app/data /app/secrets

EXPOSE 8000

# Marks the container "unhealthy" in `docker ps` if the app stops responding
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/api/health', timeout=4).status == 200 else 1)" || exit 1

# --proxy-headers: trust X-Forwarded-For from the IPs in $FORWARDED_ALLOW_IPS (set in docker-compose.yml)
# so rate limiting sees each visitor's real IP when running behind a reverse proxy.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers"]
