#!/bin/bash
# Record one reviewer finding for this round. Nothing touches GitHub here;
# post-findings.sh merges the round's findings and posts them in one review.
# Usage: record-finding.sh <pr-number|local> <file-path> <line> <agent-name> <P1|P2|P3> "finding"

set -euo pipefail

USAGE='Usage: record-finding.sh <pr-number|local> <file-path> <line> <agent-name> <P1|P2|P3> "finding"'
PR="${1:?$USAGE}"; FILE="${2:?$USAGE}"; LINE="${3:?$USAGE}"
AGENT="${4:?$USAGE}"; SEV="${5:?$USAGE}"; BODY="${6:?$USAGE}"

[[ "$SEV" =~ ^P[123]$ ]] || { echo "Error: severity must be P1, P2 or P3 (got '$SEV')" >&2; exit 1; }
[[ "$LINE" =~ ^[0-9]+$ ]] || { echo "Error: line must be a number (got '$LINE')" >&2; exit 1; }

# Under the git dir, so the working tree stays clean for the round.
DIR="$(git rev-parse --absolute-git-dir)/pr-review-loop"
mkdir -p "$DIR"
STORE="$DIR/findings-$PR.jsonl"

# Reviewers record in parallel; one line per append, serialised.
exec 9>>"$STORE.lock"
flock 9
jq -nc --arg file "$FILE" --argjson line "$LINE" --arg agent "$AGENT" \
    --arg severity "$SEV" --arg body "$BODY" \
    '{file: $file, line: $line, agent: $agent, severity: $severity, body: $body}' >> "$STORE"
echo "Recorded $SEV from '$AGENT' at $FILE:$LINE"
