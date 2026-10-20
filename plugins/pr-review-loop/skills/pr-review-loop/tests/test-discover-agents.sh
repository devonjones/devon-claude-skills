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
export PR_REVIEW_LOOP_MODELS=/nonexistent   # no real ~/.config/pr-review-loop/models.json

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
    # An EXIT trap whose last command fails takes the script's exit status with
    # it: without this the suite reported failure on a clean run (the last path
    # is usually already gone, so the `&&` returns 1).
    return 0
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
echo "=== Test 7b: pin == DEFAULTS_VERSION, below plugin version → stale_pin false ==="
DEFAULTS_VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/../../../DEFAULTS_VERSION")"
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<EOF
# Configuration

\`\`\`json
{
  "defaults_version_checked": "${DEFAULTS_VERSION}"
}
\`\`\`
EOF
run_discover "$repo" "src/foo.py" t7b
assert_exit "exit 0" "$t7b_exit" "0"
assert_jq "stale_pin false" "$t7b" '.configuration.stale_pin == false'
assert_jq "defaults_version reported" "$t7b" ".configuration.defaults_version == \"$DEFAULTS_VERSION\""
rm -rf "$repo"

echo
echo "=== Test 7c: pin just below DEFAULTS_VERSION → stale_pin true ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Configuration

```json
{
  "defaults_version_checked": "1.2.99"
}
```
EOF
run_discover "$repo" "src/foo.py" t7c
assert_exit "exit 0" "$t7c_exit" "0"
assert_jq "stale_pin true" "$t7c" '.configuration.stale_pin == true'
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
assert_jq "enabled defaults false (validation is opt-in)" "$t17" '.configuration.independent_validator.enabled == false'
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
    "enabled": true,
    "skip_for": ["code-simplifier", "comment-analyzer"],
    "uncertain_action": "drop"
  }
}
\`\`\`
EOF
run_discover "$repo" "src/foo.py" t18
assert_exit "exit 0" "$t18_exit" "0"
assert_jq "enabled echoes true (explicit opt-in overrides the false default)" "$t18" '.configuration.independent_validator.enabled == true'
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
assert_jq "golang detected at root" "$t24" '.language_detection.matched[0] | (.language == "golang" and .subtree == "." and .template == "golang")'
rm -rf "$repo"

echo
echo "=== Test 25: per-subtree polyglot (go in backend, python in frontend) ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/backend" "$repo/frontend"
touch "$repo/backend/go.mod" "$repo/frontend/pyproject.toml"
run_discover "$repo" "backend/main.go" t25
assert_jq "two matches" "$t25" '.language_detection.matched | length == 2'
assert_jq "templates include both" "$t25" '[.language_detection.matched[].template] | sort == ["golang","python"]'
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
# Test 29–32: fence-aware awk parsing in discover-agents.sh and
# _parse_configuration.sh. Regression for the same fence-unaware bug class
# that install-template.sh's extract_section closed in 98b — adjacent awk
# programs had the same silent-data-loss failure mode.
# ---------------------------------------------------------------------------

echo
echo "=== Test 29: fenced '# ' inside agent body doesn't drop subsequent agents ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Agents

## first-reviewer

Look for shell scripts missing `set -euo pipefail`. Example of what to flag:

```bash
#!/bin/bash
# BAD: no error handling
echo hello
```

## second-reviewer

A different reviewer that should still appear in the merged agent list.

## third-reviewer

A third reviewer that should also still appear.
EOF
run_discover "$repo" "src/foo.py" t29
assert_exit "exit 0" "$t29_exit" "0"
assert_jq "first user agent present" "$t29" 'any(.agents[]; .name == "first-reviewer" and .kind == "user")'
assert_jq "second user agent present (would be dropped by fence-unaware parser)" "$t29" 'any(.agents[]; .name == "second-reviewer" and .kind == "user")'
assert_jq "third user agent present" "$t29" 'any(.agents[]; .name == "third-reviewer" and .kind == "user")'
assert_jq "user_count is 3" "$t29" '.configuration.user_count == 3'
rm -rf "$repo"

echo
echo "=== Test 30: fenced '## ' inside agent body doesn't fragment current agent ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Agents

## docs-reviewer

Look for missing sections in README files. Example template:

```markdown
# Project Title

## Installation
...
## Usage
...
```

The above markdown fences `## Installation` and `## Usage` should not
register as new agent definitions.

## other-reviewer

