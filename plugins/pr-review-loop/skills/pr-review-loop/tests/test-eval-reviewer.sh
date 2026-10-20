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
export PR_REVIEW_LOOP_MODELS=/nonexistent   # no real ~/.config/pr-review-loop/models.json
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL="$SCRIPT_DIR/../scripts/eval-reviewer.sh"
T="$(mktemp -d)"; trap 'rm -rf -- "$T"' EXIT
PASSED=0; FAILED=0
ok(){ PASSED=$((PASSED+1)); echo "  PASS: $1"; }
bad(){ FAILED=$((FAILED+1)); echo "  FAIL: $1"; }

mkdir -p "$T/bin"
# gh: two pages of review threads for harvest; FAKE_PRLIST_FAIL makes `pr list` fail.
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
c(){ jq -nc --arg b "$1" --arg at "$2" '{databaseId: 0, body: $b, path: "f", line: 1, originalLine: 1, createdAt: $at,
       originalCommit: {oid: "3333333333333333333333333333333333333333", committedDate: "2026-01-01T00:00:00Z"}}'; }
t(){ local id="$1" body="$2" reply="$3"
     jq -nc --argjson id "$id" --argjson a "$(c "$body" 2026-01-01T00:00:00Z)" --argjson r "$(c "$reply" 2026-01-02T00:00:00Z)" \
       '{comments: {nodes: ([$a + {databaseId: $id}] + (if $r.body == "" then [] else [$r] end))}}'; }
page(){ jq -nc --argjson n "$1" --argjson more "$2" '{data: {repository: {pullRequest: {reviewThreads:
          {pageInfo: {hasNextPage: $more, endCursor: "C1"}, nodes: $n}}}}}'; }
S='<!-- Agent: h -->'
case "$*" in
  "pr list"*) [[ -n "${FAKE_PRLIST_FAIL:-}" ]] && { echo "gh: boom" >&2; exit 1; }; echo 5 ;;
  "api graphql"*c=C1*) page "[$(t 4 "P3 x $S" "Won't fix - no"),$(t 5 "P2 x $S" "Withdrawn - refuted"),$(t 6 "P2 x $S" "sure")]" false ;;
  "api graphql"*) page "[$(t 1 "P0 x $S" "Fixed - done"),$(t 2 "P2 x $S" "Out of scope - tracked in bd-1"),$(t 3 "P2 x <!-- Agent: other -->" "Fixed")]" true ;;
  *) echo o/r ;;
esac
GH
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
  | map(. + {file:"f",line:1,finding:"x",at:"2026-01-01T00:00:00Z",sha_at:"2026-01-01T00:00:00Z",replies:[]})
  # Unscored threads on a third commit of PR 1, one before S1 was committed and one after.
  + [{pr:1,id:20,sha:"3333333333333333333333333333333333333333",severity:"P2",verdict:"unscored",file:"f",line:1,
      finding:"EARLIER",at:"2025-12-01T00:00:00Z",sha_at:"2025-12-01T00:00:00Z",
      replies:[{at:"2025-12-02T00:00:00Z",body:"EARLYREPLY"},{at:"2026-02-01T00:00:00Z",body:"LATEREPLY"}]},
     {pr:1,id:21,sha:"3333333333333333333333333333333333333333",severity:"P2",verdict:"unscored",file:"f",line:1,
      finding:"LATER",at:"2026-02-01T00:00:00Z",sha_at:"2025-12-01T00:00:00Z",replies:[]}]' > "$D/x/cases.json"
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
# weak/e catches only S1 (weight 9.5 of 18.5, catch 0.51); weaker/f only id 1 (0.16).
seed weak/e $S1 1000 "$all_s1"; seed weak/e $S2 1000 '[]'
seed weaker/f $S1 1000 '[{"i":0,"match":1}]'; seed weaker/f $S2 1000 '[]'
for m in claude:sonnet claude-proxy/x; do seed $m $S1 1000 "$all_s1"; seed $m $S2 1000 "$all_s2"; done
# failing/d: one of two runs failed.
seed failing/d $S1 1000 "$all_s1"
echo '{"failed": true, "exit": 3, "error": "x", "model": "failing/d"}' > "$D/x/replays/${S2:0:12}__failing_d.json"
echo '{"candidates": []}' > "$D/x/replays/${S2:0:12}__failing_d.judge.json"

