#!/bin/bash
# Reply to a PR review comment and resolve the thread
# Usage: reply-to-comment.sh <pr-number> <comment-id> "reply message" [--no-resolve]
#
# Comment IDs can be found in the output of get-review-comments.sh --with-ids
# Accepts either numeric database ID or GraphQL Node ID (PRRC_...)
# By default, resolves the conversation after replying. Use --no-resolve to skip.

set -euo pipefail

PR_NUMBER="${1:?Usage: reply-to-comment.sh <pr-number> <comment-id> \"reply message\" [--no-resolve]}"
COMMENT_ID="${2:?Usage: reply-to-comment.sh <pr-number> <comment-id> \"reply message\" [--no-resolve]}"
REPLY="${3:?Usage: reply-to-comment.sh <pr-number> <comment-id> \"reply message\" [--no-resolve]}"
NO_RESOLVE="${4:-}"

# Get repo info
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
OWNER=$(echo "$REPO" | cut -d'/' -f1)
REPO_NAME=$(echo "$REPO" | cut -d'/' -f2)

echo "Replying to comment $COMMENT_ID on PR #$PR_NUMBER..."

# Determine if this is a Node ID (starts with letters) or database ID (numeric)
REPLY_POSTED=false
if [[ "$COMMENT_ID" =~ ^[0-9]+$ ]]; then
    # Numeric database ID - use REST API
    REPLY_RESULT=$(gh api \
        --method POST \
        "repos/$REPO/pulls/$PR_NUMBER/comments/$COMMENT_ID/replies" \
        -f body="$REPLY" 2>&1) && REPLY_POSTED=true || {
        echo "Warning: Failed to post reply via REST API."
        echo "Error: $REPLY_RESULT"
    }
else
    # Node ID - use GraphQL
    echo "Using GraphQL with Node ID..."
fi

