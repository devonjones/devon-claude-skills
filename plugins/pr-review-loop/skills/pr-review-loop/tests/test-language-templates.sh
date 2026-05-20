#!/usr/bin/env bash
# Test harness for detect-language.sh and install-template.sh.
#
# Each test creates a temp fixture repo, runs the script(s) under test,
# and asserts the JSON output or filesystem state matches expectations.
#
# Usage: tests/test-language-templates.sh
# Exit code: 0 if all pass, 1 if any fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="$SCRIPT_DIR/../scripts/detect-language.sh"
INSTALL="$SCRIPT_DIR/../scripts/install-template.sh"

for s in "$DETECT" "$INSTALL"; do
    if [[ ! -x "$s" ]]; then
        echo "Error: $s not executable" >&2
        exit 2
    fi
done

TESTS_PASSED=0
TESTS_FAILED=0
FAILED=()

# ---------------------------------------------------------------------------
# Infrastructure
# ---------------------------------------------------------------------------

TEMP_PATHS=()
cleanup_temp_paths() {
    local p
    for p in "${TEMP_PATHS[@]}"; do
        [[ -n "$p" && -e "$p" ]] && rm -rf -- "$p"
    done
}
trap cleanup_temp_paths EXIT

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

assert_jq() {
    local name="$1" json="$2" expr="$3"
    local result
    result="$(echo "$json" | jq -e "$expr" 2>/dev/null || true)"
    if [[ "$result" == "true" ]]; then
        echo "  PASS  $name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL  $name"
        echo "        expected: $expr"
        echo "        actual JSON (first 400 chars):"
        echo "          $(echo "$json" | head -c 400)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED+=("$name")
    fi
}

assert_exit() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS  $name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL  $name (exit was $actual, expected $expected)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED+=("$name")
    fi
}

assert_file_exists() {
    local name="$1" path="$2"
    if [[ -f "$path" ]]; then
        echo "  PASS  $name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL  $name (missing file: $path)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED+=("$name")
    fi
}

assert_file_grep() {
    local name="$1" path="$2" pattern="$3"
    if [[ -f "$path" ]] && grep -qE "$pattern" "$path"; then
        echo "  PASS  $name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL  $name (pattern '$pattern' not in $path)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED+=("$name")
    fi
}

assert_file_not_grep() {
    local name="$1" path="$2" pattern="$3"
    if [[ -f "$path" ]] && ! grep -qE "$pattern" "$path"; then
        echo "  PASS  $name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL  $name (pattern '$pattern' should NOT be in $path)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED+=("$name")
    fi
}

run_detect() {
    local repo="$1" out_var="$2"
    local out exit_code=0
    out="$("$DETECT" --repo-root "$repo" 2>/dev/null)" || exit_code=$?
    printf -v "$out_var" '%s' "$out"
    printf -v "${out_var}_exit" '%s' "$exit_code"
}

run_install() {
    local repo="$1" out_var="$2"
    shift 2
    local stdout_file stderr_file
    stdout_file="$(mktemp)"; stderr_file="$(mktemp)"
    TEMP_PATHS+=("$stdout_file" "$stderr_file")
    local exit_code=0
    "$INSTALL" --repo-root "$repo" "$@" >"$stdout_file" 2>"$stderr_file" || exit_code=$?
    printf -v "$out_var" '%s' "$(cat "$stdout_file")"
    printf -v "${out_var}_err" '%s' "$(cat "$stderr_file")"
    printf -v "${out_var}_exit" '%s' "$exit_code"
}

# ---------------------------------------------------------------------------
# detect-language.sh tests
# ---------------------------------------------------------------------------

echo
echo "=== Test D1: empty repo -> empty list ==="
repo="$(make_temp_repo)"
run_detect "$repo" d1
assert_exit "exit 0" "$d1_exit" "0"
assert_jq "empty array" "$d1" '. == []'

echo
echo "=== Test D2: go.mod at root -> single golang entry ==="
repo="$(make_temp_repo)"
touch "$repo/go.mod"
run_detect "$repo" d2
assert_jq "one entry" "$d2" 'length == 1'
assert_jq "golang at root" "$d2" '.[0] == {language:"golang", subtree:".", manifest:"go.mod"}'

