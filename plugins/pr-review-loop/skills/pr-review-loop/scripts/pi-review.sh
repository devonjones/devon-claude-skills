#!/usr/bin/env bash
# Run one agent reviewer on a non-Claude model: a one-shot Pi run in Docker.
# Usage: pi-review.sh <pr-number> <agent-name> <sha> [--model <provider/id>] [--replay [--prior <file>]]
#
# Reviews only - posts nothing. Pi reviews a throwaway export of <sha> and
# reports through tools from ../pi/review-tools.ts: report_finding and
# reopen_thread, each validated as it is called, then finish_review. A run that
# never calls finish_review did not report. This script prints one JSON object:
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
# (default 600) by every later run, via ~/.cache/pr-review-loop/exhausted/.
#
# Z.ai plan pacing: past the plan limit the same key bills per token, so zai/*
# is skipped once any plan window reaches PI_REVIEW_PLAN_CAP percent (default
# 90). Unused weekly quota is wasted at reset, so while the week has more quota
# left than time left, a configured chain tries its zai/* models first. No
# quota reading (API down, no key) means neither.
#
# --replay: review a historical commit for eval-reviewer.sh. No head check; the
# diff is the PR's base..<sha>, computed locally. Prior comments come from
# --prior <file> (the agent's threads as they stood at that commit), else none.
# In a replay, "claude" / "claude:<model>" runs headless Claude Code on your
# subscription (ANTHROPIC_API_KEY unset) in the same scratch copy - the harness
# a live round's Claude Task uses - reporting through --json-schema output.
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
# Env: PI_REVIEW_IDLE_TIMEOUT (seconds with no new output before a run counts
# as hung and is stopped, default 600), PI_REVIEW_TIMEOUT (hard cap, default
# 3600), PI_REVIEW_IMAGE (default: the
# image built from ../pi/Dockerfile on first use), PI_REVIEW_ENV_FILE (docker
# --env-file for credentials; default: pass only <PROVIDER>_API_KEY),
# PI_REVIEW_MODELS_JSON (a Pi models.json that replaces the image's; default:
# your own Pi config, ${PI_CODING_AGENT_DIR:-~/.pi/agent}/models.json, when it
# exists, so host Pi and the reviewers share one provider list),
# PI_REVIEW_EXHAUSTED_TTL, PI_REVIEW_PLAN_CAP, PI_REVIEW_CACHE_DIR (default ~/.cache/pr-review-loop),
# PI_REVIEW_SANDBOX (docker (default) | host). host runs your installed pi
# directly - the host's toolchains for proofs, your ~/.pi/agent config - with a
# stripped environment (HOME, PATH, the one model key), but WITHOUT the
# container boundary: PR code the reviewer runs can read your files, gh login
# included.
#
# Every run's event stream is kept in $PI_REVIEW_CACHE_DIR/runs/ for 7 days;
# watch one live with pi-watch.sh.

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
TIMEOUT="${PI_REVIEW_TIMEOUT:-3600}"
IDLE_TIMEOUT="${PI_REVIEW_IDLE_TIMEOUT:-600}"
EXHAUSTED_DIR="${PI_REVIEW_CACHE_DIR:-$HOME/.cache/pr-review-loop}/exhausted"
EXHAUSTED_TTL="${PI_REVIEW_EXHAUSTED_TTL:-600}"
QUOTA_DIR="${PI_REVIEW_CACHE_DIR:-$HOME/.cache/pr-review-loop}/quota"
PLAN_CAP="${PI_REVIEW_PLAN_CAP:-90}"

T="$(mktemp -d)"
RUNS_DIR="${PI_REVIEW_CACHE_DIR:-$HOME/.cache/pr-review-loop}/runs"
export KEEP=""   # host mode: the variables that survive into pi's environment
mkdir -p "$RUNS_DIR" && find "$RUNS_DIR" -name '*.jsonl' -mtime +7 -delete 2>/dev/null || true
SANDBOX="${PI_REVIEW_SANDBOX:-docker}"
[[ "$SANDBOX" == docker || "$SANDBOX" == host ]] || { echo "Error: PI_REVIEW_SANDBOX must be docker or host" >&2; exit 1; }
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

