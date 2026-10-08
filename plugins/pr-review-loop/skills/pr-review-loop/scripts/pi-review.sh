#!/usr/bin/env bash
# Run one agent reviewer on a non-Claude model: a one-shot Pi run in Docker.
# Usage: pi-review.sh <pr-number> <agent-name> <sha> [--model <provider/id>] [--replay [--prior <file>]]
#
# Reviews only - posts nothing. Pi reviews a throwaway export of <sha>, prints
# its report as one fenced ```json block and exits. This script validates it
# and prints one JSON object on stdout:
#   {agent, pr, sha, model, tried, seconds,
#    usage: {input, output, cacheRead, cacheWrite, usd (Pi's own price; 0 if it has none)},
#    report: {findings: [...], reopens: [...]}, dropped: [...]}
# The Haiku poster Task (SKILL.md "Pi Engine") turns `report` into PR comments,
# so no GitHub token ever enters the container.
#
# Models: --model, else the agent's chain from # Configuration .pi
# (discover-agents.sh `pi_models`). The chain advances only on a PROVIDER
# failure - quota or credits used up, rate limit, auth or access denied,
# unreachable. A model that ran and produced no valid report is a reviewer
# failure (exit 3), never a reason to try the next model. A provider that
# reports exhausted quota is skipped for PI_REVIEW_EXHAUSTED_TTL seconds
# (default 3600) by every later run, via ~/.cache/pr-review-loop/exhausted/.
#
# --replay: review a historical commit for eval-reviewer.sh. No head check; the
# diff is the PR's base..<sha>, computed locally. Prior comments come from
# --prior <file> (the agent's threads as they stood at that commit), else none.
#
# Exit codes - only 0 means the reviewer REPORTED:
#   0  report on stdout
#   1  setup failed (args, roster, docker, model key)
#   2  the PR head is not <sha>
#   3  a model ran but produced no valid report (malformed, timeout, crash)
#   5  the chain reached "claude" or "claude:<model>": spawn the Claude Task for
#      this agent; stdout is {"fallback": "claude", "model": "<model or empty>"}
#   6  every model in the chain failed on the provider side
#
# Env: PI_REVIEW_TIMEOUT (seconds, default 900), PI_REVIEW_IMAGE (default: the
# image built from ../pi/Dockerfile on first use), PI_REVIEW_ENV_FILE (docker
# --env-file for credentials; default: pass only <PROVIDER>_API_KEY),
# PI_REVIEW_MODELS_JSON (a Pi models.json that replaces the image's; default:
# your own Pi config, ${PI_CODING_AGENT_DIR:-~/.pi/agent}/models.json, when it
# exists, so host Pi and the reviewers share one provider list),
# PI_REVIEW_EXHAUSTED_TTL, PI_REVIEW_CACHE_DIR (default ~/.cache/pr-review-loop).

set -euo pipefail

USAGE="Usage: pi-review.sh <pr-number> <agent-name> <sha> [--model <provider/id>] [--replay [--prior <file>]]"
PR="${1:?$USAGE}"
AGENT="${2:?$USAGE}"
SHA="${3:?$USAGE}"
shift 3
MODEL_ARG="" REPLAY=false PRIOR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model) MODEL_ARG="${2:?$USAGE}"; shift 2 ;;
        --replay) REPLAY=true; shift ;;
        --prior) PRIOR="${2:?$USAGE}"; shift 2 ;;
        *) echo "$USAGE" >&2; exit 1 ;;
    esac
