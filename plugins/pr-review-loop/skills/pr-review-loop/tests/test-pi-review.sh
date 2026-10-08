#!/usr/bin/env bash
# pi-review.sh, run for real against a fake `gh` and a fake `docker`.
#
# The fake docker plays Pi in --mode json: for each model it prints the events
# stored in $T/pi/<model with / as _> and plays the review tools by writing
# $T/pi/<model>.report into the mounted /out (see `says` / `fails` below), so
# each case checks what the wrapper does with a given run - which model it ends
# on, what it reports, and which exit code the orchestrator sees.
#
# Usage: tests/test-pi-review.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_REVIEW="$SCRIPT_DIR/../scripts/pi-review.sh"
T="$(mktemp -d)"; trap 'rm -rf -- "$T"' EXIT
PASSED=0; FAILED=0
ok(){ PASSED=$((PASSED+1)); echo "  PASS: $1"; }
bad(){ FAILED=$((FAILED+1)); echo "  FAIL: $1"; }

# A repo with a base commit and one PR commit. The root config routes pi-agent
# down a chain, keeps claude-agent on Claude, and gives fallback-agent a chain
# that ends in claude.
REPO="$T/repo"; mkdir -p "$REPO/src"
G(){ git -C "$REPO" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null "$@"; }
printf 'x = 0\n' > "$REPO/src/a.py"
G init -q; G add -A; G commit -q -m base
printf 'x = 1\n' > "$REPO/src/a.py"; printf 'y = 2\n' > "$REPO/src/b.py"
cat > "$REPO/AGENT-REVIEWERS.md" <<'MD'
# Configuration

```json
{"defaults_version_checked": "99.0.0",
 "disabled": ["code-reviewer", "silent-failure-hunter", "pr-test-analyzer",
              "comment-analyzer", "type-design-analyzer", "code-simplifier"],
 "pi": {"model": "deepseek/deepseek-chat",
        "agents": {"pi-agent": ["zai/glm-5.1", "google/gemini-2.5-flash"],
                   "fallback-agent": ["zai/glm-5.1", "claude"]}}}
```

# Agents

## pi-agent
Look for bugs.

## claude-agent
Look for bugs too.

## fallback-agent
Also bugs.
MD
G add -A; G commit -q -m pr
SHA="$(G rev-parse HEAD)"

mkdir -p "$T/bin" "$T/pi"
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\0' "$@" >> "$GH_LOG"; printf '\n' >> "$GH_LOG"
case "$*" in
  "repo view"*)                 echo "o/r" ;;
  "pr view"*headRefOid*)        echo "$FAKE_HEAD" ;;
  "pr view"*commits*)           echo "$FAKE_FIRST" ;;
  "pr diff"*)                   echo "diff --git a/src/a.py b/src/a.py" ;;
  "api graphql"*)               echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' ;;
  *)                            echo '{}' ;;
