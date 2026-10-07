#!/usr/bin/env bash
# _pace.sh — GitHub secondary rate limits are a VELOCITY response.
#
# Measured the evening this was written: 40 review comments inside one minute
# tripped a 403 that blocked content creation account-wide, while 23 comments at
# 4-second spacing posted cleanly. Same volume, opposite outcome.
#
# The pacer must bound the rate GLOBALLY, because reviewers post in parallel:
# ten processes each sleeping a second still burst at ten a second. So every
# test here uses CONCURRENT callers — a sequential test would pass against a
# per-process sleep that does not fix the measured cause.
#
# Usage: tests/test-pace.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACE="$SCRIPT_DIR/../scripts/_pace.sh"

PASSED=0
FAILED=0
ok(){ PASSED=$((PASSED+1)); echo "  PASS: $1"; }
bad(){ FAILED=$((FAILED+1)); echo "  FAIL: $1"; }

# Fire N callers in parallel; print the span between first and last in seconds.
span() {
    local interval="$1" n="$2" out
    out=$(mktemp)
    (
        export PR_REVIEW_LOOP_PACE_S="$interval"
        export PR_REVIEW_LOOP_PACE_DIR="$(mktemp -d)"   # isolated pacer per measurement
        # shellcheck source=../scripts/_pace.sh
        source "$PACE"
        for _ in $(seq "$n"); do ( pace_github; date +%s.%N ) & done
        wait
    ) > "$out" 2>/dev/null
    sort -n "$out" | awk 'NR==1{f=$1} END{printf "%.1f", $1-f}'
    rm -f "$out"
}

echo "=== disabled: concurrent callers must not be spaced ==="
s=$(span 0 5)
if awk -v s="$s" 'BEGIN{exit !(s < 0.5)}'; then
    ok "PACE_S=0 leaves 5 concurrent callers unspaced (span ${s}s)"
else
    bad "PACE_S=0 spaced them anyway (span ${s}s) — pacer runs when disabled"
fi

echo "=== enabled: the interval is enforced across PROCESSES, not within one ==="
s=$(span 1 4)
if awk -v s="$s" 'BEGIN{exit !(s >= 2.5)}'; then
    ok "PACE_S=1 spaces 4 concurrent callers over ${s}s"
else
    bad "PACE_S=1 did not serialise concurrent callers (span ${s}s)"
fi

echo "=== the interval is the knob ==="
s=$(span 2 3)
if awk -v s="$s" 'BEGIN{exit !(s >= 3.5)}'; then
    ok "PACE_S=2 spaces 3 concurrent callers over ${s}s"
else
    bad "PACE_S=2 ignored the interval (span ${s}s)"
fi

echo "=== a broken pacer must never block a post ==="
out=$(
    export PR_REVIEW_LOOP_PACE_S=1
    export PR_REVIEW_LOOP_PACE_DIR=/proc/nonexistent-cannot-mkdir
    source "$PACE"
    pace_github && echo reached
)
[[ "$out" == "reached" ]] && ok "unwritable pacer state returns 0 rather than aborting the caller" \
                          || bad "pacer failure blocked the caller"

echo "=== the lock is machine-wide, not per-TMPDIR ==="
dir="$( unset PR_REVIEW_LOOP_PACE_DIR; TMPDIR=/tmp/private-session-x; source "$PACE"; echo "$_PACE_DIR" )"
[[ "$dir" != /tmp/private-session-x* ]] && ok "a private TMPDIR does not split the pacer ($dir)" \
                                       || bad "pacer follows TMPDIR, so a session with its own TMPDIR paces alone"

echo "=== the default is the spacing measured clean ==="
d="$( unset PR_REVIEW_LOOP_PACE_S; source "$PACE"; echo "$PR_REVIEW_LOOP_PACE_S" )"
[[ "$d" == "4" ]] && ok "default interval is 4s" || bad "default interval is ${d}s"

echo "=== each content-creating script paces immediately BEFORE its gh command ==="
# Presence is not enough: a pace call inserted inside a backslash-continued
# command becomes an argument to gh and drops the body. Check position.
for f in post-line-comment.sh reply-to-comment.sh; do
    s="$SCRIPT_DIR/../scripts/$f"
    n="$(grep -n '^pace_github$' "$s" | cut -d: -f1)"
    if [[ -z "$n" || "$(grep -c '^pace_github$' "$s")" -ne 1 ]]; then bad "$f: expected exactly one pace_github line"; continue; fi
    prev="$(sed -n "$((n-1))p" "$s")"; next="$(sed -n "$((n+1))p" "$s")"
    if [[ "$prev" == *\\ ]]; then bad "$f: pace_github is inside a continued command (previous line ends in \\)"
    elif [[ "$next" != *'=$(gh api'* ]]; then bad "$f: line after pace_github is not the gh command: $next"
    else ok "$f paces on the line before its gh command"; fi
done

echo ""
echo "Passed: $PASSED  Failed: $FAILED"
[[ "$FAILED" -eq 0 ]]