A second agent.
EOF
run_discover "$repo" "src/foo.py" t30
assert_exit "exit 0" "$t30_exit" "0"
assert_jq "docs-reviewer present" "$t30" 'any(.agents[]; .name == "docs-reviewer")'
assert_jq "other-reviewer present" "$t30" 'any(.agents[]; .name == "other-reviewer")'
assert_jq "no spurious agent named Installation" "$t30" '[.agents[] | select(.name == "Installation")] | length == 0'
assert_jq "no spurious agent named Usage" "$t30" '[.agents[] | select(.name == "Usage")] | length == 0'
rm -rf "$repo"

echo
echo "=== Test 31: fenced '^# ' in prose before json block doesn't discard # Configuration ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Configuration

Here is an annotated example showing what each field does. The fenced
shell block below contains `#` comments that the parser must ignore —
otherwise the json block further down would be silently discarded.

```bash
# disabled lists default reviewer names to skip
# overlap_acknowledged maps user agent name → {overlaps_with, reason}
echo "explanatory shell example"
```

And here is the real configuration:

```json
{
  "disabled": ["code-simplifier"],
  "overlap_acknowledged": {
    "my-extra-reviewer": {
      "overlaps_with": "code-reviewer",
      "reason": "project-specific scope"
    }
  }
}
```
EOF
run_discover "$repo" "src/foo.py" t31
assert_exit "exit 0" "$t31_exit" "0"
assert_jq "disabled list parsed from json (would be empty under fence-unaware parser)" "$t31" '.configuration.disabled_defaults == ["code-simplifier"]'
assert_jq "overlap_acknowledged parsed" "$t31" '.configuration.overlaps_acknowledged | has("my-extra-reviewer")'
rm -rf "$repo"

echo
echo "=== Test 34: unclosed code fence in agent body emits stderr warning ==="
# Defensive: an unclosed code fence is malformed input that would otherwise
# silently swallow subsequent H1/H2. The awk's END block warns to stderr so
# the user has a clear signal.
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Agents

## first-reviewer

Example with an unclosed fence:

```bash
# this fence never closes
echo "oops"

## second-reviewer

A second reviewer that gets silently swallowed under toggle semantics.
EOF
run_discover "$repo" "src/foo.py" t34
assert_exit "exit 0 (warning, not error)" "$t34_exit" "0"
assert_stderr_contains "unclosed-fence warning in stderr" "$t34_err" "unclosed code fence"
rm -rf "$repo"

echo
echo "=== Test 35: unclosed fence in # Configuration narrative emits stderr warning ==="
# Same defensive check in _parse_configuration.sh's awk. An unclosed fence
# before the json block means the parser will never reach the real config —
# the END block warns so the user knows why their config didn't take effect.
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Configuration

Example with an unclosed shell fence (no closing backticks):

```bash
# disabled lists default reviewer names to skip

```json
{
  "disabled": ["code-simplifier"]
}
```
EOF
run_discover "$repo" "src/foo.py" t35
# The unclosed fence corrupts the parse — but the script falls back to {}
# rather than aborting the whole loop. What we care about is the user gets
# a clear stderr signal so they can fix their markdown.
assert_exit "exit 0 (non-fatal — locks in graceful-fallback half of contract)" "$t35_exit" "0"
assert_stderr_contains "unclosed-fence warning in stderr" "$t35_err" "unclosed code fence"
rm -rf "$repo"

echo
echo "=== Test 33: multiple json blocks under # Configuration — rejected loudly ==="
# CONTRACT CHANGE (was: "first block wins"). The awk used to exit at the first
# json fence close, so an annotated "example" block ahead of the real config
# silently won and the user's actual settings vanished — for `disabled` that
# means retired reviewers quietly start running again, and for `bots` it means a
# disabled review bot quietly starts getting triggered (and billed). The awk now
# reads on, so both blocks land in the capture and the single-document check
# rejects them. Full-config mode still degrades to {} + exit 0 so the loop can
# start; the difference is that the user is told.
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Configuration

Example showing the shape (this is an annotated illustration):

```json
{
  "disabled": ["example-only-not-real"],
  "overlap_acknowledged": {}
}
```

And the real config:

```json
{
  "disabled": ["code-simplifier"],
  "overlap_acknowledged": {}
}
```
EOF
run_discover "$repo" "src/foo.py" t33
assert_exit "exit 0" "$t33_exit" "0"
# Neither block governs now: silently applying the wrong one was the bug.
assert_jq "example block does not win" "$t33" '(.configuration.disabled_defaults | index("example-only-not-real")) == null'
assert_jq "real block does not silently win either" "$t33" '(.configuration.disabled_defaults | index("code-simplifier")) == null'
assert_stderr_contains "multiple json blocks warned" "$t33_err" "more than one"
rm -rf "$repo"

