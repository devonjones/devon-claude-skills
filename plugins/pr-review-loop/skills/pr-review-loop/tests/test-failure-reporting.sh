#!/usr/bin/env bash
# What do reply-to-comment.sh, reopen-comment.sh and check-ci.sh return when
# they CANNOT TELL whether they worked? Each case runs the real script against a
# stub `gh` on PATH and checks its exit status and the calls it made.
#
# Usage: tests/test-failure-reporting.sh
# Exit code: 0 if all pass, 1 if any fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/../scripts"

PASSED=0
FAILED=0

ok()   { PASSED=$((PASSED+1)); echo "  PASS: $1"; }
bad()  { FAILED=$((FAILED+1)); echo "  FAIL: $1"; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
SHA_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHA_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# Stub gh. Every call is logged to $T/log; behaviour comes from STUB_* vars.
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/log"
args="$*"
case "$args" in
    "repo view"*) echo "o/r" ;;
    "pr view"*headRefOid*)
        n=$(( $(cat "$STUB_DIR/views" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_DIR/views"
        [[ -n "${STUB_HEAD_FAIL:-}" ]] && { echo "HTTP 502" >&2; exit 1; }
        if [[ "$n" -gt 1 && -n "${STUB_HEAD_LATER:-}" ]]; then echo "$STUB_HEAD_LATER"; else echo "$STUB_HEAD"; fi ;;
    "pr checks"*) echo "[]" ;;
    *"--method POST"*replies*)
        [[ -n "${STUB_POST_FAIL:-}" ]] && { echo "$STUB_POST_FAIL" >&2; exit 1; }
        echo '{"id":1}' ;;
    *check-runs*)
        [[ -n "${STUB_RUNS_FAIL:-}" ]] && { echo "$STUB_RUNS_FAIL" >&2; exit 1; }
        echo "${STUB_RUNS:-{\"check_runs\":[]\}}" ;;
    *check-suites*) echo '{"check_suites":[]}' ;;
    *addPullRequestReviewComment*)
        [[ -n "${STUB_GQL_REPLY_FAIL:-}" ]] && { echo "$STUB_GQL_REPLY_FAIL" >&2; exit 1; }
        echo '{}' ;;
    *ReviewThread*) echo '{}' ;;   # resolve / unresolve mutations
    *reviewThreads*)
        echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"T1","isResolved":true,"comments":{"nodes":[{"id":"PRRC_1","databaseId":111}]}}]}}}}}' ;;
    *) echo "stub gh: unhandled: $args" >&2; exit 99 ;;
esac
STUB
printf '#!/bin/sh\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/gh" "$T/bin/sleep"

# run <script> <args...>: sets RC, OUT, ERR; fresh log per run.
run() {
    local script=$1; shift
    rm -f "$T/log" "$T/views"
    set +e
    PATH="$T/bin:$PATH" STUB_DIR="$T" PR_REVIEW_LOOP_PACE_S=0 \
        bash "$SCRIPTS/$script" "$@" >"$T/out" 2>"$T/err"
    RC=$?
    set -e
    OUT=$(cat "$T/out"); ERR=$(cat "$T/err")
}
resolved() { grep -q 'resolveReviewThread' "$T/log" 2>/dev/null && echo yes || echo no; }

echo "=== reply-to-comment.sh ==="
run reply-to-comment.sh 1 111 "Fixed - x"
check "posted reply exits 0" "$RC" 0
check "posted reply resolves the thread" "$(resolved)" yes

for body in '{"errors":[{"code":"abuse"}]}' 'You have exceeded a secondary rate limit' \
            'was submitted too quickly' 'temporarily blocked from content creation'; do
    STUB_POST_FAIL="$body" run reply-to-comment.sh 1 111 "Fixed - x"
    check "rate limit ($body) exits 3" "$RC" 3
    check "rate limit ($body) leaves thread unresolved" "$(resolved)" no
done

STUB_POST_FAIL='{"message":"Not Found"}' run reply-to-comment.sh 1 111 "Fixed - x"
check "failed post exits 1" "$RC" 1
check "failed post leaves thread unresolved" "$(resolved)" no

echo "=== reopen-comment.sh ==="
STUB_GQL_REPLY_FAIL="GQL-ERR" run reopen-comment.sh 1 111 agent "why"
check "GraphQL fails, REST posts: exits 0" "$RC" 0

