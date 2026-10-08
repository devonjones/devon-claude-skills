#!/usr/bin/env bash
# pi-review.sh, run for real against a fake `gh` and a fake `docker`.
#
# The fake docker prints whatever Pi "said" ($FAKE_PI_OUT) and exits $FAKE_PI_RC,
# so each case checks what the wrapper does with a given Pi transcript: what it
# posts, what it refuses, and which exit code the orchestrator sees.
#
# Usage: tests/test-pi-review.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_REVIEW="$SCRIPT_DIR/../scripts/pi-review.sh"
T="$(mktemp -d)"; trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf -- "$T"' EXIT
PASSED=0; FAILED=0
ok(){ PASSED=$((PASSED+1)); echo "  PASS: $1"; }
bad(){ FAILED=$((FAILED+1)); echo "  FAIL: $1"; }

# A repo whose root config routes `pi-agent` to pi and leaves `claude-agent` alone.
REPO="$T/repo"; mkdir -p "$REPO/src"
printf 'x = 1\n' > "$REPO/src/a.py"; printf 'y = 2\n' > "$REPO/src/b.py"
cat > "$REPO/AGENT-REVIEWERS.md" <<'MD'
# Configuration

```json
{"defaults_version_checked": "99.0.0",
 "disabled": ["code-reviewer", "silent-failure-hunter", "pr-test-analyzer",
              "comment-analyzer", "type-design-analyzer", "code-simplifier"],
 "pi": {"model": "deepseek/deepseek-chat", "agents": {"pi-agent": true}}}
```

# Agents

## pi-agent
Look for bugs.

## claude-agent
Look for bugs too.
MD
git -C "$REPO" init -q
git -C "$REPO" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null add -A
git -C "$REPO" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null commit -q -m init
SHA="$(git -C "$REPO" rev-parse HEAD)"

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\0' "$@" >> "$GH_LOG"; printf '\n' >> "$GH_LOG"
case "$*" in
  "repo view"*)                 echo "o/r" ;;
  "pr view"*headRefOid*)        # FAKE_HEAD_AFTER: the head moves after the first read (a push mid-run)
      if [[ -n "${FAKE_HEAD_AFTER:-}" && -e "$GH_LOG.headread" ]]; then echo "$FAKE_HEAD_AFTER"
      else : > "$GH_LOG.headread"; echo "$FAKE_HEAD"; fi ;;
  "pr view"*commits*)           echo "$FAKE_HEAD" ;;
  "pr diff"*)                   [[ -n "${FAKE_DIFF_FAIL:-}" ]] && exit 4; echo "diff --git a/src/a.py b/src/a.py" ;;
  "api graphql"*)               # one resolved thread whose first comment is database id 7
      echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"T1","isResolved":true,"comments":{"nodes":[{"id":"C1","databaseId":7,"body":"x","author":{"login":"me"},"path":"src/a.py","line":1}]}}]}}}}}' ;;
  *"--method POST"*)
      [[ -n "${FAKE_POST_FAIL:-}" ]] && { echo '{"message":"Validation Failed"}'; exit 1; }
      echo '{"id":7}' ;;
  *)                            echo '{}' ;;
esac
GH
cat > "$T/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
case "$1" in
  run) echo run >> "$DOCKER_LOG"; printf '%s\n' "$*" >> "$DOCKER_LOG.args"
       if [[ -n "${FAKE_LOCK_SCRATCH:-}" ]]; then   # leave the wrapper an unremovable scratch dir
           w="$(tr ' ' '\n' <<<"$*" | sed -n 's|:/work$||p')"; mkdir -p "$w/locked/x"; chmod 500 "$w/locked"; fi
       printf '%s' "$FAKE_PI_OUT"; exit "${FAKE_PI_RC:-0}" ;;
  *)   exit 0 ;;
esac
DOCKER
chmod +x "$T/bin/gh" "$T/bin/docker"

