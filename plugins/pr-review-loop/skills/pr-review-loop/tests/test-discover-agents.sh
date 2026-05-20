#!/usr/bin/env bash
# Test harness for discover-agents.sh C+E merge logic and # Configuration parsing.
#
# Each test creates a temp directory, initializes it as a git repo, writes a
# specific AGENT-REVIEWERS.md (or not), runs discover-agents.sh against it,
# and asserts a jq expression evaluates to true.
#
# The script under test reads defaults from the REAL plugin agents/ dir and
# the REAL plugin.json. Only the repo-level state (AGENT-REVIEWERS.md,
# changed files) is varied per test.
#
# Usage: tests/test-discover-agents.sh
# Exit code: 0 if all pass, 1 if any fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISCOVER="$SCRIPT_DIR/../scripts/discover-agents.sh"

if [[ ! -x "$DISCOVER" ]]; then
    echo "Error: discover-agents.sh not found or not executable at $DISCOVER" >&2
    exit 2
fi

# Read the canonical plugin version from the real plugin.json for use in
# version-pin assertions. Falls back to "unknown" — tests that depend on it
# will then fail with a clear mismatch.
PLUGIN_JSON="$SCRIPT_DIR/../../../.claude-plugin/plugin.json"
PLUGIN_VERSION="$(jq -r '.version // "unknown"' "$PLUGIN_JSON")"

TESTS_PASSED=0
TESTS_FAILED=0
FAILED=()

# ---------------------------------------------------------------------------
# Test infrastructure
# ---------------------------------------------------------------------------

# Track every temp dir / temp file we create so an EXIT trap can clean them
# up even on unexpected failure (set -e abort, Ctrl-C, mktemp on full disk).
# Without this, a failed test leaks /tmp/tmp.XXX dirs.
TEMP_PATHS=()
cleanup_temp_paths() {
    local p
    for p in "${TEMP_PATHS[@]}"; do
        [[ -n "$p" && -e "$p" ]] && rm -rf -- "$p"
    done
}
trap cleanup_temp_paths EXIT

# Create a temp repo dir, init git, return the absolute path on stdout.
make_temp_repo() {
    local td
    td="$(mktemp -d)"
    TEMP_PATHS+=("$td")
    (
        cd "$td"
        git init -q
        git config user.email "test@example.com"
        git config user.name "Test"
    )
    echo "$td"
}

# Run discover-agents.sh inside a repo dir and capture stdout + stderr + exit.
# Args:
#   $1 = repo dir
#   $2 = changed files (newline-separated string, may be empty)
#   $3 = output var name (caller declares; we set $3=stdout, ${3}_err=stderr, ${3}_exit=code)
run_discover() {
    local repo_dir="$1"
    local changed="$2"
    local out_var="$3"
    local stdout_file stderr_file
    stdout_file="$(mktemp)"
    stderr_file="$(mktemp)"
    TEMP_PATHS+=("$stdout_file" "$stderr_file")
    local exit_code=0

    (
        cd "$repo_dir"
        PR_REVIEW_LOOP_TEST_CHANGED_FILES="$changed" "$DISCOVER" 0 \
            > "$stdout_file" 2> "$stderr_file"
    ) || exit_code=$?

    printf -v "$out_var" '%s' "$(cat "$stdout_file")"
    printf -v "${out_var}_err" '%s' "$(cat "$stderr_file")"
    printf -v "${out_var}_exit" '%s' "$exit_code"

    rm -f "$stdout_file" "$stderr_file"
}

# Assert that a jq expression evaluates to "true" against the given JSON.
# Prints PASS/FAIL line. Increments counters.
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
        echo "        actual JSON (first 500 chars):"
        echo "          $(echo "$json" | head -c 500)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED+=("$name")
    fi
}

# Assert that the script exited with the expected code.
assert_exit() {
    local name="$1"
    local actual="$2"
    local expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS  $name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL  $name (exit was $actual, expected $expected)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED+=("$name")
    fi
}

