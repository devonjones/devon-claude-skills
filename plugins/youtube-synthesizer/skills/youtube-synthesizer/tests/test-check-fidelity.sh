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
  printf -- '---\ntitle: x\n%s\n---\n\n# Title\n\n**Source:** [u](u)\n\n## TL;DR\n\nNot transcript words.\n\n## Key takeaways\n\n- Also not.\n\n%s\n\n## References\n\n- Some ref\n\n## Commands & Code\n\nAt 00:05:\n\n```sh\nls -la\n```\n' "$1" "$2" > "$TMP/e.md"
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

: > "$TMP/empty.txt"
out=$("$SCRIPT" "$TMP/empty.txt" "$TMP/e.md" 2>&1); rc=$?
check "empty transcript is an error" '[[ $rc -eq 1 && $out == *"no words"* ]]'

exit $fail