cat > "$T/prices.json" <<'EOF'
{"models": {"cheap/a": {"usd_per_mtok": {"input": 1, "output": 1}},
            "pricey/b": {"usd_per_mtok": {"input": 10, "output": 10}},
            "junk/c": {"usd_per_mtok": {"input": 0.1, "output": 0.1}},
            "failing/d": {"usd_per_mtok": {"input": 0.1, "output": 0.1}},
            "weak/e": {"usd_per_mtok": {"input": 0.1, "output": 0.1}},
            "weaker/f": {"usd_per_mtok": {"input": 0.1, "output": 0.1}},
            "claude-proxy/x": {"usd_per_mtok": {"input": 0.1, "output": 0.1}}},
 "plans": {}}
EOF

run(){ set +e; OUT=$(PATH="$T/bin:$PATH" PI_REVIEW_CACHE_DIR="$T/cache" PI_REVIEW_PRICES="$T/prices.json" FAKE_PRLIST_FAIL="${FAKE_PRLIST_FAIL:-}" \
        bash "$EVAL" "$@" 2>>"$T/err"); RC=$?; set -e; }

echo "=== scoring against a baseline ==="
run run x --models cheap/a,pricey/b,junk/c,failing/d --baseline anthropic/claude-sonnet-4-6
[[ "$RC" -eq 0 ]] && ok "exit 0" || bad "rc=$RC: $(cat "$T/err")"
R="$D/x/result.json"
jq -e '.baseline.catch == 1 and .baseline.junk == 0' "$R" >/dev/null && ok "baseline catches all, no junk" || bad "baseline: $(jq -c .baseline "$R")"
jq -e '.candidates[] | select(.model == "cheap/a") | .catch == 1 and .pass and .material_total == 8' "$R" >/dev/null \
    && ok "cheap/a: missing a churn finding costs nothing" || bad "cheap/a: $(jq -c '.candidates[0]' "$R")"
[[ -s "$D/x/prior/${S2:0:12}.txt" ]] && ok "prior-comments file written per commit" || bad "no prior file"
P1F="$D/x/prior/${S1:0:12}.txt"
grep -q EARLIER "$P1F" && grep -q EARLYREPLY "$P1F" && ! grep -q -e 'LATER$' -e LATEREPLY "$P1F" \
    && ok "prior comments stop at the commit time, replies too" || bad "prior: $(cat "$P1F")"
jq -e '.candidates[] | select(.model == "junk/c") | (.junk > 0.3) and (.pass | not) and .novel_plausible == 1' "$R" >/dev/null \
    && ok "junk/c: noise + implausible counted, fails" || bad "junk/c: $(jq -c '.candidates[] | select(.model == "junk/c")' "$R")"
jq -e '.candidates[] | select(.model == "failing/d") | .failed == 1 and (.pass | not)' "$R" >/dev/null \
    && ok "failing/d: a failed run fails it" || bad "failing/d"
jq -e '.recommended == ["cheap/a", "pricey/b"]' "$R" >/dev/null && ok "recommends the cheapest passing first" || bad "recommended: $(jq -c .recommended "$R")"
jq -e '.candidates[] | select(.model == "cheap/a") | (.usd_per_review * 1e6 | round) == 5100' "$R" >/dev/null \
    && ok "cost = measured tokens x price" || bad "cost: $(jq '.candidates[] | select(.model == "cheap/a") | .usd_per_review' "$R")"

echo "=== pass rules ==="
run run x --models weak/e --baseline anthropic/claude-sonnet-4-6
jq -e '.candidates[0] | (.catch > 0.5) and (.pass | not)' "$R" >/dev/null && ok "catch more than 10 points under the baseline fails" || bad "$(jq -c '.candidates[0]' "$R")"
run run x --models weak/e,weaker/f
jq -e '.baseline == null and ([.candidates[] | {(.model): .pass}] | add) == {"weak/e": true, "weaker/f": false}' "$R" >/dev/null \
    && ok "no baseline: catch >= 0.5 passes, below fails" || bad "$(jq -c '[.candidates[] | {model, catch, pass}]' "$R")"

