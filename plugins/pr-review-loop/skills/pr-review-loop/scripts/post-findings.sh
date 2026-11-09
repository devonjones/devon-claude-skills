#!/bin/bash
# Merge this round's recorded findings and post them as ONE review.
#
#   P1/P2 findings on the same file:line  -> one thread, every flagger signed
#   all P3 findings                       -> one roll-up thread
#
# One review is one GitHub write, where posting comment by comment cost one
# write per finding. If GitHub rejects the review (usually a line outside the
# diff), each thread is posted on its own, paced, falling back to its file and
# then to a plain PR comment when GitHub answers 422. Afterwards every recorded
# finding is looked for in what GitHub says was posted; any it cannot find goes
# back in the store, so --check keeps failing until it is dealt with.
#
# Usage: post-findings.sh <pr-number> --open    # open the round: record-finding.sh refuses without it
#        post-findings.sh <pr-number>           # post to the PR
#        post-findings.sh <pr-number|local> --local   # print the merged report, post nothing
#        post-findings.sh <pr-number|local> --check   # exit 1 if findings are still unposted

set -euo pipefail

# shellcheck source=_pace.sh
source "$(dirname "${BASH_SOURCE[0]}")/_pace.sh"

PR="${1:?Usage: post-findings.sh <pr-number|local> [--local|--check]}"
MODE="${2:-post}"
case "$MODE" in
    post|--open|--local|--check) ;;
    *) echo "Error: unknown mode '$MODE' (expected --open, --local or --check)" >&2; exit 1 ;;
esac

STORE="$(git rev-parse --absolute-git-dir)/pr-review-loop/findings-$PR.jsonl"

if [[ "$MODE" == "--open" ]]; then
    mkdir -p "$(dirname "$STORE")"
    git rev-parse --show-toplevel > "${STORE%.jsonl}.open"
    echo "Round open for PR $PR in $(git rev-parse --show-toplevel): reviewers record from here."
    exit 0
fi

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

# Hold record-finding.sh's lock throughout, so nothing recorded mid-post is
# archived unsent.
exec 9>>"$STORE.lock"
flock 9

archive() { mv -f "$STORE" "$STORE.$(date +%s%N).done"; }
ERR=$(mktemp); trap 'rm -f "$ERR"' EXIT