esac
GH
cat > "$T/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
[[ "$1" == run ]] || exit 0
printf '%s\n' "$*" >> "$DOCKER_LOG.args"
while [[ $# -gt 0 && "$1" != --model ]]; do shift; done
m="${2//\//_}"; echo "$2" >> "$DOCKER_LOG"
out="$(tr ' ' '\n' < <(tail -n 1 "$DOCKER_LOG.args") | sed -n 's|:/out$||p')"
if [[ -f "$PI_DIR/$m.report" ]]; then   # the model called the tools
    jq -c '.findings[]' "$PI_DIR/$m.report" > "$out/findings.jsonl"
    jq -c '.reopens[]?' "$PI_DIR/$m.report" > "$out/reopens.jsonl"
    jq -e '.closed != false' "$PI_DIR/$m.report" >/dev/null && echo "x" > "$out/done"
fi
cat "$PI_DIR/$m" 2>/dev/null || { echo "no fake for $2" >&2; exit 1; }
DOCKER
chmod +x "$T/bin/gh" "$T/bin/docker"

# says <model> <report json>: Pi ran and reported that through the tools.
# A non-JSON second argument means it answered in prose and never reported.
says(){ rm -f "$T/pi/${1//\//_}.report"
  jq -e . <<<"$2" >/dev/null 2>&1 && printf '%s\n' "$2" > "$T/pi/${1//\//_}.report"
  jq -nc --arg t "$2" '{type: "agent_end", messages: [
    {role: "assistant", stopReason: "toolUse", usage: {input: 100, output: 10, cacheRead: 900, cacheWrite: 0}, content: []},
    {role: "assistant", stopReason: "stop", usage: {input: 50, output: 20, cacheRead: 1000, cacheWrite: 0},
     content: [{type: "text", text: $t}]}]}' > "$T/pi/${1//\//_}"; }
# fails <model> <error>: the provider refused (Pi still exits 0).
fails(){ rm -f "$T/pi/${1//\//_}.report"; jq -nc --arg e "$2" '{type: "agent_end", messages: [
    {role: "assistant", stopReason: "error", errorMessage: $e, usage: {input: 0, output: 0}, content: []}]}' \
    > "$T/pi/${1//\//_}"; }
fence='```'
report(){ printf '%s' "$1"; }
EMPTY='{"findings": [], "reopens": []}'

# run <agent> [extra args...] -> OUT, RC; logs: $T/gh.log, $T/docker.log
run(){ : > "$T/gh.log"; : > "$T/docker.log"; : > "$T/docker.log.args"; set +e
  OUT=$(cd "$REPO" && PATH="$T/bin:$PATH" GH_LOG="$T/gh.log" DOCKER_LOG="$T/docker.log" PI_DIR="$T/pi" \
        FAKE_HEAD="${FAKE_HEAD:-$SHA}" FAKE_FIRST="$SHA" \
        PR_REVIEW_LOOP_TEST_CHANGED_FILES=$'src/a.py\nsrc/b.py' \
        PI_REVIEW_CACHE_DIR="$T/cache" DREAM_HOME="$T/dream" PI_CODING_AGENT_DIR="${PI_CODING_AGENT_DIR:-$T/no-pi}" \
        PRIOR_SEEN="${PRIOR_SEEN:-/dev/null}" CLAUDE_LOG="${CLAUDE_LOG:-/dev/null}" FAKE_CLAUDE_NOREPORT="${FAKE_CLAUDE_NOREPORT:-}" \
        ZAI_API_KEY="${ZAI_API_KEY-k}" GEMINI_API_KEY="${GEMINI_API_KEY-k}" DEEPSEEK_API_KEY=k \
        bash "$PI_REVIEW" 42 "$1" "$SHA" "${@:2}" 2>"$T/err"); RC=$?; set -e; }
ran(){ paste -sd' ' "$T/docker.log"; }
posts(){ tr '\0' ' ' < "$T/gh.log" | grep -c -- '--method POST' || true; }

echo "=== a valid report comes back as JSON; out-of-scope findings are split off ==="
rm -rf "$T/cache"
says zai/glm-5.1 "$(report '{"findings": [
  {"severity": "P2", "file": "src/a.py", "line": 1, "title": "x is wrong", "body": "judgement: rename"},
  {"severity": "P1", "file": "elsewhere.py", "line": 3, "title": "not mine", "body": "b"}], "reopens": []}')"
run pi-agent
[[ "$RC" -eq 0 ]] && ok "exit 0" || bad "rc=$RC: $(cat "$T/err")"
jq -e '.model == "zai/glm-5.1" and .tried == ["zai/glm-5.1"]' <<<"$OUT" >/dev/null && ok "names the model that ran" || bad "model: $OUT"
jq -e '.report.findings == [{"severity":"P2","file":"src/a.py","line":1,"title":"x is wrong","body":"judgement: rename"}]' <<<"$OUT" >/dev/null \
    && ok "in-scope finding in report" || bad "report: $OUT"
