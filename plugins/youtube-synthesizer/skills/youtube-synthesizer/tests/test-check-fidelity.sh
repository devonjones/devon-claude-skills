#!/usr/bin/env bash
# Checks for check_fidelity.py. Run: tests/test-check-fidelity.sh
set -uo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/check_fidelity.py"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

cat > "$TMP/t.txt" <<'EOF'
[00:01] so the ox is slow and it eats a lot
[00:05] which means a farm needs kills for measurement
[01:02] chapter two the wagon
EOF

# entry FRONT BODY: frontmatter lines, then body under the fixed non-prose sections
entry() {
  printf -- '---\ntitle: x\n%s\n---\n\n# Title\n\n**Source:** [u](u)\n\n## TL;DR\n\nNot transcript words.\n\n## Key takeaways\n\n- Also not.\n\n%s\n\n## References\n\n- Some ref\n\n## Commands & Code\n\nRun this before plowing.\n\nAt 00:05:\n\n```sh\nls -la\n```\n' "$1" "$2" > "$TMP/e.md"
  out=$("$SCRIPT" "$TMP/t.txt" "$TMP/e.md" 2>&1); rc=$?
}
CORR='transcript_corrections:
  - original: "kills"
    corrected: "scales"
    timestamp: 5.0'

entry "$CORR" $'## Chapter 1\n\nSo the ox is slow, and it eats a lot. Which means a farm\n\n![[image-01.png]]\n\nneeds scales for measurement.\n\nIt runs:\n\n```sh\nplow --deep\n```\n\n## Chapter 2\n\nChapter two: the wagon.'
check "faithful body with logged correction passes" '[[ $rc -eq 0 && $out == ok* ]]'

entry "transcript_corrections: []" $'## Body\n\nSo the ox is slow and it eats a lot. Which means a farm needs scales for measurement. Chapter two the wagon.'
check "unlogged word change fails" '[[ $rc -eq 1 ]]'
check "difference names the word and timestamp" '[[ $out == *"[00:05]"*"kills"*"scales"* ]]'

entry "$CORR" $'## Body\n\nThe ox is slow and hungry, so a farm needs scales for measurement. Chapter two the wagon.'
check "paraphrase fails" '[[ $rc -eq 1 ]]'

entry "$CORR" $'## Body\n\nSo the ox is slow and it eats a lot which means a farm needs scales for measurement.'
check "dropped transcript words fail" '[[ $rc -eq 1 && $out == *"chapter two the wagon"* ]]'

entry "$CORR" $'## Body\n\nSO THE OX\'S slow... no: so the ox is slow and it eats a lot. Which means a farm needs scales for measurement. Chapter two the wagon.'
check "inserted words fail" '[[ $rc -eq 1 ]]'

entry "transcript_corrections: null" $'## Body\n\nSo the ox is slow and it eats a lot. Which means a farm needs kills for measurement. Chapter two the wagon.'
check "null transcript_corrections, verbatim body passes" '[[ $rc -eq 0 ]]'

entry 'transcript_corrections:
  - original: ""
    corrected: "very"' $'## Body\n\nSo the very ox is slow and it eats a lot. Which means a farm needs kills for measurement. Chapter two the wagon.'
check "correction with an empty side excuses nothing" '[[ $rc -eq 1 ]]'

entry 'transcript_corrections:
  - original: "farm"
    corrected: "barn"
  - original: "needs"
    corrected: "wants"' $'## Body\n\nSo the ox is slow and it eats a lot. Which means a barn wants kills for measurement. Chapter two the wagon.'
check "adjacent logged corrections pass" '[[ $rc -eq 0 ]]'

entry 'transcript_corrections:
  - "kills -> scales"' $'## Body\n\nSo the ox.'
check "malformed correction entry is an error" '[[ $rc -eq 1 && $out == *"entry 1 is not"* ]]'

entry 'title: [unclosed' $'## Body\n\nSo the ox.'
check "bad YAML frontmatter is an error" '[[ $rc -eq 1 && $out == error:* ]]'

out=$("$SCRIPT" "$TMP/t.txt" "$TMP/missing.md" 2>&1); rc=$?
check "missing entry file is an error" '[[ $rc -eq 1 && $out == error:* ]]'

printf 'the café don’t close\n' > "$TMP/plain.txt"
printf -- '## Body\n\nThe café: don'"'"'t close.\n' > "$TMP/p.md"
"$SCRIPT" "$TMP/plain.txt" "$TMP/p.md" >/dev/null 2>&1
check "untimestamped transcript, curly apostrophe and accents match" '[[ $? -eq 0 ]]'
printf 'the café мир\n' > "$TMP/u.txt"
printf -- '## Body\n\nThe cafè привет.\n' > "$TMP/u.md"
out=$("$SCRIPT" "$TMP/u.txt" "$TMP/u.md" 2>&1); rc=$?
check "non-ASCII word change fails" '[[ $rc -eq 1 && $out == *"word "* ]]'

seq 1 30 | sed 's/^/a w/' | tr '\n' ' ' > "$TMP/many.txt"
printf -- '## Body\n\n%s\n' "$(seq 1 30 | sed 's/^/a x/' | tr '\n' ' ')" > "$TMP/m.md"
out=$("$SCRIPT" "$TMP/many.txt" "$TMP/m.md" 2>&1)
check "long difference lists are truncated" '[[ $(wc -l <<<"$out") -eq 22 && $out == *"... and 10 more"* ]]'

: > "$TMP/empty.txt"
out=$("$SCRIPT" "$TMP/empty.txt" "$TMP/p.md" 2>&1); rc=$?
check "empty transcript is an error" '[[ $rc -eq 1 && $out == *"no words"* ]]'

exit $fail
