#!/usr/bin/env bash
# Pick the cheapest model that reviews as well as Claude, per agent, per repo.
#
# Usage:
#   eval-reviewer.sh harvest <agent> [--prs N]
#   eval-reviewer.sh run <agent> --models m1,m2[,...] [--baseline M] [--commits N] [--files REGEX]
#   eval-reviewer.sh assign
#
# harvest  Reads this repo's PR threads that <agent> started (signed
#          `<!-- Agent: <agent> -->`) and how each was answered. The first word
#          of the first reply is the verdict: Fixed / Out of scope / Deferred
#          = real, Won't fix / Withdrawn = noise; anything else is not scored.
# run      Replays the commits with the most real findings on each model
#          (pi-review.sh --replay, posts nothing). Each replay sees the agent's
#          threads as they stood at that commit, as a live round would. Sonnet
#          grades every real original once (material / minor / churn - "Fixed"
#          is weak evidence when a loop fixes nearly everything), then matches
#          each model's findings against the originals, and scores: value- and
#          severity-weighted
#          share of real findings caught, share of its findings that repeat
#          known noise, novel findings the judge calls plausible, failed runs,
#          and cost per review. A model passes if it fails <=10% of runs and, with
#          --baseline, catches within 0.10 of the baseline with no more than 0.10
#          extra noise (without one: catches >= 0.5). The recommendation is the
#          CHEAPEST passing model. Fewer than 8 real findings is "inconclusive".
#          --baseline is any Pi model, e.g. anthropic/claude-sonnet-4-5, so the
#          comparison runs in the same harness. --files keeps only originals
#          whose path matches REGEX, e.g. code for a code-focused agent:
#          --files '\.(py|sh|go|ts|js|rb)$'.
# assign   Reads every agent's result and builds one # Configuration .pi.agents
#          block: each agent gets a passing model on the subscription with the
#          least projected load, then its other passing models on other
#          subscriptions, then "claude". Anthropic candidates (tested through Pi
#          as anthropic/claude-sonnet-4-6 etc.) come out as claude:sonnet /
#          claude:haiku, which run as the normal Claude Task on that model.
#
# Cost: ~/.config/pr-review-loop/pi-prices.json (see pi/prices.example.json).
# Pay-per-token models cost measured tokens x price. Plan models cost
# monthly_usd / reviews_per_month, which you calibrate by reading the plan's
# usage % before and after a few replays; until then they show as "plan".
#
# State: $PI_REVIEW_CACHE_DIR/eval/<repo>/<agent>/ (default
# ~/.cache/pr-review-loop); finished replays and judgements are reused.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USAGE="Usage: eval-reviewer.sh harvest <agent> [--prs N] | run <agent> --models a,b [--baseline M] [--commits N] | assign"
CMD="${1:?$USAGE}"; shift
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)" || { echo "Error: not in a GitHub repo" >&2; exit 1; }
BASE_DIR="${PI_REVIEW_CACHE_DIR:-$HOME/.cache/pr-review-loop}/eval/${REPO//\//_}"
PRICES="${PI_REVIEW_PRICES:-$HOME/.config/pr-review-loop/pi-prices.json}"
[[ -r "$PRICES" ]] || PRICES="$SCRIPT_DIR/../pi/prices.example.json"

