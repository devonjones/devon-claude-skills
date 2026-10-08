#!/usr/bin/env bash
# eval-reviewer.sh scoring and assignment, on a pre-seeded cache.
#
# Replays and judge verdicts are written up front, so `run` skips both and only
# scores - no model is called. Checks: severity-weighted catch, pass/fail
# against a baseline, cheapest-passing recommendation, inconclusive below 8
# real findings, and `assign` spreading agents across subscriptions.
#
# Usage: tests/test-eval-reviewer.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL="$SCRIPT_DIR/../scripts/eval-reviewer.sh"
T="$(mktemp -d)"; trap 'rm -rf -- "$T"' EXIT
PASSED=0; FAILED=0
ok(){ PASSED=$((PASSED+1)); echo "  PASS: $1"; }
bad(){ FAILED=$((FAILED+1)); echo "  FAIL: $1"; }

mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\necho o/r\n' > "$T/bin/gh"
printf '#!/usr/bin/env bash\necho "judge must not be called" >&2; exit 1\n' > "$T/bin/claude"
chmod +x "$T/bin/gh" "$T/bin/claude"
D="$T/cache/eval/o_r"
S1=1111111111111111111111111111111111111111
S2=2222222222222222222222222222222222222222

# Agent x: 10 real findings and one noise. Grades: id 3 minor (half weight),
# id 8 churn (no weight), the rest material - 8 material, total weight 18.5.
mkdir -p "$D/x/replays" "$D/x/grades"
jq -n --arg s1 $S1 --arg s2 $S2 '[
  {pr:1,id:1,sha:$s1,severity:"P1",verdict:"real"},{pr:1,id:2,sha:$s1,severity:"P2",verdict:"real"},
  {pr:1,id:3,sha:$s1,severity:"P3",verdict:"real"},{pr:1,id:10,sha:$s1,severity:"P2",verdict:"real"},
  {pr:1,id:11,sha:$s1,severity:"P2",verdict:"real"},{pr:2,id:4,sha:$s2,severity:"P2",verdict:"real"},
  {pr:2,id:5,sha:$s2,severity:"P2",verdict:"real"},{pr:2,id:6,sha:$s2,severity:"P1",verdict:"real"},
  {pr:2,id:7,sha:$s2,severity:"P2",verdict:"real"},{pr:2,id:8,sha:$s2,severity:"P3",verdict:"real"},
  {pr:2,id:9,sha:$s2,severity:"P2",verdict:"noise"}]
  | map(. + {file:"f",line:1,finding:"x",at:"2026-01-01T00:00:00Z",sha_at:"2026-01-01T00:00:00Z",replies:[]})' > "$D/x/cases.json"
echo '{"grades": [{"id": 3, "value": "minor"}]}' > "$D/x/grades/${S1:0:12}.json"
echo '{"grades": [{"id": 8, "value": "churn"}]}' > "$D/x/grades/${S2:0:12}.json"

# seed <model> <sha> <tokens-in> <judge candidates json>
seed(){ local f="$D/x/replays/${2:0:12}__${1//\//_}.json"
  jq -n --argjson i "$3" '{usage: {input: $i, output: 100, cacheRead: 0, cacheWrite: 0, usd: 0}, report: {findings: []}}' > "$f"
  echo "{\"candidates\": $4}" > "${f%.json}.judge.json"; }
all_s1='[{"i":0,"match":1},{"i":1,"match":2},{"i":2,"match":3},{"i":3,"match":10},{"i":4,"match":11}]'
all_s2='[{"i":0,"match":4},{"i":1,"match":5},{"i":2,"match":6},{"i":3,"match":7},{"i":4,"match":8}]'
for m in anthropic/claude-sonnet-4-6 pricey/b; do seed $m $S1 9000 "$all_s1"; seed $m $S2 9000 "$all_s2"; done
# cheap/a misses only id 8, which the grader called churn: nothing lost.
seed cheap/a $S1 5000 "$all_s1"
seed cheap/a $S2 5000 '[{"i":0,"match":4},{"i":1,"match":5},{"i":2,"match":6},{"i":3,"match":7}]'
# junk/c catches everything but half its findings are noise or implausible.
seed junk/c $S1 1000 "$all_s1"
seed junk/c $S2 1000 '[{"i":0,"match":4},{"i":1,"match":5},{"i":2,"match":6},{"i":3,"match":7},{"i":4,"match":8},
  {"i":5,"match":9},{"i":6,"match":null,"plausible":false},{"i":7,"match":null,"plausible":false},
  {"i":8,"match":null,"plausible":false},{"i":9,"match":null,"plausible":false},{"i":10,"match":null,"plausible":true}]'
# failing/d: one of two runs failed.
seed failing/d $S1 1000 "$all_s1"
echo '{"failed": true, "exit": 3, "error": "x", "model": "failing/d"}' > "$D/x/replays/${S2:0:12}__failing_d.json"
echo '{"candidates": []}' > "$D/x/replays/${S2:0:12}__failing_d.judge.json"

cat > "$T/prices.json" <<'EOF'
{"models": {"cheap/a": {"usd_per_mtok": {"input": 1, "output": 1}},
            "pricey/b": {"usd_per_mtok": {"input": 10, "output": 10}},
            "junk/c": {"usd_per_mtok": {"input": 0.1, "output": 0.1}},
            "failing/d": {"usd_per_mtok": {"input": 0.1, "output": 0.1}}},
 "plans": {}}