jq -e '.dropped | length == 1 and .[0].file == "elsewhere.py"' <<<"$OUT" >/dev/null && ok "out-of-scope finding dropped" || bad "dropped: $OUT"
jq -e '.usage == {"input":150,"output":30,"cacheRead":1900,"cacheWrite":0,"usd":0}' <<<"$OUT" >/dev/null \
    && ok "usage summed over every turn" || bad "usage: $(jq -c .usage <<<"$OUT")"
[[ "$(posts)" -eq 0 ]] && ok "posts nothing (the Haiku poster does)" || bad "posts=$(posts)"
jq -e 'select(.kind == "reviewer-fired" and .reviewer == "pi-agent" and .status == "reported" and .model == "zai/glm-5.1")' \
    "$T/dream/markers/pr-review-loop.jsonl" >/dev/null && ok "firing marker names the model" || bad "no firing marker"

echo "=== an empty report is still a report ==="
says zai/glm-5.1 "$(report "$EMPTY")"
run pi-agent
[[ "$RC" -eq 0 ]] && jq -e '.report.findings == []' <<<"$OUT" >/dev/null && ok "exit 0, no findings" || bad "rc=$RC"

echo "=== a model that never closed its report is a strike, not a fallback ==="
says zai/glm-5.1 "Looks good to me!"; says google/gemini-2.5-flash "$(report "$EMPTY")"
run pi-agent
[[ "$RC" -eq 3 ]] && ok "no tool report -> exit 3" || bad "rc=$RC"
[[ "$(ran)" == "zai/glm-5.1" ]] && ok "did not move on to the next model" || bad "ran: $(ran)"
says zai/glm-5.1 '{"closed": false, "findings": [{"severity": "P2", "file": "src/a.py", "line": 1, "title": "t", "body": "b"}]}'
run pi-agent
[[ "$RC" -eq 3 ]] && ok "findings recorded but finish_review never called -> exit 3" || bad "rc=$RC out=$OUT"
grep -q 'review-tools.ts' "$T/docker.log.args" && grep -q -- '--no-extensions -e /opt/pi-ext/review-tools.ts' "$T/docker.log.args" \
    && ok "only the review tools extension is loaded" || bad "args: $(cat "$T/docker.log.args")"

echo "=== a provider failure moves down the chain ==="
fails zai/glm-5.1 "401 token expired or incorrect"; says google/gemini-2.5-flash "$(report "$EMPTY")"
run pi-agent
[[ "$RC" -eq 0 && "$(ran)" == "zai/glm-5.1 google/gemini-2.5-flash" ]] && ok "fell through to gemini" || bad "rc=$RC ran=$(ran)"
jq -e '.model == "google/gemini-2.5-flash" and .tried == ["zai/glm-5.1:provider-error", "google/gemini-2.5-flash"]' <<<"$OUT" >/dev/null \
    && ok "tried records both" || bad "tried: $(jq -c .tried <<<"$OUT")"
[[ ! -e "$T/cache/exhausted/zai" ]] && ok "an auth error does not mark the provider exhausted" || bad "zai marked exhausted"

echo "=== exhausted quota is remembered across runs ==="
fails zai/glm-5.1 "429 You have exceeded your monthly quota"
run pi-agent
[[ "$RC" -eq 0 && -e "$T/cache/exhausted/zai" ]] && ok "quota error marks zai exhausted" || bad "rc=$RC"
says zai/glm-5.1 "$(report "$EMPTY")"
run pi-agent
[[ "$(ran)" == "google/gemini-2.5-flash" ]] && ok "next run skips zai without calling it" || bad "ran: $(ran)"
touch -d '2 hours ago' "$T/cache/exhausted/zai"
run pi-agent
[[ "$(ran)" == "zai/glm-5.1" ]] && ok "after the TTL zai is tried again" || bad "ran: $(ran)"
rm -rf "$T/cache"

