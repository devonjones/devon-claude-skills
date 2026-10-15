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
Intro prose above every heading.

# Configuration

```json
{"defaults_version_checked": "1.8.0", "disabled": ["code-simplifier"], "bots": {"gemini": false}}
```

The bots are off because this repo has no Gemini quota.

# Agents

## inline-reviewer

model: haiku
verification: mutation
**Checks:** the inline things.
Flags the inline things.

### What to flag

Things.

### Do not flag

Other things.

## indexed-reviewer

**What it checks:** the indexed things.
**When to spawn:** the diff touches `idx/`.

Read `.reviewers/indexed-reviewer.md` and follow it as your complete review specification.

## wrapped-reviewer

**Checks:** that the router cannot feed itself. No subscription may
target `actions`; fan-out stays bounded
**Spawn when:** PR touches `subscriptions.py` or
adds an enqueue target.
Body line one.

### Flag

1. **`# type: ignore` without a reason:** x
2. **Bare `except:`** y
3. **Plain title: detail** z

## wrapped-indexed

**What it checks:** wrapped index text that
continues here.
**When to spawn:** the diff touches
`wi/`.

Read `.reviewers/wrapped-indexed.md` and follow it as your complete review specification.

## my_pci_auditor

Underscore name, still a reviewer.

## Retired reviewers

old-reviewer was retired.

# Guidelines

Use parameterized queries.
EOF
  printf 'verification: judgement\nThe indexed spec body.\n' > .reviewers/indexed-reviewer.md
  printf 'Indexed body.\n' > .reviewers/wrapped-indexed.md
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
check "notes a non-kebab name that still runs" '[[ "$OUT" == *"'"'"'my_pci_auditor'"'"' is not kebab-case"* ]]'
check "flags the prose H2" '[[ "$OUT" == *"moved '"'"'## Retired reviewers'"'"' to README.md"* ]]'

echo "=== --write converts ==="
python3 "$CONVERT" repo --write >/dev/null
check "indexes removed" '[[ ! -e AGENT-REVIEWERS.md && ! -e svc/AGENT-REVIEWERS.md ]]'
H="$(head -n 12 .reviewers/inline-reviewer.md)"
check "header: title, model, verification first" '[[ "$(sed -n 1,3p <<< "$H")" == $'"'"'# inline-reviewer\nmodel: haiku\nverification: mutation'"'"' ]]'
check "header: contents from the spec's sections" '[[ "$H" == *"**Contents:** What to flag · Do not flag"* ]]'
check "header: an inline Checks line is lifted into the header" '[[ "$H" == *"**Checks:** the inline things."* && "$(grep -c "^\*\*Checks:" .reviewers/inline-reviewer.md)" == 1 ]]'
check "header: TODO where the source had no checks/spawn text" '[[ "$H" == *"**Spawn when:** TODO"* ]]'
check "model line not left in the body" '[[ "$(grep -c "^model:" .reviewers/inline-reviewer.md)" == 1 ]]'
H="$(head -n 12 .reviewers/indexed-reviewer.md)"
check "index text becomes Checks / Spawn when" '[[ "$H" == *"**Checks:** the indexed things."* && "$H" == *"**Spawn when:** the diff touches \`idx/\`."* ]]'
W="$(cat .reviewers/wrapped-reviewer.md)"
check "a wrapped Checks line is joined whole" '[[ "$W" == *$'"'"'\n**Checks:** that the router cannot feed itself. No subscription may target `actions`; fan-out stays bounded\n'"'"'* ]]'
check "a wrapped Spawn when line is joined whole" '[[ "$W" == *"**Spawn when:** PR touches \`subscriptions.py\` or adds an enqueue target."* ]]'
check "no wrapped fragment is left in the body" '[[ "$(grep -c "^target \|^adds an" <<< "$W")" == 0 ]]'
check "the body after the sentence ends is kept" '[[ "$W" == *$'"'"'\n\nBody line one.'"'"'* ]]'
check "a colon inside backticks stays in the item title" '[[ "$W" == *"**Contents:** Flag: \`# type: ignore\` without a reason; Bare \`except:\`; Plain title"$'"'"'\n'"'"'* ]]'
W="$(cat .reviewers/wrapped-indexed.md)"
check "wrapped index text is joined whole" '[[ "$W" == *"**Checks:** wrapped index text that continues here."* && "$W" == *"**Spawn when:** the diff touches \`wi/\`."* ]]'
check "and no fragment of it reaches the body" '[[ "$W" != *$'"'"'\ncontinues here.'"'"'* && "$W" != *$'"'"'\n`wi/`.'"'"'* ]]'
check "pointer line dropped" '! grep -q "Read \`.reviewers" .reviewers/indexed-reviewer.md'
check "existing spec body kept" 'grep -q "The indexed spec body." .reviewers/indexed-reviewer.md'
check "subtree index converts beside itself" '[[ -f svc/.reviewers/svc-reviewer.md ]]'
check "prose above the first heading is kept in README.md" 'grep -q "Intro prose above every heading." .reviewers/README.md'
check "prose H2 and other H1s go to README.md" 'grep -q "old-reviewer was retired" .reviewers/README.md && grep -q "parameterized queries" .reviewers/README.md'
check "a non-kebab name is still converted as a reviewer" '[[ -f .reviewers/my_pci_auditor.md ]]'
check "notes written around the JSON block go to README.md" 'grep -q "no Gemini quota" .reviewers/README.md'
check "config.json keeps what still applies" '[[ "$(jq -c . .reviewers/config.json)" == "{\"bots\":{\"gemini\":false}}" ]]'

