#!/bin/bash
# Record one reviewer finding for this round. Nothing touches GitHub here;
# post-findings.sh merges the round's findings and posts them in one review.
# Usage: record-finding.sh <pr-number|local> <file-path> <line> <agent-name> <P1|P2|P3> - <<'EOF'
#        <finding body>
#        EOF
# A body of "-" is read from stdin. Pass it that way rather than through a
# scratch file: parallel reviewers sharing a scratchpad overwrite each other's files.

set -euo pipefail

USAGE='Usage: record-finding.sh <pr-number|local> <file-path> <line> <agent-name> <P1|P2|P3> - <<EOF (body on stdin)'
PR="${1:?$USAGE}"; FILE="${2:?$USAGE}"; LINE="${3:?$USAGE}"
AGENT="${4:?$USAGE}"; SEV="${5:?$USAGE}"; BODY="${6:?$USAGE}"
[[ "$BODY" == "-" ]] && BODY="$(cat)"
[[ -n "${BODY//[[:space:]]/}" ]] || { echo "Error: the finding body is empty" >&2; exit 1; }

[[ "$SEV" =~ ^P[123]$ ]] || { echo "Error: severity must be P1, P2 or P3 (got '$SEV')" >&2; exit 1; }
[[ "$LINE" =~ ^[0-9]+$ ]] || { echo "Error: line must be a number (got '$LINE')" >&2; exit 1; }

# Under the git dir, so the working tree stays clean for the round.
DIR="$(git rev-parse --absolute-git-dir)/pr-review-loop"
STORE="$DIR/findings-$PR.jsonl"

# The orchestrator opens the round in the PR's own repo. A reviewer in any other
# repo (a parent checkout, a sibling) would strand its findings where
# post-findings.sh never looks.
if [[ "$PR" != "local" && ! -f "$DIR/findings-$PR.open" ]]; then
    echo "Error: no round is open for PR $PR in $(git rev-parse --show-toplevel)." >&2
    echo "  If this is the PR's repo, the orchestrator runs: post-findings.sh $PR --open" >&2
    echo "  Otherwise cd to the PR's repo and record from there." >&2
    exit 1
fi
mkdir -p "$DIR"

# Reviewers record in parallel; one line per append, serialised.
exec 9>>"$STORE.lock"
flock 9

# The same body under another label is a crossed record, not a second finding.
if [[ -s "$STORE" ]]; then
    MATCH=$(jq -sc --arg body "$BODY" 'map(select(.body == $body))[0] // empty' "$STORE")
    if [[ -n "$MATCH" ]]; then
        echo "Error: this body is already recorded as $(jq -r '"\(.severity) from \(.agent) at \(.file):\(.line)"' <<< "$MATCH")." >&2
        echo "  Same agent and line: a duplicate, nothing to do. Otherwise two records crossed: re-check your body." >&2
        exit 1
    fi
fi

jq -nc --arg file "$FILE" --argjson line "$LINE" --arg agent "$AGENT" \
    --arg severity "$SEV" --arg body "$BODY" \
    '{file: $file, line: $line, agent: $agent, severity: $severity, body: $body}' >> "$STORE"
# Read back what landed, so the reviewer can check it against what it meant.
tail -n 1 "$STORE" | jq -r '"Recorded \(.severity) from \(.agent) at \(.file):\(.line): \(.body | split("\n")[0])"'
