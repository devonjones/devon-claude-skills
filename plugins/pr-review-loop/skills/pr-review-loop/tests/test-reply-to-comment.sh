#!/usr/bin/env bash
# reply-to-comment.sh, run for real against a fake `gh` that records every call.
#
# Behavioural, not structural: it checks what the script actually sends. A
# grep that a line exists cannot tell where in a backslash-continued command
# the line landed - and a call inserted mid-command turned the POST into one
# with no body, after which the script resolved the thread anyway.
#
# Usage: tests/test-reply-to-comment.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPLY="$SCRIPT_DIR/../scripts/reply-to-comment.sh"
T="$(mktemp -d)"; trap 'rm -rf -- "$T"' EXIT
PASSED=0; FAILED=0
ok(){ PASSED=$((PASSED+1)); echo "  PASS: $1"; }
bad(){ FAILED=$((FAILED+1)); echo "  FAIL: $1"; }

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\0' "$@" >> "$GH_LOG"; printf '\n' >> "$GH_LOG"
case "$*" in
  "repo view"*)            echo "o/r" ;;
  *"--method POST"*replies*)
      [[ -n "${FAKE_POST_FAIL:-}" ]] && { echo '{"message":"Validation Failed"}'; exit 1; }
      echo '{"id":99}' ;;
  "api graphql"*)          echo '{"data":{}}' ;;
  *)                       echo '{}' ;;
esac
GH
chmod +x "$T/bin/gh"

run(){ : > "$T/log"; set +e
  OUT=$(PATH="$T/bin:$PATH" GH_LOG="$T/log" PR_REVIEW_LOOP_PACE_S=0 TMPDIR="$T" \
        bash "$REPLY" 42 123 "the reply text" "$@" 2>&1); RC=$?; set -e; }
post_call(){ tr '\0' ' ' < "$T/log" | grep -- '--method POST' || true; }

echo "=== the POST carries the body ==="
run --no-resolve
p="$(post_call)"
[[ "$p" == *"body=the reply text"* ]] && ok "POST includes -f body=<reply>" || bad "POST sent without the body: $p"
[[ "$p" != *pace_github* ]] && ok "nothing leaked into the POST's arguments" || bad "pace_github passed to gh as an argument: $p"
[[ "$RC" -eq 0 ]] && ok "successful post exits 0" || bad "rc=$RC"

echo "=== a failed POST never resolves the thread ==="
FAKE_POST_FAIL=1 run
[[ "$RC" -ne 0 ]] && ok "failed post exits non-zero (rc=$RC)" || bad "failed post exited 0"
if tr '\0' ' ' < "$T/log" | grep -q 'graphql'; then bad "resolve path ran after a failed post"
else ok "no GraphQL resolve call after a failed post"; fi

echo ""; echo "Passed: $PASSED  Failed: $FAILED"; [[ "$FAILED" -eq 0 ]]
