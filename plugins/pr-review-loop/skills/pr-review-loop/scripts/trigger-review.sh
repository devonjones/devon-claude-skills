#!/bin/bash
# Trigger a code review on a PR (supports Gemini, Cursor, Claude)
# Usage: trigger-review.sh [pr-number] [--gemini|--cursor|--claude] [--wait]
#
# This script supports multiple review bot types:
# - Gemini Code Assist: Manually triggered via /gemini review comment
# - Cursor Bugbot: Auto-reviews on push (no manual trigger needed)
# - Claude: Fallback using a Claude agent to review the PR
#
# By default, triggers Gemini Code Assist. If Gemini is rate-limited,
# outputs instructions for Claude fallback.
#
# Options:
#   --gemini    Trigger Gemini Code Assist review (default)
#   --cursor    Check for Cursor Bugbot comments (auto-triggered on push)
#   --claude    Use Claude agent for code review
#   --wait      Poll for up to 5 minutes waiting for review comments to appear

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_NUMBER=""
BOT_TYPE="gemini"  # Default to gemini
WAIT_FOR_COMMENTS=false
WAIT_TIMEOUT=300  # 5 minutes
POLL_INTERVAL=30

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gemini)
            BOT_TYPE="gemini"
            shift
            ;;
        --cursor)
            BOT_TYPE="cursor"
            shift
            ;;
        --claude)
            BOT_TYPE="claude"
            shift
            ;;
        --wait)
            WAIT_FOR_COMMENTS=true
            shift
            ;;
        *)
            if [[ -z "$PR_NUMBER" ]]; then
                PR_NUMBER="$1"
            fi
            shift
            ;;
    esac
done

# Get PR number if not provided
if [[ -z "$PR_NUMBER" ]]; then
    PR_NUMBER=$(gh pr view --json number --jq '.number' 2>&1) || {
        PR_NUMBER=""
    }
fi

if [[ -z "$PR_NUMBER" ]]; then
    echo "Error: Could not determine PR number. Provide it as argument or run from a branch with an open PR."
    exit 1
fi

# Handle Claude fallback directly
if [[ "$BOT_TYPE" == "claude" ]]; then
    echo "Using Claude agent for code review..."
    exec "$SCRIPT_DIR/claude-review.sh" "$PR_NUMBER"
fi

# Handle Cursor - it auto-reviews on push, so we just wait for comments
if [[ "$BOT_TYPE" == "cursor" ]]; then
    echo "Cursor Bugbot auto-reviews on push. Checking for existing comments..."
    echo ""
    echo "Note: Cursor reviews typically appear within 1-2 minutes of push."
    echo ""
    # Skip to the waiting logic below
fi

# For Gemini, check quota and trigger review
if [[ "$BOT_TYPE" == "gemini" ]]; then
    # Check if Gemini is already rate-limited before triggering
    if ! "$SCRIPT_DIR/check-gemini-quota.sh" "$PR_NUMBER" > /dev/null 2>&1; then
        echo "!!! Gemini Code Assist is rate-limited !!!"
        echo ""
        echo "Options:"
        echo "  1. Wait up to 24 hours for quota to reset"
        echo "  2. Use Cursor if available (auto-reviews on push):"
        echo ""
        echo "     ~/.claude/skills/pr-review-loop/scripts/trigger-review.sh $PR_NUMBER --cursor --wait"
        echo ""
        echo "  3. Use Claude agent for code review:"
        echo ""
        echo "     ~/.claude/skills/pr-review-loop/scripts/trigger-review.sh $PR_NUMBER --claude"
        echo ""
        exit 1
    fi
    echo "Triggering Gemini review on PR #$PR_NUMBER..."
fi

# Get repo info for GraphQL queries
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
OWNER=$(echo "$REPO" | cut -d'/' -f1)
REPO_NAME=$(echo "$REPO" | cut -d'/' -f2)