echo
echo "=== Test 32: fenced '# Configuration' inside subtree agent body doesn't trigger ignored-warning ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/sub"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Agents

## root-reviewer

Root-level reviewer.
EOF
cat > "$repo/sub/AGENT-REVIEWERS.md" <<'EOF'
# Agents

## sub-reviewer

This reviewer flags missing config sections. Example of what to look for:

```markdown
# Configuration

```json
{}
```
```

The above is a documentation snippet, not a real Configuration section.
EOF
run_discover "$repo" "sub/file.py" t32
assert_exit "exit 0" "$t32_exit" "0"
# The subtree file has no real # Configuration heading (only fenced examples),
# so the "ignored" warning should NOT fire.
if [[ "$t32_err" == *"# Configuration section found in"*"sub/AGENT-REVIEWERS.md"* ]]; then
    echo "  FAIL  no spurious ignored-warning on subtree (fence-unaware grep -q would emit it)"
    echo "        stderr: $t32_err"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILED+=("no spurious ignored-warning on subtree")
else
    echo "  PASS  no spurious ignored-warning on subtree (fence-unaware grep -q would emit it)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi
rm -rf "$repo"

echo
echo "=== Every agent has a model: sonnet unless it declares one ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Agents

## plain-agent

Reviews things.

## haiku-agent

model: haiku
Reviews cheaply.

## late-model-agent

Line one.
Line two.
Line three.
Line four.
Line five.
model: opus

## line-five-agent

One.
Two.
Three.
Four.
model: opus

## inherit-agent

model: inherit

## quoted-agent

model: "haiku"

## full-id-agent

model: claude-sonnet-5-5

## code-reviewer

model: haiku
Override of the shipped code-reviewer.
EOF
run_discover "$repo" "src/foo.py" tm
assert_exit "exit 0" "$tm_exit" "0"
assert_jq "no agent without a model" "$tm" '[.agents[] | select((.model // "") == "")] == []'
assert_jq "undeclared user agent -> sonnet" "$tm" '[.agents[] | select(.name == "plain-agent") | .model] == ["sonnet"]'
assert_jq "model: line declares a user agent's model" "$tm" '[.agents[] | select(.name == "haiku-agent") | .model] == ["haiku"]'
assert_jq "a model: line past the first five lines is prose, not a declaration" "$tm" '[.agents[] | select(.name == "late-model-agent") | .model] == ["sonnet"]'
assert_jq "a model: line on the fifth line still counts" "$tm" '[.agents[] | select(.name == "line-five-agent") | .model] == ["opus"]'
assert_jq "model: inherit becomes sonnet, never the session model" "$tm" '[.agents[] | select(.name == "inherit-agent") | .model] == ["sonnet"]'
assert_jq "a quoted model name is accepted" "$tm" '[.agents[] | select(.name == "quoted-agent") | .model] == ["haiku"]'
assert_jq "a full claude-* model id is accepted" "$tm" '[.agents[] | select(.name == "full-id-agent") | .model] == ["claude-sonnet-5-5"]'
assert_jq "a user override of a default keeps its declared model" "$tm" '[.agents[] | select(.name == "code-reviewer") | {kind, model}] == [{"kind": "user-override", "model": "haiku"}]'
assert_jq "every remaining shipped default is on sonnet" "$tm" '[.agents[] | select(.kind == "default") | .model] | length > 0 and all(. == "sonnet")'
rm -rf "$repo"

echo
echo "=== Test G1: generated files leave review scope ==="
repo="$(make_temp_repo)"
run_discover "$repo" $'src/a.py\nuv.lock\nweb/package-lock.json\n.beads/issues.jsonl\ndist/app.min.js' tg1
assert_exit "exit 0" "$tg1_exit" "0"
assert_jq "only the hand-written file is in scope" "$tg1" '[.agents[].changed_files[]] | unique == ["src/a.py"]'
assert_jq "excluded files reported" "$tg1" '.configuration.excluded_files | length == 4'
assert_jq "dispatched reviewers are not listed as skipped" "$tg1" '.configuration.not_dispatched_no_files == []'
rm -rf "$repo"

