import yt_dlp
import os

os.makedirs("test_dl", exist_ok=True)
ydl_opts = {
    'outtmpl': 'test_dl/%(title)s.%(ext)s',
    'quiet': False,
    'yes_playlist': True,
    'lazy_playlist': True,
    'format': 'worst', # fast download
}
# Short playlist: https://www.youtube.com/playlist?list=PL4lCao7KL_QQGgE8Znt8E5-uC_mY-QZ1X (2 videos)
with yt_dlp.YoutubeDL(ydl_opts) as ydl:
    ydl.download(["https://www.youtube.com/playlist?list=PL4lCao7KL_QQGgE8Znt8E5-uC_mY-QZ1X"])

print("Downloaded files:", os.listdir("test_dl"))