# run <agent> [pi stdout]  -> sets OUT, RC; logs in $T/gh.log, $T/docker.log
run(){ : > "$T/gh.log"; rm -f "$T/gh.log.headread"; : > "$T/docker.log"; : > "$T/docker.log.args"; set +e
  OUT=$(cd "$REPO" && PATH="$T/bin:$PATH" GH_LOG="$T/gh.log" DOCKER_LOG="$T/docker.log" \
        FAKE_HEAD="${FAKE_HEAD:-$SHA}" FAKE_PI_OUT="${2:-}" FAKE_HEAD_AFTER="${FAKE_HEAD_AFTER:-}" FAKE_DIFF_FAIL="${FAKE_DIFF_FAIL:-}" \
        FAKE_LOCK_SCRATCH="${FAKE_LOCK_SCRATCH:-}" \
        PR_REVIEW_LOOP_TEST_CHANGED_FILES=$'src/a.py\nsrc/b.py' \
        PR_REVIEW_LOOP_PACE_S=0 PR_REVIEW_LOOP_PACE_DIR="$T/pace" DREAM_HOME="$T/dream" \
        DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY-k}" \
        bash "$PI_REVIEW" 42 "$1" "$SHA" 2>"$T/err"); RC=$?; set -e; }
posts(){ tr '\0' ' ' < "$T/gh.log" | grep -c -- '--method POST' || true; }
fence='```'

echo "=== a valid report posts in-scope findings and drops out-of-scope ones ==="
run pi-agent "thinking...
${fence}json
{\"findings\": [
  {\"severity\": \"P2\", \"file\": \"src/a.py\", \"line\": 1, \"title\": \"x is wrong\", \"body\": \"judgement: rename\"},
  {\"severity\": \"P1\", \"file\": \"elsewhere.py\", \"line\": 3, \"title\": \"not mine\", \"body\": \"b\"}],
 \"reopens\": []}
${fence}"
[[ "$RC" -eq 0 ]] && ok "exit 0" || bad "rc=$RC: $(cat "$T/err")"
[[ "$OUT" == *"P2 | src/a.py:1 | x is wrong"* ]] && ok "manifest line for the posted finding" || bad "manifest: $OUT"
[[ "$OUT" == *"DROPPED | elsewhere.py:3"* ]] && ok "out-of-scope finding dropped, not posted" || bad "manifest: $OUT"
[[ "$(posts)" -eq 1 ]] && ok "exactly one POST" || bad "posts=$(posts)"
grep -q 'engine: pi · model: deepseek/deepseek-chat' "$T/gh.log" \
    && ok "posted body names engine and model" || bad "body missing engine/model"
jq -e 'select(.kind == "reviewer-fired" and .reviewer == "pi-agent" and .status == "reported" and .posted == "1")' \
    "$T/dream/markers/pr-review-loop.jsonl" >/dev/null && ok "firing marker written" || bad "no firing marker"

echo "=== an empty report is 'No issues found' ==="
run pi-agent "${fence}json
{\"findings\": [], \"reopens\": []}
${fence}"
[[ "$RC" -eq 0 && "$OUT" == "No issues found" && "$(posts)" -eq 0 ]] && ok "rc 0, no posts" || bad "rc=$RC out=$OUT"

echo "=== a Pi that fails silently is NOT reported ==="
FAKE_PI_RC=1 run pi-agent '{"error":{"message":"API key not valid"}}'
[[ "$RC" -eq 3 && "$(posts)" -eq 0 ]] && ok "provider error -> exit 3, nothing posted" || bad "rc=$RC"
FAKE_PI_RC=0 run pi-agent "Looks good to me!"
[[ "$RC" -eq 3 ]] && ok "exit 0 with no JSON block -> exit 3" || bad "rc=$RC"
run pi-agent "${fence}json
{\"findings\": [{\"severity\": \"P2\", \"file\": \"src/a.py\", \"line\": \"1\", \"title\": \"t\", \"body\": \"b\"}]}
${fence}"
[[ "$RC" -eq 3 && "$(posts)" -eq 0 ]] && ok "string line number -> exit 3" || bad "rc=$RC"

echo "=== a moved head posts nothing and never runs Pi ==="
FAKE_HEAD=0000000000000000000000000000000000000000 run pi-agent "${fence}json
{\"findings\": [], \"reopens\": []}
${fence}"
[[ "$RC" -eq 2 && ! -s "$T/docker.log" ]] && ok "exit 2 before docker run" || bad "rc=$RC docker=$(cat "$T/docker.log")"

echo "=== a failed post is exit 4 ==="
FAKE_POST_FAIL=1 run pi-agent "${fence}json
{\"findings\": [{\"severity\": \"P3\", \"file\": \"src/b.py\", \"line\": 1, \"title\": \"t\", \"body\": \"b\"}], \"reopens\": []}
${fence}"
[[ "$RC" -eq 4 && "$OUT" == *"FAILED | src/b.py:1"* ]] && ok "exit 4 with FAILED line" || bad "rc=$RC out=$OUT"
[[ "$OUT" != *"No issues found"* ]] && ok "a failed post never reads as No issues found" || bad "out=$OUT"

echo "=== the head moves while Pi runs: nothing is posted ==="
FAKE_HEAD_AFTER=1111111111111111111111111111111111111111 run pi-agent "${fence}json
{\"findings\": [{\"severity\": \"P2\", \"file\": \"src/a.py\", \"line\": 1, \"title\": \"t\", \"body\": \"b\"}], \"reopens\": []}
${fence}"
[[ "$RC" -eq 2 && "$(posts)" -eq 0 ]] && grep -q 'moved' "$T/err" && ok "post-run head check: exit 2, no POST" || bad "rc=$RC posts=$(posts)"

echo "=== reopens ==="
run pi-agent "${fence}json
{\"findings\": [], \"reopens\": [{\"comment_id\": 7, \"reason\": \"the reply ignores the issue\"}]}
${fence}"
[[ "$RC" -eq 0 && "$OUT" == *"REOPENED | comment 7"* && "$OUT" != *"No issues found"* ]] && ok "reopen goes through reopen-comment.sh" || bad "rc=$RC out=$OUT"
tr '\0' ' ' < "$T/gh.log" | grep -q 'addPullRequestReviewComment' && grep -q 'the reply ignores the issue' "$T/gh.log" \
    && ok "the reopen reply carries the reason" || bad "no reopen reply in gh calls"
run pi-agent "${fence}json
{\"findings\": [], \"reopens\": [{\"comment_id\": \"7\", \"reason\": \"r\"}]}
${fence}"
[[ "$RC" -eq 3 ]] && ok "string comment_id -> exit 3" || bad "rc=$RC"

echo "=== finding paths are normalised before the scope check ==="
run pi-agent "${fence}json
{\"findings\": [{\"severity\": \"P2\", \"file\": \"./src/a.py\", \"line\": 1, \"title\": \"dot\", \"body\": \"b\"},
 {\"severity\": \"P2\", \"file\": \"/work/src/b.py\", \"line\": 1, \"title\": \"abs\", \"body\": \"b\"}], \"reopens\": []}
${fence}"
[[ "$RC" -eq 0 && "$(posts)" -eq 2 && "$OUT" == *"P2 | src/a.py:1 | dot"* && "$OUT" == *"P2 | src/b.py:1 | abs"* ]] \
    && ok "./src/a.py and /work/src/b.py posted as repo paths" || bad "rc=$RC posts=$(posts) out=$OUT"

echo "=== every finding dropped still answers the contract ==="
run pi-agent "${fence}json
{\"findings\": [{\"severity\": \"P2\", \"file\": \"elsewhere.py\", \"line\": 1, \"title\": \"t\", \"body\": \"b\"}], \"reopens\": []}
${fence}"
[[ "$RC" -eq 0 && "$OUT" == *"DROPPED"* && "$OUT" == *"No issues found"* ]] && ok "DROPPED line plus No issues found" || bad "out=$OUT"

echo "=== failures leave a firing marker that says so ==="
: > "$T/dream/markers/pr-review-loop.jsonl"
FAKE_PI_RC=1 run pi-agent 'garbage'
jq -e 'select(.kind == "reviewer-fired" and .status == "failed" and .exit == "3")' "$T/dream/markers/pr-review-loop.jsonl" >/dev/null \
    && ok "exit 3 run: marker status failed, exit 3" || bad "marker: $(cat "$T/dream/markers/pr-review-loop.jsonl")"

echo "=== the provider decides which key enters the container ==="
sed -i 's|"pi-agent": true|"pi-agent": "google/gemini-2.5-flash"|' "$REPO/AGENT-REVIEWERS.md"
GEMINI_API_KEY=k run pi-agent "${fence}json
{\"findings\": [], \"reopens\": []}
${fence}"
grep -q -- '-e GEMINI_API_KEY' "$T/docker.log.args" && ! grep -q -- '-e GOOGLE_API_KEY' "$T/docker.log.args" \
    && ok "google -> GEMINI_API_KEY, by name" || bad "args: $(cat "$T/docker.log.args")"
GEMINI_API_KEY= run pi-agent ""
[[ "$RC" -eq 1 ]] && grep -q GEMINI_API_KEY "$T/err" && ok "missing GEMINI_API_KEY -> exit 1" || bad "rc=$RC"
sed -i 's|"pi-agent": "google/gemini-2.5-flash"|"pi-agent": true|' "$REPO/AGENT-REVIEWERS.md"

echo "=== a failed setup step is exit 1, not its own code ==="
FAKE_DIFF_FAIL=1 run pi-agent ""
[[ "$RC" -eq 1 ]] && ok "gh pr diff exiting 4 -> exit 1 (not 'post failed')" || bad "rc=$RC"

echo "=== cleanup cannot change the outcome ==="
: > "$T/dream/markers/pr-review-loop.jsonl"
FAKE_LOCK_SCRATCH=1 run pi-agent "${fence}json
{\"findings\": [], \"reopens\": []}
${fence}"
[[ "$RC" -eq 0 && "$OUT" == "No issues found" ]] && grep -q 'could not remove' "$T/err" \
    && ok "unremovable scratch dir: still exit 0, with a warning" || bad "rc=$RC out=$OUT err=$(tail -2 "$T/err")"
jq -e 'select(.status == "reported" and .exit == "0")' "$T/dream/markers/pr-review-loop.jsonl" >/dev/null \
    && ok "firing marker still written" || bad "marker: $(cat "$T/dream/markers/pr-review-loop.jsonl")"

echo "=== setup refusals ==="
run claude-agent ""
[[ "$RC" -eq 1 ]] && ok "agent not on the pi engine -> exit 1" || bad "rc=$RC"
DEEPSEEK_API_KEY= run pi-agent ""
[[ "$RC" -eq 1 ]] && grep -q DEEPSEEK_API_KEY "$T/err" && ok "missing model key -> exit 1, names the var" || bad "rc=$RC"

echo "=== # Configuration .pi parsing and routing ==="
PARSE="$SCRIPT_DIR/../scripts/_parse_configuration.sh"
cfg(){ printf '# Configuration\n\n```json\n%s\n```\n' "$1" > "$T/cfg.md"; bash "$PARSE" "$T/cfg.md" >/dev/null 2>&1; }
cfg '{"pi": {"all": true}}' && bad "all:true with no model accepted" || ok "all:true with no model rejected"
cfg '{"pi": {"agents": {"x": 5}}}' && bad "numeric agent value accepted" || ok "numeric agent value rejected"
cfg '{"pi": {"agents": {"x": "openai/gpt-5-mini"}}}' && ok "per-agent model string needs no default model" || bad "per-agent model rejected"
cfg '{"pi": {"agents": {"x": "qwen3.8-max"}}}' && bad "model with no provider accepted" || ok "model with no provider rejected"
cfg '{"pi": {"agents": {"x": "/x/"}}}' && bad "/x/ accepted" || ok "/x/ rejected"
cfg '{"pi": {"model": "nope"}}' && bad ".model with no provider accepted" || ok ".model with no provider rejected"
# Each guard must reject with its own message, not by tripping a later jq error.
cfgerr(){ printf '# Configuration\n\n```json\n%s\n```\n' "$1" > "$T/cfg.md"; bash "$PARSE" "$T/cfg.md" 2>&1 >/dev/null; }
[[ "$(cfgerr '{"pi": 5}')" == *"must be an object (got number)"* ]] && ok "non-object pi rejected by its guard" || bad "msg: $(cfgerr '{"pi": 5}')"
[[ "$(cfgerr '{"pi": {"all": "yes", "model": "a/b"}}')" == *".all must be a boolean"* ]] && ok "non-boolean .all rejected by its guard" || bad "msg: $(cfgerr '{"pi": {"all": "yes"}}')"
[[ "$(cfgerr '{"pi": {"agents": ["a/b"]}}')" == *".agents must be an object"* ]] && ok "non-object .agents rejected by its guard" || bad "msg: $(cfgerr '{"pi": {"agents": ["a/b"]}}')"
ROUTE="$(cd "$REPO" && sed -i 's/"agents": {"pi-agent": true}/"all": true, "agents": {"claude-agent": false}/' AGENT-REVIEWERS.md \
    && PR_REVIEW_LOOP_TEST_CHANGED_FILES=src/a.py bash "$SCRIPT_DIR/../scripts/discover-agents.sh" 0 2>/dev/null \
    | jq -c '[.agents[] | {name, engine, pi_model}] | sort_by(.name)')"
[[ "$ROUTE" == '[{"name":"claude-agent","engine":"claude","pi_model":null},{"name":"pi-agent","engine":"pi","pi_model":"deepseek/deepseek-chat"}]' ]] \
    && ok "all:true routes to pi; an explicit false keeps an agent on claude" || bad "routing: $ROUTE"

ROUTE="$(cd "$REPO" && sed -i 's/"all": true, "agents": {"claude-agent": false}/"agents": {"pi-agent": "openai\/gpt-5-mini"}/' AGENT-REVIEWERS.md \
    && PR_REVIEW_LOOP_TEST_CHANGED_FILES=src/a.py bash "$SCRIPT_DIR/../scripts/discover-agents.sh" 0 2>/dev/null \
    | jq -c '[.agents[] | {name, engine, pi_model}] | sort_by(.name)')"
[[ "$ROUTE" == '[{"name":"claude-agent","engine":"claude","pi_model":null},{"name":"pi-agent","engine":"pi","pi_model":"openai/gpt-5-mini"}]' ]] \
    && ok "a per-agent model string routes that agent, overriding .model" || bad "routing: $ROUTE"

UNKNOWN="$(cd "$REPO" && sed -i 's/"agents": {"pi-agent": "openai\/gpt-5-mini"}/"agents": {"pi-agent": "openai\/gpt-5-mini", "ghost-agent": true}/' AGENT-REVIEWERS.md \
    && PR_REVIEW_LOOP_TEST_CHANGED_FILES=src/a.py bash "$SCRIPT_DIR/../scripts/discover-agents.sh" 0 2>/dev/null \
    | jq -c '.configuration.pi_agents_unknown')"
[[ "$UNKNOWN" == '["ghost-agent"]' ]] && ok "pi.agents naming no roster agent shows in pi_agents_unknown" || bad "pi_agents_unknown: $UNKNOWN"

echo ""; echo "Passed: $PASSED  Failed: $FAILED"; [[ "$FAILED" -eq 0 ]]
