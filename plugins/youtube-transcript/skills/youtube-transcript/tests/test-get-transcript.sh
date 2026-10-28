#!/usr/bin/env bash
# Checks the import guard in get_transcript.py. Run: tests/test-get-transcript.sh
set -uo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/get_transcript.py"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

out=$(python3 -I "$SCRIPT" x 2>&1); rc=$?
check "missing package exits 1" '[[ $rc -eq 1 ]]'
check "missing package says how to run it, no traceback" '[[ $out == *"uv run --script"* && $out != *Traceback* ]]'

mkdir -p "$TMP/youtube_transcript_api"
echo "import no_such_module_xyz" > "$TMP/youtube_transcript_api/__init__.py"
out=$(PYTHONPATH="$TMP" python3 "$SCRIPT" x 2>&1)
check "a broken dependency is not reported as missing" '[[ $out == *"no_such_module_xyz"* && $out != *"uv run --script"* ]]'

exit $fail
