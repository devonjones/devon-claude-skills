#!/bin/bash
# Trigger a code review on a PR (supports Gemini, Cursor, Claude)
# Usage: trigger-review.sh [pr-number] [--gemini|--cursor|--claude] [--wait]
#
# This script supports multiple review bot types:
# - Gemini Code Assist: Triggered via /gemini review comment, but skipped if
#   Gemini has already reviewed the current commit (e.g., auto-review on push).
#   Also checks for .gemini/config.yaml to detect repos with auto-review enabled.
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

# Get repo info (needed for all gh calls below)
REPO=$(git remote get-url origin 2>/dev/null | sed 's/.*github\.com[:\/]//' | sed 's/\.git$//')
OWNER=$(echo "$REPO" | cut -d'/' -f1)
REPO_NAME=$(echo "$REPO" | cut -d'/' -f2)

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
    PR_NUMBER=$(gh pr view -R "$REPO" --json number --jq '.number' 2>/dev/null) || PR_NUMBER=""
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

# Check if repo has Gemini auto-review configured (.gemini/config.yaml with code_review: true)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
GEMINI_AUTO_REVIEW=false
if [[ -n "$REPO_ROOT" && -f "$REPO_ROOT/.gemini/config.yaml" ]]; then
    if grep -qEi '^[[:space:]]*code_review:[[:space:]]*true[[:space:]]*$' "$REPO_ROOT/.gemini/config.yaml" 2>/dev/null; then
        GEMINI_AUTO_REVIEW=true
    fi
fi

# Check if Gemini has already reviewed a specific commit
gemini_has_reviewed() {
    local sha="$1"
    local count
    count=$(gh api --paginate "repos/$OWNER/$REPO_NAME/pulls/$PR_NUMBER/reviews" \
      | jq -s --arg sha "$sha" 'add | [.[] | select((.user.login == "gemini-code-assist[bot]" or .user.login == "gemini-code-assist") and .commit_id == $sha)] | length') || {
        echo "Warning: Failed to check Gemini review status via API. Assuming not reviewed." >&2
        count=0
    }
    [[ "$count" -gt 0 ]]
}

# Only Gemini needs a manual trigger command — but skip if already reviewed this commit
if [[ "$BOT_TYPE" == "gemini" ]]; then
    CURRENT_SHA=$(git rev-parse HEAD)

    if gemini_has_reviewed "$CURRENT_SHA"; then
        echo "Gemini already reviewed commit ${CURRENT_SHA:0:7}, skipping manual trigger."
    elif [[ "$GEMINI_AUTO_REVIEW" == "true" && "$WAIT_FOR_COMMENTS" == "true" ]]; then
        # Repo has auto-review configured — wait one interval for it before triggering manually
        echo "Auto-review detected in .gemini/config.yaml. Waiting ${POLL_INTERVAL}s for auto-review..."
        sleep "$POLL_INTERVAL"

        if gemini_has_reviewed "$CURRENT_SHA"; then
            echo "Gemini auto-reviewed commit ${CURRENT_SHA:0:7}, skipping manual trigger."
        else
            echo "No auto-review yet. Triggering manually..."
            gh pr comment "$PR_NUMBER" -R "$REPO" --body "/gemini review"
            echo "Review requested."
        fi
        # Account for the grace period in the wait timeout below
        GRACE_ELAPSED=$POLL_INTERVAL
    else
        gh pr comment "$PR_NUMBER" -R "$REPO" --body "/gemini review"
        echo "Review requested."
    fi
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

    # Account for any grace period already waited
    ELAPSED=${GRACE_ELAPSED:-0}
    REMAINING=$((WAIT_TIMEOUT - ELAPSED))

    echo ""
    echo "Waiting for review comments..."
    echo "Will poll every ${POLL_INTERVAL}s for up to ${REMAINING}s"
    echo ""

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
            QUOTA_CHECK=$(gh pr view "$PR_NUMBER" -R "$REPO" --json comments --jq '.comments[] | select(.author.login == "gemini-code-assist[bot]" or .author.login == "gemini-code-assist") | .body' 2>/dev/null | tail -1 || echo "")
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