echo
echo "=== Test D3: pyproject.toml at root -> single python entry ==="
repo="$(make_temp_repo)"
touch "$repo/pyproject.toml"
run_detect "$repo" d3
assert_jq "one entry" "$d3" 'length == 1'
assert_jq "python at root" "$d3" '.[0] == {language:"python", subtree:".", manifest:"pyproject.toml"}'

echo
echo "=== Test D4: same dir has pyproject + setup + requirements -> canonical wins ==="
repo="$(make_temp_repo)"
touch "$repo/pyproject.toml" "$repo/setup.py" "$repo/requirements.txt"
run_detect "$repo" d4
assert_jq "one entry only" "$d4" 'length == 1'
assert_jq "pyproject.toml chosen" "$d4" '.[0].manifest == "pyproject.toml"'

echo
echo "=== Test D5: per-subtree polyglot (go in backend, python in frontend) ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/backend" "$repo/frontend"
touch "$repo/backend/go.mod" "$repo/frontend/pyproject.toml"
run_detect "$repo" d5
assert_jq "two entries" "$d5" 'length == 2'
assert_jq "golang in backend" "$d5" 'any(. == {language:"golang", subtree:"backend", manifest:"go.mod"})'
assert_jq "python in frontend" "$d5" 'any(. == {language:"python", subtree:"frontend", manifest:"pyproject.toml"})'

echo
echo "=== Test D6: same-directory polyglot (go.mod + pyproject.toml in same dir) ==="
repo="$(make_temp_repo)"
touch "$repo/go.mod" "$repo/pyproject.toml"
run_detect "$repo" d6
assert_jq "two entries" "$d6" 'length == 2'
assert_jq "both at root" "$d6" 'all(.subtree == ".")'
assert_jq "one golang, one python" "$d6" '[.[] | .language] | sort == ["golang","python"]'

echo
echo "=== Test D7: Go workspace (two go.mods in different subdirs) ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/cmd/foo" "$repo/cmd/bar"
touch "$repo/cmd/foo/go.mod" "$repo/cmd/bar/go.mod"
run_detect "$repo" d7
assert_jq "two entries" "$d7" 'length == 2'
assert_jq "both golang" "$d7" 'all(.language == "golang")'
assert_jq "distinct subtrees" "$d7" '[.[] | .subtree] | sort == ["cmd/bar","cmd/foo"]'

echo
echo "=== Test D8: excluded dirs are pruned (node_modules with go.mod ignored) ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/node_modules/some-pkg"
touch "$repo/node_modules/some-pkg/go.mod"
run_detect "$repo" d8
assert_jq "no entries (node_modules pruned)" "$d8" '. == []'

# ---------------------------------------------------------------------------
# install-template.sh tests
# ---------------------------------------------------------------------------

echo
echo "=== Test I1: single golang:. installs full file at root ==="
repo="$(make_temp_repo)"
run_install "$repo" i1 golang:.
assert_exit "exit 0" "$i1_exit" "0"
assert_file_exists "root file created" "$repo/AGENT-REVIEWERS.md"
assert_file_grep "has # Configuration" "$repo/AGENT-REVIEWERS.md" '^# Configuration'
assert_file_grep "has # Agents" "$repo/AGENT-REVIEWERS.md" '^# Agents'
assert_file_grep "has # Guidelines" "$repo/AGENT-REVIEWERS.md" '^# Guidelines'
assert_file_grep "version pin present" "$repo/AGENT-REVIEWERS.md" 'defaults_version_checked'

echo
echo "=== Test I2: per-subtree polyglot creates 3 files (2 subtree + 1 root config) ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/backend" "$repo/frontend"
run_install "$repo" i2 golang:backend python:frontend
assert_exit "exit 0" "$i2_exit" "0"
assert_file_exists "backend file" "$repo/backend/AGENT-REVIEWERS.md"
assert_file_exists "frontend file" "$repo/frontend/AGENT-REVIEWERS.md"
assert_file_exists "root config file" "$repo/AGENT-REVIEWERS.md"
assert_file_not_grep "subtree backend has NO # Configuration" "$repo/backend/AGENT-REVIEWERS.md" '^# Configuration'
assert_file_not_grep "subtree frontend has NO # Configuration" "$repo/frontend/AGENT-REVIEWERS.md" '^# Configuration'
assert_file_grep "root has # Configuration" "$repo/AGENT-REVIEWERS.md" '^# Configuration'
assert_file_not_grep "root has NO # Agents" "$repo/AGENT-REVIEWERS.md" '^# Agents'