# If REST API failed or we have a Node ID, try GraphQL
if [[ "$REPLY_POSTED" == "false" ]]; then
    # For GraphQL we need the PR's Node ID
    PR_NODE_ID=$(gh api graphql -f query="
        query(\$owner: String!, \$repo: String!, \$pr: Int!) {
            repository(owner: \$owner, name: \$repo) {
                pullRequest(number: \$pr) {
                    id
                }
            }
        }
    " -f owner="$OWNER" -f repo="$REPO_NAME" -F pr="$PR_NUMBER" \
    --jq '.data.repository.pullRequest.id' 2>/dev/null || echo "")

    if [[ -n "$PR_NODE_ID" ]]; then
        # If we have a numeric ID but REST failed, convert to Node ID
        NODE_ID="$COMMENT_ID"
        if [[ "$COMMENT_ID" =~ ^[0-9]+$ ]]; then
            # Look up the Node ID from the database ID (with pagination)
            NODE_ID=""
            CURSOR=""
            HAS_NEXT=true
            while [[ "$HAS_NEXT" == "true" ]] && [[ -z "$NODE_ID" ]]; do
                if [[ -z "$CURSOR" ]]; then
                    PAGE=$(gh api graphql -f query="
                        query(\$owner: String!, \$repo: String!, \$pr: Int!) {
                            repository(owner: \$owner, name: \$repo) {
                                pullRequest(number: \$pr) {
                                    reviewThreads(first: 100) {
                                        pageInfo { hasNextPage endCursor }
                                        nodes {
                                            comments(first: 1) {
                                                nodes { id databaseId }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    " -f owner="$OWNER" -f repo="$REPO_NAME" -F pr="$PR_NUMBER" 2>/dev/null || echo "{}")
                else
                    PAGE=$(gh api graphql -f query="
                        query(\$owner: String!, \$repo: String!, \$pr: Int!, \$cursor: String) {
                            repository(owner: \$owner, name: \$repo) {
                                pullRequest(number: \$pr) {
                                    reviewThreads(first: 100, after: \$cursor) {
                                        pageInfo { hasNextPage endCursor }
                                        nodes {
                                            comments(first: 1) {
                                                nodes { id databaseId }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    " -f owner="$OWNER" -f repo="$REPO_NAME" -F pr="$PR_NUMBER" -f cursor="$CURSOR" 2>/dev/null || echo "{}")
                fi
                NODE_ID=$(echo "$PAGE" | jq -r ".data.repository.pullRequest.reviewThreads.nodes[].comments.nodes[] | select(.databaseId == $COMMENT_ID) | .id" 2>/dev/null | head -1 || echo "")
                HAS_NEXT=$(echo "$PAGE" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false')
                CURSOR=$(echo "$PAGE" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // empty')
            done
        fi

        if [[ -n "$NODE_ID" ]]; then
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
            ' -f body="$REPLY" -f commentId="$NODE_ID" 2>&1) && REPLY_POSTED=true || {
                echo "Warning: GraphQL reply also failed."
                echo "Error: $REPLY_RESULT"
            }
        fi
    fi
fi

if [[ "$REPLY_POSTED" == "true" ]]; then
    echo "Reply posted."
else
    echo "Warning: Could not post reply. Thread will still be resolved."
fi

# Resolve the thread unless --no-resolve is specified
if [[ "$NO_RESOLVE" != "--no-resolve" ]]; then
    echo "Resolving thread..."

    # Get thread ID by finding the thread that contains this comment (with pagination)
    THREAD_ID=""
    CURSOR=""
    HAS_NEXT=true
    while [[ "$HAS_NEXT" == "true" ]] && [[ -z "$THREAD_ID" ]]; do
        if [[ -z "$CURSOR" ]]; then
            PAGE=$(gh api graphql -f query="
                query(\$owner: String!, \$repo: String!, \$pr: Int!) {
                    repository(owner: \$owner, name: \$repo) {
                        pullRequest(number: \$pr) {
                            reviewThreads(first: 100) {
                                pageInfo { hasNextPage endCursor }
                                nodes {
                                    id
                                    comments(first: 1) {
                                        nodes { databaseId }
                                    }
                                }
                            }
                        }
                    }
                }
            " -f owner="$OWNER" -f repo="$REPO_NAME" -F pr="$PR_NUMBER" 2>/dev/null || echo "{}")
        else
            PAGE=$(gh api graphql -f query="
                query(\$owner: String!, \$repo: String!, \$pr: Int!, \$cursor: String) {
                    repository(owner: \$owner, name: \$repo) {
                        pullRequest(number: \$pr) {
                            reviewThreads(first: 100, after: \$cursor) {
                                pageInfo { hasNextPage endCursor }
                                nodes {
                                    id
                                    comments(first: 1) {
                                        nodes { databaseId }
                                    }
                                }
                            }
                        }
                    }
                }
            " -f owner="$OWNER" -f repo="$REPO_NAME" -F pr="$PR_NUMBER" -f cursor="$CURSOR" 2>/dev/null || echo "{}")
        fi
        THREAD_ID=$(echo "$PAGE" | jq -r ".data.repository.pullRequest.reviewThreads.nodes[] | select(.comments.nodes[0].databaseId == $COMMENT_ID) | .id" 2>/dev/null | head -1 || echo "")
        HAS_NEXT=$(echo "$PAGE" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false')
        CURSOR=$(echo "$PAGE" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // empty')
    done

    if [[ -n "$THREAD_ID" && "$THREAD_ID" != "null" ]]; then
        gh api graphql -f query="
            mutation(\$threadId: ID!) {
                resolveReviewThread(input: {threadId: \$threadId}) {
                    thread {
                        isResolved
                    }
                }
            }
        " -f threadId="$THREAD_ID" > /dev/null 2>&1 && echo "Thread resolved." || echo "Warning: Could not resolve thread."
    else
        echo "Warning: Could not find thread ID to resolve."
    fi
fi
