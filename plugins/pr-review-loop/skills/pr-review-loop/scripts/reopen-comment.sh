#!/bin/bash
# Reopen a resolved PR review thread by unresolving it and posting a reply
# Usage: reopen-comment.sh <pr-number> <comment-id> <agent-name> "reason"
#
# This script:
# 1. Unresolves the thread (if it was resolved)
# 2. Posts a reply with Claude attribution explaining why it's being reopened
#
# Use this when an agent reviewer disagrees with a "Won't fix" response.

set -euo pipefail

PR_NUMBER="${1:?Usage: reopen-comment.sh <pr-number> <comment-id> <agent-name> \"reason\"}"
COMMENT_ID="${2:?Usage: reopen-comment.sh <pr-number> <comment-id> <agent-name> \"reason\"}"
AGENT_NAME="${3:?Usage: reopen-comment.sh <pr-number> <comment-id> <agent-name> \"reason\"}"
REASON="${4:?Usage: reopen-comment.sh <pr-number> <comment-id> <agent-name> \"reason\"}"

# Get repo info
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
OWNER=$(echo "$REPO" | cut -d'/' -f1)
REPO_NAME=$(echo "$REPO" | cut -d'/' -f2)

echo "Reopening thread for comment $COMMENT_ID on PR #$PR_NUMBER..."

# Find the thread ID for this comment
THREAD_INFO=$(gh api graphql -f query="
    query(\$owner: String!, \$repo: String!, \$pr: Int!) {
        repository(owner: \$owner, name: \$repo) {
            pullRequest(number: \$pr) {
                reviewThreads(first: 100) {
                    nodes {
                        id
                        isResolved
                        comments(first: 1) {
                            nodes {
                                id
                                databaseId
                            }
                        }
                    }
                }
            }
        }
    }
" -f owner="$OWNER" -f repo="$REPO_NAME" -F pr="$PR_NUMBER" 2>/dev/null)

# Extract thread ID - handle both numeric and node IDs
if [[ "$COMMENT_ID" =~ ^[0-9]+$ ]]; then
    THREAD_ID=$(echo "$THREAD_INFO" | jq -r --argjson cid "$COMMENT_ID" '
        .data.repository.pullRequest.reviewThreads.nodes[] |
        select(.comments.nodes[0].databaseId == $cid) |
        .id
    ')
    NODE_ID=$(echo "$THREAD_INFO" | jq -r --argjson cid "$COMMENT_ID" '
        .data.repository.pullRequest.reviewThreads.nodes[] |
        select(.comments.nodes[0].databaseId == $cid) |
        .comments.nodes[0].id
    ')
else
    THREAD_ID=$(echo "$THREAD_INFO" | jq -r --arg cid "$COMMENT_ID" '
        .data.repository.pullRequest.reviewThreads.nodes[] |
        select(.comments.nodes[0].id == $cid) |
        .id
    ')
    NODE_ID="$COMMENT_ID"
fi

if [[ -z "$THREAD_ID" || "$THREAD_ID" == "null" ]]; then
    echo "Error: Could not find thread for comment $COMMENT_ID"
    exit 1
fi

# Check if thread is resolved
IS_RESOLVED=$(echo "$THREAD_INFO" | jq -r --arg tid "$THREAD_ID" '
    .data.repository.pullRequest.reviewThreads.nodes[] |
    select(.id == $tid) |
    .isResolved
')

# Unresolve the thread if it's resolved
if [[ "$IS_RESOLVED" == "true" ]]; then
    echo "Unresolving thread..."
    gh api graphql -f query="
        mutation(\$threadId: ID!) {
            unresolveReviewThread(input: {threadId: \$threadId}) {
                thread {
                    isResolved
                }
            }
        }
    " -f threadId="$THREAD_ID" > /dev/null 2>&1 && echo "Thread unresolved." || {
        echo "Warning: Could not unresolve thread (may already be unresolved)"
    }
else
    echo "Thread is already unresolved."
fi

# Post a reply with the reason
echo "Posting reopen reason..."

REOPEN_COMMENT="🤖 **Claude Code** (${AGENT_NAME}):
<!-- Agent: ${AGENT_NAME} -->

**Reopening this thread.**

${REASON}"

# Use GraphQL to reply to the thread
REPLY_RESULT=$(gh api graphql -f query='
    mutation($body: String!, $commentId: ID!) {
        addPullRequestReviewComment(input: {
            inReplyTo: $commentId,
            body: $body
        }) {
            comment {
                id
            }
        }
    }
' -f body="$REOPEN_COMMENT" -f commentId="$NODE_ID" 2>&1) && {
    echo "Reply posted. Thread is now reopened."
} || {
    # Fallback to REST API if GraphQL fails
    gh api \
        --method POST \
        "repos/$REPO/pulls/$PR_NUMBER/comments/$COMMENT_ID/replies" \
        -f body="$REOPEN_COMMENT" > /dev/null 2>&1 && {
        echo "Reply posted via REST API. Thread is now reopened."
    } || {
        echo "Warning: Could not post reply, but thread was unresolved."
        echo "Error: $REPLY_RESULT"
    }
}
