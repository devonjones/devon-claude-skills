#!/usr/bin/env bash
# Test harness for bot-enabled.sh, the `bots` block in _parse_configuration.sh,
# and the call-site guard that must never trigger a disabled bot.
#
# Covers the three-state exit contract (0 enabled / 1 disabled / 2 undetermined)
# because collapsing 2 into either neighbour is the whole failure mode the
# contract exists to prevent: a broken config silently re-enabling a bot the
# user turned off, or a broken script being reported as the user's choice.
#
# Usage: tests/test-bot-enabled.sh
# Exit code: 0 if all pass, 1 if any fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOT_ENABLED="$SCRIPT_DIR/../scripts/bot-enabled.sh"
PARSE_CONFIG="$SCRIPT_DIR/../scripts/_parse_configuration.sh"
TRIGGER_REVIEW="$SCRIPT_DIR/../scripts/trigger-review.sh"

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

check_contains() {
    local name="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "PASS: $name"
        PASSED=$((PASSED + 1))
    else
        echo "FAIL: $name (output did not contain '$needle'): $haystack"
        FAILED=$((FAILED + 1))
    fi
}

# Exit code of bot-enabled.sh run from inside $repo.
bot_status() {
    local repo="$1" bot="$2" rc=0
    (cd "$repo" && "$BOT_ENABLED" "$bot" >/dev/null 2>&1) || rc=$?
    echo "$rc"
}

# Stderr of bot-enabled.sh run from inside $repo.
bot_stderr() {
    local repo="$1" bot="$2"
    (cd "$repo" && "$BOT_ENABLED" "$bot" 2>&1 >/dev/null) || true
}

# Exit code of an arbitrary command run inside $repo.
rc_in() {
    local repo="$1"; shift
    local rc=0
    (cd "$repo" && "$@" >/dev/null 2>&1) || rc=$?
    echo "$rc"
}

# --- resolution: enabled / disabled -----------------------------------------

repo="$(make_repo '{"bots": {"gemini": false}}')"
check "gemini disabled -> exit 1" "1" "$(bot_status "$repo" gemini)"
check "cursor untouched -> exit 0" "0" "$(bot_status "$repo" cursor)"

repo="$(make_repo '{"bots": {"gemini": true}}')"
check "gemini explicitly enabled -> exit 0" "0" "$(bot_status "$repo" gemini)"

repo="$(make_repo '{"bots": {"gemini": false, "cursor": false}}')"
check "both disabled: gemini -> exit 1" "1" "$(bot_status "$repo" gemini)"
check "both disabled: cursor -> exit 1" "1" "$(bot_status "$repo" cursor)"

repo="$(make_repo '{"disabled": ["pr-test-analyzer"]}')"
check "no bots block -> enabled" "0" "$(bot_status "$repo" gemini)"

repo="$(make_repo "")"
check "no AGENT-REVIEWERS.md -> enabled (not an error)" "0" "$(bot_status "$repo" gemini)"

# --- exit 2: undetermined, never silently 0 or 1 ----------------------------

# A config the parser rejects must NOT come back as a clean "enabled" — the
# user may well have disabled the bot in the part that failed to parse.
repo="$(make_repo '{"bots": {"gemini": "false"}}')"
check "unparseable config -> exit 2, not 0" "2" "$(bot_status "$repo" gemini)"
check_contains "exit 2 warns on stderr" "could not parse" "$(bot_stderr "$repo" gemini)"

NON_REPO="$(mktemp -d -p "$TMP_ROOT")"
check "outside a git repo -> exit 2" "2" "$(rc_in "$NON_REPO" "$BOT_ENABLED" gemini)"

# --- parser validation ------------------------------------------------------

repo="$(make_repo '{"bots": {"gemini": "false"}}')"
check "string bot value rejected by parser" "1" "$(rc_in "$repo" "$PARSE_CONFIG" AGENT-REVIEWERS.md)"

repo="$(make_repo '{"bots": ["gemini"]}')"
check "non-object bots rejected by parser" "1" "$(rc_in "$repo" "$PARSE_CONFIG" AGENT-REVIEWERS.md)"

# A typo'd bot name leaves the bot running, so it has to be called out.
repo="$(make_repo '{"bots": {"gemni": false}}')"
UNKNOWN_ERR="$(cd "$repo" && "$PARSE_CONFIG" AGENT-REVIEWERS.md 2>&1 >/dev/null)"
check_contains "unknown bot name warns" "unknown bots" "$UNKNOWN_ERR"
check "unknown bot name does not disable gemini" "0" "$(bot_status "$repo" gemini)"

# --- call site: a disabled bot must never be triggered ----------------------

# trigger-review.sh talks to GitHub through `gh`. Stub it so the test can assert
# the one thing that matters: `gh pr comment ... /gemini review` is never run.
STUB_BIN="$TMP_ROOT/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALL_LOG"
case "$*" in
    "repo view"*) echo "acme/widgets" ;;
    "pr view"*)   echo "42" ;;
    *)            echo "" ;;
esac
STUB
chmod +x "$STUB_BIN/gh"

repo="$(make_repo '{"bots": {"gemini": false}}')"
GH_CALL_LOG="$TMP_ROOT/gh-calls.log"
: > "$GH_CALL_LOG"
TRIGGER_RC=0
TRIGGER_OUT="$(cd "$repo" && PATH="$STUB_BIN:$PATH" GH_CALL_LOG="$GH_CALL_LOG" "$TRIGGER_REVIEW" 42 --gemini 2>&1)" || TRIGGER_RC=$?
check "disabled gemini: trigger-review exits 0" "0" "$TRIGGER_RC"
check_contains "disabled gemini: says so" "disabled for this repo" "$TRIGGER_OUT"
if grep -q "gemini review" "$GH_CALL_LOG"; then
    echo "FAIL: disabled gemini: posted a /gemini review comment"
    FAILED=$((FAILED + 1))
else
    echo "PASS: disabled gemini: no /gemini review comment posted"
    PASSED=$((PASSED + 1))
fi

echo "---"
echo "Passed: $PASSED, Failed: $FAILED"
[[ "$FAILED" -eq 0 ]]