echo "=== only claude and claude:<model> bill as the Claude plan ==="
run run x --models claude:sonnet,claude-proxy/x
jq -e '([.candidates[] | {(.model): .billing}] | add) == {"claude:sonnet": "plan", "claude-proxy/x": "paid"}' "$R" >/dev/null \
    && ok "claude:sonnet is plan, claude-proxy/x is paid" || bad "$(jq -c '[.candidates[] | {model, billing}]' "$R")"

echo "=== a failed grade or replay is not scored as if it were fine ==="
mv -f "$D/x/grades/${S1:0:12}.json" "$T/g1"
run run x --models cheap/a --baseline anthropic/claude-sonnet-4-6
[[ "$RC" -eq 1 ]] && grep -q 'grading failed' "$T/err" && ok "grading failure -> exit 1, not material by default" || bad "rc=$RC"
mv -f "$T/g1" "$D/x/grades/${S1:0:12}.json"
J1="$D/x/replays/${S1:0:12}__cheap_a.judge.json"; mv -f "$J1" "$T/j1"
run run x --models cheap/a --baseline anthropic/claude-sonnet-4-6
[[ "$RC" -eq 1 ]] && grep -q 'judging failed' "$T/err" && ok "judge failure -> exit 1, not a failed model run" || bad "rc=$RC"
mv -f "$T/j1" "$J1"
mkdir -p "$T/stub"; printf '#!/usr/bin/env bash\necho "{\\"report\\": {\\"findings\\": []}, \\"usage\\": {\\"input\\": 1, \\"output\\": 1, \\"cacheRead\\": 0, \\"cacheWrite\\": 0, \\"usd\\": 0}}"\n' > "$T/pi-review.sh"
cp -f "$T/err" "$T/err.keep"
FAILED_REPLAY="$D/x/replays/${S2:0:12}__failing_d.json"
cp -f "$EVAL" "$T/stub/eval-reviewer.sh"; cp -f "$T/pi-review.sh" "$T/stub/pi-review.sh"; chmod +x "$T/stub/pi-review.sh"
set +e; PATH="$T/bin:$PATH" PI_REVIEW_CACHE_DIR="$T/cache" PI_REVIEW_PRICES="$T/prices.json" \
    bash "$T/stub/eval-reviewer.sh" run x --models failing/d --baseline anthropic/claude-sonnet-4-6 >/dev/null 2>"$T/err"; set -e
jq -e '.failed | not' "$FAILED_REPLAY" >/dev/null && ok "a failed replay is retried on a rerun" || bad "still failed: $(cat "$FAILED_REPLAY")"
[[ ! -s "${FAILED_REPLAY%.json}.judge.json" ]] || ! jq -e '.candidates == []' "${FAILED_REPLAY%.json}.judge.json" >/dev/null \
    && ok "its stale empty judgement is dropped" || bad "stale judge kept"
echo '{"failed": true, "exit": 3, "error": "x", "model": "failing/d"}' > "$FAILED_REPLAY"
echo '{"candidates": []}' > "${FAILED_REPLAY%.json}.judge.json"

echo "=== a plan model ranks first but still shows its list price ==="
cp -f "$T/prices.json" "$T/prices.bak"
jq '.models["pricey/b"].plan = "pricey" | .plans = {"pricey": {}}' "$T/prices.bak" > "$T/prices.json"
run run x --models cheap/a,pricey/b,junk/c,failing/d --baseline anthropic/claude-sonnet-4-6
jq -e '.recommended == ["pricey/b", "cheap/a"] and (.candidates[] | select(.model == "pricey/b") | .billing == "plan" and .usd_per_review > 0)' "$R" >/dev/null \
    && ok "plan model first, priced at list" || bad "recommended: $(jq -c .recommended "$R")"
cp -f "$T/prices.bak" "$T/prices.json"

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

echo "=== assign --user merges into the per-user models.json ==="
printf '%s' '{"agents": {"other-agent": "zai/glm-5.1", "x": "old/model"}, "note": "kept"}' > "$T/models.json"
PR_REVIEW_LOOP_MODELS="$T/models.json" run assign --user
[[ "$RC" -eq 0 ]] && jq -e '.agents.x == ["cheap/a", "pricey/b", "claude"] and .agents["other-agent"] == "zai/glm-5.1"
    and (.agents.y | length) > 0 and .note == "kept"' "$T/models.json" >/dev/null \
    && ok "replaces the evaluated agents, keeps the rest of the file" || bad "rc=$RC file: $(cat "$T/models.json")"