echo
echo "=== Test I3: merged config has union of disabled defaults ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/backend" "$repo/frontend"
run_install "$repo" i3 golang:backend python:frontend
root_json="$(awk '/^```json$/,/^```$/' "$repo/AGENT-REVIEWERS.md" | sed '1d;$d')"
assert_jq "3 disabled (both packs disable the same 3)" "$root_json" '.disabled | length == 3'
assert_jq "disabled list sorted" "$root_json" '.disabled == (.disabled | sort)'

echo
echo "=== Test I4: merged config concatenates same-key overlap reasons with ' | ' ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/backend" "$repo/frontend"
run_install "$repo" i4 golang:backend python:frontend
root_json="$(awk '/^```json$/,/^```$/' "$repo/AGENT-REVIEWERS.md" | sed '1d;$d')"
assert_jq "overlap key present" "$root_json" '.overlap_acknowledged | has("test-coverage-reviewer")'
assert_jq "overlap reason contains ' | ' separator" "$root_json" '.overlap_acknowledged["test-coverage-reviewer"].reason | contains(" | ")'

echo
echo "=== Test I5: refuse to overwrite existing root file ==="
repo="$(make_temp_repo)"
echo "existing" > "$repo/AGENT-REVIEWERS.md"
mkdir -p "$repo/backend"
run_install "$repo" i5 golang:backend
assert_exit "exit 1 (refused)" "$i5_exit" "1"

echo
echo "=== Test I6: refuse to overwrite existing subtree file ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/backend"
echo "existing" > "$repo/backend/AGENT-REVIEWERS.md"
run_install "$repo" i6 golang:backend
assert_exit "exit 1 (refused)" "$i6_exit" "1"

echo
echo "=== Test I7: refuse same-directory polyglot (two packs at same subtree) ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/backend"
run_install "$repo" i7 golang:backend python:backend
assert_exit "exit 1 (refused)" "$i7_exit" "1"

echo
echo "=== Test I8: unknown language -> error ==="
repo="$(make_temp_repo)"
run_install "$repo" i8 rust:.
assert_exit "exit 2 (no such template)" "$i8_exit" "2"

echo
echo "=== Test I9: missing subtree dir -> error ==="
repo="$(make_temp_repo)"
run_install "$repo" i9 golang:no-such-dir
assert_exit "exit 2 (subtree doesn't exist)" "$i9_exit" "2"

echo
echo
echo "=== Test I_T1: lang with slash → exit 2 (path-traversal guard) ==="
repo="$(make_temp_repo)"
run_install "$repo" iT1 "foo/bar:."
assert_exit "exit 2" "$iT1_exit" "2"
rm -rf "$repo"

echo
echo "=== Test I_T2: subtree with '..' → exit 2 ==="
repo="$(make_temp_repo)"
run_install "$repo" iT2 "golang:../escape"
assert_exit "exit 2" "$iT2_exit" "2"
rm -rf "$repo"

echo
echo "=== Test I_T3: absolute subtree path → exit 2 ==="
repo="$(make_temp_repo)"
run_install "$repo" iT3 "golang:/etc"
assert_exit "exit 2" "$iT3_exit" "2"
rm -rf "$repo"

echo
echo "=== Test I_T4: subtree with embedded '..' segment → exit 2 ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/sub"
run_install "$repo" iT4 "golang:sub/../escape"
assert_exit "exit 2" "$iT4_exit" "2"
rm -rf "$repo"

echo
echo "=== Test I10: install pins defaults_version_checked to plugin version ==="
repo="$(make_temp_repo)"
run_install "$repo" i10 golang:.
plugin_version="$(jq -r '.version' "$SCRIPT_DIR/../../../.claude-plugin/plugin.json")"
root_json="$(awk '/^```json$/,/^```$/' "$repo/AGENT-REVIEWERS.md" | sed '1d;$d')"
assert_jq "version pinned to plugin.json value" "$root_json" ".defaults_version_checked == \"$plugin_version\""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
echo "=================================================================="
echo "  Passed: $TESTS_PASSED / $((TESTS_PASSED + TESTS_FAILED))"
if [[ $TESTS_FAILED -gt 0 ]]; then
    echo "  Failed: $TESTS_FAILED"
    for name in "${FAILED[@]}"; do
        echo "    - $name"
    done
    exit 1
fi
echo
echo "All tests passed."
