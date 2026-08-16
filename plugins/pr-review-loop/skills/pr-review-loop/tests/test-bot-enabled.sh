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
    # trigger-review.sh resolves HEAD, so the fixture needs a commit. -c keeps
    # this independent of whatever identity the machine has configured.
    git -C "$repo" add -A
    git -C "$repo" -c user.email=test@example.com -c user.name=test \
        commit -qm "fixture" --allow-empty
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

# An unreadable `bots` block must NOT come back as a clean "enabled" — the user
# may well have disabled the bot in the part that failed to parse.
repo="$(make_repo '{"bots": {"gemini": "false"}}')"
check "invalid bot value -> exit 2, not 0" "2" "$(bot_status "$repo" gemini)"
check_contains "exit 2 warns on stderr" "could not read the .bots block" "$(bot_stderr "$repo" gemini)"

# Genuinely malformed JSON, not just a schema violation. The full parser
# degrades to `{}` here so the loop can proceed; --bots-only must not, or
# "your config is unreadable" silently becomes "the bot is on".
repo="$(mktemp -d -p "$TMP_ROOT")"
git -C "$repo" init -q
printf '# Configuration\n\n```json\n{"bots": {"gemini": false\n```\n' > "$repo/AGENT-REVIEWERS.md"
check "malformed JSON -> exit 2, not 0" "2" "$(bot_status "$repo" gemini)"

# A broken entry in an UNRELATED block must not discard a readable bots block:
# the user asked for gemini off, and an overlap_acknowledged typo is not a
# reason to start posting /gemini review again.
repo="$(make_repo '{"bots": {"gemini": false}, "overlap_acknowledged": {"x": {"overlaps_with": "y"}}}')"
check "unrelated config error still honors explicit disable" "1" "$(bot_status "$repo" gemini)"

NON_REPO="$(mktemp -d -p "$TMP_ROOT")"
check "outside a git repo -> exit 2" "2" "$(rc_in "$NON_REPO" "$BOT_ENABLED" gemini)"

# --- parser validation ------------------------------------------------------

repo="$(make_repo '{"bots": {"gemini": "false"}}')"
check "string bot value rejected by parser" "1" "$(rc_in "$repo" "$PARSE_CONFIG" AGENT-REVIEWERS.md)"

repo="$(make_repo '{"bots": ["gemini"]}')"
check "non-object bots rejected by parser" "1" "$(rc_in "$repo" "$PARSE_CONFIG" AGENT-REVIEWERS.md)"
# Assert the type check specifically: an array also trips the value check, so a
# bare exit-code assertion passes even with the type branch deleted.
NONOBJ_ERR="$(cd "$repo" && "$PARSE_CONFIG" AGENT-REVIEWERS.md 2>&1 >/dev/null || true)"
check_contains "non-object bots names the type error" "must be an object" "$NONOBJ_ERR"

# An unclosed prose fence swallows the whole json block, leaving nothing to
# extract — which must not read as "no config, bot enabled".
repo="$(mktemp -d -p "$TMP_ROOT")"
git -C "$repo" init -q
printf '# Configuration\n\n```text\nunclosed prose fence\n\n```json\n{"bots": {"gemini": false}}\n```\n' \
    > "$repo/AGENT-REVIEWERS.md"
check "swallowed json block -> exit 2, not 0" "2" "$(bot_status "$repo" gemini)"

# A misspelled `bots` key is invisible to the bot-name check, so the top-level
# unknown-key warning has to survive --bots-only.
repo="$(make_repo '{"bot": {"gemini": false}}')"
MISSPELLED_ERR="$(cd "$repo" && "$PARSE_CONFIG" AGENT-REVIEWERS.md --bots-only 2>&1 >/dev/null || true)"
check_contains "misspelled bots key warns under --bots-only" "unknown top-level keys" "$MISSPELLED_ERR"

# A typo'd flag must not quietly fall back to full-config gating.
repo="$(make_repo '{"bots": {"gemini": false}}')"
check "unknown parser flag rejected" "1" "$(rc_in "$repo" "$PARSE_CONFIG" AGENT-REVIEWERS.md --bots_only)"

# A typo'd bot name leaves the bot running, so it has to be called out.
repo="$(make_repo '{"bots": {"gemni": false}}')"
UNKNOWN_ERR="$(cd "$repo" && "$PARSE_CONFIG" AGENT-REVIEWERS.md 2>&1 >/dev/null)"
check_contains "unknown bot name warns" "unknown bots" "$UNKNOWN_ERR"
check "unknown bot name does not disable gemini" "0" "$(bot_status "$repo" gemini)"

