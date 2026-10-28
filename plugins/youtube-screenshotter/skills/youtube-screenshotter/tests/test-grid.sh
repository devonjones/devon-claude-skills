#!/usr/bin/env bash
# Checks for grid.py that need no network. Run: tests/test-grid.sh
set -uo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

mkdir -p "$TMP/frames"
ffmpeg -loglevel error -f lavfi -i testsrc=size=1280x720:rate=1 -frames:v 11 "$TMP/frames/f%02d.png"
python3 - "$TMP" <<'PY'
import json, sys, pathlib
d = pathlib.Path(sys.argv[1])
entries = [{"timestamp": 5.0 * i + (3600 if i == 10 else 0), "frame_path": str(p), "phash": "0"}
           for i, p in enumerate(sorted((d / "frames").glob("f*.png")))]
(d / "m.json").write_text(json.dumps({"entries": entries}))
PY

out=$("$SCRIPTS/grid.py" "$TMP/m.json" -o "$TMP/sheets" 2>"$TMP/err"); rc=$?
check "11 frames make two sheets" '[[ $rc -eq 0 && $(jq length <<<"$out") -eq 2 ]]'
check "sheet 1 holds 9 cells, sheet 2 holds 2" '[[ $(jq -c "[.[].cells | length]" <<<"$out") == "[9,2]" ]]'
check "labels carry index and timestamp" '[[ $(jq -r ".[0].cells[1].label, .[1].cells[1].label" <<<"$out" | tr "\n" "|") == "#2 00:05|#11 1:00:50|" ]]'

uv run -q --with 'Pillow>=10.1' python - "$TMP/sheets" <<'PY' || fail=1
import sys
from PIL import Image
d = sys.argv[1]
a, b = Image.open(f"{d}/sheet-01.jpg"), Image.open(f"{d}/sheet-02.jpg")
ok = a.size == (1920, 1080) and b.size == (1920, 360)
print("ok   sheet sizes follow the grid" if ok else f"FAIL sheet sizes {a.size} {b.size}")
# testsrc has no pure yellow in a cell's top-left corner; the label does.
px = a.convert("RGB").load()
yellow = sum(1 for x in range(200) for y in range(60)
             if px[x, y][0] > 200 and px[x, y][1] > 200 and px[x, y][2] < 80)
print("ok   labels are drawn" if yellow > 20 else f"FAIL labels are drawn ({yellow} yellow px)")
sys.exit(0 if ok and yellow > 20 else 1)
PY

uv run -q --with 'Pillow>=10.1' python - "$SCRIPTS" "$TMP" <<'PY' || fail=1
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from grid import compose_sprite_grid
from PIL import Image
d = Path(sys.argv[2])
frames = sorted((d / "frames").glob("f*.png"))[:4]
compose_sprite_grid(frames, d / "sprite", cols=2, max_width=640)  # motion.py's unlabeled call
img = Image.open(d / "sprite")
ok = img.format == "PNG" and img.size == (640, 360)
print("ok   unlabeled grid to a suffix-less path is a PNG" if ok else f"FAIL unlabeled grid {img.format} {img.size}")
sys.exit(0 if ok else 1)
PY

out=$("$SCRIPTS/grid.py" "$TMP/missing.json" -o "$TMP/x" 2>&1); rc=$?
check "missing manifest is an error" '[[ $rc -eq 1 && $out == error:* ]]'
echo '{"entries": []}' > "$TMP/empty.json"
out=$("$SCRIPTS/grid.py" "$TMP/empty.json" -o "$TMP/x" 2>&1); rc=$?
check "empty manifest is an error" '[[ $rc -eq 1 && $out == *"no entries"* ]]'
echo '{"frames": []}' > "$TMP/wrong.json"
out=$("$SCRIPTS/grid.py" "$TMP/wrong.json" -o "$TMP/x" 2>&1); rc=$?
check "manifest without entries key is an error" '[[ $rc -eq 1 && $out == *"no entries"* ]]'
echo '[1, 2]' > "$TMP/list.json"
out=$("$SCRIPTS/grid.py" "$TMP/list.json" -o "$TMP/x" 2>&1); rc=$?
check "list-shaped manifest is an error" '[[ $rc -eq 1 && $out == *"no entries"* ]]'
out=$("$SCRIPTS/grid.py" "$TMP/m.json" -o "$TMP/x" --cols 0 2>&1); rc=$?
check "zero --cols is a usage error" '[[ $rc -eq 2 && $out == *"--cols"* ]]'
echo '{"entries": [{"timestamp": 1, "frame_path": "/nonexistent.png"}]}' > "$TMP/gone.json"
out=$("$SCRIPTS/grid.py" "$TMP/gone.json" -o "$TMP/x" 2>&1); rc=$?
check "missing frame file is an error" '[[ $rc -eq 1 && $out == error:*"nonexistent.png"* ]]'

exit $fail
