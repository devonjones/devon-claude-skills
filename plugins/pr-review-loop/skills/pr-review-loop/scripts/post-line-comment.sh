#!/bin/bash
# Post a line comment on a PR with agent signature
# Usage: post-line-comment.sh <pr-number> <file-path> <line-number> <agent-name> "comment"
#
# Posts a review comment on a specific line of the PR diff.
# Automatically adds an agent signature: <!-- Agent: <agent-name> -->

set -euo pipefail

PR_NUMBER="${1:?Usage: post-line-comment.sh <pr-number> <file-path> <line-number> <agent-name> \"comment\"}"
FILE_PATH="${2:?Usage: post-line-comment.sh <pr-number> <file-path> <line-number> <agent-name> \"comment\"}"
LINE_NUMBER="${3:?Usage: post-line-comment.sh <pr-number> <file-path> <line-number> <agent-name> \"comment\"}"
AGENT_NAME="${4:?Usage: post-line-comment.sh <pr-number> <file-path> <line-number> <agent-name> \"comment\"}"
COMMENT="${5:?Usage: post-line-comment.sh <pr-number> <file-path> <line-number> <agent-name> \"comment\"}"

# Get repo info
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')

# Get the latest commit SHA on the PR
COMMIT_SHA=$(gh pr view "$PR_NUMBER" --json commits --jq '.commits[-1].oid')

if [[ -z "$COMMIT_SHA" ]]; then
    echo "Error: Could not get latest commit SHA for PR #$PR_NUMBER"
    exit 1
fi

# Add agent signature to comment
SIGNED_COMMENT="<!-- Agent: ${AGENT_NAME} -->
${COMMENT}"

echo "Posting comment from agent '${AGENT_NAME}' on ${FILE_PATH}:${LINE_NUMBER}..."

# Post the review comment using REST API
RESULT=$(gh api \
    --method POST \
    "repos/${REPO}/pulls/${PR_NUMBER}/comments" \
    -f body="$SIGNED_COMMENT" \
    -f commit_id="$COMMIT_SHA" \
    -f path="$FILE_PATH" \
    -F line="$LINE_NUMBER" \
    -f side="RIGHT" 2>&1) || {
    echo "Error posting comment: $RESULT"

    # Try with subject_type for newer API
    RESULT=$(gh api \
        --method POST \
        "repos/${REPO}/pulls/${PR_NUMBER}/comments" \
        -f body="$SIGNED_COMMENT" \
        -f commit_id="$COMMIT_SHA" \
        -f path="$FILE_PATH" \
        -F line="$LINE_NUMBER" \
        -f subject_type="line" 2>&1) || {
        echo "Error: Failed to post comment"
        echo "$RESULT"
        exit 1
    }
}

COMMENT_ID=$(echo "$RESULT" | jq -r '.id // empty')
if [[ -n "$COMMENT_ID" ]]; then
    echo "Comment posted successfully (ID: $COMMENT_ID)"
else
    echo "Comment posted (could not extract ID from response)"
fi