done
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "Error: SHA must be 40 hex chars, got '$SHA'" >&2; exit 1; }
[[ "$REPLAY" == false || -n "$MODEL_ARG" ]] || { echo "Error: --replay needs --model" >&2; exit 1; }
[[ -z "$PRIOR" || ( "$REPLAY" == true && -r "$PRIOR" ) ]] || { echo "Error: --prior needs --replay and a readable file" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_IMAGE="pr-review-loop-pi:0.73.1"
IMAGE="${PI_REVIEW_IMAGE:-$DEFAULT_IMAGE}"
TIMEOUT="${PI_REVIEW_TIMEOUT:-900}"
EXHAUSTED_DIR="${PI_REVIEW_CACHE_DIR:-$HOME/.cache/pr-review-loop}/exhausted"
EXHAUSTED_TTL="${PI_REVIEW_EXHAUSTED_TTL:-3600}"

T="$(mktemp -d)"
CONTAINER="pi-review-$$-$RANDOM"
MODEL="" STATUS="failed" TRIED=()
finish() {
    local rc=$?
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -rf -- "$T"
    # Replays are evaluation, not firings; only a live run gets a marker.
    [[ "$REPLAY" == true ]] || "$SCRIPT_DIR/emit-dream-marker.sh" reviewer-fired pr="$PR" \
        reviewer="$AGENT" engine=pi model="$MODEL" tried="${TRIED[*]:-}" sha="$SHA" \
        status="$STATUS" exit="$rc" || true
    exit "$rc"
}
trap finish EXIT

head_sha() { gh pr view "$PR" --json headRefOid --jq .headRefOid; }
have_commit() { git cat-file -e "$1^{commit}" 2>/dev/null; }

# ---- inputs, pinned to <sha> ----
if [[ "$REPLAY" == true ]]; then
    have_commit "$SHA" || git fetch -q origin "+refs/pull/$PR/head:refs/pr-review-loop/pr-$PR" \
        || { echo "Error: cannot fetch PR #$PR commits" >&2; exit 1; }
    have_commit "$SHA" || { echo "Error: $SHA is not reachable from PR #$PR" >&2; exit 1; }
    FIRST="$(gh pr view "$PR" --json commits --jq '.commits[0].oid')" \
        || { echo "Error: cannot list PR #$PR commits" >&2; exit 1; }
    BASE="$(git rev-parse "$FIRST^")"
    export PR_REVIEW_LOOP_TEST_CHANGED_FILES
    PR_REVIEW_LOOP_TEST_CHANGED_FILES="$(git diff --name-only "$BASE" "$SHA")"
else
    NOW="$(head_sha)" || { echo "Error: could not read PR #$PR head" >&2; exit 1; }
    [[ "$NOW" == "$SHA" ]] || { echo "Error: PR #$PR head is $NOW, not $SHA - round is invalid" >&2; exit 2; }
    have_commit "$SHA" || git fetch -q origin "$SHA" || { echo "Error: cannot fetch $SHA" >&2; exit 1; }
fi

# ---- roster: the same agent definition a Task would get ----
AGENT_JSON="$("$SCRIPT_DIR/discover-agents.sh" "$PR" | jq -c --arg n "$AGENT" '.agents[] | select(.name == $n)')"
[[ -n "$AGENT_JSON" ]] || { echo "Error: no agent '$AGENT' on the roster for PR #$PR" >&2; exit 1; }
if [[ -n "$MODEL_ARG" ]]; then
    CHAIN=("$MODEL_ARG")
else
    [[ "$(jq -r .engine <<<"$AGENT_JSON")" == "pi" ]] \
        || { echo "Error: agent '$AGENT' is not configured for the pi engine (# Configuration .pi)" >&2; exit 1; }
    mapfile -t CHAIN < <(jq -r '.pi_models[]' <<<"$AGENT_JSON")
fi
SCOPE_JSON="$(jq -c .changed_files <<<"$AGENT_JSON")"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    [[ "$IMAGE" == "$DEFAULT_IMAGE" ]] || { echo "Error: image $IMAGE not found" >&2; exit 1; }
    echo "Building $IMAGE (first use)..." >&2
    docker build -q -t "$IMAGE" "$SCRIPT_DIR/../pi" >&2 || { echo "Error: image build failed" >&2; exit 1; }
fi

mkdir -p "$T/work" "$T/review"
git archive "$SHA" | tar -x -C "$T/work"
git -C "$T/work" init -q
git -C "$T/work" -c core.hooksPath=/dev/null -c user.name=pi -c user.email=pi@localhost add -A
git -C "$T/work" -c core.hooksPath=/dev/null -c user.name=pi -c user.email=pi@localhost \
    commit -q --no-verify -m "PR #$PR at $SHA"
if [[ "$REPLAY" == true ]]; then
    git diff "$BASE" "$SHA" > "$T/review/pr.diff"
    if [[ -n "$PRIOR" ]]; then cp -f "$PRIOR" "$T/review/prior-comments.txt"
    else echo "(none - first review of this commit)" > "$T/review/prior-comments.txt"; fi
else
    gh pr diff "$PR" > "$T/review/pr.diff"
    "$SCRIPT_DIR/get-agent-comments.sh" "$PR" "$AGENT" --with-replies > "$T/review/prior-comments.txt"
fi

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
   (severity is P1, P2 or P3; if your focus above uses another scale, map it:
    critical -> P1, high -> P2, medium or low -> P3)
   "title": "<one line>", "body": "<the issue, the fix, and its proof - or 'judgement:' / 'hypothesis:'>"}],
 "reopens": [{"comment_id": <Thread ID from prior-comments.txt>, "reason": "<why the reply is insufficient>"}]}
