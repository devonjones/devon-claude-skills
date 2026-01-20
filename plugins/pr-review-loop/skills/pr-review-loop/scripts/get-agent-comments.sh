#!/bin/bash
# Get review comments posted by a specific agent reviewer
# Usage: get-agent-comments.sh <pr-number> <agent-name> [--with-replies]
#
# Filters comments by agent signature: <!-- Agent: <agent-name> -->
# With --with-replies, also shows any replies to the agent's comments.

set -euo pipefail

PR_NUMBER="${1:?Usage: get-agent-comments.sh <pr-number> <agent-name> [--with-replies]}"
AGENT_NAME="${2:?Usage: get-agent-comments.sh <pr-number> <agent-name> [--with-replies]}"
shift 2

WITH_REPLIES=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-replies)
            WITH_REPLIES=true
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

AGENT_SIGNATURE="<!-- Agent: ${AGENT_NAME} -->"

echo "Fetching comments from agent '${AGENT_NAME}' on PR #${PR_NUMBER}..."
echo ""

# Use GraphQL to get all review threads with their comments
QUERY='
query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          comments(first: 20) {
            nodes {
              id
              databaseId
              author {
                login
              }
              body
              path
              line
              originalLine
              createdAt
            }
          }
        }
      }
    }
  }
}
'

RESULT=$(gh api graphql -f query="$QUERY" -f owner="$OWNER" -f repo="$REPO_NAME" -F pr="$PR_NUMBER" 2>/dev/null)

if [[ -z "$RESULT" ]]; then
    echo "No review comments found."
    exit 0
fi

# Process results - find threads started by this agent and optionally include replies
echo "$RESULT" | jq -r --arg signature "$AGENT_SIGNATURE" --argjson withReplies "$WITH_REPLIES" '
    .data.repository.pullRequest.reviewThreads.nodes[] |
    # Check if first comment has our agent signature
    select(.comments.nodes[0].body | contains($signature)) |
    . as $thread |
    "=== Thread (ID: \(.comments.nodes[0].databaseId)) ===",
    "Status: \(if .isResolved then "RESOLVED" else "UNRESOLVED" end)",
    "File: \(.comments.nodes[0].path):\(.comments.nodes[0].line // .comments.nodes[0].originalLine // "?")",
    "",
    "ORIGINAL COMMENT:",
    (.comments.nodes[0].body | gsub($signature; "") | gsub("^\n+"; "")),
    "",
    if $withReplies and (.comments.nodes | length) > 1 then
        "REPLIES:",
        (.comments.nodes[1:] | map(
            "  [\(.author.login // "unknown")] \(.body)"
        ) | join("\n\n")),
        ""
    else
        ""
    end,
    "---",
    ""
'

# Count stats
TOTAL=$(echo "$RESULT" | jq --arg signature "$AGENT_SIGNATURE" '
    [.data.repository.pullRequest.reviewThreads.nodes[] |
     select(.comments.nodes[0].body | contains($signature))] | length
')

UNRESOLVED=$(echo "$RESULT" | jq --arg signature "$AGENT_SIGNATURE" '
    [.data.repository.pullRequest.reviewThreads.nodes[] |
     select(.comments.nodes[0].body | contains($signature)) |
     select(.isResolved == false)] | length
')

echo ""
echo "Summary: ${TOTAL} total comments from '${AGENT_NAME}', ${UNRESOLVED} unresolved"