STUB_GQL_REPLY_FAIL="GQL-ERR" STUB_POST_FAIL="REST-ERR" run reopen-comment.sh 1 111 agent "why"
check "both posts fail: exits 1" "$RC" 1
check "REST failure reports the REST call's own error" \
    "$(grep -c '^REST response: REST-ERR' <<<"$ERR" || true)" 1

echo "=== check-ci.sh ==="
RUNS_OK='{"check_runs":[{"name":"t","status":"completed","conclusion":"success"}]}'
RUNS_BAD='{"check_runs":[{"name":"t","status":"completed","conclusion":"failure"}]}'
RUNS_STALE='{"check_runs":[{"name":"t","status":"completed","conclusion":"stale"}]}'
RUNS_RUNNING='{"check_runs":[{"name":"t","status":"in_progress","conclusion":null}]}'

STUB_HEAD="$SHA_A" STUB_RUNS="$RUNS_OK" run check-ci.sh 1
check "passing checks exit 0" "$RC" 0
check "verdict is read from the head commit" "$(grep -c "commits/$SHA_A/check-runs" "$T/log" || true)" 1

STUB_HEAD="$SHA_A" STUB_RUNS="$RUNS_BAD" run check-ci.sh 1
check "failing checks exit 1" "$RC" 1

STUB_HEAD="$SHA_A" STUB_RUNS="$RUNS_STALE" run check-ci.sh 1
check "unclassified conclusion (stale) is not a pass" "$RC" 1

STUB_HEAD="$SHA_A" STUB_RUNS="$RUNS_RUNNING" run check-ci.sh 1
check "in-progress run reports pending" "$(grep -c 'still running' <<<"$OUT" || true)" 1
check "pending without --wait exits 0" "$RC" 0

# Every state the script names, classified the way the script promises.
run_state() { STUB_HEAD="$SHA_A" STUB_RUNS="{\"check_runs\":[{\"name\":\"t\",\"status\":\"$1\",\"conclusion\":$2}]}" run check-ci.sh 1; }
for c in success neutral skipped; do run_state completed "\"$c\""; check "conclusion $c passes" "$RC" 0; done
for c in failure timed_out cancelled startup_failure; do run_state completed "\"$c\""; check "conclusion $c fails" "$RC" 1; done
for s in queued in_progress waiting requested pending; do
    run_state "$s" null; check "status $s is pending" "$(grep -c 'still running' <<<"$OUT" || true)" 1
done
run_state completed '"action_required"'; check "conclusion action_required is pending" "$(grep -c 'still running' <<<"$OUT" || true)" 1

STUB_HEAD="$SHA_A" run check-ci.sh 1
check "no check runs exits 0" "$RC" 0

STUB_HEAD="$SHA_A" STUB_RUNS_FAIL="HTTP 401" run check-ci.sh 1
check "unreadable check runs exit 2, not 'no CI'" "$RC" 2
check "unreadable check runs surface gh's error" "$(grep -c 'HTTP 401' <<<"$ERR" || true)" 1

STUB_HEAD="$SHA_A" STUB_RUNS_FAIL="HTTP 401" run check-ci.sh 1 --wait --timeout 30
check "--wait: check runs unreadable until timeout exits 2" "$RC" 2

STUB_HEAD_FAIL=1 run check-ci.sh 1
check "unresolvable head SHA exits 2" "$RC" 2

STUB_HEAD="garbage" STUB_RUNS="$RUNS_OK" run check-ci.sh 1
check "malformed head SHA exits 2" "$RC" 2

STUB_HEAD="$SHA_A" STUB_RUNS="$RUNS_OK" run check-ci.sh 1 --wait
check "--wait: passing checks exit 0" "$RC" 0

STUB_HEAD="$SHA_A" STUB_RUNS="$RUNS_BAD" run check-ci.sh 1 --wait
check "--wait: failing checks exit 1" "$RC" 1

STUB_HEAD="$SHA_A" run check-ci.sh 1 --wait
check "--wait: no runs and no active suites exits 0" "$RC" 0
check "--wait: no active suites is reported" "$(grep -c 'No active CI' <<<"$OUT" || true)" 1

STUB_HEAD="$SHA_A" STUB_RUNS="$RUNS_RUNNING" run check-ci.sh 1 --wait --timeout 30
check "--wait: still running at timeout exits 2" "$RC" 2

STUB_HEAD="$SHA_A" STUB_HEAD_LATER="$SHA_B" STUB_RUNS="$RUNS_OK" run check-ci.sh 1 --wait
check "--wait: head moved exits 3" "$RC" 3

echo ""
echo "Passed: $PASSED  Failed: $FAILED"
[[ "$FAILED" -eq 0 ]]