rm -f "$T/models.json"
PR_REVIEW_LOOP_MODELS="$T/new/models.json" run assign --user
jq -e '.agents.x[0] == "cheap/a"' "$T/new/models.json" >/dev/null && ok "creates the file when missing" || bad "rc=$RC"
printf 'not json' > "$T/models.json"
PR_REVIEW_LOOP_MODELS="$T/models.json" run assign --user
[[ "$RC" -eq 1 && "$(cat "$T/models.json")" == "not json" ]] && ok "an unreadable file is an error and is left untouched" || bad "rc=$RC"
ln -sf "$T/real-models.json" "$T/link-models.json"; printf '{}' > "$T/real-models.json"
PR_REVIEW_LOOP_MODELS="$T/link-models.json" run assign --user
[[ -L "$T/link-models.json" ]] && jq -e '.agents.x[0] == "cheap/a"' "$T/real-models.json" >/dev/null \
    && ok "a symlinked models.json stays a symlink and its target gets the chains" || bad "rc=$RC"
mkdir -p "$T/held/x" "$T/held/y" "$D/z"; mv -f "$D/x/result.json" "$T/held/x/"; mv -f "$D/y/result.json" "$T/held/y/"
jq -n '{agent: "z", candidates: [{model: "cheap/a", pass: false, subscription: "cheap", usd_per_review: 0.001, tokens: {input: 1, output: 1, cacheRead: 0}}]}' > "$D/z/result.json"
printf '%s' '{"agents": {"z": "old/model"}}' > "$T/models.json"
PR_REVIEW_LOOP_MODELS="$T/models.json" run assign --user
[[ "$RC" -eq 1 ]] && jq -e '.agents.z == "old/model"' "$T/models.json" >/dev/null && grep -q 'no evaluated agent has a passing model' "$T/err" \
    && ok "no passing agent: an error, and the file is left unchanged" || bad "rc=$RC file: $(cat "$T/models.json")"
rm -rf "$D/z"; mv -f "$T/held/x/result.json" "$D/x/"; mv -f "$T/held/y/result.json" "$D/y/"
printf '  \n' > "$T/models.json"
PR_REVIEW_LOOP_MODELS="$T/models.json" run assign --user
jq -e '.agents.x[0] == "cheap/a"' "$T/models.json" >/dev/null && ok "a whitespace-only file is treated as empty, not emptied" || bad "rc=$RC file: $(cat "$T/models.json")"
printf '{} {}' > "$T/models.json"
PR_REVIEW_LOOP_MODELS="$T/models.json" run assign --user
[[ "$RC" -eq 1 && "$(cat "$T/models.json")" == "{} {}" ]] && ok "several JSON values: an error, file untouched" || bad "rc=$RC"
run assign --bogus
[[ "$RC" -eq 1 ]] && ok "an unknown assign flag is a usage error" || bad "rc=$RC"

echo "=== harvest ==="
run harvest h
H="$D/h/cases.json"
[[ "$RC" -eq 0 ]] && ok "exit 0" || bad "rc=$RC: $(tail -2 "$T/err")"
jq -e 'map({(.id | tostring): .verdict}) | add == {"1":"real","2":"real","4":"noise","5":"noise","6":"unscored"}' "$H" >/dev/null \
    && ok "both pages read; verdicts from the first reply; other agents ignored" || bad "verdicts: $(jq -c 'map({id, verdict})' "$H")"
jq -e '(.[] | select(.id == 1) | .severity) == "P1" and (.[] | select(.id == 4) | .severity) == "P3"' "$H" >/dev/null \
    && ok "P0 counts as P1; severity read from the body" || bad "sev: $(jq -c 'map({id, severity})' "$H")"
cp -f "$H" "$T/h.keep"
FAKE_PRLIST_FAIL=1 run harvest h
[[ "$RC" -eq 1 ]] && cmp -s "$H" "$T/h.keep" && ok "a failed gh pr list exits 1 and keeps the old corpus" || bad "rc=$RC"

echo ""; echo "Passed: $PASSED  Failed: $FAILED"; [[ "$FAILED" -eq 0 ]]
