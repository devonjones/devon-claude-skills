#!/bin/bash
# Summarize review comments by priority and file
# Usage: summarize-reviews.sh <pr-number> [--all]
#
# Options:
#   --all    Include resolved threads (default: unresolved only)

set -euo pipefail

# Load shared jq helpers
source "$(dirname "${BASH_SOURCE[0]}")/_jq_helpers.sh"

PR_NUMBER="${1:?Usage: summarize-reviews.sh <pr-number> [--all]}"
INCLUDE_RESOLVED=false

for arg in "$@"; do
    if [[ "$arg" == "--all" ]]; then
        INCLUDE_RESOLVED=true
    fi
done

# Get repo info
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
OWNER=$(echo "$REPO" | cut -d'/' -f1)
REPO_NAME=$(echo "$REPO" | cut -d'/' -f2)

echo "=== PR #$PR_NUMBER Review Summary ==="
echo ""

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
          comments(first: 1) {
            nodes {
              path
              line
              originalLine
              body
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
            echo "Error: Failed to fetch review comments from GitHub API" >&2
            exit 1
        }
    else
        PAGE_RESULT=$(gh api graphql -f query="$QUERY" -f owner="$OWNER" -f repo="$REPO_NAME" -F pr="$PR_NUMBER" -f cursor="$CURSOR") || {
            echo "Error: Failed to fetch review comments from GitHub API" >&2
            exit 1
        }
    fi

    PAGE_THREADS=$(echo "$PAGE_RESULT" | jq '.data.repository.pullRequest.reviewThreads.nodes')
    ALL_THREADS=$(echo "$ALL_THREADS $PAGE_THREADS" | jq -s 'add')

    HAS_NEXT_PAGE=$(echo "$PAGE_RESULT" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')
    CURSOR=$(echo "$PAGE_RESULT" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')
done

RESULT=$(echo "$ALL_THREADS" | jq '{data: {repository: {pullRequest: {reviewThreads: {nodes: .}}}}}')

if [[ -z "$RESULT" ]] || [[ "$ALL_THREADS" == "[]" ]]; then
    echo "No review comments."
    exit 0
fi

# Extract comments based on resolution filter
COMMENTS=$(echo "$RESULT" | jq --argjson resolved "$INCLUDE_RESOLVED" '
    [.data.repository.pullRequest.reviewThreads.nodes[] |
     select($resolved or .isResolved == false) |
     .comments.nodes[0] |
     select(. != null)]
')

if [[ "$COMMENTS" == "[]" ]]; then
    if [[ "$INCLUDE_RESOLVED" == "false" ]]; then
        echo "No unresolved review comments."
    else
        echo "No review comments."
    fi
    exit 0
fi

# PRIORITY_DETECT is now loaded from _jq_helpers.sh

# Count by priority
echo "## By Priority"
echo "$COMMENTS" | jq -r "$PRIORITY_DETECT"'
    [.[] | . + {priority: (.body | detect_priority)}] |
    group_by(.priority) |
    sort_by(.[0].priority | if . == "critical" then 0 elif . == "high" then 1 elif . == "medium" then 2 elif . == "low" then 3 else 4 end) |
    .[] |
    "- \(.[0].priority): \(length) comment(s)"
'
echo ""

# Group by file
echo "## By File"
echo "$COMMENTS" | jq -r '
    group_by(.path) |
    .[] |
    "- \(.[0].path): \(length) comment(s)"
'
echo ""

# List critical and high priority items
echo "## Critical/High Priority Items"
echo "$COMMENTS" | jq -r "$PRIORITY_DETECT"'
    .[] |
    select((.body | detect_priority) == "critical" or (.body | detect_priority) == "high") |
    "- [\(.path):\(.line // .originalLine // "?")] [\(.body | detect_priority)] \(.body | split("\n")[0] | gsub("!\\[(critical|high|medium|low)\\]\\([^)]+\\)"; "") | .[0:80])"
'
