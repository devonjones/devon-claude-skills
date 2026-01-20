#!/bin/bash
# Get review comments for a PR, formatted for easy reading
# Usage: get-review-comments.sh <pr-number> [--latest] [--with-ids] [--all] [--wait]
#
# Options:
#   --latest      Only show comments on the latest commit
#   --with-ids    Include comment IDs for replying/resolving
#   --all         Include resolved threads (default: unresolved only)
#   --wait        Poll for up to 5 minutes waiting for new comments to appear

set -euo pipefail

# Load shared jq helpers
source "$(dirname "${BASH_SOURCE[0]}")/_jq_helpers.sh"

PR_NUMBER="${1:?Usage: get-review-comments.sh <pr-number> [--latest] [--with-ids] [--all]}"
shift

LATEST_ONLY=false
WITH_IDS=false
INCLUDE_RESOLVED=false
WAIT_FOR_COMMENTS=false
WAIT_TIMEOUT=300  # 5 minutes
POLL_INTERVAL=30

while [[ $# -gt 0 ]]; do
    case "$1" in
        --latest)
            LATEST_ONLY=true
            shift
            ;;
        --with-ids)
            WITH_IDS=true
            shift
            ;;
        --all)
            INCLUDE_RESOLVED=true
            shift
            ;;
        --wait)
            WAIT_FOR_COMMENTS=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# Get repo info
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

        has_next=$(echo "$result" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')
        cursor=$(echo "$result" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')
    done

    echo "$count"
}

# If --wait, poll until comments exist or timeout
if [[ "$WAIT_FOR_COMMENTS" == "true" ]]; then
    INITIAL_COUNT=$(get_comment_count)

    # If there are already unresolved comments, proceed immediately
    if [[ "$INITIAL_COUNT" -gt 0 ]]; then
        echo "Found $INITIAL_COUNT unresolved comment(s), proceeding..."
        echo ""
    else
        ELAPSED=0
        echo "Waiting for review comments (current: 0 unresolved)..."
        echo "Will poll every ${POLL_INTERVAL}s for up to ${WAIT_TIMEOUT}s (5 minutes)"
        echo ""

        while [[ $ELAPSED -lt $WAIT_TIMEOUT ]]; do
            sleep "$POLL_INTERVAL"
            ELAPSED=$((ELAPSED + POLL_INTERVAL))

            CURRENT_COUNT=$(get_comment_count)

            if [[ "$CURRENT_COUNT" -gt 0 ]]; then
                echo "New comments detected! ($CURRENT_COUNT unresolved)"
                echo ""
                break
            fi

            # Check for Gemini quota exceeded
            QUOTA_CHECK=$(gh pr view "$PR_NUMBER" --json comments --jq '.comments[] | select(.author.login == "gemini-code-assist[bot]" or .author.login == "gemini-code-assist") | .body' 2>/dev/null | tail -1 || echo "")
            if echo "$QUOTA_CHECK" | grep -qi "daily quota limit"; then
                echo "Gemini is rate-limited. Use Claude fallback:"
                echo "   ~/.claude/skills/pr-review-loop/scripts/claude-review.sh $PR_NUMBER"
                echo ""
                exit 1
            fi

            echo "Still waiting... (${ELAPSED}s/${WAIT_TIMEOUT}s, $CURRENT_COUNT unresolved comments)"
        done

        if [[ $ELAPSED -ge $WAIT_TIMEOUT ]]; then
            FINAL_COUNT=$(get_comment_count)
            if [[ "$FINAL_COUNT" -eq 0 ]]; then
                echo "No comments after ${WAIT_TIMEOUT}s. Gemini may not have feedback on this change."
                echo ""
            fi
        fi
    fi
fi

# Check for Gemini rate-limit in PR comments
RATE_LIMITED=$(gh pr view "$PR_NUMBER" --json comments --jq '.comments[] | select(.author.login == "gemini-code-assist[bot]" or .author.login == "gemini-code-assist") | .body' 2>/dev/null | grep -q "daily quota limit" && echo "true" || echo "false")
if [[ "$RATE_LIMITED" == "true" ]]; then
    echo "⚠️  Gemini is rate-limited. Use Claude fallback:"
    echo "   ~/.claude/skills/pr-review-loop/scripts/claude-review.sh $PR_NUMBER"
    echo ""
fi

# Get latest commit if --latest flag
SINCE_COMMIT=""
if [[ "$LATEST_ONLY" == "true" ]]; then
    SINCE_COMMIT=$(gh pr view "$PR_NUMBER" --json commits --jq '.commits[-1].oid')
fi

# Use GraphQL to get review threads with resolution status (with pagination)
QUERY='
query($owner: String!, $repo: String!, $pr: Int!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          isResolved
          comments(first: 10) {
            nodes {
              id
              databaseId
              path
              line
              originalLine
              body
              commit {
                oid
              }
            }
          }
        }
      }
    }
  }
}
'

