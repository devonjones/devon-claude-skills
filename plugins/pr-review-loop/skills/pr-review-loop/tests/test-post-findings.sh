#!/usr/bin/env bash
# record-finding.sh + post-findings.sh against a fake `gh` that records what is sent.
#
# Usage: tests/test-post-findings.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECORD="$SCRIPT_DIR/../scripts/record-finding.sh"
POST="$SCRIPT_DIR/../scripts/post-findings.sh"
T="$(mktemp -d)"; trap 'rm -rf -- "$T"' EXIT
PASSED=0; FAILED=0
ok(){ PASSED=$((PASSED+1)); echo "  PASS: $1"; }
bad(){ FAILED=$((FAILED+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  "repo view"*) echo "o/r" ;;
  "pr view"*)   echo "abc123" ;;
  *"--method POST"*/reviews*)
      cat > "$T/review.json"
      [[ -n "${FAKE_REVIEW_FAIL:-}" ]] && { echo '{"message":"Unprocessable Entity"}'; exit 1; }
      echo '{"id":7}' ;;
  *"--method POST"*/comments*)
      body=$(cat); jq -c . <<< "$body" >> "$T/comments.jsonl"
      [[ -n "${FAKE_FAIL_PATH:-}" && "$(jq -r .path <<< "$body")" == "$FAKE_FAIL_PATH" ]] && { echo '{"message":"line not in diff"}'; exit 1; }
      echo '{"id":9}' ;;
  *reviews/7/comments*) echo "101 a.py:10 header" ;;
  *) echo '{}' ;;
esac
GH
chmod +x "$T/bin/gh"

repo(){ rm -rf "$T/r" "$T"/review.json "$T"/comments.jsonl; git init -q "$T/r"; }
rec(){ (cd "$T/r" && bash "$RECORD" "$@" >/dev/null); }
seed(){
  rec 42 a.py 10 error-handling-reviewer P2 "swallows the exit code"
  rec 42 a.py 10 concurrency-reviewer P1 "races the writer"
  rec 42 b.py 5 test-coverage-reviewer P1 "no test pins this"
  rec 42 c.py 1 clarity-reviewer P3 "comment narrates history; delete it"
  rec 42 d.py 2 dead-code-reviewer P3 "unused import"
}
run(){ set +e; OUT=$(cd "$T/r" && PATH="$T/bin:$PATH" T="$T" PR_REVIEW_LOOP_PACE_S=0 \
        PR_REVIEW_LOOP_PACE_DIR="$T/pace" bash "$POST" "$@" 2>&1); RC=$?; set -e; }

echo "=== bad severity is refused ==="
repo; set +e; (cd "$T/r" && bash "$RECORD" 42 a.py 1 x HIGH "y" >/dev/null 2>&1); rc=$?; set -e
check "non-P severity exits non-zero" '[[ $rc -ne 0 ]]'

echo "=== local mode merges and posts nothing ==="
repo; seed; run 42 --local
check "5 findings collapse to 3 threads" '[[ "$OUT" == *"5 finding(s) in 3 thread(s)"* ]]'
check "same-line findings share a thread, P1 first" \
  '[[ "$(grep -A3 "=== a.py:10 ===" <<< "$OUT" | sed -n 2p)" == *"concurrency-reviewer"*"P1"* ]]'
check "signatures are stripped from the local report" '[[ "$OUT" != *"<!-- Agent:"* ]]'
check "no GitHub write" '[[ ! -e "$T/review.json" && ! -e "$T/comments.jsonl" ]]'
run 42 --check; check "store consumed" '[[ $RC -eq 0 ]]'

echo "=== one review carries every thread ==="
repo; seed; run 42 --check; check "--check fails while findings are unposted" '[[ $RC -eq 1 ]]'
run 42
check "posts exit 0" '[[ $RC -eq 0 ]]'
check "one review with 3 comments" '[[ "$(jq ".comments | length" "$T/review.json")" == 3 ]]'
check "merged thread is signed by both flaggers" \
  '[[ "$(jq -r ".comments[] | select(.path==\"a.py\") | .body" "$T/review.json" | grep -c "<!-- Agent: ")" == 2 ]]'
check "merged thread starts with the skill header (F4 gate)" \
  '[[ "$(jq -r ".comments[0].body" "$T/review.json")" == "🤖 **Claude Code** ("* ]]'
check "P3 roll-up names both P3 flaggers" \
  '[[ "$(jq -r ".comments[] | select(.body | contains(\"P3 roll-up\")) | .body" "$T/review.json" | grep -c "<!-- Agent: ")" == 2 ]]'
check "review is pinned to the PR head" '[[ "$(jq -r .commit_id "$T/review.json")" == abc123 ]]'
check "no per-comment POSTs when the review lands" '[[ ! -e "$T/comments.jsonl" ]]'
run 42 --check; check "store consumed after posting" '[[ $RC -eq 0 ]]'

echo "=== a rejected review falls back, and failures stay recorded ==="
repo; seed; FAKE_REVIEW_FAIL=1 FAKE_FAIL_PATH=b.py run 42
check "exits non-zero when a thread fails" '[[ $RC -ne 0 ]]'
check "every thread was attempted on its own" '[[ "$(wc -l < "$T/comments.jsonl")" == 3 ]]'
run 42 --check; check "--check still fails" '[[ $RC -eq 1 ]]'
check "only the failed finding is back in the store" \
  '[[ "$(cat "$T/r/.git/pr-review-loop/findings-42.jsonl" | jq -r .file)" == b.py ]]'

echo ""; echo "Passed: $PASSED  Failed: $FAILED"; [[ "$FAILED" -eq 0 ]]
