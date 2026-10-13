#!/usr/bin/env bash
# Test harness for the three scripts that mutate state or report a verdict.
#
# One question: what does this return when it CANNOT TELL? Each of these
# answered "success" to that, in a different way:
#   - reply-to-comment.sh exited 0 AND resolved the thread on a failed POST
#   - reopen-comment.sh exited 0 and reported a different call's error
#   - check-ci.sh resolved the verdict from the PR, so it could answer for a
#     commit that is no longer the head
#
# Every case below is paired: the failure must be distinguishable from the
# success, or the check proves nothing.
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

echo "=== reply-to-comment.sh: rate limiting is retryable, other failures are not ==="

retryable() {
    grep -qE '"code": *"abuse"|secondary rate limit|was submitted too quickly|temporarily blocked from content creation' <<<"$1" \
        && echo "retryable" || echo "hard"
}
check "422 abuse is retryable"            "$(retryable '{"errors":[{"code":"abuse"}]}')"        "retryable"
check "secondary rate limit is retryable" "$(retryable 'exceeded a secondary rate limit')"      "retryable"
check "403 content-creation block is retryable" "$(retryable 'temporarily blocked from content creation')" "retryable"
check "Not Found is NOT retryable"        "$(retryable '{"message":"Not Found"}')"              "hard"
check "Forbidden is NOT retryable"        "$(retryable '{"message":"Forbidden"}')"              "hard"

echo "=== reply-to-comment.sh: a failed post must never reach the resolve ==="
# Structural: the failure branch exits before the resolve block. If someone
# reintroduces a fall-through, the resolve moves above an exit and this trips.
fail_exit_line=$(grep -n 'Thread left UNRESOLVED' "$SCRIPTS/reply-to-comment.sh" | cut -d: -f1)
resolve_line=$(grep -n 'Resolving thread' "$SCRIPTS/reply-to-comment.sh" | head -1 | cut -d: -f1)
if [[ -n "$fail_exit_line" && -n "$resolve_line" && "$fail_exit_line" -lt "$resolve_line" ]]; then
    ok "failure path exits before the resolve block"
else
    bad "failure path does not clearly precede the resolve block"
fi
if grep -q 'Will still attempt to resolve' "$SCRIPTS/reply-to-comment.sh"; then
    bad "the resolve-anyway fall-through is back"
else
    ok "no resolve-anyway fall-through"
fi

echo "=== reopen-comment.sh: report THIS call's error, not the previous one's ==="
if grep -q 'REST_RESULT=\$(gh api' "$SCRIPTS/reopen-comment.sh"; then
    ok "REST call's own output is captured"
else
    bad "REST call's output is not captured (a wrong-but-plausible error will be reported)"
fi

echo "=== check-ci.sh: no SHA is not 'passing' ==="
# Source the function in isolation; with no SHA it must refuse to answer.
status=$(bash -c '
    REPO=o/r
    '"$(sed -n "/^get_check_status() {/,/^}/p" "$SCRIPTS/check-ci.sh")"'
    get_check_status ""
')
check "get_check_status with no SHA returns unknown_sha" "$status" "unknown_sha"
if grep -q 'repos/\${REPO}/commits/\${sha}/check-runs' "$SCRIPTS/check-ci.sh"; then
    ok "verdict is resolved from a commit, not from the PR"
else
    bad "verdict is not resolved from a commit SHA"
fi

echo ""
echo "Passed: $PASSED  Failed: $FAILED"
[[ "$FAILED" -eq 0 ]]
