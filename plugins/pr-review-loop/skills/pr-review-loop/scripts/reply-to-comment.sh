#!/bin/bash
# Reply to a PR review comment and resolve the thread
# Usage: reply-to-comment.sh <pr-number> <comment-id> "reply message" [--no-resolve]
#
# Comment IDs can be found in the output of get-review-comments.sh --with-ids
# Accepts:
#   - Numeric database ID for review comments
#   - GraphQL Node ID for review comments (PRRC_...)
#   - GraphQL Node ID for PR/issue comments (IC_...) - replies by quoting original
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

# Check if this is a PR/issue comment (IC_...) vs a review comment (PRRC_... or numeric)
# PR comments don't have threading, so we quote the original and post a new comment
if [[ "$COMMENT_ID" =~ ^IC_ ]]; then
    echo "Detected PR comment (issue comment). Will quote and reply..."

    # Fetch the original comment to quote it
    ORIGINAL_COMMENT=$(gh pr view "$PR_NUMBER" --json comments \
        --jq ".comments[] | select(.id == \"$COMMENT_ID\") | {author: .author.login, body: .body}" 2>/dev/null || echo "")

    if [[ -z "$ORIGINAL_COMMENT" || "$ORIGINAL_COMMENT" == "null" ]]; then
        echo "ERROR: Could not find PR comment with ID: $COMMENT_ID" >&2
        echo "The comment may have been deleted or the ID is invalid." >&2
        echo "" >&2
        echo "To debug, list all PR comments with:" >&2
        echo "  gh pr view $PR_NUMBER --json comments --jq '.comments[].id'" >&2
        exit 1
    fi

    ORIGINAL_AUTHOR=$(echo "$ORIGINAL_COMMENT" | jq -r '.author')
    ORIGINAL_BODY=$(echo "$ORIGINAL_COMMENT" | jq -r '.body')

    # Create a quoted reply - take first 500 chars of original to keep it reasonable
    QUOTED_BODY=$(echo "$ORIGINAL_BODY" | head -c 500)
    if [[ ${#ORIGINAL_BODY} -gt 500 ]]; then
        QUOTED_BODY="${QUOTED_BODY}..."
    fi

    # Format the reply with quote
    REPLY_BODY=$(cat <<EOF
> **@${ORIGINAL_AUTHOR}** wrote:
$(echo "$QUOTED_BODY" | sed 's/^/> /')

$REPLY
EOF
)

    # Post as a new PR comment
    REPLY_RESULT=$(gh pr comment "$PR_NUMBER" --body "$REPLY_BODY" 2>&1) && {
        echo "Reply posted successfully (as new PR comment with quote)."
        exit 0
    } || {
        echo "ERROR: Failed to post PR comment." >&2
        echo "API Response: $REPLY_RESULT" >&2
        exit 1
    }
fi

# For review comments: we need the numeric database ID for the REST API
# GraphQL's addPullRequestReviewComment mutation is for pending reviews only,
# not for replying to existing comments. REST API is the only way to reply.
DATABASE_ID="$COMMENT_ID"

# If given a Node ID (PRRC_...), look up the database ID via REST API
if [[ ! "$COMMENT_ID" =~ ^[0-9]+$ ]]; then
    echo "Converting Node ID to database ID..."

    # Fetch all comments and find the one with matching node_id
    DATABASE_ID=$(gh api "repos/$REPO/pulls/$PR_NUMBER/comments" --paginate \
        --jq ".[] | select(.node_id == \"$COMMENT_ID\") | .id" 2>/dev/null | head -1 || echo "")

    if [[ -z "$DATABASE_ID" ]]; then
        echo "ERROR: Could not find review comment with Node ID: $COMMENT_ID" >&2
        echo "The comment may have been deleted or the Node ID is invalid." >&2
        echo "" >&2
        echo "To debug, list all review comments with:" >&2
        echo "  gh api repos/$REPO/pulls/$PR_NUMBER/comments --jq '.[].node_id'" >&2
        exit 1
    fi

    echo "Found database ID: $DATABASE_ID"
fi

# Post reply using REST API (the only way to reply to existing review comments)
REPLY_POSTED=false
REPLY_RESULT=$(gh api \
    --method POST \
    "repos/$REPO/pulls/$PR_NUMBER/comments/$DATABASE_ID/replies" \
    -f body="$REPLY" 2>&1) && REPLY_POSTED=true || {
    echo "ERROR: Failed to post reply via REST API." >&2
    echo "" >&2
    echo "API Response: $REPLY_RESULT" >&2
    echo "" >&2
    # Parse common errors
    if echo "$REPLY_RESULT" | grep -q "Not Found"; then
        echo "Possible causes:" >&2
        echo "  - Comment ID $DATABASE_ID does not exist on PR #$PR_NUMBER" >&2
        echo "  - The comment may have been deleted" >&2
        echo "  - You may not have access to this repository" >&2
    elif echo "$REPLY_RESULT" | grep -q "Forbidden"; then
        echo "Possible causes:" >&2
        echo "  - You don't have permission to comment on this PR" >&2
        echo "  - Your GitHub token may be missing 'repo' scope" >&2
        echo "  - Check token permissions: gh auth status" >&2
    elif echo "$REPLY_RESULT" | grep -q "Validation Failed"; then
        echo "Possible causes:" >&2
        echo "  - The reply body may be empty or invalid" >&2
        echo "  - The comment thread may be locked" >&2
    fi
}

if [[ "$REPLY_POSTED" == "true" ]]; then
    echo "Reply posted successfully."
else
    echo "Warning: Could not post reply. Will still attempt to resolve thread."
fi

# Resolve the thread unless --no-resolve is specified
if [[ "$NO_RESOLVE" != "--no-resolve" ]]; then
    echo "Resolving thread..."

    # Get thread ID by finding the thread that contains this comment (with pagination)
    # Use DATABASE_ID which we resolved earlier (handles both numeric and Node ID inputs)
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
            " -f owner="$OWNER" -f repo="$REPO_NAME" -F pr="$PR_NUMBER" 2>&1) || {
                echo "Warning: GraphQL query failed: $PAGE" >&2
                break
            }
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
            " -f owner="$OWNER" -f repo="$REPO_NAME" -F pr="$PR_NUMBER" -f cursor="$CURSOR" 2>&1) || {
                echo "Warning: GraphQL query failed: $PAGE" >&2
                break
            }
        fi
        THREAD_ID=$(echo "$PAGE" | jq -r ".data.repository.pullRequest.reviewThreads.nodes[] | select(.comments.nodes[0].databaseId == $DATABASE_ID) | .id" 2>/dev/null | head -1 || echo "")
        HAS_NEXT=$(echo "$PAGE" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false' 2>/dev/null || echo "false")
        CURSOR=$(echo "$PAGE" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // empty' 2>/dev/null || echo "")
    done

    if [[ -n "$THREAD_ID" && "$THREAD_ID" != "null" ]]; then
        RESOLVE_RESULT=$(gh api graphql -f query="
            mutation(\$threadId: ID!) {
                resolveReviewThread(input: {threadId: \$threadId}) {
                    thread {
                        isResolved
                    }
                }
            }
        " -f threadId="$THREAD_ID" 2>&1) && echo "Thread resolved." || {
            echo "Warning: Could not resolve thread." >&2
            echo "GraphQL response: $RESOLVE_RESULT" >&2
        }
    else
        echo "Warning: Could not find thread ID to resolve." >&2
        echo "This may happen if:" >&2
        echo "  - The comment is not part of a review thread (e.g., a PR comment)" >&2
        echo "  - The thread was already resolved" >&2
        echo "  - The comment ID $DATABASE_ID doesn't match any thread" >&2
    fi
fi
