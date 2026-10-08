#!/bin/bash
# Merge this round's recorded findings and post them as ONE review.
#
#   P1/P2 findings on the same file:line  -> one thread, every flagger signed
#   all P3 findings                       -> one roll-up thread
#
# One review is one GitHub write, where posting comment by comment cost one
# write per finding. If GitHub rejects the review (usually a line outside the
# diff), each thread is posted on its own, paced, and any that fail go back into
# the store so --check keeps failing until they are dealt with.
#
# Usage: post-findings.sh <pr-number>           # post to the PR
#        post-findings.sh <pr-number|local> --local   # print the merged report, post nothing
#        post-findings.sh <pr-number|local> --check   # exit 1 if findings are still unposted

set -euo pipefail

# shellcheck source=_pace.sh
source "$(dirname "${BASH_SOURCE[0]}")/_pace.sh"

PR="${1:?Usage: post-findings.sh <pr-number|local> [--local|--check]}"
MODE="${2:-post}"

STORE="$(cd "$(git rev-parse --git-dir)" && pwd)/pr-review-loop/findings-$PR.jsonl"

if [[ "$MODE" == "--check" ]]; then
    if [[ -s "$STORE" ]]; then
        echo "$(wc -l < "$STORE") recorded finding(s) not yet posted - run post-findings.sh $PR" >&2
        exit 1
    fi
    echo "no unposted findings"
    exit 0
fi

if [[ ! -s "$STORE" ]]; then
    echo "No findings recorded for $PR."
    exit 0
fi

archive() { mv -f "$STORE" "$STORE.$(date +%s).done"; }

GROUPS_JSON=$(jq -s '
    def sig(a): "<!-- Agent: \(a) -->";
    def rank: {P1: 1, P2: 2, P3: 3}[.severity];
    (map(select(.severity != "P3")) | group_by([.file, .line])
        | map(sort_by(rank) | {
            path: .[0].file, line: .[0].line, findings: .,
            body: (map("🤖 **Claude Code** (\(.agent)) · \(.severity):\n\(sig(.agent))\n\n\(.body)")
                   | join("\n\n---\n\n"))
          })) as $inline
    | map(select(.severity == "P3")) as $p3
    | ($p3 | map(.agent) | unique) as $p3_agents
    | $inline + (if ($p3 | length) == 0 then [] else [{
        path: $p3[0].file, line: $p3[0].line, findings: $p3,
        body: ("🤖 **Claude Code** (P3 roll-up: \($p3_agents | join(", "))):\n"
               + ($p3_agents | map(sig(.)) | join("\n"))
               + "\n\nLow-priority findings. One reply covers them all.\n\n"
               + ($p3 | to_entries
                  | map("\(.key + 1). `\(.value.file):\(.value.line)` (\(.value.agent)): \(.value.body)")
                  | join("\n\n")))
      }] end)
' "$STORE")

COUNT=$(jq 'length' <<< "$GROUPS_JSON")
FINDINGS=$(wc -l < "$STORE")

if [[ "$MODE" == "--local" ]]; then
    echo "$FINDINGS finding(s) in $COUNT thread(s). Nothing posted."
    jq -r '.[] | "\n=== \(.path):\(.line) ===\n\(.body)"' <<< "$GROUPS_JSON" | grep -v '^<!-- Agent: '
    archive
    exit 0
fi

[[ "$MODE" == "post" ]] || { echo "Error: unknown mode '$MODE'" >&2; exit 1; }

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
    echo "Error: Could not determine repository. Run from within a git repository." >&2
    exit 1
}
SHA=$(gh pr view "$PR" -R "$REPO" --json headRefOid --jq .headRefOid)
[[ -n "$SHA" ]] || { echo "Error: could not read head SHA of PR #$PR" >&2; exit 1; }

REVIEW=$(jq --arg sha "$SHA" --arg n "$FINDINGS" '{
    commit_id: $sha, event: "COMMENT",
    body: "pr-review-loop: \($n) finding(s) in \(length) thread(s).",
    comments: map({path, line, side: "RIGHT", body})
}' <<< "$GROUPS_JSON")

pace_github
if RESULT=$(gh api --method POST "repos/$REPO/pulls/$PR/reviews" --input - <<< "$REVIEW" 2>&1); then
    RID=$(jq -r '.id' <<< "$RESULT")
    archive
    echo "Posted review $RID: $FINDINGS finding(s) in $COUNT thread(s)."
    gh api --paginate "repos/$REPO/pulls/$PR/reviews/$RID/comments" \
        --jq '.[] | "\(.id) \(.path):\(.line // .original_line) \(.body | split("\n")[0])"'
    exit 0
fi

echo "Review rejected, posting threads one at a time: $RESULT" >&2
FAILED_FINDINGS=""
for i in $(seq 0 $((COUNT - 1))); do
    G=$(jq -c ".[$i]" <<< "$GROUPS_JSON")
    pace_github
    if OUT=$(jq --arg sha "$SHA" '{commit_id: $sha, path, line, side: "RIGHT", body}' <<< "$G" \
            | gh api --method POST "repos/$REPO/pulls/$PR/comments" --input - 2>&1); then
        echo "$(jq -r '.id' <<< "$OUT") $(jq -r '"\(.path):\(.line)"' <<< "$G")"
    else
        echo "FAILED $(jq -r '"\(.path):\(.line)"' <<< "$G"): $OUT" >&2
        FAILED_FINDINGS+="$(jq -c '.findings[]' <<< "$G")"$'\n'
    fi
done

archive
if [[ -n "$FAILED_FINDINGS" ]]; then
    printf '%s' "$FAILED_FINDINGS" > "$STORE"
    echo "$(wc -l < "$STORE") finding(s) did not post and are back in the store." >&2
    exit 1
fi