echo "=== chain endings ==="
fails zai/glm-5.1 "503 unavailable"
run fallback-agent
[[ "$RC" -eq 5 ]] && jq -e '. == {"fallback": "claude", "model": ""}' <<<"$OUT" >/dev/null \
    && ok "chain reaching claude -> exit 5, agent's own model" || bad "rc=$RC out=$OUT"
fails google/gemini-2.5-flash "401 bad key"
run pi-agent
[[ "$RC" -eq 6 ]] && ok "every provider failed -> exit 6" || bad "rc=$RC"
says google/gemini-2.5-flash "$(report "$EMPTY")"
ZAI_API_KEY= run pi-agent
[[ "$RC" -eq 0 && "$(ran)" == "google/gemini-2.5-flash" ]] && jq -e '.tried[0] == "zai/glm-5.1:no-key"' <<<"$OUT" >/dev/null \
    && ok "a missing key skips that model" || bad "rc=$RC ran=$(ran)"

echo "=== the host Pi config is the one source of models ==="
says zai/glm-5.1 "$(report "$EMPTY")"
run pi-agent
grep -q 'models.json' "$T/docker.log.args" && bad "mounted a models.json with no host config" || ok "no host config -> the image's own models.json"
mkdir -p "$T/pi-home" && echo '{"providers": {}}' > "$T/pi-home/models.json" && echo '{}' > "$T/pi-home/auth.json"
PI_CODING_AGENT_DIR="$T/pi-home" run pi-agent
grep -q -- "-v $T/pi-home/models.json:/opt/pi-agent/models.json:ro" "$T/docker.log.args" \
    && ok "host models.json mounted read-only" || bad "args: $(cat "$T/docker.log.args")"
grep -q 'auth.json' "$T/docker.log.args" && bad "auth.json mounted" || ok "auth.json never mounted"
echo '{"providers": {"zai-payg": {"apiKey": "ZAI_API_KEY", "models": [{"id": "glm-5.1"}]}}}' > "$T/pi-home/models.json"
says zai-payg/glm-5.1 "$(report "$EMPTY")"
PI_CODING_AGENT_DIR="$T/pi-home" run pi-agent --model zai-payg/glm-5.1
[[ "$RC" -eq 0 ]] && grep -q -- '-e ZAI_API_KEY ' "$T/docker.log.args" \
    && ok "custom provider's key variable comes from models.json" || bad "rc=$RC args: $(cat "$T/docker.log.args")"

echo "=== a moved head stops before Pi runs ==="
FAKE_HEAD=0000000000000000000000000000000000000000 run pi-agent
[[ "$RC" -eq 2 && ! -s "$T/docker.log" ]] && ok "exit 2 before docker run" || bad "rc=$RC ran=$(ran)"

echo "=== --replay reviews a historical commit with the given model ==="
says zai/glm-5.1 "$(report "$EMPTY")"
: > "$T/dream/markers/pr-review-loop.jsonl"
FAKE_HEAD=0000000000000000000000000000000000000000 run claude-agent --replay --model zai/glm-5.1
[[ "$RC" -eq 0 ]] && ok "replay ignores the PR head and the agent's engine" || bad "rc=$RC: $(cat "$T/err")"
tr '\0' ' ' < "$T/gh.log" | grep -q 'graphql' && bad "replay fetched prior comments" || ok "replay skips prior comments"
[[ ! -s "$T/dream/markers/pr-review-loop.jsonl" ]] && ok "replay writes no firing marker" || bad "replay wrote a marker"
run claude-agent --replay
[[ "$RC" -eq 1 ]] && ok "--replay without --model -> exit 1" || bad "rc=$RC"
printf '=== Thread (ID: 7) ===\nearlier finding\n' > "$T/prior.txt"
cat > "$T/bin/docker-spy" <<'SPY'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in *:/review:ro) cp -f "${a%%:*}/prior-comments.txt" "$PRIOR_SEEN" ;; esac; done
exec "$(dirname "$0")/docker-real" "$@"
SPY
mv -f "$T/bin/docker" "$T/bin/docker-real"; mv -f "$T/bin/docker-spy" "$T/bin/docker"; chmod +x "$T/bin/docker"
PRIOR_SEEN="$T/prior-seen" run claude-agent --replay --model zai/glm-5.1 --prior "$T/prior.txt"
export -n PRIOR_SEEN 2>/dev/null || true
[[ "$RC" -eq 0 ]] && grep -q 'earlier finding' "$T/prior-seen" 2>/dev/null \
    && ok "--prior reaches the reviewer as its prior comments" || bad "rc=$RC seen=$(cat "$T/prior-seen" 2>/dev/null)"
