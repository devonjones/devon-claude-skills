#!/bin/bash
# Get PR-level comments from bot reviewers (Claude, Cursor, Copilot, etc.)
# Usage: get-pr-comments.sh <pr-number> [--with-ids] [--wait] [--author <login>]
#
# Unlike get-review-comments.sh (line comments via reviewThreads), this fetches
# PR-level comments — single-comment reviews from bots like Claude.
#
# Options:
#   --with-ids    Include comment IDs for use with reply-to-comment.sh
#   --wait        Poll for up to 5 minutes waiting for new bot comments
#   --author      Filter to a specific author (e.g., "claude")

set -euo pipefail

# Load shared jq helpers
source "$(dirname "${BASH_SOURCE[0]}")/_jq_helpers.sh"

PR_NUMBER="${1:?Usage: get-pr-comments.sh <pr-number> [--with-ids] [--wait] [--author <login>]}"
shift

WITH_IDS=false
WAIT_FOR_COMMENTS=false
WAIT_TIMEOUT=300  # 5 minutes
POLL_INTERVAL=30
AUTHOR_FILTER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-ids)
            WITH_IDS=true
            shift
            ;;
        --wait)
            WAIT_FOR_COMMENTS=true
            shift
            ;;
        --author)
            AUTHOR_FILTER="${2:?--author requires a value}"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Get repo info (needed for all gh calls to work from worktrees or when origin remote differs)
REPO=$(git remote get-url origin 2>/dev/null | sed 's/.*github\.com[:\/]//' | sed 's/\.git$//')

# Validate PR number to fail fast on invalid input
if ! gh pr view "$PR_NUMBER" -R "$REPO" --json number &> /dev/null; then
    echo "Error: Pull request #$PR_NUMBER not found or access denied." >&2
    exit 1
fi

# Default bot pattern (regex); --author uses exact match instead
BOT_PATTERN="claude|cursor|copilot|gemini-code-assist"
EXACT_MATCH=false
if [[ -n "$AUTHOR_FILTER" ]]; then
    BOT_PATTERN="$AUTHOR_FILTER"
    EXACT_MATCH=true
fi

# jq filter: exact case-insensitive match for --author, regex for default
JQ_SELECT='select(if $exact then (.author.login | ascii_downcase) == ($pattern | ascii_downcase) else .author.login | test($pattern; "i") end)'

# Function to get bot PR comment count
get_bot_comment_count() {
    gh pr view "$PR_NUMBER" -R "$REPO" --json comments \
        --arg pattern "$BOT_PATTERN" --argjson exact "$EXACT_MATCH" \
        --jq "[.comments[] | $JQ_SELECT] | length" 2>/dev/null || echo 0
}

# If --wait, poll until bot comments exist or timeout
if [[ "$WAIT_FOR_COMMENTS" == "true" ]]; then
    INITIAL_COUNT=$(get_bot_comment_count)

    if [[ "$INITIAL_COUNT" -gt 0 ]]; then
        echo "Found $INITIAL_COUNT bot PR comment(s), proceeding..."
        echo ""
    else
        ELAPSED=0
        echo "Waiting for bot PR comments (current: 0)..."
        echo "Will poll every ${POLL_INTERVAL}s for up to ${WAIT_TIMEOUT}s (5 minutes)"
        echo ""

        while [[ $ELAPSED -lt $WAIT_TIMEOUT ]]; do
            sleep "$POLL_INTERVAL"
            ELAPSED=$((ELAPSED + POLL_INTERVAL))

            CURRENT_COUNT=$(get_bot_comment_count)

            if [[ "$CURRENT_COUNT" -gt 0 ]]; then
                echo "Bot PR comments detected! ($CURRENT_COUNT comments)"
                echo ""
                break
            fi

            echo "Still waiting... (${ELAPSED}s/${WAIT_TIMEOUT}s)"
        done

        if [[ $ELAPSED -ge $WAIT_TIMEOUT ]]; then
            FINAL_COUNT=$(get_bot_comment_count)
            if [[ "$FINAL_COUNT" -eq 0 ]]; then
                echo "No bot PR comments after ${WAIT_TIMEOUT}s."
                echo ""
                exit 0
            fi
        fi
    fi
fi

# Fetch bot PR comments
COMMENTS=$(gh pr view "$PR_NUMBER" -R "$REPO" --json comments \
    --arg pattern "$BOT_PATTERN" --argjson exact "$EXACT_MATCH" \
    --jq "[.comments[] | $JQ_SELECT | {id: .id, author: .author.login, createdAt: .createdAt, body: .body}]" 2>/dev/null || echo "[]")

if [[ "$COMMENTS" == "[]" ]] || [[ -z "$COMMENTS" ]]; then
    echo "No PR comments found from bot reviewers."
    exit 0
fi

TOTAL=$(echo "$COMMENTS" | jq 'length')
echo "Found $TOTAL bot PR comment(s):"
echo ""

# Process and output each comment
echo "$COMMENTS" | jq -r --argjson withIds "$WITH_IDS" "$PRIORITY_DETECT"'
    .[] |
    (.body | detect_priority) as $priority |
    if $withIds then
        "=== Comment ID: \(.id) | Author: \(.author) | \(.createdAt) ===",
        "Priority: \($priority)",
        "",
        .body,
        "",
        "---",
        ""
    else
        "=== Author: \(.author) | \(.createdAt) ===",
        "Priority: \($priority)",
        "",
        (.body | split("\n") | .[0:5] | join("\n")),
        "... (use --with-ids for full text)",
        "",
        "---",
        ""
    end
'

# Summary by author
echo ""
echo "## Summary"
echo "$COMMENTS" | jq -r 'group_by(.author) | .[] | "\(.[0].author): \(length) comment(s)"'
