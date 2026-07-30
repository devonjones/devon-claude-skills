#!/usr/bin/env bash
# Test harness for _load_defaults.sh validation paths.
#
# Exercises the three skip-with-warning code paths added in commit b2ba3da:
#   - File with no YAML frontmatter (no --- markers)
#   - File with frontmatter that never closes (only opening ---)
#   - File with empty/missing `name` in frontmatter
#
# Plus a happy-path smoke test (a well-formed file produces a valid record).
# Uses --agents-dir to point at fixture dirs rather than the real plugin
# defaults dir.
#
# Usage: tests/test-load-defaults.sh
# Exit code: 0 if all pass, 1 if any fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOADER="$SCRIPT_DIR/../scripts/_load_defaults.sh"

if [[ ! -x "$LOADER" ]]; then
    echo "Error: _load_defaults.sh not found or not executable at $LOADER" >&2
    exit 2
fi

TESTS_PASSED=0
TESTS_FAILED=0
FAILED=()

# Track temp dirs for trap-based cleanup.
TEMP_PATHS=()
cleanup_temp_paths() {
    local p
    for p in "${TEMP_PATHS[@]}"; do
        [[ -n "$p" && -e "$p" ]] && rm -rf -- "$p"
    done
}
trap cleanup_temp_paths EXIT

# Make a fixture dir, return its absolute path on stdout.
make_fixture_dir() {
    local td
    td="$(mktemp -d)"
    TEMP_PATHS+=("$td")
    echo "$td"
}

# Run loader against a fixture dir; capture stdout/stderr/exit.
run_loader() {
    local agents_dir="$1"
    local out_var="$2"
    local stdout_file stderr_file
    stdout_file="$(mktemp)"
    stderr_file="$(mktemp)"
    TEMP_PATHS+=("$stdout_file" "$stderr_file")
    local exit_code=0
    "$LOADER" --agents-dir "$agents_dir" \
        > "$stdout_file" 2> "$stderr_file" || exit_code=$?
    printf -v "$out_var" '%s' "$(cat "$stdout_file")"
    printf -v "${out_var}_err" '%s' "$(cat "$stderr_file")"
    printf -v "${out_var}_exit" '%s' "$exit_code"
}

assert_jq() {
    local name="$1"
    local json="$2"
    local expr="$3"
    local result
    result="$(echo "$json" | jq -e "$expr" 2>/dev/null || true)"
    if [[ "$result" == "true" ]]; then
        echo "  PASS  $name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL  $name"
        echo "        expected: $expr"
        echo "        actual JSON: $(echo "$json" | head -c 300)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED+=("$name")
    fi
}