# Assert that a string is in stderr.
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
echo "=== Test 1: no AGENT-REVIEWERS.md → all 6 defaults spawn ==="
repo="$(make_temp_repo)"
run_discover "$repo" "src/foo.py" t1
assert_exit "exit 0" "$t1_exit" "0"
assert_jq "6 agents total" "$t1" '.agents | length == 6'
assert_jq "all kind=default" "$t1" '[.agents[] | .kind] | all(. == "default")'
assert_jq "expected names" "$t1" '
    ([.agents[] | .name] | sort) == ["code-reviewer","code-simplifier","comment-analyzer","pr-test-analyzer","silent-failure-hunter","type-design-analyzer"]
'
assert_jq "stale_pin true (no config at all)" "$t1" '.configuration.stale_pin == true'
assert_jq "current_plugin_version present" "$t1" '.configuration.current_plugin_version != null and .configuration.current_plugin_version != ""'
rm -rf "$repo"

echo
echo "=== Test 2: empty AGENT-REVIEWERS.md (no # Agents) → defaults still spawn ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Guidelines

Some repo-wide guidelines here.

# Context

Project context.
EOF
run_discover "$repo" "src/foo.py" t2
assert_exit "exit 0" "$t2_exit" "0"
assert_jq "6 defaults still spawn" "$t2" '.agents | length == 6'
assert_jq "context section present" "$t2" '(.context | length) >= 1'
rm -rf "$repo"

echo
echo "=== Test 3: custom user agent (no name overlap) → additive ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Agents

## pci-auditor

You are a PCI-compliance auditor.
EOF
run_discover "$repo" "src/foo.py" t3
assert_exit "exit 0" "$t3_exit" "0"
assert_jq "7 agents (6 defaults + 1 user)" "$t3" '.agents | length == 7'
assert_jq "pci-auditor kind=user" "$t3" '[.agents[] | select(.name == "pci-auditor") | .kind] == ["user"]'
assert_jq "user_count == 1" "$t3" '.configuration.user_count == 1'
assert_jq "default_count == 6" "$t3" '.configuration.default_count == 6'
rm -rf "$repo"

echo
echo "=== Test 4: user agent with same name as default → override ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Agents

## code-reviewer

You are a CUSTOM code reviewer for this repo.
EOF
run_discover "$repo" "src/foo.py" t4
assert_exit "exit 0" "$t4_exit" "0"
assert_jq "still 6 agents total" "$t4" '.agents | length == 6'
assert_jq "code-reviewer is user-override" "$t4" '[.agents[] | select(.name == "code-reviewer") | .kind] == ["user-override"]'
assert_jq "no default code-reviewer" "$t4" '[.agents[] | select(.name == "code-reviewer" and .kind == "default")] | length == 0'
assert_jq "override_count == 1" "$t4" '.configuration.override_count == 1'
assert_jq "overridden_default_names == [code-reviewer]" "$t4" '.configuration.overridden_default_names == ["code-reviewer"]'
rm -rf "$repo"

echo
echo "=== Test 5: # Configuration disabled list excludes named defaults ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<EOF
# Configuration