\`\`\`

Nothing to report: {"findings": [], "reopens": []}. That block is your whole
report; anything outside it is discarded.
EOF

key_var() {   # the env var holding <provider>'s API key, per Pi's provider table
    case "$1" in
        google) echo GEMINI_API_KEY ;;
        huggingface) echo HF_TOKEN ;;
        vercel-ai-gateway) echo AI_GATEWAY_API_KEY ;;
        opencode|opencode-go) echo OPENCODE_API_KEY ;;
        *) echo "$(tr '[:lower:]-' '[:upper:]_' <<<"$1")_API_KEY" ;;
    esac
}
exhausted() {   # true while <provider> is inside its exhausted TTL
    local f="$EXHAUSTED_DIR/$1"
    [[ -f "$f" ]] && (( $(date +%s) - $(stat -c %Y "$f") < EXHAUSTED_TTL ))
}

MODELS_JSON="${PI_REVIEW_MODELS_JSON:-${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/models.json}"
[[ -n "${PI_REVIEW_MODELS_JSON:-}" || -r "$MODELS_JSON" ]] || MODELS_JSON=""

# ---- run the chain ----
REPORT="" USAGE_JSON="" SECS=0
for MODEL in "${CHAIN[@]}"; do
    if [[ "$MODEL" == claude || "$MODEL" == claude:* ]]; then
        echo "Chain reached $MODEL after: ${TRIED[*]:-nothing} - spawn the Claude Task" >&2
        jq -nc --arg m "${MODEL#claude}" '{fallback: "claude", model: ($m | ltrimstr(":"))}'
        STATUS="fallback-claude"; exit 5
    fi
    PROVIDER="${MODEL%%/*}"
    if exhausted "$PROVIDER"; then
        echo "Skipping $MODEL: $PROVIDER marked exhausted ($EXHAUSTED_DIR/$PROVIDER)" >&2
        TRIED+=("$MODEL:skipped"); continue
    fi
    DOCKER_ENV=()
    if [[ -n "${PI_REVIEW_ENV_FILE:-}" ]]; then
        [[ -r "$PI_REVIEW_ENV_FILE" ]] || { echo "Error: PI_REVIEW_ENV_FILE not readable: $PI_REVIEW_ENV_FILE" >&2; exit 1; }
        DOCKER_ENV=(--env-file "$PI_REVIEW_ENV_FILE")
    else
        # A custom provider names its key variable in models.json (zai-payg can
        # reuse ZAI_API_KEY); built-in providers follow Pi's naming.
        KEY_VAR="$(jq -r --arg p "$PROVIDER" '.providers[$p].apiKey // empty' \
            "${MODELS_JSON:-$SCRIPT_DIR/../pi/models.json}" 2>/dev/null || true)"
        [[ "$KEY_VAR" =~ ^[A-Z_][A-Z0-9_]*$ ]] || KEY_VAR="$(key_var "$PROVIDER")"
        if [[ -z "${!KEY_VAR:-}" ]]; then
            echo "Skipping $MODEL: $KEY_VAR is not set" >&2
            TRIED+=("$MODEL:no-key"); continue
        fi
        DOCKER_ENV=(-e "$KEY_VAR")   # name only: the value never reaches argv
    fi
    if [[ -n "$MODELS_JSON" ]]; then
        [[ -r "$MODELS_JSON" ]] || { echo "Error: PI_REVIEW_MODELS_JSON not readable: $MODELS_JSON" >&2; exit 1; }
        # Only models.json: auth.json can hold /login subscription tokens, and
        # anything mounted here is readable by the PR code the reviewer runs.
        DOCKER_ENV+=(-v "$(cd "$(dirname "$MODELS_JSON")" && pwd)/$(basename "$MODELS_JSON"):/opt/pi-agent/models.json:ro")
    fi

    git -C "$T/work" reset -q --hard && git -C "$T/work" clean -qfdx   # undo the last model's edits
    START=$SECONDS
    set +e
    timeout -k 30 "$TIMEOUT" docker run --rm --name "$CONTAINER" \
        --user "$(id -u):$(id -g)" --cap-drop ALL --security-opt no-new-privileges \
        --memory 4g --pids-limit 512 \
        "${DOCKER_ENV[@]}" \
        -v "$T/work:/work" -v "$T/review:/review:ro" -w /work \
        "$IMAGE" --mode json --no-session --model "$MODEL" @/review/prompt.md \
        > "$T/pi.out" 2> "$T/pi.err"
    PI_RC=$?
    set -e
    SECS=$((SECONDS - START))

    # Pi reports a provider error as stopReason "error" and still exits 0.
    LAST="$(jq -c 'select(.type == "agent_end") | [.messages[] | select(.role == "assistant")] | last' "$T/pi.out" 2>/dev/null | tail -n 1)"
    ERR="$(jq -r 'select(.stopReason == "error") | .errorMessage // "unknown provider error"' <<<"${LAST:-null}" 2>/dev/null || true)"
    if [[ -n "$ERR" || ( "$PI_RC" -ne 0 && "$PI_RC" -ne 124 && -z "$LAST" ) ]]; then
        ERR="${ERR:-pi exit $PI_RC: $(tail -n 1 "$T/pi.err")}"
        echo "Provider failure on $MODEL: $ERR" >&2
        TRIED+=("$MODEL:provider-error")
        if grep -qiE 'quota|credit|insufficient|exceed|429|rate.?limit|balance|billing' <<<"$ERR"; then
            mkdir -p "$EXHAUSTED_DIR" && printf '%s\n' "$ERR" > "$EXHAUSTED_DIR/$PROVIDER"
        fi
        continue
    fi
    TRIED+=("$MODEL")

    # ---- parse: the last ```json block of the final reply, strictly shaped ----
    TEXT="$(jq -r '[.content[]? | select(.type == "text") | .text] | join("")' <<<"${LAST:-null}" 2>/dev/null || true)"
    REPORT="$(awk '/^```json[[:space:]]*$/ {buf=""; inb=1; next}
                   inb && /^```[[:space:]]*$/ {last=buf; inb=0; next}
                   inb {buf = buf $0 "\n"}
                   END {printf "%s", last}' <<<"$TEXT" \
        | jq -ce '
            # Agents written for Claude often grade critical/high/medium/low.
            def sev: (if type == "string" then ascii_upcase else "" end)
                | {"P0":"P1","P1":"P1","P2":"P2","P3":"P3","CRITICAL":"P1","HIGH":"P2","MEDIUM":"P3","LOW":"P3"}[.];
            def finding: (.severity | sev != null) and (.file | type == "string")
                and (.line | type == "number" and . > 0 and floor == .)
                and (.title | type == "string" and length > 0) and (.body | type == "string");
            def reopen: (.comment_id | type == "number") and (.reason | type == "string" and length > 0);
            select(type == "object" and (.findings | type == "array")
                   and ((.reopens // []) | type == "array")
                   and all(.findings[]; finding) and all((.reopens // [])[]; reopen))
            | .reopens //= [] | .findings |= map(.severity |= sev)' 2>/dev/null)" || REPORT=""
    if [[ -z "$REPORT" ]]; then
        # A model that crashed, timed out or answered off-contract looks exactly
        # like a reviewer with nothing to say. It is a strike, not a fallback.
        echo "Error: $MODEL produced no valid report (pi exit $PI_RC; 124 = timeout after ${TIMEOUT}s)" >&2
        echo "--- pi stderr (tail) ---" >&2; tail -n 20 "$T/pi.err" >&2
        echo "--- final reply (tail) ---" >&2; tail -n 40 <<<"$TEXT" >&2
        exit 3
    fi
    USAGE_JSON="$(jq -sc '[.[] | select(.type == "agent_end") | .messages[] | select(.role == "assistant") | .usage]
        | {input: (map(.input // 0) | add // 0), output: (map(.output // 0) | add // 0),
           cacheRead: (map(.cacheRead // 0) | add // 0), cacheWrite: (map(.cacheWrite // 0) | add // 0),
           usd: (map(.cost.total // 0) | add // 0)}' "$T/pi.out")"
    break
done
if [[ -z "$REPORT" ]]; then
    echo "Error: every model in the chain failed on the provider side: ${TRIED[*]:-none}" >&2
    STATUS="providers-failed"; exit 6
fi

if [[ "$REPLAY" == false ]]; then
    # Pi ran for minutes; a push in that window means nothing it saw would ship.
    NOW="$(head_sha)" || { echo "Error: could not re-read PR #$PR head" >&2; exit 1; }
    [[ "$NOW" == "$SHA" ]] || { echo "Error: PR #$PR moved to $NOW while Pi ran - round is invalid" >&2; exit 2; }
fi

STATUS="reported"
jq -n --arg agent "$AGENT" --argjson pr "$PR" --arg sha "$SHA" --arg model "$MODEL" \
    --argjson secs "$SECS" --argjson usage "$USAGE_JSON" --argjson scope "$SCOPE_JSON" \
    --argjson report "$REPORT" --args '{
    agent: $agent, pr: $pr, sha: $sha, model: $model, tried: $ARGS.positional,
    seconds: $secs, usage: $usage,
    report: {findings: [$report.findings[] | select(.file as $f | $scope | index($f))],
             reopens: $report.reopens},
    dropped: [$report.findings[] | select(.file as $f | $scope | index($f) | not)]}' "${TRIED[@]}"