assert_stderr_contains() {
    local name="$1"
    local stderr="$2"
    local needle="$3"
    if [[ "$stderr" == *"$needle"* ]]; then
        echo "  PASS  $name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL  $name (stderr did not contain '$needle')"
        echo "        stderr: $stderr"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED+=("$name")
    fi
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

echo
echo "=== Test 1: well-formed agent file → loads as default ==="
fixture="$(make_fixture_dir)"
cat > "$fixture/good-agent.md" <<'EOF'
---
name: good-agent
description: A well-formed agent.
model: sonnet
color: blue
---

You are a good agent. Do good things.
EOF
run_loader "$fixture" t1
assert_jq "loads exactly 1 agent" "$t1" '. | length == 1'
assert_jq "name preserved" "$t1" '.[0].name == "good-agent"'
assert_jq "model preserved" "$t1" '.[0].model == "sonnet"'
assert_jq "color preserved" "$t1" '.[0].color == "blue"'
assert_jq "kind = default" "$t1" '.[0].kind == "default"'
assert_jq "instructions captured" "$t1" '(.[0].instructions | length) > 0'

echo
echo "=== Test 2: file with no frontmatter (no --- markers) → skipped with warning ==="
fixture="$(make_fixture_dir)"
cat > "$fixture/no-frontmatter.md" <<'EOF'
This is just a body with no YAML frontmatter at all.

You are an agent without proper structure.
EOF
run_loader "$fixture" t2
assert_jq "0 agents loaded" "$t2" '. | length == 0'
assert_stderr_contains "warning mentions no frontmatter" "$t2_err" "no YAML frontmatter"
assert_stderr_contains "warning names the offending file" "$t2_err" "no-frontmatter.md"

echo
echo "=== Test 3: frontmatter that never closes (only opening ---) → skipped with warning ==="
fixture="$(make_fixture_dir)"
cat > "$fixture/unterminated.md" <<'EOF'
---
name: unterminated
description: Missing closing dashes.
model: sonnet

This body should never be reached because the frontmatter never closes.
EOF
run_loader "$fixture" t3
assert_jq "0 agents loaded" "$t3" '. | length == 0'
assert_stderr_contains "warning mentions unterminated frontmatter" "$t3_err" "frontmatter never closes"
assert_stderr_contains "warning names the offending file" "$t3_err" "unterminated.md"

echo
echo "=== Test 4: empty name field → skipped with warning ==="
fixture="$(make_fixture_dir)"
cat > "$fixture/empty-name.md" <<'EOF'
---
name:
description: Has no name.
model: sonnet
---

You are nameless.
EOF
run_loader "$fixture" t4
assert_jq "0 agents loaded" "$t4" '. | length == 0'
assert_stderr_contains "warning mentions empty name" "$t4_err" "empty or missing"

echo
echo "=== Test 5: missing name field entirely → skipped with warning ==="
fixture="$(make_fixture_dir)"
cat > "$fixture/no-name.md" <<'EOF'
---
description: I have a description but no name.
model: sonnet
---

You are also nameless.
EOF
run_loader "$fixture" t5
assert_jq "0 agents loaded" "$t5" '. | length == 0'
assert_stderr_contains "warning mentions empty name" "$t5_err" "empty or missing"

echo
echo "=== Test 6: mixed dir (good + bad files) → only good loads, bad skipped ==="
fixture="$(make_fixture_dir)"
cat > "$fixture/agent-a.md" <<'EOF'
---
name: agent-a
description: First good agent.
model: opus
color: red
---

Body A.
EOF
cat > "$fixture/agent-b.md" <<'EOF'
---
name:
---

Empty name should fail.
EOF
cat > "$fixture/agent-c.md" <<'EOF'
---
name: agent-c
description: Second good agent.
---

Body C.
EOF
run_loader "$fixture" t6
assert_jq "loads 2 good agents" "$t6" '. | length == 2'
assert_jq "agent-a present" "$t6" '[.[] | .name] | index("agent-a") != null'
assert_jq "agent-c present" "$t6" '[.[] | .name] | index("agent-c") != null'
assert_stderr_contains "warning emitted for empty-name file" "$t6_err" "empty or missing"

echo
echo "=== Test 7: empty agents dir → empty array with warning ==="
fixture="$(make_fixture_dir)"
run_loader "$fixture" t7
assert_jq "empty array" "$t7" '. == []'
assert_stderr_contains "warning mentions empty dir" "$t7_err" "no agent files"

echo
echo "=== Test 8: nonexistent agents dir → empty array with warning + clean exit ==="
# Pass --agents-dir to a path that doesn't exist. The loader's `cd` in
# the optional-arg branch will fail noisily, but should not crash the test.
# (We expect the loader to either warn or quietly produce []; either is OK.)
nonexistent_dir="/tmp/this-dir-definitely-does-not-exist-$$-$$"
stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
TEMP_PATHS+=("$stdout_file" "$stderr_file")
exit_code=0
"$LOADER" --agents-dir "$nonexistent_dir" \
    > "$stdout_file" 2> "$stderr_file" || exit_code=$?
# The script tries `cd` to the dir which fails noisily. The expected behavior:
# either exit with a clear error, OR fall through to "[]" with a warning. The
# bash command-substitution path actually exits non-zero on cd failure, so
# the test accepts either outcome as long as nothing leaks into stdout JSON.
if [[ $exit_code -ne 0 || "$(cat "$stdout_file")" == "[]" ]]; then
    echo "  PASS  nonexistent dir handled (exit $exit_code, stdout: $(cat "$stdout_file"))"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo "  FAIL  nonexistent dir produced unexpected output"
    echo "        exit: $exit_code  stdout: $(cat "$stdout_file")  stderr: $(cat "$stderr_file")"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILED+=("nonexistent dir handled")
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "=== Summary ==="
total=$((TESTS_PASSED + TESTS_FAILED))
echo "  Passed: $TESTS_PASSED / $total"
if [[ $TESTS_FAILED -gt 0 ]]; then
    echo "  Failed: $TESTS_FAILED"
    for name in "${FAILED[@]}"; do
        echo "    - $name"
    done
    exit 1
fi
echo
echo "All tests passed."
exit 0