\`\`\`json
{
  "defaults_version_checked": "${PLUGIN_VERSION}",
  "disabled": ["pr-test-analyzer", "code-simplifier"]
}
\`\`\`
EOF
run_discover "$repo" "src/foo.py" t5
assert_exit "exit 0" "$t5_exit" "0"
assert_jq "4 defaults spawn (2 disabled)" "$t5" '.agents | length == 4'
assert_jq "pr-test-analyzer excluded" "$t5" '[.agents[] | .name] | index("pr-test-analyzer") == null'
assert_jq "code-simplifier excluded" "$t5" '[.agents[] | .name] | index("code-simplifier") == null'
assert_jq "disabled_defaults populated" "$t5" '.configuration.disabled_defaults == ["pr-test-analyzer", "code-simplifier"]'
rm -rf "$repo"

echo
echo "=== Test 6: matching defaults_version_checked → stale_pin false ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<EOF
# Configuration

\`\`\`json
{
  "defaults_version_checked": "${PLUGIN_VERSION}"
}
\`\`\`
EOF
run_discover "$repo" "src/foo.py" t6
assert_exit "exit 0" "$t6_exit" "0"
assert_jq "stale_pin false" "$t6" '.configuration.stale_pin == false'
assert_jq "defaults_version_checked echoes back" "$t6" ".configuration.defaults_version_checked == \"$PLUGIN_VERSION\""
rm -rf "$repo"

echo
echo "=== Test 7: mismatched defaults_version_checked → stale_pin true ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Configuration

```json
{
  "defaults_version_checked": "0.0.0-pinned-to-stale"
}
```
EOF
run_discover "$repo" "src/foo.py" t7
assert_exit "exit 0" "$t7_exit" "0"
assert_jq "stale_pin true" "$t7" '.configuration.stale_pin == true'
assert_jq "defaults_version_checked echoes back" "$t7" '.configuration.defaults_version_checked == "0.0.0-pinned-to-stale"'
rm -rf "$repo"

echo
echo "=== Test 8: overlap_acknowledged without reason → exit 1 ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Configuration

```json
{
  "overlap_acknowledged": {
    "my_agent": {
      "overlaps_with": "code-reviewer"
    }
  }
}
```
EOF
run_discover "$repo" "src/foo.py" t8
assert_exit "exit 1" "$t8_exit" "1"
assert_stderr_contains "missing-reason error in stderr" "$t8_err" "missing required 'reason'"
rm -rf "$repo"

echo
echo "=== Test 9: overlap_acknowledged with required reason → passes ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Configuration

```json
{
  "overlap_acknowledged": {
    "my_agent": {
      "overlaps_with": "code-reviewer",
      "reason": "Custom focus on a specific compliance regime."
    }
  }
}
```
EOF
run_discover "$repo" "src/foo.py" t9
assert_exit "exit 0" "$t9_exit" "0"
assert_jq "overlap passed through" "$t9" '.configuration.overlaps_acknowledged.my_agent.overlaps_with == "code-reviewer"'
assert_jq "reason preserved" "$t9" '.configuration.overlaps_acknowledged.my_agent.reason | length > 0'
rm -rf "$repo"

echo
echo "=== Test 10: subdirectory # Configuration → warning emitted, ignored ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/sub"
cat > "$repo/sub/AGENT-REVIEWERS.md" <<'EOF'
# Configuration

```json
{
  "disabled": ["should-be-ignored"]
}
```
EOF
run_discover "$repo" "sub/foo.py" t10
assert_exit "exit 0" "$t10_exit" "0"
assert_stderr_contains "warning emitted" "$t10_err" "# Configuration section found"
assert_jq "subdirectory config NOT applied" "$t10" '.configuration.disabled_defaults == []'
rm -rf "$repo"

echo
echo "=== Test 11: invalid JSON in # Configuration → graceful fallback to {} ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Configuration

```json
{ this is not valid json }
```
EOF
run_discover "$repo" "src/foo.py" t11
assert_exit "exit 0" "$t11_exit" "0"
assert_jq "defaults still spawn after invalid config" "$t11" '.agents | length == 6'
assert_jq "stale_pin true (config treated as empty)" "$t11" '.configuration.stale_pin == true'
rm -rf "$repo"

echo
echo "=== Test 12: combined scenario (override + disable + additive + config) ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<EOF
# Configuration

\`\`\`json
{
  "defaults_version_checked": "${PLUGIN_VERSION}",
  "disabled": ["code-simplifier"],
  "overlap_acknowledged": {
    "pci-auditor": {
      "overlaps_with": "code-reviewer",
      "reason": "PCI scope vs general bugs"
    }
  }
}
\`\`\`

# Agents

## code-reviewer

You are a custom code reviewer.

## pci-auditor

You are a PCI auditor.
EOF
run_discover "$repo" "src/foo.py" t12
assert_exit "exit 0" "$t12_exit" "0"
# Expected: 1 user-override (code-reviewer) + 1 user (pci-auditor) + 4 defaults (silent-failure-hunter, pr-test-analyzer, comment-analyzer, type-design-analyzer) = 6 total
# code-simplifier is disabled; code-reviewer default is overridden
assert_jq "6 agents total" "$t12" '.agents | length == 6'
assert_jq "code-simplifier excluded" "$t12" '[.agents[] | .name] | index("code-simplifier") == null'
assert_jq "code-reviewer kind=user-override" "$t12" '[.agents[] | select(.name == "code-reviewer") | .kind] == ["user-override"]'
assert_jq "pci-auditor kind=user" "$t12" '[.agents[] | select(.name == "pci-auditor") | .kind] == ["user"]'
assert_jq "stale_pin false" "$t12" '.configuration.stale_pin == false'
assert_jq "all counts correct" "$t12" '
    (.configuration.spawned_count == 6) and
    (.configuration.default_count == 4) and
    (.configuration.override_count == 1) and
    (.configuration.user_count == 1)
'
rm -rf "$repo"

echo
echo "=== Test 13: default in BOTH disabled AND user-override → user-override wins; default filtered ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<EOF
# Configuration

\`\`\`json
{
  "defaults_version_checked": "${PLUGIN_VERSION}",
  "disabled": ["code-reviewer"]
}
\`\`\`

# Agents

## code-reviewer

You are a custom code reviewer overriding the default.
EOF
run_discover "$repo" "src/foo.py" t13
assert_exit "exit 0" "$t13_exit" "0"
# Expected: code-reviewer present as user-override; NO default code-reviewer; 5 other defaults
assert_jq "code-reviewer present exactly once" "$t13" '[.agents[] | select(.name == "code-reviewer")] | length == 1'
assert_jq "the code-reviewer is user-override (not a stray default)" "$t13" '[.agents[] | select(.name == "code-reviewer") | .kind] == ["user-override"]'
assert_jq "5 other defaults still spawn (6 total agents)" "$t13" '.agents | length == 6'
assert_jq "disabled_defaults still listed in configuration" "$t13" '.configuration.disabled_defaults == ["code-reviewer"]'
rm -rf "$repo"

echo
echo "=== Test 14: overlap_acknowledged with empty reason / null reason → exit 1 ==="
# Empty string
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Configuration

```json
{
  "overlap_acknowledged": {
    "agent_a": {"overlaps_with": "code-reviewer", "reason": ""}
  }
}
```
EOF
run_discover "$repo" "src/foo.py" t14a
assert_exit "exit 1 on empty-string reason" "$t14a_exit" "1"
assert_stderr_contains "stderr mentions missing reason" "$t14a_err" "missing required 'reason'"
rm -rf "$repo"
# Explicit null
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Configuration

```json
{
  "overlap_acknowledged": {
    "agent_b": {"overlaps_with": "code-reviewer", "reason": null}
  }
}
```
EOF
run_discover "$repo" "src/foo.py" t14b
assert_exit "exit 1 on null reason" "$t14b_exit" "1"
assert_stderr_contains "stderr mentions missing reason (null case)" "$t14b_err" "missing required 'reason'"
rm -rf "$repo"

echo
echo "=== Test 15: unknown top-level key in # Configuration → warning + still parses ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<EOF
# Configuration

\`\`\`json
{
  "defaults_version_checked": "${PLUGIN_VERSION}",
  "diabled": ["pr-test-analyzer"]
}
\`\`\`
EOF
run_discover "$repo" "src/foo.py" t15
assert_exit "exit 0" "$t15_exit" "0"
assert_stderr_contains "warning on unknown key" "$t15_err" "unknown top-level keys"
# The typo means the disabled list is effectively empty (real `disabled` not present)
assert_jq "disabled_defaults empty (typo not honored)" "$t15" '.configuration.disabled_defaults == []'
assert_jq "all 6 defaults still spawn" "$t15" '.agents | length == 6'
rm -rf "$repo"

echo
echo "=== Test 16: disabled list contains unknown name → warning + still parses ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<EOF
# Configuration

\`\`\`json
{
  "defaults_version_checked": "${PLUGIN_VERSION}",
  "disabled": ["nonexistent-reviewer", "pr-test-analyzer"]
}
\`\`\`
EOF
run_discover "$repo" "src/foo.py" t16
assert_exit "exit 0" "$t16_exit" "0"
assert_stderr_contains "warning names the unknown disabled name" "$t16_err" "nonexistent-reviewer"
# pr-test-analyzer is a real name and gets disabled
assert_jq "pr-test-analyzer still excluded" "$t16" '[.agents[] | .name] | index("pr-test-analyzer") == null'
# disabled_defaults echoes raw user input; disabled_defaults_unknown isolates typos
assert_jq "disabled_defaults_unknown names the typo" "$t16" '.configuration.disabled_defaults_unknown == ["nonexistent-reviewer"]'
assert_jq "disabled_defaults_unknown does NOT contain valid names" "$t16" '.configuration.disabled_defaults_unknown | index("pr-test-analyzer") == null'
rm -rf "$repo"

echo
echo "=== Test 17: independent_validator defaults populate when no config given ==="
repo="$(make_temp_repo)"
run_discover "$repo" "src/foo.py" t17
assert_exit "exit 0" "$t17_exit" "0"
assert_jq "enabled defaults true" "$t17" '.configuration.independent_validator.enabled == true'
assert_jq "skip_for defaults []" "$t17" '.configuration.independent_validator.skip_for == []'
assert_jq "uncertain_action defaults post_with_annotation" "$t17" '.configuration.independent_validator.uncertain_action == "post_with_annotation"'
rm -rf "$repo"

echo
echo "=== Test 18: explicit independent_validator config echoed in output ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<EOF
# Configuration

\`\`\`json
{
  "defaults_version_checked": "${PLUGIN_VERSION}",
  "independent_validator": {
    "enabled": false,
    "skip_for": ["code-simplifier", "comment-analyzer"],
    "uncertain_action": "drop"
  }
}
\`\`\`
EOF
run_discover "$repo" "src/foo.py" t18
assert_exit "exit 0" "$t18_exit" "0"
assert_jq "enabled echoes false" "$t18" '.configuration.independent_validator.enabled == false'
assert_jq "skip_for echoes back" "$t18" '.configuration.independent_validator.skip_for == ["code-simplifier", "comment-analyzer"]'
assert_jq "uncertain_action echoes drop" "$t18" '.configuration.independent_validator.uncertain_action == "drop"'
rm -rf "$repo"

echo
echo "=== Test 19: invalid uncertain_action enum → exit 1 ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Configuration

```json
{ "independent_validator": { "uncertain_action": "ignore" } }
```
EOF
run_discover "$repo" "src/foo.py" t19
assert_exit "exit 1 on bad uncertain_action" "$t19_exit" "1"
assert_stderr_contains "stderr names the bad value" "$t19_err" "ignore"
assert_stderr_contains "stderr lists allowed enum values" "$t19_err" "post_with_annotation"
rm -rf "$repo"

echo
echo "=== Test 20: invalid enabled type (string instead of bool) → exit 1 ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Configuration

```json
{ "independent_validator": { "enabled": "yes" } }
```
EOF
run_discover "$repo" "src/foo.py" t20
assert_exit "exit 1 on string enabled" "$t20_exit" "1"
assert_stderr_contains "stderr says must be boolean" "$t20_err" "must be a boolean"
rm -rf "$repo"

echo
echo "=== Test 21: invalid skip_for type (string instead of array) → exit 1 ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Configuration

```json
{ "independent_validator": { "skip_for": "code-simplifier" } }
```
EOF
run_discover "$repo" "src/foo.py" t21
assert_exit "exit 1 on string skip_for" "$t21_exit" "1"
assert_stderr_contains "stderr says must be array" "$t21_err" "must be an array"
rm -rf "$repo"

echo
echo "=== Test 22a: explicit null for enabled → rejected (regression test for // empty bypass) ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Configuration

```json
{ "independent_validator": { "enabled": null } }
```
EOF
run_discover "$repo" "src/foo.py" t22a
assert_exit "exit 1 on null enabled (was bypassing via // empty)" "$t22a_exit" "1"
assert_stderr_contains "stderr says enabled must be boolean" "$t22a_err" "must be a boolean"
rm -rf "$repo"

echo
echo "=== Test 22b: explicit null for skip_for → rejected ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Configuration

```json
{ "independent_validator": { "skip_for": null } }
```
EOF
run_discover "$repo" "src/foo.py" t22b
assert_exit "exit 1 on null skip_for" "$t22b_exit" "1"
assert_stderr_contains "stderr says must be array" "$t22b_err" "must be an array"
rm -rf "$repo"

echo
echo "=== Test 22: unknown nested key under independent_validator → warning ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Configuration

```json
{ "independent_validator": { "enabld": true } }
```
EOF
run_discover "$repo" "src/foo.py" t22
assert_exit "exit 0 (warning, not error)" "$t22_exit" "0"
assert_stderr_contains "warning names the typo" "$t22_err" "enabld"
rm -rf "$repo"

# ---------------------------------------------------------------------------
# Test 23–26: language_detection block (98b tranche b)
# ---------------------------------------------------------------------------

echo
echo "=== Test 23: no AGENT-REVIEWERS.md + no manifests → language_detection.matched is empty ==="
repo="$(make_temp_repo)"
run_discover "$repo" "src/foo.py" t23
assert_exit "exit 0" "$t23_exit" "0"
assert_jq "language_detection is object" "$t23" '.language_detection | type == "object"'
assert_jq "matched is empty array" "$t23" '.language_detection.matched == []'
assert_jq "same_directory_polyglot false" "$t23" '.language_detection.same_directory_polyglot == false'
rm -rf "$repo"

echo
echo "=== Test 24: no AGENT-REVIEWERS.md + go.mod at root → detects golang ==="
repo="$(make_temp_repo)"
touch "$repo/go.mod"
run_discover "$repo" "main.go" t24
assert_jq "one match" "$t24" '.language_detection.matched | length == 1'
assert_jq "golang detected at root" "$t24" '.language_detection.matched[0] | (.language == "golang" and .subtree == "." and .template == "golang.md")'
rm -rf "$repo"

echo
echo "=== Test 25: per-subtree polyglot (go in backend, python in frontend) ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/backend" "$repo/frontend"
touch "$repo/backend/go.mod" "$repo/frontend/pyproject.toml"
run_discover "$repo" "backend/main.go" t25
assert_jq "two matches" "$t25" '.language_detection.matched | length == 2'
assert_jq "templates include both" "$t25" '[.language_detection.matched[].template] | sort == ["golang.md","python.md"]'
assert_jq "same_directory_polyglot false" "$t25" '.language_detection.same_directory_polyglot == false'
rm -rf "$repo"

echo
echo "=== Test 26: same-directory polyglot (go.mod + pyproject.toml at same dir) ==="
repo="$(make_temp_repo)"
touch "$repo/go.mod" "$repo/pyproject.toml"
run_discover "$repo" "main.go" t26
assert_jq "two matches" "$t26" '.language_detection.matched | length == 2'
assert_jq "both at root" "$t26" 'all(.language_detection.matched[]; .subtree == ".")'
assert_jq "same_directory_polyglot true" "$t26" '.language_detection.same_directory_polyglot == true'
rm -rf "$repo"

echo
echo "=== Test 27: AGENT-REVIEWERS.md exists → language_detection is null (suppressed) ==="
repo="$(make_temp_repo)"
touch "$repo/go.mod"   # manifest present
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Agents

## my-reviewer

Custom reviewer.
EOF
run_discover "$repo" "main.go" t27
assert_jq "language_detection is null" "$t27" '.language_detection == null'
rm -rf "$repo"

echo
echo "=== Test 28: AGENT-REVIEWERS.md in subdir (no root file) → language_detection still suppressed ==="
repo="$(make_temp_repo)"
touch "$repo/go.mod"
mkdir -p "$repo/sub"
cat > "$repo/sub/AGENT-REVIEWERS.md" <<'EOF'
# Agents

## sub-reviewer

A scoped reviewer.
EOF
run_discover "$repo" "sub/file.go" t28
assert_jq "language_detection is null (subdir AGENT-REVIEWERS.md found via walk-up)" "$t28" '.language_detection == null'
rm -rf "$repo"

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