# Negative control: without this, the closed-set check could warn on every
# config — including the valid ones — and the assertion above would still pass.
repo="$(make_repo '{"bots": {"gemini": false, "cursor": true}}')"
KNOWN_ERR="$(cd "$repo" && "$PARSE_CONFIG" AGENT-REVIEWERS.md 2>&1 >/dev/null)"
check "known bot names do not warn" "" "$KNOWN_ERR"

# --- call site: a disabled bot must never be triggered ----------------------

# trigger-review.sh talks to GitHub through `gh`. Stub it so the test can assert
# the one thing that matters: `gh pr comment ... /gemini review` is never run.
STUB_BIN="$TMP_ROOT/bin"
mkdir -p "$STUB_BIN"
# Each arm must return something the caller can actually parse: the quota check
# and the already-reviewed check both pipe this through jq under `set -e`, so a
# bare echo makes trigger-review.sh die before it reaches the guard under test —
# which is precisely how the disabled-case assertion could pass for free.
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALL_LOG"
case "$*" in
    "repo view"*)             echo "acme/widgets" ;;
    "pr view"*--json\ comments*) echo '{"body":"looks good","createdAt":"2020-01-01T00:00:00Z"}' ;;
    "pr view"*)               echo "42" ;;
    "api"*)                   echo "[]" ;;
    *)                        echo "" ;;
esac
STUB
chmod +x "$STUB_BIN/gh"

GH_CALL_LOG="$TMP_ROOT/gh-calls.log"

# Run a script under the stub from inside $1, resetting the gh call log.
# Sets RUN_RC and RUN_OUT.
run_stubbed() {
    local repo="$1"; shift
    : > "$GH_CALL_LOG"
    RUN_RC=0
    RUN_OUT="$(cd "$repo" && PATH="$STUB_BIN:$PATH" GH_CALL_LOG="$GH_CALL_LOG" "$@" 2>&1)" || RUN_RC=$?
}

check_gh_posted() {
    local name="$1" want="$2" got=no
    grep -q "gemini review" "$GH_CALL_LOG" && got=yes
    check "$name" "$want" "$got"
}

repo="$(make_repo '{"bots": {"gemini": false}}')"
run_stubbed "$repo" "$TRIGGER_REVIEW" 42 --gemini
check "disabled gemini: trigger-review exits 0" "0" "$RUN_RC"
check_contains "disabled gemini: says so" "disabled for this repo" "$RUN_OUT"
check_gh_posted "disabled gemini: no /gemini review comment posted" "no"

# Positive control. Without it the assertion above is vacuous: it also passes
# when trigger-review.sh bails for some unrelated reason (or when the guard is
# deleted outright and the script dies earlier in the stubbed environment).
repo="$(make_repo '{"bots": {"gemini": true}}')"
run_stubbed "$repo" "$TRIGGER_REVIEW" 42 --gemini
check_gh_posted "enabled gemini: /gemini review IS posted" "yes"

# The second call site. commit-and-push.sh carries its own copy of the guard, so
# it needs its own coverage — it pushes first, hence the local bare origin.
COMMIT_PUSH="$SCRIPT_DIR/../scripts/commit-and-push.sh"
BARE="$TMP_ROOT/origin.git"
git init -q --bare "$BARE"
repo="$(make_repo '{"bots": {"gemini": false}}')"
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
git -C "$repo" remote add origin "$BARE"
git -C "$repo" push -q -u origin HEAD
echo "change" > "$repo/file.txt"
run_stubbed "$repo" "$COMMIT_PUSH" "test commit" --trigger-review
check "disabled gemini: commit-and-push exits 0" "0" "$RUN_RC"
check_gh_posted "disabled gemini: commit-and-push posts no /gemini review" "no"

repo="$(make_repo '{"bots": {"gemini": true}}')"
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
git -C "$repo" remote add origin "$TMP_ROOT/origin2.git"
git init -q --bare "$TMP_ROOT/origin2.git"
git -C "$repo" push -q -u origin HEAD
echo "change" > "$repo/file.txt"
run_stubbed "$repo" "$COMMIT_PUSH" "test commit" --trigger-review
check_gh_posted "enabled gemini: commit-and-push DOES post /gemini review" "yes"

echo "---"
echo "Passed: $PASSED, Failed: $FAILED"
[[ "$FAILED" -eq 0 ]]