# Fetch all pages of review threads
ALL_THREADS="[]"
CURSOR=""
HAS_NEXT_PAGE=true

while [[ "$HAS_NEXT_PAGE" == "true" ]]; do
    if [[ -z "$CURSOR" ]]; then
        PAGE_RESULT=$(gh api graphql -f query="$QUERY" -f owner="$OWNER" -f repo="$REPO_NAME" -F pr="$PR_NUMBER") || {
            echo "Error: Failed to fetch review comments from GitHub API"
            exit 1
        }
    else
        PAGE_RESULT=$(gh api graphql -f query="$QUERY" -f owner="$OWNER" -f repo="$REPO_NAME" -F pr="$PR_NUMBER" -f cursor="$CURSOR") || {
            echo "Error: Failed to fetch review comments from GitHub API"
            exit 1
        }
    fi

    # Extract threads from this page and merge
    PAGE_THREADS=$(echo "$PAGE_RESULT" | jq '.data.repository.pullRequest.reviewThreads.nodes')
    ALL_THREADS=$(echo "$ALL_THREADS $PAGE_THREADS" | jq -s 'add')

    # Check for next page
    HAS_NEXT_PAGE=$(echo "$PAGE_RESULT" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')
    CURSOR=$(echo "$PAGE_RESULT" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')
done

# Build a result structure matching what the jq processing expects
RESULT=$(echo "$ALL_THREADS" | jq '{data: {repository: {pullRequest: {reviewThreads: {nodes: .}}}}}')

if [[ -z "$RESULT" ]] || [[ "$ALL_THREADS" == "[]" ]]; then
    echo "No review comments found."
    exit 0
fi

# Process and filter the results
# PRIORITY_DETECT is loaded from _jq_helpers.sh
echo "$RESULT" | jq -r --arg since "$SINCE_COMMIT" --argjson resolved "$INCLUDE_RESOLVED" --argjson withIds "$WITH_IDS" "$PRIORITY_DETECT"'
    .data.repository.pullRequest.reviewThreads.nodes[] |
    select($resolved or .isResolved == false) |
    .comments.nodes[0] as $comment |
    select($comment != null) |
    select($since == "" or ($comment.commit.oid // "") >= $since) |
    ($comment.body | detect_priority) as $priority |
    if $withIds then
        "=== Comment ID: \($comment.databaseId) | Node ID: \($comment.id) ===",
        "File: \($comment.path):\($comment.line // $comment.originalLine // "?")",
        "Priority: \($priority)",
        "",
        ($comment.body | gsub("!\\[(critical|high|medium|low)\\]\\([^)]+\\)"; "") | gsub("```suggestion"; "SUGGESTION:") | gsub("```"; "")),
        "",
        "---",
        ""
    else
        "[\($comment.path):\($comment.line // $comment.originalLine // "?")]",
        "Priority: \($priority)",
        "",
        ($comment.body | gsub("!\\[(critical|high|medium|low)\\]\\([^)]+\\)"; "") | gsub("```suggestion"; "SUGGESTION:") | gsub("```"; "")),
        "",
        "---",
        ""
    end
'