mv -f "$T/bin/docker-real" "$T/bin/docker"
run claude-agent --prior "$T/prior.txt"
[[ "$RC" -eq 1 ]] && ok "--prior without --replay -> exit 1" || bad "rc=$RC"

echo "=== --replay with a claude entry runs headless Claude Code on the subscription ==="
cat > "$T/bin/claude" <<'CL'
#!/usr/bin/env bash
{ echo "key=${ANTHROPIC_API_KEY-unset}"; printf '%s\n' "$*"; } > "$CLAUDE_LOG"
[[ -n "${FAKE_CLAUDE_NOREPORT:-}" ]] && { echo '{"result": "looks fine", "usage": {}}'; exit 0; }
echo '{"structured_output": {"findings": [{"severity": "P2", "file": "src/a.py", "line": 1, "title": "t", "body": "b"}], "reopens": []},
       "usage": {"input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 0},
       "total_cost_usd": 0.03}'
CL
chmod +x "$T/bin/claude"
ANTHROPIC_API_KEY=sk-should-not-be-used CLAUDE_LOG="$T/claude.log" run claude-agent --replay --model claude:haiku
[[ "$RC" -eq 0 ]] && jq -e '.model == "claude:haiku" and .usage.billing == "subscription" and (.report.findings | length) == 1' <<<"$OUT" >/dev/null \
    && ok "claude:haiku replay reports through structured output" || bad "rc=$RC out=$OUT err=$(tail -3 "$T/err")"
grep -q '^key=unset$' "$T/claude.log" && ok "ANTHROPIC_API_KEY unset: billed to the subscription" || bad "claude saw: $(head -1 "$T/claude.log")"
grep -q -- '--model haiku' "$T/claude.log" && grep -q 'Bash(gh \*)' "$T/claude.log" \
    && ok "right model, gh blocked" || bad "args: $(tail -1 "$T/claude.log")"
[[ ! -s "$T/docker.log" ]] && ok "no docker for a claude replay" || bad "docker ran: $(ran)"
CLAUDE_LOG="$T/claude.log" FAKE_CLAUDE_NOREPORT=1 run claude-agent --replay --model claude
[[ "$RC" -eq 3 ]] && ok "no structured report -> exit 3" || bad "rc=$RC"
grep -q -- '--model sonnet' "$T/claude.log" && ok "bare claude falls back to sonnet for an agent with no model" || bad "args: $(tail -1 "$T/claude.log")"

echo "=== setup refusals ==="
run claude-agent
[[ "$RC" -eq 1 ]] && ok "agent not on the pi engine -> exit 1" || bad "rc=$RC"

