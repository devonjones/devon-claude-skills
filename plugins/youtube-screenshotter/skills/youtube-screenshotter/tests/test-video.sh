#!/usr/bin/env bash
# Checks for video.py that need no network. Run: tests/test-video.sh
set -uo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

uv run -q --with 'yt-dlp[default]>=2026.10.21' python - "$SCRIPTS" "$TMP" <<'PY'
import shutil, sys
from collections import namedtuple
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import video

Usage = namedtuple("Usage", "total used free")
video.shutil.disk_usage = lambda p: Usage(10 * 1024**3, 9 * 1024**3, 1 * 1024**3)


class NoNetwork:
    def __init__(self, *a, **k):
        raise AssertionError("yt-dlp was reached")


video.yt_dlp.YoutubeDL = NoNetwork
fail = 0
try:
    video.download("dQw4w9WgXcQ", Path(sys.argv[2]))
    print("FAIL low disk refuses to download (no error)"); fail = 1
except RuntimeError as e:
    ok = "1.0 GiB free" in str(e) and "need 3 GiB" in str(e)
    print("ok   low disk refuses to download before yt-dlp" if ok else f"FAIL low disk message: {e}"); fail |= not ok
except AssertionError:
    print("FAIL low disk refuses to download (yt-dlp was reached)"); fail = 1

try:
    (Path(sys.argv[2]) / "dQw4w9WgXcQ.mp4").write_bytes(b"cached")
    video.download("https://youtu.be/dQw4w9WgXcQ", Path(sys.argv[2]))
    print("FAIL low disk still reuses a cached video (no yt-dlp call)"); fail = 1
except AssertionError:
    print("ok   low disk still reuses a cached video")
except RuntimeError as e:
    print(f"FAIL low disk still reuses a cached video: {e}"); fail = 1
(Path(sys.argv[2]) / "dQw4w9WgXcQ.mp4").unlink()

video.shutil.disk_usage = lambda p: Usage(10 * 1024**3, 1 * 1024**3, 9 * 1024**3)
try:
    video.download("dQw4w9WgXcQ", Path(sys.argv[2]))
    print("FAIL ample disk downloads (no yt-dlp call)"); fail = 1
except AssertionError:
    print("ok   ample disk downloads")
except RuntimeError as e:
    print(f"FAIL ample disk downloads: {e}"); fail = 1

video.shutil.disk_usage = lambda p: Usage(10 * 1024**3, 9 * 1024**3, 1 * 1024**3)
try:
    video.download("dQw4w9WgXcQ", Path(sys.argv[2]), skip_download=True)
    print("FAIL metadata-only probe skips the disk check (no yt-dlp call)"); fail = 1
except AssertionError:
    print("ok   metadata-only probe skips the disk check")
except RuntimeError as e:
    print(f"FAIL metadata-only probe skips the disk check: {e}"); fail = 1
sys.exit(fail)
PY