EOF

run(){ set +e; OUT=$(PATH="$T/bin:$PATH" PI_REVIEW_CACHE_DIR="$T/cache" PI_REVIEW_PRICES="$T/prices.json" \
        bash "$EVAL" "$@" 2>>"$T/err"); RC=$?; set -e; }

echo "=== scoring against a baseline ==="
run run x --models cheap/a,pricey/b,junk/c,failing/d --baseline anthropic/claude-sonnet-4-6
[[ "$RC" -eq 0 ]] && ok "exit 0" || bad "rc=$RC: $(cat "$T/err")"
R="$D/x/result.json"
jq -e '.baseline.catch == 1 and .baseline.junk == 0' "$R" >/dev/null && ok "baseline catches all, no junk" || bad "baseline: $(jq -c .baseline "$R")"
jq -e '.candidates[] | select(.model == "cheap/a") | .catch == 1 and .pass and .material_total == 8' "$R" >/dev/null \
    && ok "cheap/a: missing a churn finding costs nothing" || bad "cheap/a: $(jq -c '.candidates[0]' "$R")"
[[ -s "$D/x/prior/${S2:0:12}.txt" ]] && ok "prior-comments file written per commit" || bad "no prior file"
jq -e '.candidates[] | select(.model == "junk/c") | (.junk > 0.3) and (.pass | not) and .novel_plausible == 1' "$R" >/dev/null \
    && ok "junk/c: noise + implausible counted, fails" || bad "junk/c: $(jq -c '.candidates[] | select(.model == "junk/c")' "$R")"
jq -e '.candidates[] | select(.model == "failing/d") | .failed == 1 and (.pass | not)' "$R" >/dev/null \
    && ok "failing/d: a failed run fails it" || bad "failing/d"
jq -e '.recommended == ["cheap/a", "pricey/b"]' "$R" >/dev/null && ok "recommends the cheapest passing first" || bad "recommended: $(jq -c .recommended "$R")"
jq -e '.candidates[] | select(.model == "cheap/a") | (.usd_per_review * 1e6 | round) == 5100' "$R" >/dev/null \
    && ok "cost = measured tokens x price" || bad "cost: $(jq '.candidates[] | select(.model == "cheap/a") | .usd_per_review' "$R")"

echo "=== too few real findings is inconclusive ==="
jq 'map(select(.sha != "2222222222222222222222222222222222222222"))' "$D/x/cases.json" > "$T/c" && cp -f "$D/x/cases.json" "$T/full" && cp -f "$T/c" "$D/x/cases.json"
run run x --models cheap/a --baseline anthropic/claude-sonnet-4-6
jq -e '.inconclusive and .recommended == null' "$R" >/dev/null && ok "4 material findings -> inconclusive, no recommendation" || bad "$(jq -c '{inconclusive, recommended}' "$R")"
cp -f "$T/full" "$D/x/cases.json"
run run x --models cheap/a,pricey/b,junk/c,failing/d --baseline anthropic/claude-sonnet-4-6

echo "=== assign spreads agents across subscriptions ==="
# Agent y: lighter, passes on cheap/a and pricey/b, and on a Claude model.
mkdir -p "$D/y"
jq -n '{agent: "y", candidates: [
  {model: "cheap/a", pass: true, subscription: "cheap", usd_per_review: 0.001, tokens: {input: 100, output: 10, cacheRead: 0}},
  {model: "pricey/b", pass: true, subscription: "pricey", usd_per_review: 0.01, tokens: {input: 100, output: 10, cacheRead: 0}},
  {model: "anthropic/claude-haiku-4-5", pass: true, subscription: "claude", usd_per_review: 0.02, tokens: {input: 100, output: 10, cacheRead: 0}}]}' \
  > "$D/y/result.json"
run assign
[[ "$RC" -eq 0 ]] && ok "exit 0" || bad "rc=$RC: $(cat "$T/err")"
jq -e '.pi.agents.x == ["cheap/a", "pricey/b", "claude"]' <<<"$OUT" >/dev/null \
    && ok "heavier agent x takes the cheapest subscription" || bad "x: $(jq -c .pi.agents.x <<<"$OUT")"
jq -e '.pi.agents.y[0] == "claude:haiku" or .pi.agents.y[0] == "pricey/b"' <<<"$OUT" >/dev/null \
    && ok "y starts on a different subscription from x" || bad "y: $(jq -c .pi.agents.y <<<"$OUT")"
jq -e '[.pi.agents.y[] | select(startswith("anthropic/"))] == [] and (.pi.agents.y | index("claude:haiku"))' <<<"$OUT" >/dev/null \
    && ok "an Anthropic winner becomes claude:haiku" || bad "y: $(jq -c .pi.agents.y <<<"$OUT")"
jq -e '.pi.agents.y | (map(select(. == "claude" or startswith("claude:"))) | length) <= 2 and .[-1] == "claude"' <<<"$OUT" >/dev/null \
    && ok "chain ends in claude" || bad "y: $(jq -c .pi.agents.y <<<"$OUT")"

echo ""; echo "Passed: $PASSED  Failed: $FAILED"; [[ "$FAILED" -eq 0 ]]
