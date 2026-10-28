#!/usr/bin/env bash
# Checks for discover.py that need no network. Run: tests/test-discover.sh
set -uo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

uv run -q --with 'yt-dlp[default]>=2026.10.21' --with 'imagehash>=4.3' --with 'Pillow>=10' python - "$SCRIPTS" <<'PY' || fail=1
import sys
sys.path.insert(0, sys.argv[1])
from discover import looks_like_path
cases = {
    "/abs/v.mp4": True, "./v.mp4": True, "../v": True, "~/v": True, "v.MKV": True, "out/v.webm": True,
    "https://www.youtube.com/watch?v=dQw4w9WgXcQ": False, "youtu.be/dQw4w9WgXcQ": False,
    "www.youtube.com/watch?v=dQw4w9WgXcQ": False, "dQw4w9WgXcQ": False,
}
bad = {t: want for t, want in cases.items() if looks_like_path(t) != want}
print("ok   looks_like_path" if not bad else f"FAIL looks_like_path: {bad}")
sys.exit(1 if bad else 0)
PY

out=$("$SCRIPTS/discover.py" "$TMP/missing.mp4" -o "$TMP/w" 2>&1); rc=$?
check "missing file exits 1" '[[ $rc -eq 1 ]]'
check "missing file names the file" '[[ $out == *"no such video file"* ]]'

echo junk > "$TMP/bad.mp4"
out=$("$SCRIPTS/discover.py" "$TMP/bad.mp4" -o "$TMP/w" 2>&1); rc=$?
check "junk video exits 1" '[[ $rc -eq 1 ]]'
check "junk video shows ffmpeg's reason" '[[ $out == *"Invalid data"* ]]'

exit $fail