echo "=== # Configuration .pi parsing and routing ==="
PARSE="$SCRIPT_DIR/../scripts/_parse_configuration.sh"
cfg(){ printf '# Configuration\n\n```json\n%s\n```\n' "$1" > "$T/cfg.md"; bash "$PARSE" "$T/cfg.md" >/dev/null 2>&1; }
cfg '{"pi": {"all": true}}' && bad "all:true with no model accepted" || ok "all:true with no model rejected"
cfg '{"pi": {"agents": {"x": 5}}}' && bad "numeric agent value accepted" || ok "numeric agent value rejected"
cfg '{"pi": {"agents": {"x": []}}}' && bad "empty chain accepted" || ok "empty chain rejected"
cfg '{"pi": {"agents": {"x": ["zai/glm-5.1", ""]}}}' && bad "empty chain entry accepted" || ok "empty chain entry rejected"
cfg '{"pi": {"agents": {"x": ["zai/glm-5.1", "claude"]}}}' && ok "chain accepted" || bad "chain rejected"
cfg '{"pi": {"all": true, "model": ["zai/glm-5.1", "claude"]}}' && ok "default model may be a chain" || bad "default chain rejected"
cfg '{"pi": {"agents": {"x": ["zai/glm-5.1", "claude:haiku"]}}}' && ok "claude:haiku accepted" || bad "claude:haiku rejected"
cfg '{"pi": {"agents": {"x": "claude:gpt"}}}' && bad "claude:gpt accepted" || ok "claude:<unknown> rejected"
ROUTE="$(cd "$REPO" && sed -i 's/"agents": {"pi-agent"/"all": true, "agents": {"claude-agent": false, "pi-agent"/' AGENT-REVIEWERS.md \
    && PR_REVIEW_LOOP_TEST_CHANGED_FILES=src/a.py bash "$SCRIPT_DIR/../scripts/discover-agents.sh" 0 2>/dev/null \
    | jq -c '[.agents[] | {name, engine, pi_models}] | sort_by(.name)')"
[[ "$ROUTE" == '[{"name":"claude-agent","engine":"claude","pi_models":null},{"name":"fallback-agent","engine":"pi","pi_models":["zai/glm-5.1","claude"]},{"name":"pi-agent","engine":"pi","pi_models":["zai/glm-5.1","google/gemini-2.5-flash"]}]' ]] \
    && ok "chains pass through; an explicit false keeps an agent on claude" || bad "routing: $ROUTE"
ROUTE="$(cd "$REPO" && sed -i 's/"fallback-agent": \["zai\/glm-5.1", "claude"\]/"fallback-agent": ["claude", "zai\/glm-5.1"]/' AGENT-REVIEWERS.md \
    && PR_REVIEW_LOOP_TEST_CHANGED_FILES=src/a.py bash "$SCRIPT_DIR/../scripts/discover-agents.sh" 0 2>/dev/null \
    | jq -r '.agents[] | select(.name == "fallback-agent") | .engine')"
[[ "$ROUTE" == claude ]] && ok "a chain starting with claude is a Claude agent" || bad "engine: $ROUTE"
ROUTE="$(cd "$REPO" && sed -i 's/"fallback-agent": \["claude",/"fallback-agent": ["claude:haiku",/' AGENT-REVIEWERS.md \
    && PR_REVIEW_LOOP_TEST_CHANGED_FILES=src/a.py bash "$SCRIPT_DIR/../scripts/discover-agents.sh" 0 2>/dev/null \
    | jq -c '.agents[] | select(.name == "fallback-agent") | {engine, model}')"
[[ "$ROUTE" == '{"engine":"claude","model":"haiku"}' ]] && ok "claude:haiku first -> a Claude agent on haiku" || bad "got: $ROUTE"
says zai/glm-5.1 "$(report "$EMPTY")"
(cd "$REPO" && sed -i 's/"fallback-agent": \["claude:haiku", "zai\/glm-5.1"\]/"fallback-agent": ["zai\/glm-5.1", "claude:sonnet"]/' AGENT-REVIEWERS.md)
fails zai/glm-5.1 "503 unavailable"
run fallback-agent
[[ "$RC" -eq 5 ]] && jq -e '.model == "sonnet"' <<<"$OUT" >/dev/null && ok "falling to claude:sonnet names sonnet" || bad "rc=$RC out=$OUT"

echo ""; echo "Passed: $PASSED  Failed: $FAILED"; [[ "$FAILED" -eq 0 ]]