# Z.ai plan quota, cached 5 minutes: {pct: fullest window, behind: the weekly
# window has more quota left than time left}, or {} when it cannot be read.
# Window unit codes (3 = hours, 6 = weeks) are inferred, not documented.
zai_quota() {
    local f="$QUOTA_DIR/zai.json"
    if [[ ! -s "$f" ]] || (( $(date +%s) - $(stat -c %Y "$f") > 300 )); then
        mkdir -p "$QUOTA_DIR"
        { printf 'Authorization: Bearer %s\n' "${ZAI_API_KEY:-}" \
              | curl -sf --max-time 5 -H @- https://api.z.ai/api/monitor/usage/quota/limit \
              | jq -c '(now * 1000) as $now | [.data.limits[]] as $l | if ($l | length) == 0 then {} else
                  {pct: ([$l[].percentage // 0] | max),
                   behind: ([$l[] | select(.unit == 6 and .nextResetTime != null)
                            | (100 - .percentage) / 100 > (.nextResetTime - $now) / (7 * 86400000)] | any)} end' \
              || echo '{}'; } > "$f.$$" 2>/dev/null
        mv -f "$f.$$" "$f"
    fi
    cat "$f"
}
near_cap() { [[ "$1" == zai ]] && jq -e --argjson cap "$PLAN_CAP" '(.pct // 0) >= $cap' <<<"$(zai_quota)" >/dev/null; }

# ---- roster: the same agent definition a Task would get ----
AGENT_JSON="$("$SCRIPT_DIR/discover-agents.sh" "$PR" | jq -c --arg n "$AGENT" '.agents[] | select(.name == $n)')"
[[ -n "$AGENT_JSON" ]] || { echo "Error: no agent '$AGENT' on the roster for PR #$PR" >&2; exit 1; }
if [[ -n "$MODEL_ARG" ]]; then
    CHAIN=("$MODEL_ARG")
else
    [[ "$(jq -r .engine <<<"$AGENT_JSON")" == "pi" ]] \
        || { echo "Error: agent '$AGENT' is not configured for the pi engine (# Configuration .pi)" >&2; exit 1; }
    mapfile -t CHAIN < <(jq -r '.pi_models[]' <<<"$AGENT_JSON")
    if [[ " ${CHAIN[*]} " == *" zai/"* ]] && jq -e '.behind' <<<"$(zai_quota)" >/dev/null; then
        mapfile -t CHAIN < <(printf '%s\n' "${CHAIN[@]}" | grep '^zai/'; printf '%s\n' "${CHAIN[@]}" | grep -v '^zai/')
        echo "Z.ai plan is behind its weekly pace: trying zai first" >&2
    fi
fi
SCOPE_JSON="$(jq -c .changed_files <<<"$AGENT_JSON")"

if [[ "$SANDBOX" == docker ]] && ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    [[ "$IMAGE" == "$DEFAULT_IMAGE" ]] || { echo "Error: image $IMAGE not found" >&2; exit 1; }
    echo "Building $IMAGE (first use)..." >&2
    docker build -q -t "$IMAGE" "$SCRIPT_DIR/../pi" >&2 || { echo "Error: image build failed" >&2; exit 1; }
fi

mkdir -p "$T/work" "$T/review" "$T/out"
printf '%s\n' "$SCOPE_JSON" > "$T/review/scope.json"
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
3. Report through your tools - your written reply is discarded:
   - report_finding once per finding, as soon as you have checked it. If a call
     returns an error, the finding was NOT recorded: fix it and call again.
   - reopen_thread for each prior comment you reopen (step 1).
   - finish_review exactly once at the end, also when there is nothing to
     report. Without it your review counts as not delivered.
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

# Headless Claude Code for a replay: same scratch copy, same prompt with
# host paths, structured output instead of the Pi review tools.
claude_replay() {
    local cm="${MODEL#claude}"; cm="${cm#:}"; cm="${cm:-$(jq -r '.model // empty' <<<"$AGENT_JSON")}"
    command -v claude >/dev/null || { echo "Error: claude CLI not found" >&2; return 1; }
    git -C "$T/work" reset -q --hard && git -C "$T/work" clean -qfdx
    sed -e "s|/review/|$T/review/|g" -e "s|^/work (your cwd)|Your working directory|" \
        -e '/^3\. Report through your tools/,$d' "$T/review/prompt.md" > "$T/review/prompt-claude.md"
    printf '%s\n' '3. Return your report as the structured output: every finding (severity P1|P2|P3, a file' \
        '   from your scope, a line in the new file inside a diff hunk, title, body) and every' \
        '   reopen (comment_id from prior-comments.txt, reason). Empty lists if nothing to report.' \
        >> "$T/review/prompt-claude.md"
    local schema='{"type":"object","additionalProperties":false,"required":["findings","reopens"],"properties":{
      "findings":{"type":"array","items":{"type":"object","additionalProperties":false,
        "required":["severity","file","line","title","body"],"properties":{"severity":{"enum":["P1","P2","P3"]},
        "file":{"type":"string"},"line":{"type":"integer","minimum":1},"title":{"type":"string","minLength":1},
        "body":{"type":"string","minLength":1}}}},
      "reopens":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["comment_id","reason"],
        "properties":{"comment_id":{"type":"integer"},"reason":{"type":"string","minLength":1}}}}}}'
    local START=$SECONDS rc
    set +e
    # Invocation shape follows Fleet's vigil ephemeral sessions (one-shot -p,
    # an entrypoint tag, the result envelope read on every exit).
    (cd "$T/work" && env -u ANTHROPIC_API_KEY CLAUDE_CODE_ENTRYPOINT=pr-review-loop \
        timeout -k 30 "$TIMEOUT" claude -p --model "${cm:-sonnet}" \
        --no-session-persistence --output-format json --permission-mode acceptEdits \
        --allowedTools "Read Grep Glob Bash Edit Write" --disallowedTools "Bash(gh *)" "Bash(git push*)" "Bash(curl *)" \
        --add-dir "$T/review" --json-schema "$schema" < "$T/review/prompt-claude.md" > "$T/claude.out" 2> "$T/claude.err")
    rc=$?
    set -e
    SECS=$((SECONDS - START))
    # Claude emits a result envelope on every exit; an API error or a usage
    # limit there is the provider failing, not the reviewer.
    local why
    why="$(jq -r 'select(.is_error == true) | [.api_error_status, .terminal_reason, .result] | map(select(. != null) | tostring) | join(" | ")' \
        "$T/claude.out" 2>/dev/null || true)"
    if [[ -n "$why" ]] && grep -qiE 'limit|quota|429|5[0-9][0-9]|overloaded|rate|credit|auth|401|403' <<<"$why"; then
        echo "Provider failure on $MODEL: $why" >&2
        TRIED+=("$MODEL:provider-error"); return 2
    fi
    TRIED+=("$MODEL")
    REPORT="$(jq -ce '.structured_output | select(type == "object" and (.findings | type == "array"))
        | .reopens //= []' "$T/claude.out" 2>/dev/null)" || REPORT=""
    if [[ -z "$REPORT" ]]; then
        echo "Error: $MODEL produced no structured report (claude exit $rc; 124 = timeout after ${TIMEOUT}s)${why:+: $why}" >&2
        tail -n 20 "$T/claude.err" >&2; jq -r '.result // empty' "$T/claude.out" 2>/dev/null | tail -n 20 >&2
        return 1
    fi
    USAGE_JSON="$(jq -c '{input: (.usage.input_tokens // 0), output: (.usage.output_tokens // 0),
        cacheRead: (.usage.cache_read_input_tokens // 0), cacheWrite: (.usage.cache_creation_input_tokens // 0),
        usd: (.total_cost_usd // 0), billing: "subscription"}' "$T/claude.out")"
}

# Run "$@" in the background and stop it only when it HANGS: no new output in
# $PIOUT for IDLE_TIMEOUT seconds, or past the TIMEOUT hard cap. A long review
# that keeps streaming is left alone. Sets PI_RC (124 when stopped).
run_watched() {
    "$@" & local pid=$! idle
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        idle=$(( $(date +%s) - $(stat -c %Y "$PIOUT" 2>/dev/null || date +%s) ))
        if (( idle > IDLE_TIMEOUT || SECONDS - START > TIMEOUT )); then
            echo "Stopping $MODEL: $( (( idle > IDLE_TIMEOUT )) && echo "no output for ${idle}s" || echo "over the ${TIMEOUT}s cap")" >&2
            docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
            pkill -TERM -P "$pid" 2>/dev/null || true; kill -TERM "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true; PI_RC=124; return
        fi
    done
    wait "$pid"; PI_RC=$?
}

# ---- run the chain ----
REPORT="" USAGE_JSON="" SECS=0
for MODEL in "${CHAIN[@]}"; do
    if [[ ( "$MODEL" == claude || "$MODEL" == claude:* ) && "$REPLAY" == true ]]; then
        claude_replay && break
        [[ $? -eq 2 ]] && continue   # usage limit / API error: a provider failure
        exit 3
    fi
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
    if near_cap "$PROVIDER"; then
        echo "Skipping $MODEL: Z.ai plan at ${PLAN_CAP}%+ of a window; past the limit it bills" >&2
        TRIED+=("$MODEL:plan-cap"); continue
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
    rm -f "$T/out/"*
    PIOUT="$RUNS_DIR/$(date -u +%Y%m%dT%H%M%SZ)-${AGENT}-${SHA:0:8}-${MODEL//\//_}.jsonl"
    : > "$PIOUT"
    echo "Pi run log: $PIOUT (watch: pi-watch.sh)" >&2
    START=$SECONDS
    set +e
    if [[ "$SANDBOX" == docker ]]; then
        run_watched bash -c 'o="$0" e="$1"; shift; exec "$@" > "$o" 2> "$e"' "$PIOUT" "$T/pi.err" \
            docker run --rm --name "$CONTAINER" \
            --user "$(id -u):$(id -g)" --cap-drop ALL --security-opt no-new-privileges \
            --memory 4g --pids-limit 512 \
            "${DOCKER_ENV[@]}" \
            -v "$T/work:/work" -v "$T/review:/review:ro" -v "$T/out:/out" -w /work \
            -v "$SCRIPT_DIR/../pi/review-tools.ts:/opt/pi-ext/review-tools.ts:ro" \
            "$IMAGE" --mode json --no-session --no-extensions -e /opt/pi-ext/review-tools.ts \
            --model "$MODEL" @/review/prompt.md
    else
        # Same prompt with host paths; only the model key crosses into the env.
        sed -e "s|/review/|$T/review/|g" -e "s|^/work (your cwd)|Your working directory|" \
            "$T/review/prompt.md" > "$T/review/prompt-host.md"
        # Strip the environment inside a subshell (never via argv, where ps shows it):
        # keep HOME, PATH, the Pi config dir and the one model key.
        KEEP=" HOME PATH PI_CODING_AGENT_DIR KEEP ${KEY_VAR:-} "
        run_watched bash -c '
            for v in $(compgen -e); do [[ "$KEEP" == *" $v "* ]] || unset "$v"; done
            export PI_OFFLINE=1 PI_REVIEW_DIR="$1" PI_REVIEW_OUT="$2"
            [[ -n "$3" && -r "$3" ]] && { set -a; . "$3"; set +a; }
            cd "$0" && exec pi --mode json --no-session --no-extensions -e "$4" --model "$5" "@$1/prompt-host.md" \
                < /dev/null > "$6" 2> "$7"' \
            "$T/work" "$T/review" "$T/out" "${PI_REVIEW_ENV_FILE:-}" "$SCRIPT_DIR/../pi/review-tools.ts" \
            "$MODEL" "$PIOUT" "$T/pi.err"
    fi
    set -e
    SECS=$((SECONDS - START))

    # Pi reports a provider error as stopReason "error" and still exits 0.
    LAST="$(jq -c 'select(.type == "agent_end") | [.messages[] | select(.role == "assistant")] | last' "$PIOUT" 2>/dev/null | tail -n 1)"
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

    # ---- the report is what the tools recorded, and only if it was closed ----
    TEXT="$(jq -r '[.content[]? | select(.type == "text") | .text] | join("")' <<<"${LAST:-null}" 2>/dev/null || true)"
    REPORT=""
    if [[ -f "$T/out/done" ]]; then
        REPORT="$(jq -nc --slurpfile f <(cat "$T/out/findings.jsonl" 2>/dev/null) \
            --slurpfile r <(cat "$T/out/reopens.jsonl" 2>/dev/null) '{findings: $f, reopens: $r}')" || REPORT=""
    fi
    if [[ -z "$REPORT" ]]; then
        # A model that crashed, timed out or never closed its report looks exactly
        # like a reviewer with nothing to say. It is a strike, not a fallback.
        echo "Error: $MODEL never called finish_review (pi exit $PI_RC; 124 = stopped as hung or over the cap)" >&2
        echo "--- pi stderr (tail) ---" >&2; tail -n 20 "$T/pi.err" >&2
        echo "--- final reply (tail) ---" >&2; tail -n 40 <<<"$TEXT" >&2
        exit 3
    fi
    USAGE_JSON="$(jq -sc '[.[] | select(.type == "agent_end") | .messages[] | select(.role == "assistant") | .usage]
        | {input: (map(.input // 0) | add // 0), output: (map(.output // 0) | add // 0),
           cacheRead: (map(.cacheRead // 0) | add // 0), cacheWrite: (map(.cacheWrite // 0) | add // 0),
           usd: (map(.cost.total // 0) | add // 0)}' "$PIOUT")"
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
