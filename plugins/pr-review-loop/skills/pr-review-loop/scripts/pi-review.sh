#!/usr/bin/env bash
# Run one agent reviewer on a non-Claude model: a one-shot Pi run in Docker.
# Usage: pi-review.sh <pr-number> <agent-name> <dispatch-sha>
#
# The C3 counterpart of a reviewer Task, for agents discover-agents.sh stamps
# engine "pi". Pi reviews a throwaway export of <dispatch-sha>, prints its report
# as one fenced ```json block and exits. This script, not Pi, posts the findings
# via post-line-comment.sh and reopen-comment.sh, so no GitHub token ever enters
# the container. Pi may edit and run code in its export to prove a finding.
#
# stdout: the posting manifest, `<severity> | <file>:<line> | <title>` per
# posted finding, or "No issues found" - the same contract as a reviewer Task.
#
# Exit codes - only 0 means the reviewer REPORTED:
#   0  reported; every finding and reopen was posted
#   1  setup failed (args, roster, docker, model key)
#   2  the PR head is not <dispatch-sha>; nothing was posted
#   3  Pi produced no valid report (crash, timeout, provider error, bad JSON)
#   4  reported, but at least one post failed (manifest lists FAILED lines)
#
# Env: PI_REVIEW_TIMEOUT (seconds, default 900), PI_REVIEW_IMAGE (default: the
# image built from ../pi/Dockerfile on first use), PI_REVIEW_ENV_FILE (docker
# --env-file for the model's credentials; default: pass only <PROVIDER>_API_KEY).

set -euo pipefail

USAGE="Usage: pi-review.sh <pr-number> <agent-name> <dispatch-sha>"
PR="${1:?$USAGE}"
AGENT="${2:?$USAGE}"
SHA="${3:?$USAGE}"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "Error: dispatch SHA must be 40 hex chars, got '$SHA'" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_IMAGE="pr-review-loop-pi:0.73.1"
IMAGE="${PI_REVIEW_IMAGE:-$DEFAULT_IMAGE}"
TIMEOUT="${PI_REVIEW_TIMEOUT:-900}"

T="$(mktemp -d)"
CONTAINER="pi-review-$$-$RANDOM"
MODEL="" STATUS="failed" POSTED=0
finish() {
    local rc=$?
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -rf -- "$T"
    # Firing marker: a Bash-run reviewer leaves no Task description for dream
    # to mine, so this is its only record of having fired.
    "$SCRIPT_DIR/emit-dream-marker.sh" reviewer-fired pr="$PR" reviewer="$AGENT" \
        engine=pi model="$MODEL" sha="$SHA" status="$STATUS" exit="$rc" posted="$POSTED" || true
    exit "$rc"
}
trap finish EXIT

head_sha() { gh pr view "$PR" --json headRefOid --jq .headRefOid; }

# ---- roster: the same agent definition a Task would get ----
AGENT_JSON="$("$SCRIPT_DIR/discover-agents.sh" "$PR" | jq -c --arg n "$AGENT" '.agents[] | select(.name == $n)')"
[[ -n "$AGENT_JSON" ]] || { echo "Error: no agent '$AGENT' on the roster for PR #$PR" >&2; exit 1; }
[[ "$(jq -r .engine <<<"$AGENT_JSON")" == "pi" ]] \
    || { echo "Error: agent '$AGENT' is not configured for the pi engine (# Configuration .pi)" >&2; exit 1; }
MODEL="$(jq -r .pi_model <<<"$AGENT_JSON")"
SCOPE_JSON="$(jq -c .changed_files <<<"$AGENT_JSON")"

# ---- model credentials: only what this model's provider needs ----
DOCKER_ENV=()
if [[ -n "${PI_REVIEW_ENV_FILE:-}" ]]; then
    [[ -r "$PI_REVIEW_ENV_FILE" ]] || { echo "Error: PI_REVIEW_ENV_FILE not readable: $PI_REVIEW_ENV_FILE" >&2; exit 1; }
    DOCKER_ENV=(--env-file "$PI_REVIEW_ENV_FILE")