PR_REVIEW_LOOP_TEST_CHANGED_FILES="$(git ls-files; find .reviewers svc -type f)" "$DISCOVER" 0 > "$T/after.json" 2>"$T/after.err"
check "discovery sees the new layout" '[[ "$(jq -r .configuration.layout "$T/after.json")" == reviewers ]]'
check "same reviewers, same models (minus the prose H2, plus the stray file that now runs)" \
  '[[ "$(jq -r ".agents[] | select(.kind != \"default\") | select(.name != \"Retired reviewers\") | \"\(.name) \(.model)\"" "$T/before.json" | sort)" == "$(jq -r ".agents[] | select(.name != \"stray-reviewer\") | \"\(.name) \(.model)\"" "$T/after.json" | sort)" ]]'
check "the stray file runs after conversion" '[[ "$(jq -r ".agents[] | select(.name == \"stray-reviewer\") | .name" "$T/after.json")" == stray-reviewer ]]'
check "spec text survives" '[[ "$(jq -r ".agents[] | select(.name==\"inline-reviewer\") | .instructions" "$T/after.json")" == *"Flags the inline things."*"Other things."* ]]'
check "TODO headers are reported" 'grep -q "inline-reviewer.md has a TODO in its header" "$T/after.err"'

echo "=== a reviewer name that can't be a safe file name stops the conversion ==="
for bad in '../../escape' 'src/foo' 'README' 'readme' '.hidden'; do
  printf '# Agents\n\n## %s\n\nx\n' "$bad" > "$T/bad.md"; rm -rf "$T/u"; mkdir -p "$T/u"
  set +e; python3 "$CONVERT" template "$T/bad.md" --into "$T/u" >/dev/null 2>"$T/u.err"; rc=$?; set -e
  check "'$bad' stops conversion and writes nothing" '[[ $rc -ne 0 && -z "$(find "$T/u" -type f)" ]] && grep -q "rename it" "$T/u.err"'
done
check "nothing escaped the scratch dir" '[[ -z "$(find "$T" -maxdepth 2 -name "escape.md")" ]]'
printf '# Agents\n\n## café-reviewer\n\nx\n' > "$T/uni.md"; rm -rf "$T/u"; mkdir -p "$T/u"
python3 "$CONVERT" template "$T/uni.md" --into "$T/u" >/dev/null
check "a Unicode name is a reviewer" '[[ -f "$T/u/.reviewers/café-reviewer.md" ]]'
printf '# Agents\n\n## Foo\n\none\n\n## foo\n\ntwo\n' > "$T/case.md"; rm -rf "$T/u"; mkdir -p "$T/u"
set +e; python3 "$CONVERT" template "$T/case.md" --into "$T/u" >/dev/null 2>&1; rc=$?; set -e
check "names differing only in case are duplicates" '[[ $rc -ne 0 && -z "$(find "$T/u" -type f)" ]]'

