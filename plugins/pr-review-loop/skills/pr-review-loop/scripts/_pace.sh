#!/usr/bin/env bash
# Shared pacer for GitHub content-creation calls.
#
# Secondary rate limits are a VELOCITY response, not a volume one. Measured on
# two repos the same evening: 40 comments inside one minute tripped a 403 and
# blocked the whole account, while 23 comments at 4-second spacing posted
# cleanly. Same volume, different shape, opposite outcome.
#
# A sleep inside each caller does not fix it, because reviewers post in
# parallel: ten processes each pausing a second still burst at ten a second.
# The pacer therefore has to be GLOBAL, so this serialises on one lock and
# spaces by wall clock across every concurrent caller.
#
# Usage:  pace_github            # blocks until it is this caller's turn
#         PR_REVIEW_LOOP_PACE_S=2 pace_github
#
# Set PR_REVIEW_LOOP_PACE_S=0 to disable (a single sequential caller posting a
# handful of comments does not need it).

: "${PR_REVIEW_LOOP_PACE_S:=1}"
_PACE_DIR="${TMPDIR:-/tmp}/pr-review-loop-pace"
_PACE_STAMP="$_PACE_DIR/last-post"
_PACE_LOCK="$_PACE_DIR/lock"

pace_github() {
    [[ "$PR_REVIEW_LOOP_PACE_S" == "0" ]] && return 0
    mkdir -p "$_PACE_DIR" 2>/dev/null || return 0   # never block a post on the pacer
    command -v flock >/dev/null 2>&1 || { sleep "$PR_REVIEW_LOOP_PACE_S"; return 0; }

    exec 9>"$_PACE_LOCK" || { sleep "$PR_REVIEW_LOOP_PACE_S"; return 0; }
    flock 9 || { sleep "$PR_REVIEW_LOOP_PACE_S"; return 0; }

    local now last wait
    now=$(date +%s.%N)
    last=$(cat "$_PACE_STAMP" 2>/dev/null || echo 0)
    wait=$(awk -v n="$now" -v l="$last" -v p="$PR_REVIEW_LOOP_PACE_S" \
        'BEGIN { w = p - (n - l); print (w > 0) ? w : 0 }')
    [[ "$wait" != "0" ]] && sleep "$wait"
    date +%s.%N > "$_PACE_STAMP"
    exec 9>&-
}