echo
echo "=== Test G1b: each generated-file pattern, and only at a path boundary ==="
repo="$(make_temp_repo)"
run_discover "$repo" $'uv.lock\npoetry.lock\nPipfile.lock\nweb/package-lock.json\nweb/yarn.lock\npnpm-lock.yaml\nbun.lockb\nCargo.lock\ngo.sum\nGemfile.lock\ncomposer.lock\nflake.lock\ninfra/.terraform.lock.hcl\napp.min.css\napp.js.map\nsub/.beads/x.jsonl\nnotuv.lock\nsrc/go.sumx\nnotes.beads/x.md\nfoomap\nappxmin.js\nkeep.py' tg1b
assert_jq "all 16 generated paths excluded" "$tg1b" '.configuration.excluded_files | length == 16'
assert_jq "a name that only ends like one is kept" "$tg1b" '[.agents[0].changed_files[]] | sort == ["appxmin.js", "foomap", "keep.py", "notes.beads/x.md", "notuv.lock", "src/go.sumx"]'
rm -rf "$repo"

echo
echo "=== Test G2: a diff of only generated files spawns nobody ==="
repo="$(make_temp_repo)"
run_discover "$repo" $'uv.lock\n.beads/issues.jsonl' tg2
assert_exit "exit 0" "$tg2_exit" "0"
assert_jq "no agents" "$tg2" '.agents == []'
assert_jq "every default named as not dispatched" "$tg2" '.configuration.not_dispatched_no_files | length == 6'
rm -rf "$repo"

echo
echo "=== Test G2b: a Pi-routed reviewer with nothing to read is skipped, not unknown ==="
repo="$(make_temp_repo)"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Configuration

```json
{"pi": {"model": "deepseek/deepseek-chat", "agents": {"code-reviewer": true}}}
```
EOF
run_discover "$repo" $'uv.lock' tg2b
assert_exit "exit 0" "$tg2b_exit" "0"
assert_jq "not reported as an unknown Pi route" "$tg2b" '.configuration.pi_agents_unknown == []'
assert_jq "reported as not dispatched" "$tg2b" '.configuration.not_dispatched_no_files | index("code-reviewer") != null'
rm -rf "$repo"

echo
echo "=== Test G3: a truly empty diff still spawns defaults (bfd) ==="
repo="$(make_temp_repo)"
run_discover "$repo" "" tg3
assert_jq "defaults spawn" "$tg3" '.agents | length == 6'
rm -rf "$repo"

echo
echo "=== Test G4: --base diffs <ref>...HEAD with no PR ==="
repo="$(make_temp_repo)"
(
  cd "$repo"
  git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git branch -q base-ref
  mkdir -p src; echo x > src/a.py; echo y > uv.lock
  git add -A; git -c user.email=t@t -c user.name=t commit -q -m change
)
tg4=$(cd "$repo" && "$DISCOVER" --base base-ref 2>/dev/null); tg4_exit=$?
assert_exit "exit 0" "$tg4_exit" "0"
assert_jq "scope comes from the local diff" "$tg4" '[.agents[].changed_files[]] | unique == ["src/a.py"]'
assert_jq "lockfile excluded" "$tg4" '.configuration.excluded_files == ["uv.lock"]'
rm -rf "$repo"