else
    PROVIDER="${MODEL%%/*}"
    case "$PROVIDER" in
        google) KEY_VAR=GEMINI_API_KEY ;;
        vercel-ai-gateway) KEY_VAR=AI_GATEWAY_API_KEY ;;
        opencode|opencode-go) KEY_VAR=OPENCODE_API_KEY ;;
        *) KEY_VAR="$(tr '[:lower:]-' '[:upper:]_' <<<"$PROVIDER")_API_KEY" ;;
    esac
    [[ -n "${!KEY_VAR:-}" ]] || { echo "Error: $KEY_VAR is not set (model $MODEL); set it or PI_REVIEW_ENV_FILE" >&2; exit 1; }
    DOCKER_ENV=(-e "$KEY_VAR")   # name only: the value never reaches argv
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    [[ "$IMAGE" == "$DEFAULT_IMAGE" ]] || { echo "Error: image $IMAGE not found" >&2; exit 1; }
    echo "Building $IMAGE (first use)..." >&2
    docker build -q -t "$IMAGE" "$SCRIPT_DIR/../pi" >&2 || { echo "Error: image build failed" >&2; exit 1; }
fi

# ---- inputs, pinned to the dispatch SHA ----
NOW="$(head_sha)" || { echo "Error: could not read PR #$PR head" >&2; exit 1; }
[[ "$NOW" == "$SHA" ]] || { echo "Error: PR #$PR head is $NOW, not dispatch SHA $SHA - round is invalid" >&2; exit 2; }
git cat-file -e "$SHA^{commit}" 2>/dev/null || git fetch -q origin "$SHA" \
    || { echo "Error: cannot fetch $SHA" >&2; exit 1; }

mkdir -p "$T/work" "$T/review"
git archive "$SHA" | tar -x -C "$T/work"
git -C "$T/work" init -q
git -C "$T/work" -c core.hooksPath=/dev/null -c user.name=pi -c user.email=pi@localhost \
    add -A
git -C "$T/work" -c core.hooksPath=/dev/null -c user.name=pi -c user.email=pi@localhost \
    commit -q --no-verify -m "PR #$PR at $SHA"
gh pr diff "$PR" > "$T/review/pr.diff"
"$SCRIPT_DIR/get-agent-comments.sh" "$PR" "$AGENT" --with-replies > "$T/review/prior-comments.txt"

cat > "$T/review/prompt.md" <<EOF
You are the "$AGENT" code reviewer for PR #$PR, reviewing commit $SHA.

Your focus:
$(jq -r .instructions <<<"$AGENT_JSON")

**Carry the proof in the finding.** A behavioural claim - it exits 0 on
failure, this branch is unreachable, that fixture cannot fail - is checkable,
so check it: change the code and watch the check fail, or run the query that
produces the evidence the claim depends on and report the number. Report what
you observed, not what you expect. A finding you could not demonstrate is a
hypothesis and must say so. A judgement about design or wording owes no
demonstration and must be labelled as judgement.