# Archive the store, keeping back each finding whose marker is in none of the
# comment bodies GitHub returned ($1, a JSON array). Markers, not bodies: GitHub
# may store a body altered (it rewrote a literal \u001b), and a posted finding
# that looks missing gets posted twice.
settle() {
    local missing total
    missing=$(jq -c --argjson posted "$1" 'def mark: "<!-- finding: \(.fid) -->";
        .[].findings[]
        | select(mark as $m | any($posted[]; contains($m)) | not) | del(.fid)' <<< "$GROUPS_JSON")
    total=$(wc -l < "$STORE")
    archive
    if [[ -n "$missing" ]]; then
        printf '%s\n' "$missing" > "$STORE"
        echo "Posted $((total - $(wc -l < "$STORE"))) of $total finding(s); $(wc -l < "$STORE") are not on the PR and are back in the store." >&2
        return 1
    fi
    echo "Posted $total of $total finding(s) in $COUNT thread(s)."
}

GROUPS_JSON=$(jq -s --arg run "$(date +%s%N)" '
    def sig(a): "<!-- Agent: \(a) -->";
    def mark: "<!-- finding: \(.fid) -->";
    to_entries | map(.value + {fid: "\($run)-\(.key)"}) |
    def rank: {P1: 1, P2: 2, P3: 3}[.severity];
    (map(select(.severity != "P3")) | group_by([.file, .line])
        | map(sort_by(rank) | {
            path: .[0].file, line: .[0].line, findings: .,
            body: (map("🤖 **Claude Code** (\(.agent)) · \(.severity):\n\(sig(.agent))\n\(mark)\n\n\(.body)")
                   | join("\n\n---\n\n"))
          })) as $inline
    | map(select(.severity == "P3")) as $p3
    | ($p3 | map(.agent) | unique) as $p3_agents
    | $inline + (if ($p3 | length) == 0 then [] else [{
        path: $p3[0].file, line: $p3[0].line, findings: $p3, rollup: true,
        body: ("🤖 **Claude Code** (P3 roll-up: \($p3_agents | join(", "))):\n"
               + ($p3_agents | map(sig(.)) | join("\n")) + "\n"
               + ($p3 | map(mark) | join("\n"))
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
    jq -r '.[] | "\n=== \(.path):\(.line) ===\n\(.body)"' <<< "$GROUPS_JSON" | grep -v '^<!-- \(Agent\|finding\): '
    # A preview of a real PR's findings must leave them to be posted.
    [[ "$PR" == "local" ]] && archive
    exit 0
fi


REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
    echo "Error: Could not determine repository. Run from within a git repository." >&2
    exit 1
}
SHA=$(gh pr view "$PR" -R "$REPO" --json headRefOid --jq .headRefOid)
[[ -n "$SHA" ]] || { echo "Error: could not read head SHA of PR #$PR" >&2; exit 1; }

# A file the PR deletes has no RIGHT side; its findings cite the old file.
FILES=$(gh api --paginate "repos/$REPO/pulls/$PR/files" --jq '.[] | "\(.status) \(.filename)"' \
    | jq -Rsc 'split("\n") | map(select(. != "") | capture("^(?<status>\\S+) (?<name>.*)$"))') || {
    echo "Warning: could not list the PR's files; findings on deleted files will be rejected and the P3 roll-up keeps its first anchor" >&2
    FILES='[]'
}
# The roll-up anchors on a P3 in a file the PR touches, so one P3 elsewhere
# cannot sink the rest.
GROUPS_JSON=$(jq --argjson files "$FILES" '
    ($files | map(.name)) as $names
    | ($files | map(select(.status == "removed") | .name)) as $removed
    | map(if .rollup then
            (first(.findings[] | select(.file | IN($names[]))) // null) as $a
            | if $a then .path = $a.file | .line = $a.line else . end
          else . end)
    | map(.side = (if (.path | IN($removed[])) then "LEFT" else "RIGHT" end))' <<< "$GROUPS_JSON")

REVIEW=$(jq --arg sha "$SHA" --arg n "$FINDINGS" '{
    commit_id: $sha, event: "COMMENT",
    body: "pr-review-loop: \($n) finding(s) in \(length) thread(s).",
    comments: map({path, line, side, body})
}' <<< "$GROUPS_JSON")

pace_github
if RESULT=$(gh api --method POST "repos/$REPO/pulls/$PR/reviews" --input - <<< "$REVIEW" 2>"$ERR"); then
    RID=$(jq -r '.id' <<< "$RESULT")
    echo "Posted review $RID."
    # The per-review comments endpoint carries no line numbers; the PR's does.
    if ! LISTED=$(gh api --paginate "repos/$REPO/pulls/$PR/comments" \
            --jq "[.[] | select(.pull_request_review_id == $RID)]" | jq -s 'add // []'); then
        # The review landed whole or not at all, so this is unchecked, not failed.
        archive
        echo "Warning: review $RID is posted, but its comments could not be listed or checked; read them with get-agent-comments.sh" >&2
        exit 0
    fi
    jq -r '.[] | "\(.id) \(.path):\(.line // .original_line) \(.body | split("\n")[0])"' <<< "$LISTED"
    settle "$(jq -c 'map(.body)' <<< "$LISTED")"
    exit
fi

echo "Review rejected, posting threads one at a time: $RESULT $(cat "$ERR")" >&2
POSTED='[]'
landed() { POSTED=$(jq -c --arg o "$OUT" '. + [($o | fromjson? | .body) // ""]' <<< "$POSTED"); }
# Only a 422 means GitHub cannot anchor the comment there; a 5xx or rate limit must not demote it.
unanchorable() { grep -q 'HTTP 422' "$ERR"; }
for i in $(seq 0 $((COUNT - 1))); do
    G=$(jq -c ".[$i]" <<< "$GROUPS_JSON")
    AT=$(jq -r '"\(.path):\(.line)"' <<< "$G")
    pace_github
    if OUT=$(jq --arg sha "$SHA" '{commit_id: $sha, path, line, side, body}' <<< "$G" \
            | gh api --method POST "repos/$REPO/pulls/$PR/comments" --input - 2>"$ERR"); then
        echo "$(jq -r '.id' <<< "$OUT") $AT"
        landed
        continue
    fi
    if unanchorable; then
        echo "Line comment rejected at $AT, trying the file: $OUT $(cat "$ERR")" >&2
        pace_github
        if OUT=$(jq --arg sha "$SHA" '{commit_id: $sha, path, subject_type: "file",
                    body: "\(.body)\n\n_Posted on the file: GitHub would not anchor line \(.line)._"}' <<< "$G" \
                | gh api --method POST "repos/$REPO/pulls/$PR/comments" --input - 2>"$ERR"); then
            echo "$(jq -r '.id' <<< "$OUT") $AT (on the file)"
            landed
            continue
        fi
    fi
    if unanchorable; then
        echo "File comment rejected at $AT, posting it as a PR comment: $OUT $(cat "$ERR")" >&2
        pace_github
        # get-agent-comments.sh reads review threads only, so this one is not deduped next round.
        if OUT=$(jq '{body: "\(.body)\n\n_Posted unanchored: `\(.path):\(.line)` is not in the diff._"}' <<< "$G" \
                | gh api --method POST "repos/$REPO/issues/$PR/comments" --input - 2>"$ERR"); then
            echo "$(jq -r '.id' <<< "$OUT") $AT (unanchored PR comment: reply with gh pr comment, not reply-to-comment.sh)"
            landed
            continue
        fi
    fi
    echo "FAILED $AT: $OUT $(cat "$ERR")" >&2
done

settle "$POSTED"