echo
echo "=== Test R1: .reviewers/<name>.md is the spec, the H2 is the summary ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/.reviewers/bin" "$repo/svc/.reviewers"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
- [store-reviewer](#store-reviewer) - store invariants

# Agents

## store-reviewer

**Checks:** store invariants. **Spawn when:** the diff writes to the store.

## inline-reviewer

Reviews inline, the old way.

## spec-model-reviewer

**Checks:** a thing.

## Retired reviewers

These used to run.

## summary-model-reviewer

model: haiku
**Checks:** a thing.
EOF
printf 'verification: mutation\nFull store spec.\n' > "$repo/.reviewers/store-reviewer.md"
printf 'model: opus\nSpec body.\n' > "$repo/.reviewers/spec-model-reviewer.md"
printf 'model: opus\nSpec body.\n' > "$repo/.reviewers/summary-model-reviewer.md"
printf 'Nobody indexes me.\n' > "$repo/.reviewers/orphan-reviewer.md"
printf 'About this dir.\n' > "$repo/.reviewers/README.md"
cat > "$repo/svc/AGENT-REVIEWERS.md" <<'EOF'
# Agents

## svc-reviewer

**Checks:** the service.
EOF
printf 'Service spec.\n' > "$repo/svc/.reviewers/svc-reviewer.md"
run_discover "$repo" $'src/a.py\nsvc/b.py' tr1
assert_exit "exit 0" "$tr1_exit" "0"
assert_jq "spec file becomes instructions" "$tr1" '[.agents[] | select(.name=="store-reviewer") | .instructions] == ["verification: mutation\nFull store spec.\n"]'
assert_jq "H2 body becomes summary" "$tr1" '[.agents[] | select(.name=="store-reviewer") | .summary | contains("Spawn when")] == [true]'
assert_jq "spec path reported" "$tr1" '[.agents[] | select(.name=="store-reviewer") | .spec] == [".reviewers/store-reviewer.md"]'
assert_jq "bin reported when it exists" "$tr1" '[.agents[] | select(.name=="store-reviewer") | .bin] == [".reviewers/bin"]'
assert_jq "inline reviewer unchanged, no summary" "$tr1" '[.agents[] | select(.name=="inline-reviewer") | (.summary == null) and (.instructions | contains("the old way"))] == [true]'
assert_jq "model read from the spec when the summary has none" "$tr1" '[.agents[] | select(.name=="spec-model-reviewer") | .model] == ["opus"]'
assert_jq "the summary's model wins over the spec's" "$tr1" '[.agents[] | select(.name=="summary-model-reviewer") | .model] == ["haiku"]'
assert_jq "a subdirectory index reads its own .reviewers/" "$tr1" '[.agents[] | select(.name=="svc-reviewer") | {spec, instructions}] == [{"spec": "svc/.reviewers/svc-reviewer.md", "instructions": "Service spec.\n"}]'
assert_jq "no bin when the directory is absent" "$tr1" '[.agents[] | select(.name=="svc-reviewer") | has("bin")] == [false]'
assert_stderr_contains "a prose H2 under # Agents warns" "$tr1_err" "'## Retired reviewers' under # Agents"
assert_jq "until conversion, a file with no H2 does not run" "$tr1" '[.agents[] | select(.name=="orphan-reviewer")] == []'
assert_stderr_contains "and discovery says so" "$tr1_err" ".reviewers/orphan-reviewer.md has no '## orphan-reviewer' entry in an AGENT-REVIEWERS.md, so it does not run"
if [[ "$tr1_err" == *README* ]] || jq -e '.agents[] | select(.name=="README")' <<< "$tr1" >/dev/null; then
    echo "  FAIL  README.md is not a reviewer"; TESTS_FAILED=$((TESTS_FAILED + 1)); FAILED+=("README.md is not a reviewer")
else
    echo "  PASS  README.md is not a reviewer"; TESTS_PASSED=$((TESTS_PASSED + 1))
fi
assert_jq "a table of contents above the first H1 is not a section" "$tr1" '[.context[] | select(.content | contains("store invariants"))] == []'
rm -rf "$repo"

echo
echo "=== Test R2: a .reviewers/ directory with no AGENT-REVIEWERS.md ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/.reviewers" "$repo/svc/.reviewers"
cat > "$repo/.reviewers/store-reviewer.md" <<'EOF'
# store-reviewer
model: haiku
verification: mutation
**Checks:** store invariants.
**Spawn when:** the diff writes under `store/`.
**Contents:** [What to flag](#what-to-flag)

## What to flag

Partial writes.
EOF
printf '# svc-reviewer\n**Spawn when:** svc changes.\n' > "$repo/svc/.reviewers/svc-reviewer.md"
printf 'Roster notes for the orchestrator.\n' > "$repo/.reviewers/README.md"
printf '{"bots": {"gemini": false}}\n' > "$repo/.reviewers/config.json"
run_discover "$repo" $'src/a.py\nsvc/b.py' tr2
assert_exit "exit 0" "$tr2_exit" "0"
assert_jq "the file is the spec" "$tr2" '[.agents[] | select(.name=="store-reviewer") | .instructions | contains("Partial writes")] == [true]'
assert_jq "the summary is the first 12 lines" "$tr2" '[.agents[] | select(.name=="store-reviewer") | .summary | split("\n") | length] == [10]'
assert_jq "model: from the header" "$tr2" '[.agents[] | select(.name=="store-reviewer") | .model] == ["haiku"]'
assert_jq "kind user, root scope" "$tr2" '[.agents[] | select(.name=="store-reviewer") | {kind, scope}] == [{"kind": "user", "scope": "/"}]'
assert_jq "a subtree .reviewers/ scopes to its subtree" "$tr2" '[.agents[] | select(.name=="svc-reviewer") | {scope, changed_files}] == [{"scope": "/svc/", "changed_files": ["svc/b.py"]}]'
assert_jq "README.md is orchestrator context" "$tr2" '[.context[] | select(.source==".reviewers/README.md") | .content] == ["Roster notes for the orchestrator.\n"]'
assert_jq "the layout is reported" "$tr2" '.configuration.layout == "reviewers"'
assert_jq "no shipped default spawns: the roster is the files" "$tr2" '[.agents[].kind] | all(. == "user")'
assert_jq "no defaults pin to go stale" "$tr2" '.configuration.stale_pin == false'
assert_jq "no language-template offer when .reviewers/ exists" "$tr2" '.language_detection == null'
if [[ -n "$tr2_err" ]]; then
    echo "  FAIL  a well-formed roster warns about nothing: $tr2_err"; TESTS_FAILED=$((TESTS_FAILED + 1)); FAILED+=("well-formed roster is quiet")
else
    echo "  PASS  a well-formed roster warns about nothing"; TESTS_PASSED=$((TESTS_PASSED + 1))
fi
rm -rf "$repo"

echo
echo "=== Test R2b: 'disabled' in the .reviewers/ layout warns that it does nothing ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/.reviewers"
printf '# a-reviewer\n**Spawn when:** always.\n' > "$repo/.reviewers/a-reviewer.md"
printf '{"disabled": ["code-simplifier"]}\n' > "$repo/.reviewers/config.json"
run_discover "$repo" "src/a.py" tr2b
assert_stderr_contains "disabled is a no-op warning" "$tr2b_err" "'disabled' has no effect in the .reviewers/ layout"
rm -rf "$repo"

echo
echo "=== Test R3: config.json wins over a # Configuration block, with a warning ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/.reviewers"
printf '{"disabled": ["code-simplifier"]}\n' > "$repo/.reviewers/config.json"
cat > "$repo/AGENT-REVIEWERS.md" <<'EOF'
# Configuration

```json
{"disabled": ["pr-test-analyzer"]}
```
EOF
run_discover "$repo" "src/a.py" tr3
assert_jq "config.json read" "$tr3" '.configuration.disabled_defaults == ["code-simplifier"]'
assert_jq "a root AGENT-REVIEWERS.md keeps the legacy layout, defaults included" "$tr3" '.configuration.layout == "agent-reviewers" and ([.agents[] | select(.kind == "default")] | length > 0)'
assert_stderr_contains "both present warns" "$tr3_err" "only config.json is read"
printf '{"disabled": "nope"' > "$repo/.reviewers/config.json"
run_discover "$repo" "src/a.py" tr3b
assert_exit "a broken config.json stops discovery" "$tr3b_exit" "1"
assert_stderr_contains "and names the file" "$tr3b_err" ".reviewers/config.json is not valid JSON"
: > "$repo/.reviewers/config.json"
run_discover "$repo" "src/a.py" tr3c
assert_stderr_contains "an empty config.json warns" "$tr3c_err" "config.json is empty, so none of its settings apply"
rm -rf "$repo"

echo
echo "=== Test R4: a converted repo's root reviewers apply to every diff ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/.reviewers" "$repo/svc/.reviewers"
printf '# root-reviewer\n**Spawn when:** always.\n' > "$repo/.reviewers/root-reviewer.md"
printf 'root notes\n' > "$repo/.reviewers/README.md"
printf '# svc-reviewer\n**Spawn when:** svc.\n' > "$repo/svc/.reviewers/svc-reviewer.md"
printf 'svc notes\n' > "$repo/svc/.reviewers/README.md"
run_discover "$repo" "" tr4
assert_jq "an empty diff still finds the root reviewers" "$tr4" '[.agents[].name] == ["root-reviewer"]'
run_discover "$repo" $'uv.lock' tr4b
assert_jq "an all-generated diff spawns nobody" "$tr4b" '.agents == []'
assert_jq "and names the root reviewer as not dispatched" "$tr4b" '.configuration.not_dispatched_no_files == ["root-reviewer"]'
run_discover "$repo" $'a.py\nsvc/b.py' tr4c
assert_jq "every README is context, the nested one does not replace the root one" "$tr4c" '[.context[].content] | sort == ["root notes\n", "svc notes\n"]'
rm -rf "$repo"

echo
echo "=== Test R5: a root .reviewers/ with no reviewer files is not a converted repo ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/.reviewers"
printf 'notes\n' > "$repo/.reviewers/README.md"
run_discover "$repo" "a.py" tr5r
assert_jq "README.md alone is not a converted repo" "$tr5r" '.configuration.layout == "agent-reviewers"'
rm -rf "$repo"

repo="$(make_temp_repo)"
mkdir -p "$repo/.reviewers"
printf '{"bots": {"gemini": false}}\n' > "$repo/.reviewers/config.json"
run_discover "$repo" "a.py" tr5
assert_jq "legacy layout" "$tr5" '.configuration.layout == "agent-reviewers"'
assert_jq "so the shipped defaults still run" "$tr5" '[.agents[] | select(.kind == "default")] | length == 6'
rm -rf "$repo"

echo
echo "=== Test R6: a reviewer file over 100 lines needs a Contents line ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/.reviewers"
{ printf '# long-reviewer\n**Checks:** x.\n**Spawn when:** always.\n\n'; for i in $(seq 1 110); do echo "line $i"; done; } > "$repo/.reviewers/long-reviewer.md"
{ printf '# toc-reviewer\n**Checks:** x.\n**Spawn when:** always.\n**Contents:** A · B\n\n'; for i in $(seq 1 110); do echo "line $i"; done; } > "$repo/.reviewers/toc-reviewer.md"
run_discover "$repo" "a.py" tr6
assert_stderr_contains "a long file without Contents warns" "$tr6_err" ".reviewers/long-reviewer.md is over 100 lines with no 'Contents:' line"
if [[ "$tr6_err" == *toc-reviewer* ]]; then
    echo "  FAIL  a long file with Contents is quiet"; TESTS_FAILED=$((TESTS_FAILED + 1)); FAILED+=("long file with Contents quiet")
else
    echo "  PASS  a long file with Contents is quiet"; TESTS_PASSED=$((TESTS_PASSED + 1))
fi
rm -rf "$repo"

# ---------------------------------------------------------------------------
echo "=== Test S1: same-named subtree reviewer overrides only inside its subtree ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/.reviewers" "$repo/app/javascript/.reviewers"
printf '# test-coverage-reviewer\nRuby tests.\n' > "$repo/.reviewers/test-coverage-reviewer.md"
printf '# test-coverage-reviewer\nJS tests.\n' > "$repo/app/javascript/.reviewers/test-coverage-reviewer.md"
run_discover "$repo" $'app/models/game.rb\napp/javascript/dice.js' ts1
assert_exit "exit 0" "$ts1_exit" "0"
assert_jq "root copy keeps the Ruby file" "$ts1" '[.agents[] | select(.name == "test-coverage-reviewer" and .scope == "/") | .changed_files] == [["app/models/game.rb"]]'
assert_jq "subtree copy takes the JS file" "$ts1" '[.agents[] | select(.name == "test-coverage-reviewer" and .scope == "/app/javascript/") | .changed_files] == [["app/javascript/dice.js"]]'
run_discover "$repo" $'app/javascript/dice.js' ts1b
assert_jq "JS-only diff spawns only the subtree copy" "$ts1b" '[.agents[] | select(.name == "test-coverage-reviewer") | .scope] == ["/app/javascript/"]'
run_discover "$repo" $'app/models/game.rb' ts1c
assert_jq "Ruby-only diff spawns only the root copy" "$ts1c" '[.agents[] | select(.name == "test-coverage-reviewer") | .scope] == ["/"]'

echo "=== Test S2: a subtree override of a default replaces it only inside the subtree ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/app/javascript"
printf '# Agents\n\n## code-reviewer\nJS-only code review.\n' > "$repo/app/javascript/AGENT-REVIEWERS.md"
run_discover "$repo" $'app/models/a.rb\napp/javascript/b.js' ts2
assert_exit "exit 0" "$ts2_exit" "0"
assert_jq "default keeps the file outside the subtree" "$ts2" '[.agents[] | select(.name == "code-reviewer" and .kind == "default") | .changed_files] == [["app/models/a.rb"]]'
assert_jq "override takes the subtree file" "$ts2" '[.agents[] | select(.name == "code-reviewer" and .kind == "user-override") | .changed_files] == [["app/javascript/b.js"]]'
run_discover "$repo" $'app/javascript/b.js' ts2b
assert_jq "subtree-only diff: default dropped, override runs" "$ts2b" '[.agents[] | select(.name == "code-reviewer") | .kind] == ["user-override"]'

echo "=== Test S3: same default overridden at two scopes counts once ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/app/javascript"
printf '# Agents\n\n## code-reviewer\nRoot review.\n' > "$repo/AGENT-REVIEWERS.md"
printf '# Agents\n\n## code-reviewer\nJS review.\n' > "$repo/app/javascript/AGENT-REVIEWERS.md"
printf '# Agents\n\n## foo-reviewer\nRoot foo.\n' >> "$repo/AGENT-REVIEWERS.md"
printf '\n## foo-reviewer\nJS foo.\n' >> "$repo/app/javascript/AGENT-REVIEWERS.md"
run_discover "$repo" $'app/models/a.rb\napp/javascript/b.js' ts3
assert_jq "override_count == 1" "$ts3" '.configuration.override_count == 1'
assert_jq "overridden_default_names lists the name once" "$ts3" '.configuration.overridden_default_names == ["code-reviewer"]'
assert_jq "user_count counts foo-reviewer once" "$ts3" '.configuration.user_count == 1'
assert_jq "no default code-reviewer when root override claims the rest" "$ts3" '[.agents[] | select(.name == "code-reviewer") | .kind] == ["user-override", "user-override"]'

echo
echo "=== Per-user models.json chains ==="
repo="$(make_temp_repo)"
um="$(mktemp)"; TEMP_PATHS+=("$um")
printf '%s' '{"agents": {"*": ["zai/glm-5.1", "claude"], "code-simplifier": "claude:haiku", "comment-analyzer": false, "silent-failure-hunter": "zai/glm-5.1"}}' > "$um"
PR_REVIEW_LOOP_MODELS="$um" run_discover "$repo" "src/foo.py" um1
assert_exit "user models.json: exit 0" "$um1_exit" "0"
assert_jq "a user * chain routes an agent with no repo config to pi" "$um1" \
    '.agents[] | select(.name == "code-reviewer") | .engine == "pi" and .pi_models == ["zai/glm-5.1", "claude"]'
assert_jq "a named user chain beats *" "$um1" \
    '.agents[] | select(.name == "code-simplifier") | .engine == "claude" and .model == "haiku"'
assert_jq "a user false keeps that agent on claude" "$um1" \
    '.agents[] | select(.name == "comment-analyzer") | .engine == "claude" and .pi_models == null'
cat > "$repo/AGENT-REVIEWERS.md" <<'MD'
# Configuration

```json
{"defaults_version_checked": "99.0.0",
 "pi": {"model": "deepseek/deepseek-chat",
        "agents": {"code-reviewer": "google/gemini-2.5-flash", "pr-test-analyzer": false, "silent-failure-hunter": true}}}
```
MD
PR_REVIEW_LOOP_MODELS="$um" run_discover "$repo" "src/foo.py" um2
assert_jq "a repo chain beats the user chain" "$um2" \
    '.agents[] | select(.name == "code-reviewer") | .pi_models == ["google/gemini-2.5-flash"]'
assert_jq "a repo false beats the user chain" "$um2" \
    '.agents[] | select(.name == "pr-test-analyzer") | .engine == "claude"'
assert_jq "a repo true runs on the repo .pi.model, not the user chain" "$um2" \
    '.agents[] | select(.name == "silent-failure-hunter") | .pi_models == ["deepseek/deepseek-chat"]'
assert_jq "an agent the repo does not name still takes the user chain" "$um2" \
    '.agents[] | select(.name == "type-design-analyzer") | .pi_models == ["zai/glm-5.1", "claude"]'
printf '%s' '{"agents": {"*": ["zai/glm-5.1", "claude"]}}' > "$um"
cat > "$repo/AGENT-REVIEWERS.md" <<'MD'
# Configuration

```json
{"defaults_version_checked": "99.0.0", "pi": {"all": true, "model": "deepseek/deepseek-chat"}}
```
MD
PR_REVIEW_LOOP_MODELS="$um" run_discover "$repo" "src/foo.py" um4
assert_jq "a repo .pi.all runs every agent on the repo .pi.model, not the user chain" "$um4" \
    '[.agents[] | .pi_models] | all(. == ["deepseek/deepseek-chat"])'
for ok_file in '{}' '{"note": "x"}'; do
    printf '%s' "$ok_file" > "$um"
    PR_REVIEW_LOOP_MODELS="$um" run_discover "$repo" "src/foo.py" um5
    assert_exit "a user models.json with no agents key is valid: $ok_file" "$um5_exit" "0"
done
for bad in '{"agents": {"x": "a/b"}} {"agents": {"y": "a/c"}}' '{"agents": {"x": "glm"}}' '{"agents": {"x": []}}' '{"agents": {"x": "claude:gpt"}}' '{"agents": ["a/b"]}' '{"agents": false}' 'not json' '' ' '; do
    printf '%s' "$bad" > "$um"
    PR_REVIEW_LOOP_MODELS="$um" run_discover "$repo" "src/foo.py" um3
    assert_exit "invalid user models.json is an error: $bad" "$um3_exit" "1"
done
assert_stderr_contains "the error names the file" "$um3_err" "$um"
rm -f "$um"; mkdir "$um"
PR_REVIEW_LOOP_MODELS="$um" run_discover "$repo" "src/foo.py" um6
assert_exit "a directory where models.json belongs is an error, not a silent skip" "$um6_exit" "1"
rmdir "$um"

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