echo "=== conversion refuses a duplicate reviewer and keeps an existing config.json ==="
printf '# Agents\n\n## dup-reviewer\n\none\n\n## dup-reviewer\n\ntwo\n' > "$T/dup.md"
rm -rf "$T/d"; mkdir -p "$T/d"; set +e; python3 "$CONVERT" template "$T/dup.md" --into "$T/d" >/dev/null 2>&1; rc=$?; set -e
check "a duplicate name stops conversion, writing nothing" '[[ $rc -ne 0 && ! -e "$T/d/.reviewers/dup-reviewer.md" ]]'
fixture
printf '{"bots": {"cursor": false}}\n' > .reviewers/config.json
OUT="$(python3 "$CONVERT" repo --write)"
check "an existing config.json is not overwritten" '[[ "$(jq -c . .reviewers/config.json)" == "{\"bots\":{\"cursor\":false}}" ]]'
check "and the plan says to merge it by hand" '[[ "$OUT" == *"config.json already exists"* ]]'

echo "=== starters ==="
rm -rf "$T/s"; mkdir -p "$T/s"
check "lists starters with no names" '[[ "$(python3 "$CONVERT" starters)" == *"silent-failure-hunter: "* ]]'
python3 "$CONVERT" starters --into "$T/s" silent-failure-hunter >/dev/null
H="$(head -n 12 "$T/s/.reviewers/silent-failure-hunter.md")"
check "starter header has its model and checks" '[[ "$H" == *"model: sonnet"* && "$H" != *"**Checks:** TODO"* ]]'
check "starter header has no frontmatter" '! grep -q "^color:" "$T/s/.reviewers/silent-failure-hunter.md"'
set +e; python3 "$CONVERT" starters --into "$T/s" silent-failure-hunter >/dev/null 2>&1; rc=$?; set -e
check "refuses to overwrite a starter" '[[ $rc -ne 0 ]]'

echo "=== a wrapped header line stops where its text does ==="
BAD="$(python3 - "$CONVERT" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("c", sys.argv[1]); c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
cases = {  # body after "**Checks:** a thing" -> the line that must stay in the body
    "blank line": "\nkept",
    "bullet": "- kept",
    "numbered item": "1. kept",
    "heading": "### kept",
    "quote": "> kept",
    "table": "| kept |",
    "fence": "```\nkept",
}
for name, rest in cases.items():
    out = c.render("r", "**Checks:** a thing\n" + rest)
    if "**Checks:** a thing\n" not in out or rest.split("\n")[-1] not in out.split("\n\n", 1)[1]:
        print(f"{name}: {out!r}")
out = c.render("r", "**Checks:** one\ntwo\nthree.\nkept")
if "**Checks:** one two three.\n" not in out:
    print(f"three-line wrap: {out!r}")
for end in ["?", "!", ":", " (e.g. foo.)", ' "done."']:
    out = c.render("r", f"**Checks:** a thing{end}\nkept")
    if f"**Checks:** a thing{end}\n" not in out:
        print(f"terminator {end}: {out!r}")
body = "intro\n" * 8 + "**Checks:** late\nkept\n```\n**Checks:** fenced\nkept too\n```"
if body not in c.render("r", "x\n" + body):
    print("a Checks line below the header was rewritten")
if c.contents("### S\n1. **Name (detail)** z\n2. **Other** y") != "S: Name; Other":
    print("title cut at ' ('")
PYEOF
)"
check "every stop condition holds, and only the header is joined" '[[ -z "$BAD" ]]' || echo "$BAD"

echo "=== every shipped template names all its sections and items ==="
STALE="$(python3 - "$CONVERT" "$SCRIPT_DIR/../../../agent-reviewer-templates" <<'PYEOF'
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("c", sys.argv[1]); c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
for f in sorted(pathlib.Path(sys.argv[2]).glob("*/*.md")):
    if f.name == "README.md":
        continue
    lines = f.read_text().split("\n"); end = lines.index("")
    want = c.contents("\n".join(lines[end + 1:]))
    have = next((l[len("**Contents:** "):] for l in lines[:end] if l.startswith("**Contents:** ")), None)
    if want != have:
        print(f.relative_to(sys.argv[2]))
PYEOF
)"
check "every template's Contents line matches its sections" '[[ -z "$STALE" ]]' || echo "$STALE"

echo ""; echo "Passed: $PASSED  Failed: $FAILED"; [[ "$FAILED" -eq 0 ]]
