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
    # An EXIT trap whose last command fails takes the script's exit status with
    # it: without this the suite reported failure on a clean run (the last path
    # is usually already gone, so the `&&` returns 1).
    return 0
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

# Counts H2 agent headings under # Agents in a fence-aware way, then asserts the
# total matches expected. Counts inside awk's END (no `wc -l`, which adds leading
# spaces on BSD/macOS). Flexible H1/H2 matching (`#[[:space:]]+`) mirrors
# install-template.sh's own parser. Missing file → FAIL line, not suite abort,
# without using `|| true` (which would mask awk failures into false PASS at
# expected=0).
assert_agent_count() {
    local name="$1" path="$2" expected="$3"
    if [[ ! -f "$path" ]]; then
        echo "  FAIL  $name (missing file: $path)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED+=("$name")
        return
    fi
    local actual
    actual="$(awk '
        BEGIN { f=0; in_fence=0; count=0 }
        /^```/ { in_fence = !in_fence; next }
        !in_fence && /^#[[:space:]]+/ {
            h=$0; sub(/^#[[:space:]]+/, "", h); sub(/[[:space:]]+$/, "", h)
            f=(h=="Agents"); next
        }
        f && !in_fence && /^##[[:space:]]+/ { count++ }
        END { print count }
    ' "$path")"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS  $name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL  $name (got $actual, expected $expected)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED+=("$name")
    fi
}

# The pack's reviewer files all landed in .reviewers/ (starters and README aside).
assert_reviewer_files() {
    local name="$1" repo="$2" lang="$3" expected="$4" actual=0 f
    for f in "$SCRIPT_DIR/../../../agent-reviewer-templates/$lang"/*.md; do
        [[ "$(basename "$f")" == README.md ]] && continue
        [[ -f "$repo/.reviewers/$(basename "$f")" ]] && actual=$((actual + 1))
    done
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS  $name"; TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL  $name (got $actual, expected $expected)"; TESTS_FAILED=$((TESTS_FAILED + 1)); FAILED+=("$name")
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
echo "=== Test I1: golang:. installs its reviewers and starters into .reviewers/ ==="
repo="$(make_temp_repo)"
run_install "$repo" i1 golang:.
assert_exit "exit 0" "$i1_exit" "0"
assert_file_exists "a pack reviewer" "$repo/.reviewers/error-handling-reviewer.md"
assert_file_exists "the pack README" "$repo/.reviewers/README.md"
assert_file_exists "a starter the pack keeps" "$repo/.reviewers/code-reviewer.md"
if [[ -e "$repo/.reviewers/silent-failure-hunter.md" ]]; then
    echo "  FAIL  starter the pack disabled was copied"; TESTS_FAILED=$((TESTS_FAILED + 1)); FAILED+=("disabled starter skipped")
else
    echo "  PASS  starter the pack disabled is not copied"; TESTS_PASSED=$((TESTS_PASSED + 1))
fi
if [[ -e "$repo/AGENT-REVIEWERS.md" ]]; then
    echo "  FAIL  no AGENT-REVIEWERS.md written"; TESTS_FAILED=$((TESTS_FAILED + 1)); FAILED+=("no AGENT-REVIEWERS.md")
else
    echo "  PASS  no AGENT-REVIEWERS.md written"; TESTS_PASSED=$((TESTS_PASSED + 1))
fi
assert_file_grep "reviewer header has a Spawn when line" "$repo/.reviewers/error-handling-reviewer.md" '^\*\*Spawn when:\*\*'
assert_file_not_grep "installed headers carry no TODO" "$repo/.reviewers/error-handling-reviewer.md" '^\*\*(Checks|Spawn when):\*\* TODO'
d1="$(cd "$repo" && PR_REVIEW_LOOP_TEST_CHANGED_FILES="main.go" "$SCRIPT_DIR/../scripts/discover-agents.sh" 0 2>/dev/null)"
assert_jq "discovery reads it as the .reviewers layout" "$d1" '.configuration.layout == "reviewers"'
assert_jq "discovery spawns pack reviewers and starters, no built-in defaults" "$d1" '[.agents[].kind] | all(. == "user")'

echo
echo "=== Test I2: per-subtree polyglot installs beside each subtree ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/backend" "$repo/frontend"
run_install "$repo" i2 golang:backend python:frontend
assert_exit "exit 0" "$i2_exit" "0"
assert_file_exists "backend reviewer" "$repo/backend/.reviewers/error-handling-reviewer.md"
assert_file_exists "frontend reviewer" "$repo/frontend/.reviewers/importlib-resources-reviewer.md"
assert_file_exists "starters at the root" "$repo/.reviewers/code-reviewer.md"
assert_file_exists "merged config at the root" "$repo/.reviewers/config.json"

echo
echo "=== Test I3: merged config drops what no longer applies ==="
assert_jq "no disabled list" "$(cat "$repo/.reviewers/config.json")" 'has("disabled") | not'
assert_jq "no defaults pin" "$(cat "$repo/.reviewers/config.json")" 'has("defaults_version_checked") | not'

echo
echo "=== Test I4: merged config concatenates same-key overlap reasons with ' | ' ==="
root_json="$(cat "$repo/.reviewers/config.json")"
assert_jq "overlap key present" "$root_json" '.overlap_acknowledged | has("test-coverage-reviewer")'
assert_jq "overlap reason contains ' | ' separator" "$root_json" '.overlap_acknowledged["test-coverage-reviewer"].reason | contains(" | ")'

echo
echo "=== Test I4b: a second pack joins an installed one ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/backend" "$repo/infra"
run_install "$repo" i4b golang:backend
jq '. + {bots: {gemini: false}}' "$repo/.reviewers/config.json" > "$repo/cfg.tmp" && mv -f "$repo/cfg.tmp" "$repo/.reviewers/config.json"
run_install "$repo" i4c terraform:infra
assert_exit "second install exit 0" "$i4c_exit" "0"
assert_file_exists "second pack's reviewers installed" "$repo/infra/.reviewers/lifecycle-reviewer.md"
assert_jq "config.json still holds the first pack's settings" "$(cat "$repo/.reviewers/config.json")" '.overlap_acknowledged | has("test-coverage-reviewer")'
assert_jq "and the user's own settings" "$(cat "$repo/.reviewers/config.json")" '.bots.gemini == false'

echo
echo "=== Test I4d: a second pack with settings merges into the user's config.json ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/backend" "$repo/frontend"
run_install "$repo" i4d golang:backend
printf '{"bots": {"gemini": false}}\n' > "$repo/.reviewers/config.json"
run_install "$repo" i4e python:frontend
assert_exit "exit 0" "$i4e_exit" "0"
assert_jq "the user's setting survives" "$(cat "$repo/.reviewers/config.json")" '.bots.gemini == false'
assert_jq "and the pack's overlap is merged in" "$(cat "$repo/.reviewers/config.json")" '.overlap_acknowledged | has("test-coverage-reviewer")'

echo
echo "=== Test I_T5: a bare '..' subtree is refused ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/sub"
run_install "$repo/sub" iT5 "golang:.."
assert_exit "exit 2" "$iT5_exit" "2"

echo
echo "=== Test I5: refuse a repo still on AGENT-REVIEWERS.md ==="
repo="$(make_temp_repo)"
echo "existing" > "$repo/AGENT-REVIEWERS.md"
mkdir -p "$repo/backend"
run_install "$repo" i5 golang:backend
assert_exit "exit 1 (refused)" "$i5_exit" "1"

echo
echo "=== Test I6: refuse to overwrite an existing reviewer file, writing nothing ==="
repo="$(make_temp_repo)"
mkdir -p "$repo/backend/.reviewers"
echo "mine" > "$repo/backend/.reviewers/error-handling-reviewer.md"
run_install "$repo" i6 golang:backend
assert_exit "exit 1 (refused)" "$i6_exit" "1"
assert_file_grep "existing file untouched" "$repo/backend/.reviewers/error-handling-reviewer.md" '^mine$'
if [[ -e "$repo/.reviewers" || -e "$repo/backend/.reviewers/dead-code-reviewer.md" ]]; then
    echo "  FAIL  nothing else written"; TESTS_FAILED=$((TESTS_FAILED + 1)); FAILED+=("transactional refuse")
else
    echo "  PASS  nothing else written"; TESTS_PASSED=$((TESTS_PASSED + 1))
fi

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
echo
echo
echo "=== Test D9: terraform detected via main.tf ==="
repo="$(make_temp_repo)"
echo 'terraform { required_version = ">= 1.0" }' > "$repo/main.tf"
run_detect "$repo" d9
assert_jq "one match" "$d9" 'length == 1'
assert_jq "terraform at root with main.tf" "$d9" '.[0] == {language:"terraform", subtree:".", manifest:"main.tf"}'
rm -rf "$repo"

echo
echo "=== Test D10: terraform detected via versions.tf even without main.tf ==="
repo="$(make_temp_repo)"
echo 'terraform { required_version = ">= 1.0" }' > "$repo/versions.tf"
run_detect "$repo" d10
assert_jq "terraform via versions.tf" "$d10" '.[0].manifest == "versions.tf"'
rm -rf "$repo"

echo
echo "=== Test D11: rails detected via Gemfile with gem \"rails\" ==="
repo="$(make_temp_repo)"
cat > "$repo/Gemfile" <<'EOF'
source 'https://rubygems.org'
gem "rails", "~> 7.1"
EOF
run_detect "$repo" d11
assert_jq "one rails match" "$d11" 'length == 1 and .[0] == {language:"rails", subtree:".", manifest:"Gemfile"}'
rm -rf "$repo"

echo
echo "=== Test D12: Gemfile without rails does NOT detect as rails (Sinatra-style) ==="
repo="$(make_temp_repo)"
cat > "$repo/Gemfile" <<'EOF'
source 'https://rubygems.org'
gem "sinatra"
gem "puma"
EOF
run_detect "$repo" d12
assert_jq "no matches" "$d12" '. == []'
rm -rf "$repo"

echo
echo "=== Test D13: javascript detected via package.json ==="
repo="$(make_temp_repo)"
echo '{"name":"test","version":"1.0.0"}' > "$repo/package.json"
run_detect "$repo" d13
assert_jq "javascript match" "$d13" '.[0] == {language:"javascript", subtree:".", manifest:"package.json"}'
rm -rf "$repo"

echo
echo "=== Test D14: per-subtree polyglot — python at root + terraform in /terraform/ ==="
repo="$(make_temp_repo)"
touch "$repo/pyproject.toml"
mkdir -p "$repo/terraform"
echo 'terraform { required_version = ">= 1.0" }' > "$repo/terraform/main.tf"
run_detect "$repo" d14
assert_jq "two matches" "$d14" 'length == 2'
assert_jq "python at root" "$d14" 'any(. == {language:"python", subtree:".", manifest:"pyproject.toml"})'
assert_jq "terraform at terraform/" "$d14" 'any(. == {language:"terraform", subtree:"terraform", manifest:"main.tf"})'
rm -rf "$repo"

echo
echo "=== Test I_FA3: rails.md installs all 8 reviewers (fence-aware regression) ==="
repo="$(make_temp_repo)"
run_install "$repo" iFA3 rails:.
assert_reviewer_files "rails installs all 8 reviewers" "$repo" rails 8
rm -rf "$repo"

echo
echo "=== Test I_FA4: terraform.md installs all 7 reviewers ==="
repo="$(make_temp_repo)"
run_install "$repo" iFA4 terraform:.
assert_reviewer_files "terraform installs all 7 reviewers" "$repo" terraform 7
rm -rf "$repo"

echo
echo "=== Test I_FA5: javascript.md installs all 7 reviewers ==="
repo="$(make_temp_repo)"
run_install "$repo" iFA5 javascript:.
assert_reviewer_files "javascript installs all 7 reviewers" "$repo" javascript 7
rm -rf "$repo"

echo
echo "=== Test I_FA1: fence-aware extract — python.md installs all 13 reviewers (regression for latent PR #25 bug) ==="
repo="$(make_temp_repo)"
run_install "$repo" iFA1 python:.
# Counts agents under # Agents H1 ONLY, fence-aware (don't be fooled by # BAD/# GOOD in code blocks)
assert_reviewer_files "python installs all 13 reviewers" "$repo" python 13
rm -rf "$repo"

echo
echo "=== Test I_FA2: fence-aware extract — golang.md installs all 8 reviewers ==="
repo="$(make_temp_repo)"
run_install "$repo" iFA2 golang:.
assert_reviewer_files "golang installs all 8 reviewers" "$repo" golang 8
rm -rf "$repo"

echo
echo "=== Test I10: every shipped reviewer file has a usable header ==="
for f in "$SCRIPT_DIR/../../../agent-reviewer-templates"/*/*.md; do
    [[ "$(basename "$f")" == README.md ]] && continue
    h="$(head -n 12 "$f")"
    n="${f#"$SCRIPT_DIR/../../../agent-reviewer-templates/"}"
    if grep -qE '^\*\*Checks:\*\* .' <<< "$h" && grep -qE '^\*\*Spawn when:\*\* .' <<< "$h" \
        && ! grep -qE '^\*\*(Checks|Spawn when):\*\* TODO' <<< "$h" && [[ "$(sed -n 1p <<< "$h")" == "# $(basename "$f" .md)" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "  FAIL  $n header"; TESTS_FAILED=$((TESTS_FAILED + 1)); FAILED+=("$n header")
    fi
done
for f in "$SCRIPT_DIR/../../../agent-reviewer-templates"/*/*.md "$SCRIPT_DIR/../../../agents"/*.md; do
    n="${f#"$SCRIPT_DIR/../../../"}"
    if [[ "$(wc -l < "$f")" -gt 100 ]] && ! head -n 12 "$f" | grep -q '^\*\*Contents:\*\*'; then
        echo "  FAIL  $n is over 100 lines with no Contents line"; TESTS_FAILED=$((TESTS_FAILED + 1)); FAILED+=("$n contents")
    fi
done
echo "  checked template headers"

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