# Function to get current unresolved comment count (with pagination)
get_comment_count() {
    local count=0
    local cursor=""
    local has_next=true

    while [[ "$has_next" == "true" ]]; do
        local result
        if [[ -z "$cursor" ]]; then
            result=$(gh api graphql -f query='
            query($owner: String!, $repo: String!, $pr: Int!) {
              repository(owner: $owner, name: $repo) {
                pullRequest(number: $pr) {
                  reviewThreads(first: 100) {
                    pageInfo { hasNextPage endCursor }
                    nodes { isResolved }
                  }
                }
              }
            }' -f owner="$OWNER" -f repo="$REPO_NAME" -F pr="$PR_NUMBER" 2>/dev/null)
        else
            result=$(gh api graphql -f query='
            query($owner: String!, $repo: String!, $pr: Int!, $cursor: String) {
              repository(owner: $owner, name: $repo) {
                pullRequest(number: $pr) {
                  reviewThreads(first: 100, after: $cursor) {
                    pageInfo { hasNextPage endCursor }
                    nodes { isResolved }
                  }
                }
              }
            }' -f owner="$OWNER" -f repo="$REPO_NAME" -F pr="$PR_NUMBER" -f cursor="$cursor" 2>/dev/null)
        fi

        local page_count
        page_count=$(echo "$result" | jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length')
        count=$((count + page_count))

        has_next=$(echo "$result" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false')
        cursor=$(echo "$result" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // empty')
    done

    echo "$count"
}

# Only Gemini needs a manual trigger command
if [[ "$BOT_TYPE" == "gemini" ]]; then
    gh pr comment "$PR_NUMBER" --body "/gemini review"
    echo "Review requested."
fi

if [[ "$WAIT_FOR_COMMENTS" == "true" ]]; then
    # Check immediately if there are already unresolved comments
    CURRENT_COUNT=$(get_comment_count)
    if [[ "$CURRENT_COUNT" -gt 0 ]]; then
        echo "Found $CURRENT_COUNT unresolved comment(s), proceeding..."
        echo ""
        echo "Run get-review-comments.sh to see the feedback:"
        echo "  ~/.claude/skills/pr-review-loop/scripts/get-review-comments.sh $PR_NUMBER --with-ids"
        exit 0
    fi

    echo ""
    echo "Waiting for review comments..."
    echo "Will poll every ${POLL_INTERVAL}s for up to ${WAIT_TIMEOUT}s (5 minutes)"
    echo ""

    ELAPSED=0
    while [[ $ELAPSED -lt $WAIT_TIMEOUT ]]; do
        sleep "$POLL_INTERVAL"
        ELAPSED=$((ELAPSED + POLL_INTERVAL))

        CURRENT_COUNT=$(get_comment_count)

        if [[ "$CURRENT_COUNT" -gt 0 ]]; then
            echo "New comments detected! ($CURRENT_COUNT unresolved)"
            echo ""
            echo "Run get-review-comments.sh to see the feedback:"
            echo "  ~/.claude/skills/pr-review-loop/scripts/get-review-comments.sh $PR_NUMBER --with-ids"
            exit 0
        fi

        # Check for Gemini quota exceeded (only relevant for Gemini bot)
        if [[ "$BOT_TYPE" == "gemini" ]]; then
            QUOTA_CHECK=$(gh pr view "$PR_NUMBER" --json comments --jq '.comments[] | select(.author.login == "gemini-code-assist[bot]" or .author.login == "gemini-code-assist") | .body' 2>/dev/null | tail -1 || echo "")
            if echo "$QUOTA_CHECK" | grep -qi "daily quota limit"; then
                echo "Gemini is rate-limited. Use Claude fallback:"
                echo "   ~/.claude/skills/pr-review-loop/scripts/claude-review.sh $PR_NUMBER"
                exit 1
            fi
        fi

        echo "Still waiting... (${ELAPSED}s/${WAIT_TIMEOUT}s, $CURRENT_COUNT unresolved comments)"
    done

    FINAL_COUNT=$(get_comment_count)
    if [[ "$FINAL_COUNT" -eq 0 ]]; then
        echo ""
        echo "No comments after ${WAIT_TIMEOUT}s. Gemini may not have feedback on this change."
    fi
else
    echo "Comments typically arrive in 1-5 minutes."
    echo ""
    echo "Use --wait to poll for comments, or check manually:"
    echo "  ~/.claude/skills/pr-review-loop/scripts/get-review-comments.sh $PR_NUMBER --with-ids"
    echo ""
    echo "If Gemini is rate-limited, use Claude fallback:"
    echo "  ~/.claude/skills/pr-review-loop/scripts/claude-review.sh $PR_NUMBER"
fi