/work (your cwd) is a scratch copy of the repository at that commit, in a fresh
git repo: \`git diff\` shows your own edits. Edit, build and run tests there
freely to prove a finding; it is discarded when you exit. You have no GitHub
access and must not try to post anything - your report below is posted for you.

**Your scope: $(jq -r .scope <<<"$AGENT_JSON")** - review ONLY changes to these files:
$(jq -r '.[] | "- " + .' <<<"$SCOPE_JSON")

Inputs:
- /review/pr.diff - the PR's diff
- /review/prior-comments.txt - your comments from earlier rounds and the replies they got

Workflow:
1. Read /review/prior-comments.txt. Do not raise anything already there. If a
   reply is unreasonable (dismissive, incorrect, ignores the issue), reopen it.
   A reasoned decline on wording or style grounds is final; do not reopen it.
2. Review the diff for your in-scope files, reading surrounding code as needed.
   Only flag real issues within your focus; consider the project's context.
3. End your reply with exactly one fenced \`\`\`json block and nothing after it:

\`\`\`json
{"findings": [{"severity": "P1|P2|P3", "file": "<path from the scope list>",
   "line": <line number in the new file, inside a diff hunk>,
   "title": "<one line>", "body": "<the issue, the fix, and its proof - or 'judgement:' / 'hypothesis:'>"}],
 "reopens": [{"comment_id": <Thread ID from prior-comments.txt>, "reason": "<why the reply is insufficient>"}]}
\`\`\`

Nothing to report: {"findings": [], "reopens": []}. That block is your whole
report; anything outside it is discarded.
EOF

# ---- run Pi ----
set +e
timeout -k 30 "$TIMEOUT" docker run --rm --name "$CONTAINER" \
    --user "$(id -u):$(id -g)" --cap-drop ALL --security-opt no-new-privileges \
    --memory 4g --pids-limit 512 \
    "${DOCKER_ENV[@]}" \
    -v "$T/work:/work" -v "$T/review:/review:ro" -w /work \
    "$IMAGE" -p --no-session --model "$MODEL" @/review/prompt.md \
    > "$T/pi.out" 2> "$T/pi.err"
PI_RC=$?
set -e

# ---- parse: the last ```json block, strictly shaped ----
REPORT="$(awk '/^```json[[:space:]]*$/ {buf=""; inb=1; next}
               inb && /^```[[:space:]]*$/ {last=buf; inb=0; next}
               inb {buf = buf $0 "\n"}
               END {printf "%s", last}' "$T/pi.out" \
    | jq -ce '
        def finding: (.severity | IN("P1","P2","P3")) and (.file | type == "string")
            and (.line | type == "number" and . > 0 and floor == .)
            and (.title | type == "string" and length > 0) and (.body | type == "string");
        def reopen: (.comment_id | type == "number") and (.reason | type == "string" and length > 0);
        select(type == "object" and (.findings | type == "array")
               and ((.reopens // []) | type == "array")
               and all(.findings[]; finding) and all((.reopens // [])[]; reopen))
        | .reopens //= []' 2>/dev/null)" || REPORT=""
if [[ -z "$REPORT" ]]; then
    # A Pi that crashed, timed out or hit a provider error looks exactly like a
    # reviewer with nothing to say. Only a well-formed report counts.
    echo "Error: Pi produced no valid report (pi exit $PI_RC; 124 = timeout after ${TIMEOUT}s)" >&2
    echo "--- pi stderr (tail) ---" >&2; tail -n 20 "$T/pi.err" >&2
    echo "--- pi stdout (tail) ---" >&2; tail -n 40 "$T/pi.out" >&2
    exit 3
fi

# Pi ran for minutes; a push in that window means nothing it saw would ship.
NOW="$(head_sha)" || { echo "Error: could not re-read PR #$PR head" >&2; exit 1; }
[[ "$NOW" == "$SHA" ]] || { echo "Error: PR #$PR moved to $NOW while Pi ran - round is invalid; nothing posted" >&2; exit 2; }

# ---- post ----
FAILS=0
while IFS= read -r r; do
    id="$(jq -r .comment_id <<<"$r")"
    if "$SCRIPT_DIR/reopen-comment.sh" "$PR" "$id" "$AGENT" "$(jq -r .reason <<<"$r")" >&2; then
        echo "REOPENED | comment $id"
    else
        echo "FAILED | reopen comment $id"; FAILS=$((FAILS + 1))
    fi
done < <(jq -c '.reopens[]' <<<"$REPORT")

while IFS= read -r f; do
    file="$(jq -r .file <<<"$f")" line="$(jq -r .line <<<"$f")"
    sev="$(jq -r .severity <<<"$f")" title="$(jq -r .title <<<"$f")"
    if ! jq -e --arg f "$file" 'index($f) != null' <<<"$SCOPE_JSON" >/dev/null; then
        echo "DROPPED | $file:$line | $title (outside this agent's scope)"
        continue
    fi
    body="**${sev}: ${title}**

$(jq -r .body <<<"$f")

<sub>engine: pi · model: ${MODEL}</sub>"
    if "$SCRIPT_DIR/post-line-comment.sh" "$PR" "$file" "$line" "$AGENT" "$body" >&2; then
        echo "$sev | $file:$line | $title"; POSTED=$((POSTED + 1))
    else
        echo "FAILED | $file:$line | $title"; FAILS=$((FAILS + 1))
    fi
done < <(jq -c '.findings[]' <<<"$REPORT")

[[ "$(jq '(.findings | length) + (.reopens | length)' <<<"$REPORT")" -eq 0 ]] && echo "No issues found"
STATUS="reported"
[[ "$FAILS" -eq 0 ]] || { STATUS="post-failed"; exit 4; }
