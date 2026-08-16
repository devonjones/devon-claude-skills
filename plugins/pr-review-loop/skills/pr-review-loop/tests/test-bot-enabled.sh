#!/usr/bin/env bash
# Test harness for bot-enabled.sh + the `bots` block in _parse_configuration.sh.
#
# Usage: tests/test-bot-enabled.sh
# Exit code: 0 if all pass, 1 if any fail.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOT_ENABLED="$SCRIPT_DIR/../scripts/bot-enabled.sh"
PARSE_CONFIG="$SCRIPT_DIR/../scripts/_parse_configuration.sh"

PASSED=0
FAILED=0

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

# Build a throwaway git repo whose root AGENT-REVIEWERS.md has the given
# # Configuration JSON (empty arg = no AGENT-REVIEWERS.md at all).
make_repo() {
    local json="${1:-}"
    local repo
    repo="$(mktemp -d -p "$TMP_ROOT")"
    git -C "$repo" init -q
    if [[ -n "$json" ]]; then
        printf '# Configuration\n\n```json\n%s\n```\n' "$json" > "$repo/AGENT-REVIEWERS.md"
    fi
    echo "$repo"
}

check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: $name"
        PASSED=$((PASSED + 1))
    else
        echo "FAIL: $name (expected '$expected', got '$actual')"
        FAILED=$((FAILED + 1))
    fi
}

# exit code of bot-enabled.sh run from inside $repo
bot_status() {
    local repo="$1" bot="$2"
    (cd "$repo" && "$BOT_ENABLED" "$bot" >/dev/null 2>&1; echo $?)
}

repo="$(make_repo '{"bots": {"gemini": false}}')"
check "gemini disabled -> exit 1" "1" "$(bot_status "$repo" gemini)"
check "cursor untouched -> exit 0" "0" "$(bot_status "$repo" cursor)"

repo="$(make_repo '{"bots": {"gemini": true}}')"
check "gemini explicitly enabled -> exit 0" "0" "$(bot_status "$repo" gemini)"

repo="$(make_repo '{"disabled": ["pr-test-analyzer"]}')"
check "no bots block -> enabled" "0" "$(bot_status "$repo" gemini)"

repo="$(make_repo "")"
check "no AGENT-REVIEWERS.md -> enabled" "0" "$(bot_status "$repo" gemini)"

# Non-boolean values are a config error, not a silent "still enabled".
repo="$(make_repo '{"bots": {"gemini": "false"}}')"
(cd "$repo" && "$PARSE_CONFIG" AGENT-REVIEWERS.md >/dev/null 2>&1)
check "string bot value rejected by parser" "1" "$?"

repo="$(make_repo '{"bots": ["gemini"]}')"
(cd "$repo" && "$PARSE_CONFIG" AGENT-REVIEWERS.md >/dev/null 2>&1)
check "non-object bots rejected by parser" "1" "$?"

echo "---"
echo "Passed: $PASSED, Failed: $FAILED"
[[ "$FAILED" -eq 0 ]]
