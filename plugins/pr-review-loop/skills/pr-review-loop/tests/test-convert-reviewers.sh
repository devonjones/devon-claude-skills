#!/usr/bin/env bash
# convert-reviewers.py on a fixture repo, checked against what discover-agents.sh
# reported before the conversion.
#
# Usage: tests/test-convert-reviewers.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONVERT="$SCRIPT_DIR/../scripts/convert-reviewers.py"
DISCOVER="$SCRIPT_DIR/../scripts/discover-agents.sh"
T="$(mktemp -d)"; trap 'rm -rf -- "$T"' EXIT
PASSED=0; FAILED=0
ok(){ PASSED=$((PASSED+1)); echo "  PASS: $1"; }
bad(){ FAILED=$((FAILED+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

fixture(){
  rm -rf "$T/r"; mkdir -p "$T/r/.reviewers" "$T/r/svc"; cd "$T/r"; git init -q
  cat > AGENT-REVIEWERS.md <<'EOF'
# Configuration

```json
{"defaults_version_checked": "1.8.0", "disabled": ["code-simplifier"], "bots": {"gemini": false}}
```

# Agents

## inline-reviewer

model: haiku
verification: mutation
Flags the inline things.

### What to flag

Things.

### Do not flag

Other things.

## indexed-reviewer

**What it checks:** the indexed things.
**When to spawn:** the diff touches `idx/`.

Read `.reviewers/indexed-reviewer.md` and follow it as your complete review specification.

## Retired reviewers

old-reviewer was retired.

# Guidelines

Use parameterized queries.
EOF
  printf 'verification: judgement\nThe indexed spec body.\n' > .reviewers/indexed-reviewer.md
  printf 'Nobody indexed this one.\n' > .reviewers/stray-reviewer.md
  cat > svc/AGENT-REVIEWERS.md <<'EOF'
# Agents

## svc-reviewer

Service rules.
EOF
  git add -A; git -c user.email=t@t -c user.name=t commit -qm base
  PR_REVIEW_LOOP_TEST_CHANGED_FILES="$(git ls-files)" "$DISCOVER" 0 > "$T/before.json" 2>/dev/null
}

echo "=== dry run changes nothing ==="
fixture
OUT="$(python3 "$CONVERT" repo)"
check "prints the plan" '[[ "$OUT" == *"write  .reviewers/inline-reviewer.md"* && "$OUT" == *"remove AGENT-REVIEWERS.md"* ]]'
check "tree untouched" '[[ -z "$(git status --porcelain)" ]]'
check "names the defaults that ran before" '[[ "$OUT" == *"code-reviewer"* && "$OUT" != *"starters: "*"code-simplifier"* ]]'
check "flags the unindexed spec that will start running" '[[ "$OUT" == *"stray-reviewer.md has no index entry"* ]]'
check "flags the prose H2" '[[ "$OUT" == *"moved '"'"'## Retired reviewers'"'"' to README.md"* ]]'

echo "=== --write converts ==="
python3 "$CONVERT" repo --write >/dev/null
check "indexes removed" '[[ ! -e AGENT-REVIEWERS.md && ! -e svc/AGENT-REVIEWERS.md ]]'
H="$(head -n 12 .reviewers/inline-reviewer.md)"
check "header: title, model, verification first" '[[ "$(sed -n 1,3p <<< "$H")" == $'"'"'# inline-reviewer\nmodel: haiku\nverification: mutation'"'"' ]]'
check "header: contents from the spec's sections" '[[ "$H" == *"**Contents:** What to flag · Do not flag"* ]]'
check "header: TODO where the source had no checks/spawn text" '[[ "$H" == *"**Spawn when:** TODO"* ]]'
check "model line not left in the body" '[[ "$(grep -c "^model:" .reviewers/inline-reviewer.md)" == 1 ]]'
H="$(head -n 12 .reviewers/indexed-reviewer.md)"
check "index text becomes Checks / Spawn when" '[[ "$H" == *"**Checks:** the indexed things."* && "$H" == *"**Spawn when:** the diff touches \`idx/\`."* ]]'
check "pointer line dropped" '! grep -q "Read \`.reviewers" .reviewers/indexed-reviewer.md'
check "existing spec body kept" 'grep -q "The indexed spec body." .reviewers/indexed-reviewer.md'
check "subtree index converts beside itself" '[[ -f svc/.reviewers/svc-reviewer.md ]]'
check "prose H2 and other H1s go to README.md" 'grep -q "old-reviewer was retired" .reviewers/README.md && grep -q "parameterized queries" .reviewers/README.md'
check "config.json keeps what still applies" '[[ "$(jq -c . .reviewers/config.json)" == "{\"bots\":{\"gemini\":false}}" ]]'

PR_REVIEW_LOOP_TEST_CHANGED_FILES="$(git ls-files; find .reviewers svc -type f)" "$DISCOVER" 0 > "$T/after.json" 2>"$T/after.err"
check "discovery sees the new layout" '[[ "$(jq -r .configuration.layout "$T/after.json")" == reviewers ]]'
check "same reviewers, same models (minus the prose H2)" \
  '[[ "$(jq -r ".agents[] | select(.kind != \"default\") | select(.name != \"Retired reviewers\") | \"\(.name) \(.model)\"" "$T/before.json" | sort)" == "$(jq -r ".agents[] | \"\(.name) \(.model)\"" "$T/after.json" | sort)" ]]'
check "spec text survives" '[[ "$(jq -r ".agents[] | select(.name==\"inline-reviewer\") | .instructions" "$T/after.json")" == *"Flags the inline things."*"Other things."* ]]'
check "TODO headers are reported" 'grep -q "inline-reviewer.md has a TODO in its header" "$T/after.err"'

echo "=== starters ==="
rm -rf "$T/s"; mkdir -p "$T/s"
check "lists starters with no names" '[[ "$(python3 "$CONVERT" starters)" == *"silent-failure-hunter: "* ]]'
python3 "$CONVERT" starters --into "$T/s" silent-failure-hunter >/dev/null
H="$(head -n 12 "$T/s/.reviewers/silent-failure-hunter.md")"
check "starter header has its model and checks" '[[ "$H" == *"model: sonnet"* && "$H" != *"**Checks:** TODO"* ]]'
check "starter header has no frontmatter" '! grep -q "^color:" "$T/s/.reviewers/silent-failure-hunter.md"'
set +e; python3 "$CONVERT" starters --into "$T/s" silent-failure-hunter >/dev/null 2>&1; rc=$?; set -e
check "refuses to overwrite a starter" '[[ $rc -ne 0 ]]'

echo ""; echo "Passed: $PASSED  Failed: $FAILED"; [[ "$FAILED" -eq 0 ]]