# ---------------------------------------------------------------- harvest ---
harvest() {
    local agent="$1" prs="$2" dir="$BASE_DIR/$1" owner="${REPO%%/*}" name="${REPO##*/}"
    mkdir -p "$dir"
    local q='query($o:String!,$n:String!,$pr:Int!,$c:String){repository(owner:$o,name:$n){pullRequest(number:$pr){
      reviewThreads(first:100,after:$c){pageInfo{hasNextPage endCursor}
        nodes{comments(first:30){nodes{databaseId body path originalLine line createdAt originalCommit{oid committedDate}}}}}}}}'
    local pr cursor page
    : > "$dir/cases.jsonl"
    for pr in $(gh pr list -R "$REPO" --state all --limit "$prs" --json number --jq '.[].number'); do
        cursor=""
        while :; do
            page="$(gh api graphql -f query="$q" -f o="$owner" -f n="$name" -F pr="$pr" ${cursor:+-f c="$cursor"})" \
                || { echo "Error: thread query failed on PR #$pr" >&2; exit 1; }
            jq -c --argjson pr "$pr" --arg sig "<!-- Agent: $agent -->" '
                .data.repository.pullRequest.reviewThreads.nodes[]
                  | .comments.nodes as $c | select(($c[0].body // "") | contains($sig))
                  | ($c[1].body // "" | ascii_downcase | gsub("^[^a-z]+"; "")) as $r
                  | {pr: $pr, id: $c[0].databaseId, sha: $c[0].originalCommit.oid,
                     at: $c[0].createdAt, sha_at: $c[0].originalCommit.committedDate,
                     replies: [$c[1:][] | {at: .createdAt, body: .body[0:800]}],
                     file: $c[0].path, line: ($c[0].originalLine // $c[0].line),
                     severity: ((($c[0].body | capture("\\b(?<s>P[0-3])\\b").s) // "P2") | sub("P0"; "P1")),
                     finding: ($c[0].body | sub("(?s)^.*?<!-- Agent: [^>]*-->\\s*"; "") | .[0:1500]),
                     verdict: (if ($r | test("^(fixed|out of scope|deferred)")) then "real"
                               elif ($r | test("^(won.?t fix|withdrawn)")) then "noise"
                               else "unscored" end)}' <<<"$page" >> "$dir/cases.jsonl"
            [[ "$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' <<<"$page")" == true ]] || break
            cursor="$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor' <<<"$page")"
        done
    done
    jq -s '.' "$dir/cases.jsonl" > "$dir/cases.json" && rm -f "$dir/cases.jsonl"
    jq -r --arg a "$agent" '"\($a): \(length) threads on \([.[].sha] | unique | length) commits - "
        + "\([.[] | select(.verdict == "real")] | length) real, \([.[] | select(.verdict == "noise")] | length) noise, "
        + "\([.[] | select(.verdict == "unscored")] | length) unscored"' "$dir/cases.json"
}

# ------------------------------------------------------------------- run ---
weight='def w: if . == "P1" then 3 elif . == "P2" then 2 else 1 end;
        def vw: if . == "churn" then 0 elif . == "minor" then 0.5 else 1 end;'

replay_model() {   # <agent> <model> <commits-file>: one model, commits in turn
    local agent="$1" model="$2" dir="$BASE_DIR/$1" pr sha out rc
    while read -r pr sha; do
        out="$dir/replays/${sha:0:12}__${model//\//_}.json"
        [[ -s "$out" ]] && continue
        set +e
        "$SCRIPT_DIR/pi-review.sh" "$pr" "$agent" "$sha" --replay --model "$model" --prior "$dir/prior/${sha:0:12}.txt" \
            < /dev/null > "$out.tmp" 2> "$out.err"
        rc=$?
        set -e
        if [[ "$rc" -eq 0 ]]; then mv -f "$out.tmp" "$out"
        else jq -n --argjson rc "$rc" --arg e "$(tail -n 3 "$out.err")" --arg m "$model" \
                '{failed: true, exit: $rc, error: $e, model: $m}' > "$out"; rm -f "$out.tmp"
        fi
        echo "  $model @ ${sha:0:8}: exit $rc" >&2
    done < "$3"
}

prior_file() {   # <agent> <pr> <sha>: the agent's threads on <pr> as they stood when <sha> was committed
    local dir="$BASE_DIR/$1"
    mkdir -p "$dir/prior"
    jq -r --argjson pr "$2" --arg sha "$3" '
        (map(select(.sha == $sha)) | first | .sha_at) as $t |
        [.[] | select(.pr == $pr and .at < $t)] |
        if length == 0 then "(none - first review of this commit)" else .[] |
          "=== Thread (ID: \(.id)) ===", "File: \(.file):\(.line)", "", "ORIGINAL COMMENT:", .finding, "",
          ([.replies[] | select(.at < $t) | "  [reply] \(.body)"] | if length > 0 then "REPLIES:", .[] else empty end),
          "---", "" end' "$dir/cases.json" > "$dir/prior/${3:0:12}.txt"
}

grade() {   # <agent> <sha>: Sonnet rates each real original once - material, minor or churn
    local dir="$BASE_DIR/$1" sha="$2" gf reply
    gf="$dir/grades/${sha:0:12}.json"; mkdir -p "$dir/grades"
    [[ -s "$gf" ]] && return 0
    reply="$(cd "$dir" && env -u ANTHROPIC_API_KEY claude -p --model sonnet --no-session-persistence 2>/dev/null <<EOF
Grade each code-review finding below. All were acted on ("fixed"), but a review
loop that fixes nearly everything makes that weak evidence of value. Output ONLY
JSON: {"grades": [{"id": <id>, "value": "material" | "minor" | "churn"}]}
- material: a real defect or a real risk a careful maintainer must fix.
- minor: correct but low impact (wording, small robustness, polish).
- churn: wrong, speculative, pedantic, or re-litigating something already settled.

$(jq --arg sha "$sha" '[.[] | select(.sha == $sha and .verdict == "real") | {id, severity, file, line, finding}]' "$dir/cases.json")
EOF
)" || { echo "Error: grading call failed for ${sha:0:12}" >&2; return 1; }
    python3 -c 'import sys, json; t = sys.stdin.read(); print(json.dumps(json.loads(t[t.index("{"):t.rindex("}") + 1])))' \
        <<<"$reply" 2>/dev/null | jq -ce 'select(.grades | type == "array")' > "$gf" \
        || { rm -f "$gf"; echo "Error: grader gave no usable JSON for ${sha:0:12}" >&2; return 1; }
}

judge() {   # <agent> <run file> <sha>: Sonnet matches a model's findings to the originals
    local dir="$BASE_DIR/$1" run="$2" sha="$3" jf="${2%.json}.judge.json" prompt reply
    [[ -s "$jf" ]] && return 0
    if jq -e '.failed // false' "$run" >/dev/null; then echo '{"candidates": []}' > "$jf"; return 0; fi
    prompt="You compare two code reviews of the same commit. Output ONLY a JSON object, no prose.

ORIGINAL findings (from the reviewer of record; verdict real = it was acted on, noise = it was declined):
$(jq --arg sha "$sha" '[.[] | select(.sha == $sha and .verdict != "unscored") | {id, severity, verdict, file, line, finding}]' "$dir/cases.json")

CANDIDATE findings (from the model under test):
$(jq '[.report.findings | to_entries[] | {i: .key, severity: .value.severity, file: .value.file, line: .value.line, title: .value.title, body: .value.body[0:1500]}]' "$run")

For each candidate: \"match\" is the id of the ORIGINAL finding describing the same
underlying problem (same defect, even if worded differently or anchored on a
different line), else null. For a candidate with match null, \"plausible\" is true
only if, judging from its own text, it describes a real problem a careful reviewer
would want fixed; false if it is wrong, trivial or pedantic.

Output: {\"candidates\": [{\"i\": 0, \"match\": <id or null>, \"plausible\": <bool>}, ...]}"
    reply="$(cd "$dir" && env -u ANTHROPIC_API_KEY claude -p --model sonnet --no-session-persistence <<<"$prompt" 2>/dev/null)" \
        || { echo "Error: judge call failed for $run" >&2; return 1; }
    # The outermost {...} of the reply, fenced or not.
    python3 -c 'import sys, json; t = sys.stdin.read(); print(json.dumps(json.loads(t[t.index("{"):t.rindex("}") + 1])))' \
        <<<"$reply" 2>/dev/null | jq -ce 'select(.candidates | type == "array")' > "$jf" \
        || { rm -f "$jf"; echo "Error: judge gave no usable JSON for $run" >&2; return 1; }
}

score() {   # <agent> <models...>: per-model metrics over the replayed commits
    local agent="$1" dir="$BASE_DIR/$1"; shift
    local m sha f all="[]" T_EMPTY
    T_EMPTY="$(mktemp -d)/missing.json"
    echo '{"failed": true, "error": "replay or judgement missing"}' > "$T_EMPTY"
    echo '{"candidates": []}' > "${T_EMPTY%.json}.judge.json"
    for m in "$@"; do
        local rows="[]"
        while read -r _ sha; do
            f="$dir/replays/${sha:0:12}__${m//\//_}.json"
            # A replay that never finished (killed, deleted) scores as a failed run.
            [[ -s "$f" && -s "${f%.json}.judge.json" ]] || { f="$T_EMPTY"; }
            [[ -s "$dir/grades/${sha:0:12}.json" ]] || echo '{"grades": []}' > "$dir/grades/${sha:0:12}.json"
            rows="$(jq -c --slurpfile run "$f" --slurpfile j "${f%.json}.judge.json" --slurpfile cases "$dir/cases.json" \
                --slurpfile g "$dir/grades/${sha:0:12}.json" --arg sha "$sha" --arg files "$FILES" '
                ($g[0].grades | map({key: (.id | tostring), value: .value}) | from_entries) as $gr |
                . + [{sha: $sha, run: $run[0], judge: $j[0],
                    originals: [$cases[0][] | select(.sha == $sha and .verdict != "unscored")
                                | select($files == "" or (.file | test($files)))
                                | . + {value: ($gr[.id | tostring] // "material")}]}]' <<<"$rows")"
        done < "$dir/commits.txt"
        all="$(jq -c --arg m "$m" --slurpfile prices "$PRICES" --argjson acc "$all" "$weight"'
          ($prices[0]) as $P | ($P.models[$m] // {}) as $pm |
          [.[] | select(.run.failed | not)] as $ok |
          ([$ok[] | .judge.candidates[]]) as $cands |
          ([$ok[] | .originals[] | select(.verdict == "real")]) as $real |
          ([$ok[] | .judge.candidates[] | .match | select(. != null)] | unique) as $hit |
          ([$ok[] | .originals[] | select(.verdict == "noise") | .id]) as $noiseids |
          ($ok | map(.run.usage) | if length > 0 then
             {input: (map(.input) | add / length), output: (map(.output) | add / length),
              cacheRead: (map(.cacheRead) | add / length)} else null end) as $tok |
          (if ($pm.usd_per_mtok.input // null) != null and ($pm.usd_per_mtok.output // null) != null then
             ($tok | if . == null then null else
               ((.input * $pm.usd_per_mtok.input) + (.output * $pm.usd_per_mtok.output)
                + (.cacheRead * ($pm.usd_per_mtok.cacheRead // $pm.usd_per_mtok.input))) / 1000000 end)
           elif $pm.plan and ($P.plans[$pm.plan].monthly_usd // null) != null
                and ($P.plans[$pm.plan].reviews_per_month[$m] // null) != null then
             $P.plans[$pm.plan].monthly_usd / $P.plans[$pm.plan].reviews_per_month[$m]
           # No price on file: Pi prices its built-in pay-per-token models itself.
           elif ($ok | map(.run.usage.usd // 0) | add // 0) > 0 then
             ($ok | map(.run.usage.usd) | add / length)
           else null end) as $cost |
          $acc + [{model: $m, runs: length, failed: (length - ($ok | length)),
            real_total: ($real | length),
            catch: (([$real[] | (.severity | w) * (.value | vw)] | add // 0) as $den |
                    if $den == 0 then null else
                     ([$real[] | select(.id as $id | $hit | index($id)) | (.severity | w) * (.value | vw)] | add // 0)
                     / $den end),
            material_total: ([$real[] | select(.value == "material")] | length),
            findings: ($cands | length),
            junk: (if ($cands | length) == 0 then 0 else
                    ([$cands[] | select((.match != null and (.match as $x | $noiseids | index($x)))
                                        or (.match == null and (.plausible | not)))] | length) / ($cands | length) end),
            novel_plausible: ([$cands[] | select(.match == null and .plausible)] | length),
            tokens: $tok, usd_per_review: $cost,
            subscription: ($pm.plan // (if ($m | startswith("anthropic/")) then "claude" else ($m | split("/")[0]) end))}]' <<<"$rows")"
    done
    printf '%s\n' "$all"
}

run_eval() {
    local agent="$1" models="$2" baseline="$3" ncommits="$4" dir="$BASE_DIR/$1"
    FILES="$5"
    [[ -s "$dir/cases.json" ]] || { echo "Error: run 'eval-reviewer.sh harvest $agent' first" >&2; exit 1; }
    command -v claude >/dev/null || { echo "Error: the judge needs the claude CLI" >&2; exit 1; }
    mkdir -p "$dir/replays"
    # The commits with the most real findings; one replay covers all of them.
    jq -r --argjson n "$ncommits" --arg files "$FILES" '[.[] | select(.verdict == "real")
        | select($files == "" or (.file | test($files)))] | group_by(.sha)
        | sort_by(-length) | .[:$n][] | "\(.[0].pr) \(.[0].sha)"' "$dir/cases.json" > "$dir/commits.txt"
    local all_models=() m
    IFS=, read -r -a all_models <<<"$models"
    [[ -n "$baseline" ]] && all_models+=("$baseline")
    [[ -s "$dir/commits.txt" ]] || { echo "Error: no commits with real findings${FILES:+ matching $FILES}" >&2; exit 1; }
    local pr sha
    while read -r pr sha; do prior_file "$agent" "$pr" "$sha"; grade "$agent" "$sha" & done < "$dir/commits.txt"
    wait
    echo "Replaying $(wc -l < "$dir/commits.txt") commits on ${all_models[*]}" >&2
    for m in "${all_models[@]}"; do replay_model "$agent" "$m" "$dir/commits.txt" & done
    wait
    local sha f
    while read -r _ sha; do
        for m in "${all_models[@]}"; do
            f="$dir/replays/${sha:0:12}__${m//\//_}.json"
            judge "$agent" "$f" "$sha" &
        done
        wait
    done < "$dir/commits.txt"

    local scores
    scores="$(score "$agent" "${all_models[@]}")"
    jq -n --arg agent "$agent" --arg baseline "$baseline" --argjson s "$scores" '
        ($s | map(select(.model == $baseline)) | first) as $b |
        ($s | map(.material_total) | max // 0) as $n |
        [$s[] | select(.model != $baseline) | . + {pass: (
            .runs > 0 and (.failed / .runs) <= 0.1 and .catch != null and
            (if $b then .catch >= ($b.catch - 0.10) and .junk <= ($b.junk + 0.10)
             else .catch >= 0.5 and .junk <= 0.3 end))}] as $cands |
        {agent: $agent, baseline: $b, candidates: $cands, inconclusive: ($n < 8),
         recommended: (if $n < 8 then null else
            ([$cands[] | select(.pass)] | sort_by(.usd_per_review // 1e9) | map(.model))
            end)}' > "$dir/result.json"
    jq -r '"\n\(.agent)" + (if .inconclusive then "  (INCONCLUSIVE: fewer than 8 material findings replayed)" else "" end),
        "model                              pass  catch  junk  novel+  fail   tokens(in/out/cache)        $/review",
        (((if .baseline then [.baseline + {pass: "base"}] else [] end) + .candidates)[] |
        "\(.model | .[0:34] | . + " " * (35 - length))\(.pass | tostring | .[0:4] | . + " " * (6 - length))"
        + "\(.catch // 0 | . * 100 | round | tostring + "%" | . + " " * (7 - length))"
        + "\(.junk | . * 100 | round | tostring + "%" | . + " " * (6 - length))"
        + "\(.novel_plausible | tostring | . + " " * (8 - length))\(.failed)/\(.runs)    "
        + "\(if .tokens then "\(.tokens.input|round)/\(.tokens.output|round)/\(.tokens.cacheRead|round)" else "-" end | . + " " * (28 - length))"
        + "\(if .usd_per_review then (.usd_per_review * 10000 | round / 10000 | tostring) else "unpriced" end)"),
        "recommended chain start: \(if .recommended == null then "none (inconclusive)" elif (.recommended | length) == 0 then "none pass - keep on claude" else (.recommended | join(", ")) end)"' \
        "$dir/result.json"
}

# ---------------------------------------------------------------- assign ---
assign() {
    shopt -s nullglob
    local results=("$BASE_DIR"/*/result.json)
    [[ ${#results[@]} -gt 0 ]] || { echo "Error: no results under $BASE_DIR - run 'run' first" >&2; exit 1; }
    jq -s '
      # Greedy: heaviest agents first, each onto the passing model whose
      # subscription carries the least projected tokens so far (cheaper on ties).
      def toks: (.tokens.input + .tokens.output + .tokens.cacheRead);
      # A Claude model that wins runs as the normal Task, not through Pi.
      def entry: if startswith("anthropic/") then
          "claude:" + (if test("haiku") then "haiku" elif test("opus") then "opus" else "sonnet" end)
        else . end;
      [.[] | {agent, passing: [.candidates[] | select(.pass)]} | select(.passing | length > 0)
           | . + {weight: (.passing | map(toks) | max)}] | sort_by(-.weight)
      | reduce .[] as $a ({load: {}, agents: {}};
          (.load) as $load |
          ($a.passing | sort_by([($load[.subscription] // 0), (.usd_per_review // 1e9)]) | first) as $pick |
          .load[$pick.subscription] = (($load[$pick.subscription] // 0) + ($pick | toks)) |
          .agents[$a.agent] = ([$pick.model]
              + ($a.passing | map(select(.subscription != $pick.subscription)) | sort_by(.usd_per_review // 1e9)
                 | unique_by(.subscription) | map(.model)) + ["claude"]
              | map(entry) | reduce .[] as $e ([]; if index($e) then . else . + [$e] end)))
      | {pi: {agents: .agents}, projected_tokens_per_round_by_subscription: .load}' "${results[@]}"
}

case "$CMD" in
    harvest)
        AGENT="${1:?$USAGE}"; shift; PRS=50
        [[ "${1:-}" == --prs ]] && PRS="${2:?$USAGE}"
        harvest "$AGENT" "$PRS" ;;
    run)
        AGENT="${1:?$USAGE}"; shift; MODELS="" BASELINE="" COMMITS=6 FILES=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --models) MODELS="${2:?$USAGE}"; shift 2 ;;
                --baseline) BASELINE="${2:?$USAGE}"; shift 2 ;;
                --commits) COMMITS="${2:?$USAGE}"; shift 2 ;;
                --files) FILES="${2:?$USAGE}"; shift 2 ;;
                *) echo "$USAGE" >&2; exit 1 ;;
            esac
        done
        [[ -n "$MODELS" ]] || { echo "$USAGE" >&2; exit 1; }
        run_eval "$AGENT" "$MODELS" "$BASELINE" "$COMMITS" "$FILES" ;;
    assign) assign ;;
    *) echo "$USAGE" >&2; exit 1 ;;
esac
