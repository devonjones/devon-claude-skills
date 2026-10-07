#!/usr/bin/env bash
# emit-dream-marker.sh is best-effort by contract: it must always exit 0 so it
# can never block the review loop. It must not be silent about it either, or a
# failed write is indistinguishable from a successful one.
#
# So every failure case asserts BOTH halves: exit 0, and a warning on stderr.
# And the healthy case asserts the opposite: exit 0, no warning, marker written.
#
# Usage: tests/test-emit-dream-marker.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMIT="$SCRIPT_DIR/../scripts/emit-dream-marker.sh"
T="$(mktemp -d)"; trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf -- "$T"' EXIT
PASSED=0; FAILED=0
ok(){ PASSED=$((PASSED+1)); echo "  PASS: $1"; }
bad(){ FAILED=$((FAILED+1)); echo "  FAIL: $1"; }

# run <home> [args...] -> sets RC and ERR
run(){ local home="$1"; shift
  set +e; ERR=$(DREAM_HOME="$home" bash "$EMIT" reviewer-finding "$@" 2>&1 >/dev/null); RC=$?; set -e; }

expect_loud(){ local label="$1"
  if [[ "$RC" -eq 0 && "$ERR" == *"emit-dream-marker: marker dropped"* ]]; then ok "$label: exit 0 and says why"
  else bad "$label: rc=$RC stderr='${ERR}'"; fi; }

echo "=== healthy: silent, exit 0, marker actually written ==="
run "$T/ok" pr=1 reviewer=x-reviewer
if [[ "$RC" -eq 0 && -z "$ERR" && $(wc -l < "$T/ok/markers/pr-review-loop.jsonl") -eq 1 ]]; then
  ok "healthy write is silent and lands"; else bad "healthy: rc=$RC err='$ERR'"; fi

echo "=== failures: still exit 0, but never silent ==="
mkdir -p "$T/ro" && chmod 555 "$T/ro"
run "$T/ro/sub" pr=1;                         expect_loud "unwritable dir"
mkdir -p "$T/rof/markers" && : > "$T/rof/markers/pr-review-loop.jsonl" && chmod 444 "$T/rof/markers/pr-review-loop.jsonl"
run "$T/rof" pr=1;                            expect_loud "read-only file"
if [[ -e /dev/full ]]; then
  mkdir -p "$T/full/markers" && ln -s /dev/full "$T/full/markers/pr-review-loop.jsonl"
  run "$T/full" pr=1;                         expect_loud "disk full"
fi
mkdir -p "$T/nojq"; for b in bash git date mkdir basename printf tr sed; do
  p="$(command -v "$b" || true)"; [[ -n "$p" ]] && ln -sf "$p" "$T/nojq/"; done
set +e; ERR=$(PATH="$T/nojq" DREAM_HOME="$T/nj" bash "$EMIT" reviewer-finding pr=1 2>&1 >/dev/null); RC=$?; set -e
expect_loud "jq absent"

echo "=== a failure leaks no raw shell error ==="
run "$T/rof" pr=1
[[ "$ERR" != *"Permission denied"* ]] && ok "only the script's own message, not bash's" || bad "raw shell error leaked: $ERR"

echo "=== fields ==="
run "$T/args" noeq ts=forged kind=forged pr=2
rec="$(tail -1 "$T/args/markers/pr-review-loop.jsonl")"
[[ "$ERR" == *"'noeq' has no '='"* ]] && ok "bare argument is reported, not turned into a field" || bad "bare arg: $ERR"
[[ "$ERR" == *"'ts' is set by this script"* && "$ERR" == *"'kind' is set by this script"* ]] \
  && ok "caller-supplied ts/kind are reported, not silently dropped" || bad "reserved keys dropped silently: $ERR"
[[ "$(jq -r .ts <<<"$rec")" != "forged" && "$(jq -r .kind <<<"$rec")" == "reviewer-finding" ]] \
  && ok "record keeps its own ts and kind" || bad "provenance overwritten: $rec"
[[ "$(jq -r .pr <<<"$rec")" == "2" ]] && ok "valid fields still land alongside rejected ones" || bad "pr lost: $rec"

run "$T/dup" pr=7 pr=8
[[ "$ERR" == *"'pr' given twice"* && "$(jq -r .pr "$T/dup/markers/pr-review-loop.jsonl")" == "7" ]] \
  && ok "a repeated field is reported and the first kept" || bad "repeat handled silently: $ERR"

echo "=== field names are data, never jq variables ==="
# $ENV is jq's whole environment and $__loc__ a source location; neither may
# reach the marker. A sentinel stands in for real secrets.
set +e
ERR=$(DREAM_HOME="$T/env" LEAK_SENTINEL=do-not-write-me bash "$EMIT" reviewer-finding ENV=prod __loc__=x 2>&1 >/dev/null)
set -e
rec="$(cat "$T/env/markers/pr-review-loop.jsonl")"
[[ "$rec" != *do-not-write-me* ]] && ok "environment never written to the marker" || bad "environment leaked into the marker"
[[ "$(jq -r .ENV <<<"$rec")" == "prod" && "$(jq -r .__loc__ <<<"$rec")" == "x" ]] \
  && ok "ENV and __loc__ stored as the literal values given" || bad "names evaluated as jq variables: $rec"

echo "=== slug: same from a worktree of a separate-git-dir repo (mirrors config.py) ==="
G(){ git -c user.email=t@t -c user.name=t "$@" >/dev/null 2>&1; }
( cd "$T" && G init -q --separate-git-dir="$T/store.git" sg && cd sg && G commit -q --allow-empty -m i && G worktree add -q ../sg-wt -b w )
for d in "$T/sg" "$T/sg-wt"; do ( cd "$d" && HOME="$T/h-$(basename "$d")" bash "$EMIT" k a=1 ); done
main_slug="$(ls "$T/h-sg/.dream")"; wt_slug="$(ls "$T/h-sg-wt/.dream")"
[[ -n "$main_slug" && "$main_slug" == "$wt_slug" ]] && ok "worktree slug '$wt_slug' matches main" || bad "orphan slug: main='$main_slug' worktree='$wt_slug'"

echo ""; echo "Passed: $PASSED  Failed: $FAILED"; [[ "$FAILED" -eq 0 ]]
