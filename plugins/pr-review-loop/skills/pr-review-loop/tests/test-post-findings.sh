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
      [[ -n "${FAKE_STDERR:-}" ]] && echo "A new release of gh is available" >&2
      echo '{"id":7}' ;;
  *"--method POST"*issues/42/comments*)
      body=$(cat); jq -c . <<< "$body" >> "$T/issues.jsonl"
      [[ -n "${FAKE_ISSUE_FAIL:-}" ]] && { echo '{"message":"Server Error"}'; exit 1; }
      jq -c '{id: 11, body}' <<< "$body" ;;
  *"--method POST"*/comments*)
      body=$(cat); jq -c . <<< "$body" >> "$T/comments.jsonl"
      path=$(jq -r .path <<< "$body"); on_line=$(jq -r 'has("line")' <<< "$body")
      [[ -n "${FAKE_FAIL_PATH:-}" && "$path" == "$FAKE_FAIL_PATH" ]] && { echo '{"message":"path not in diff"}'; echo "gh: Unprocessable Entity (HTTP 422)" >&2; exit 1; }
      [[ -n "${FAKE_FAIL_LINE_PATH:-}" && "$path" == "$FAKE_FAIL_LINE_PATH" && "$on_line" == true ]] && { echo '{"message":"line not in diff"}'; echo "gh: Unprocessable Entity (HTTP 422)" >&2; exit 1; }
      [[ -n "${FAKE_502_PATH:-}" && "$path" == "$FAKE_502_PATH" ]] && { echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; }
      jq -c '{id: 9, body}' <<< "$body" ;;
  *pulls/42/files*)
      [[ -n "${FAKE_FILES_FAIL:-}" ]] && { echo "HTTP 502" >&2; exit 1; }
      while [[ $# -gt 0 && "$1" != --jq ]]; do shift; done
      jq -r "$2" <<< '[{"filename": "a.py", "status": "modified"}, {"filename": "b.py", "status": "removed"}]' ;;
  *pulls/42/comments*--jq*)
      [[ -n "${FAKE_LIST_FAIL:-}" ]] && { echo "HTTP 502" >&2; exit 1; }
      # Run the caller's real --jq over a listing that mixes reviews and line fields.
      while [[ $# -gt 0 && "$1" != --jq ]]; do shift; done
      # What the review posted (b.py outdated, so its line is null), less any
      # comment FAKE_DROP_PATH names, plus another review's comment.
      jq -r "$2" <<< "$(jq --arg drop "${FAKE_DROP_PATH:-}" '[.comments | to_entries[]
          | select(.value.path != $drop)
          | {id: (101 + .key), pull_request_review_id: 7, path: .value.path,
             line: (if .value.path == "b.py" then null else .value.line end),
             original_line: .value.line, body: .value.body}]
          + [{id: 900, pull_request_review_id: 6, path: "z.py", line: 1, original_line: 1, body: "another review"}]' "$T/review.json")"
      ;;
  *) echo '{}' ;;
esac
GH
chmod +x "$T/bin/gh"

repo(){ rm -rf "$T/r" "$T"/review.json "$T"/comments.jsonl "$T"/issues.jsonl; git init -q "$T/r"; }
rec(){ (cd "$T/r" && bash "$RECORD" "$@" >/dev/null); }
open(){ (cd "$T/r" && bash "$POST" "$1" --open >/dev/null); }
seed(){ local pr="${1:-42}"
  [[ "$pr" == local ]] || open "$pr"
  rec $pr a.py 10 error-handling-reviewer P2 "swallows the exit code"
  rec $pr a.py 10 concurrency-reviewer P1 "races the writer"
  rec $pr b.py 5 test-coverage-reviewer P1 "no test pins this"
  rec $pr c.py 1 clarity-reviewer P3 "comment narrates history; delete it"
  rec $pr d.py 2 dead-code-reviewer P3 "unused import"
}
run(){ set +e; OUT=$(cd "$T/r" && PATH="$T/bin:$PATH" T="$T" PR_REVIEW_LOOP_PACE_S=0 \
        PR_REVIEW_LOOP_PACE_DIR="$T/pace" bash "$POST" "$@" 2>&1); RC=$?; set -e; }

echo "=== bad severity is refused ==="
repo; set +e; (cd "$T/r" && bash "$RECORD" 42 a.py 1 x HIGH "y" >/dev/null 2>&1); rc=$?; set -e
check "non-P severity exits non-zero" '[[ $rc -ne 0 ]]'

echo "=== a mistyped mode is an error, not a clean gate ==="
repo; set +e; (cd "$T/r" && PATH="$T/bin:$PATH" bash "$POST" 42 --chek >/dev/null 2>&1); rc=$?; set -e
check "unknown mode exits non-zero even with an empty store" '[[ $rc -ne 0 ]]'

echo "=== bad line and no repo are refused ==="
set +e; (cd "$T/r" && bash "$RECORD" 42 a.py abc x P1 "y" >/dev/null 2>&1); rc=$?; set -e
check "non-numeric line exits non-zero" '[[ $rc -ne 0 ]]'
mkdir -p "$T/norepo"; set +e; (cd "$T/norepo" && GIT_CEILING_DIRECTORIES="$T" bash "$RECORD" 42 a.py 1 x P1 "y" >/dev/null 2>&1); rc=$?; set -e
check "outside a git repo exits non-zero" '[[ $rc -ne 0 ]]'
check "and writes nothing" '[[ ! -e "$T/norepo/pr-review-loop" ]]'

echo "=== local mode merges and posts nothing ==="
repo; seed local; run local --local
check "5 findings collapse to 3 threads" '[[ "$OUT" == *"5 finding(s) in 3 thread(s)"* ]]'
check "same-line findings share a thread, P1 first" \
  '[[ "$(grep -A3 "=== a.py:10 ===" <<< "$OUT" | sed -n 2p)" == *"concurrency-reviewer"*"P1"* ]]'
check "signatures are stripped from the local report" '[[ "$OUT" != *"<!-- Agent:"* ]]'
check "no GitHub write" '[[ ! -e "$T/review.json" && ! -e "$T/comments.jsonl" ]]'
run local --check; check "store consumed" '[[ $RC -eq 0 ]]'

echo "=== one review carries every thread ==="
repo; seed; run 42 --check; check "--check fails while findings are unposted" '[[ $RC -eq 1 ]]'
run 42
check "posts exit 0" '[[ $RC -eq 0 ]]'
check "the manifest gives each thread its line" '[[ "$OUT" == *"101 a.py:10 🤖 **Claude Code** (concurrency-reviewer)"* ]]'
check "an outdated thread falls back to its original line" '[[ "$OUT" == *"102 b.py:5 🤖"* ]]'
check "and counts every finding as posted" '[[ "$OUT" == *"Posted 5 of 5 finding(s) in 3 thread(s)"* ]]'
check "only this review's comments are listed" '[[ "$OUT" != *"900"* ]]'
repo; seed; FAKE_LIST_FAIL=1 run 42
check "a failed listing after a successful post still exits 0" '[[ $RC -eq 0 ]]'
check "and says the review is posted but unchecked" '[[ "$OUT" == *"review 7 is posted"*"checked"* ]]'
run 42 --check; check "the posted findings stay archived" '[[ $RC -eq 0 ]]'
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

echo "=== a deleted file's thread goes on the old side ==="
check "deleted b.py is LEFT" '[[ "$(jq -r ".comments[] | select(.path==\"b.py\") | .side" "$T/review.json")" == LEFT ]]'
check "modified a.py is RIGHT" '[[ "$(jq -r ".comments[] | select(.path==\"a.py\") | .side" "$T/review.json")" == RIGHT ]]'
repo; seed; FAKE_REVIEW_FAIL=1 run 42
check "the one-at-a-time fallback keeps LEFT" '[[ "$(jq -r "select(.path==\"b.py\") | .side" "$T/comments.jsonl")" == LEFT ]]'
repo; seed; FAKE_FILES_FAIL=1 run 42
check "an unreadable file list still posts, all RIGHT" '[[ $RC -eq 0 && "$(jq -r "[.comments[].side] | unique | join(\",\")" "$T/review.json")" == RIGHT ]]'
check "and warns" '[[ "$OUT" == *"could not list the PR'"'"'s files"* ]]'

echo "=== previewing a real PR keeps its findings ==="
repo; seed; run 42 --local
run 42 --check; check "--check still fails after a preview" '[[ $RC -eq 1 ]]'

echo "=== a posted review with gh noise on stderr is still posted ==="
repo; seed; FAKE_STDERR=1 run 42
check "exits 0" '[[ $RC -eq 0 ]]'
run 42 --check; check "store consumed (no double post on rerun)" '[[ $RC -eq 0 ]]'

echo "=== a rejected review whose threads all post clears the store ==="
repo; seed; FAKE_REVIEW_FAIL=1 run 42
check "exits 0" '[[ $RC -eq 0 ]]'
run 42 --check; check "store consumed" '[[ $RC -eq 0 ]]'

echo "=== the P3 roll-up anchors on a P3 in a file the PR touches ==="
repo; seed; rec 42 a.py 3 clarity-reviewer P3 "dead branch"; rec 42 a.py 7 clarity-reviewer P3 "stale name"; run 42
check "roll-up sits on a.py, not on c.py which the PR does not touch" \
  '[[ "$(jq -r ".comments[] | select(.body | contains(\"P3 roll-up\")) | \"\(.path):\(.line)\"" "$T/review.json")" == a.py:3 ]]'

echo "=== a line GitHub will not anchor goes on its file ==="
repo; seed; FAKE_REVIEW_FAIL=1 FAKE_FAIL_LINE_PATH=a.py run 42
check "exits 0" '[[ $RC -eq 0 ]]'
check "the retry is a file comment with no line" \
  '[[ "$(jq -c "select(.path==\"a.py\" and .subject_type==\"file\") | has(\"line\")" "$T/comments.jsonl")" == false ]]'
check "and still starts with the skill header" \
  '[[ "$(jq -r "select(.subject_type==\"file\") | .body" "$T/comments.jsonl")" == "🤖 **Claude Code** ("* ]]'
check "the manifest says it went on the file" '[[ "$OUT" == *"a.py:10 (on the file)"* ]]'
run 42 --check; check "store consumed" '[[ $RC -eq 0 ]]'

echo "=== a failure other than 422 is not demoted to the file ==="
repo; seed; FAKE_REVIEW_FAIL=1 FAKE_502_PATH=a.py run 42
check "exits non-zero" '[[ $RC -ne 0 ]]'
check "no file comment or PR comment was tried" \
  '[[ "$(jq -c "select(.subject_type==\"file\")" "$T/comments.jsonl")" == "" && ! -e "$T/issues.jsonl" ]]'
check "both a.py findings are back in the store" \
  '[[ "$(jq -r .file "$T/r/.git/pr-review-loop/findings-42.jsonl" | sort -u)" == a.py ]]'

echo "=== a P3 roll-up outside the diff posts as a PR comment ==="
repo; seed; FAKE_REVIEW_FAIL=1 FAKE_FAIL_PATH=c.py run 42
check "exits 0" '[[ $RC -eq 0 ]]'
check "the roll-up is a PR comment naming its anchor" \
  '[[ "$(jq -r .body "$T/issues.jsonl")" == *"P3 roll-up"*"Posted unanchored: \`c.py:1\`"* ]]'
check "signatures survive, so the record is attributable" \
  '[[ "$(jq -r .body "$T/issues.jsonl" | grep -c "<!-- Agent: ")" == 2 ]]'
run 42 --check; check "store consumed" '[[ $RC -eq 0 ]]'

echo "=== a P3 roll-up that fails every route puts every P3 back ==="
repo; seed; FAKE_REVIEW_FAIL=1 FAKE_FAIL_PATH=c.py FAKE_ISSUE_FAIL=1 run 42
check "exits non-zero" '[[ $RC -ne 0 ]]'
check "both P3 findings are back in the store" \
  '[[ "$(jq -r .severity "$T/r/.git/pr-review-loop/findings-42.jsonl" | sort | uniq -c | tr -s " ")" == " 2 P3" ]]'

echo "=== a rejected review falls back, and failures stay recorded ==="
repo; seed; FAKE_REVIEW_FAIL=1 FAKE_FAIL_PATH=b.py FAKE_ISSUE_FAIL=1 run 42
check "exits non-zero when a thread fails" '[[ $RC -ne 0 ]]'
check "every thread was attempted, b.py on its line and its file" '[[ "$(wc -l < "$T/comments.jsonl")" == 4 ]]'
run 42 --check; check "--check still fails" '[[ $RC -eq 1 ]]'
check "only the failed finding is back in the store" \
  '[[ "$(cat "$T/r/.git/pr-review-loop/findings-42.jsonl" | jq -r .file)" == b.py ]]'

echo "=== a finding GitHub does not show is not marked done ==="
repo; seed; FAKE_DROP_PATH=b.py run 42
check "exits non-zero" '[[ $RC -ne 0 ]]'
check "says how many of how many posted" '[[ "$OUT" == *"Posted 4 of 5 finding(s)"* ]]'
check "only the missing finding is back in the store" \
  '[[ "$(jq -r .file "$T/r/.git/pr-review-loop/findings-42.jsonl")" == b.py ]]'
run 42 --check; check "--check still fails" '[[ $RC -eq 1 ]]'

echo "=== a short body inside a longer posted one is not counted as posted ==="
repo; open 42; rec 42 a.py 10 x P2 "races the writer and loses the row"; rec 42 b.py 5 x P2 "races the writer"
FAKE_DROP_PATH=b.py run 42
check "exits non-zero" '[[ $RC -ne 0 ]]'
check "the dropped short finding is back" '[[ "$(jq -r .file "$T/r/.git/pr-review-loop/findings-42.jsonl")" == b.py ]]'

echo "=== a body posted under another agent's signature is not counted as posted ==="
repo; open 42; rec 42 a.py 10 x P2 "races the writer"
# A crossed record written past record-finding.sh's guard.
jq -nc '{file: "b.py", line: 5, agent: "y", severity: "P2", body: "races the writer"}' >> "$T/r/.git/pr-review-loop/findings-42.jsonl"
FAKE_DROP_PATH=b.py run 42
check "y's finding is back" '[[ "$(jq -r .agent "$T/r/.git/pr-review-loop/findings-42.jsonl")" == y ]]'

echo "=== a P3 posts in the roll-up by its file, line and agent ==="
repo; open 42; rec 42 a.py 10 x P3 "unused import"; run 42
check "posted 1 of 1" '[[ $RC -eq 0 && "$OUT" == *"Posted 1 of 1"* ]]'

echo "=== recording needs an open round in this repo ==="
repo; set +e; E=$(cd "$T/r" && bash "$RECORD" 42 a.py 1 x P1 "y" 2>&1 >/dev/null); rc=$?; set -e
check "refused without --open" '[[ $rc -ne 0 && ! -s "$T/r/.git/pr-review-loop/findings-42.jsonl" ]]'
check "and says what to run" '[[ "$E" == *"post-findings.sh 42 --open"* ]]'
git init -q "$T/r/sub"; open 42; set +e; (cd "$T/r/sub" && bash "$RECORD" 42 a.py 1 x P1 "y" >/dev/null 2>&1); rc=$?; set -e
check "a round open in a parent repo does not let a sub-repo record" '[[ $rc -ne 0 ]]'

echo "=== the body comes on stdin and is read back ==="
repo; open 42
O=$(cd "$T/r" && bash "$RECORD" 42 a.py 3 x P2 - <<'EOF'
first line with a "quote" and $dollar
second line
EOF
)
check "stdin body is stored verbatim" \
  '[[ "$(jq -r .body "$T/r/.git/pr-review-loop/findings-42.jsonl")" == "first line with a \"quote\" and \$dollar"$'"'"'\n'"'"'"second line" ]]'
check "the read-back names agent, place and first line" '[[ "$O" == "Recorded P2 from x at a.py:3: first line with a \"quote\" and \$dollar" ]]'
set +e; (cd "$T/r" && bash "$RECORD" 42 a.py 3 x P2 - </dev/null >/dev/null 2>&1); rc=$?; set -e
check "an empty stdin body is refused" '[[ $rc -ne 0 ]]'

echo "=== the same body under another label is refused, naming the first ==="
repo; open 42; rec 42 a.py 3 error-handling-reviewer P2 "swallows the exit code"
set +e; E=$(cd "$T/r" && bash "$RECORD" 42 bot.py 9 llm-output-reviewer P2 "swallows the exit code" 2>&1 >/dev/null); rc=$?; set -e
check "refused" '[[ $rc -ne 0 && "$(wc -l < "$T/r/.git/pr-review-loop/findings-42.jsonl")" == 1 ]]'
check "names the earlier record" '[[ "$E" == *"P2 from error-handling-reviewer at a.py:3"* ]]'
(cd "$T/r" && bash "$RECORD" 42 b.py 9 error-handling-reviewer P2 "swallows the exit code" >/dev/null)
check "the same agent may repeat a body at another line" '[[ "$(wc -l < "$T/r/.git/pr-review-loop/findings-42.jsonl")" == 2 ]]'
set +e; O=$(cd "$T/r" && bash "$RECORD" 42 b.py 9 error-handling-reviewer P2 "swallows the exit code" 2>&1); rc=$?; set -e
check "a retry at the same line exits 0 and records nothing" '[[ $rc -eq 0 && "$O" == *"nothing to do"* && "$(wc -l < "$T/r/.git/pr-review-loop/findings-42.jsonl")" == 2 ]]'

echo ""; echo "Passed: $PASSED  Failed: $FAILED"; [[ "$FAILED" -eq 0 ]]
