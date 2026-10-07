#!/bin/bash
# Commit staged changes and push to trigger next review cycle
# Usage: commit-and-push.sh "commit message"
#
# This script is designed to be granted explicit permission for autonomous
# PR review loops. It commits and pushes, then optionally triggers a new review.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MESSAGE="${1:?Usage: commit-and-push.sh \"commit message\" [--trigger-review]}"
TRIGGER_REVIEW=false

# Check for --trigger-review flag
for arg in "$@"; do
    if [[ "$arg" == "--trigger-review" ]]; then
        TRIGGER_REVIEW=true
    fi
done

# Run pre-commit if available AND if repo has pre-commit config
if command -v pre-commit &>/dev/null && [[ -f ".pre-commit-config.yaml" ]]; then
    echo "Running pre-commit hooks..."
    if ! pre-commit run --all-files; then
        # Pre-commit may have auto-fixed files - stage them and try again
        git add -A
        if ! pre-commit run --all-files; then
            echo "Pre-commit failed. Please fix issues and try again." >&2
            exit 1
        fi
    fi
elif [[ -f ".pre-commit-config.yaml" ]]; then
    echo "Note: .pre-commit-config.yaml exists but pre-commit is not installed." >&2
    echo "Consider running: pip install pre-commit && pre-commit install" >&2
fi
# Skip pre-commit silently if neither pre-commit nor config exists

# Stage all changes
git add -A

# Check if there are changes to commit.
#
# "Nothing to commit" is not "nothing to do": the branch may still be missing
# from the remote, because a previous run committed and then failed to push.
# Exiting 0 here without looking at the remote is how a branch stays local
# while two runs in a row report success.
if git diff --cached --quiet; then
    if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
        echo "No changes to commit."
        exit 0
    fi
    echo "No changes to commit, but this branch has no upstream - pushing it." >&2
    NOTHING_TO_COMMIT=true
else
    NOTHING_TO_COMMIT=false
fi

# Commit with standard footer
git commit -m "$(cat <<EOF
$MESSAGE

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"

# Push. `-u origin HEAD` rather than a bare `git push`, which fails outright
# under push.default=simple when the branch has no upstream.
echo "Pushing to origin..."
git push -u origin HEAD || {
    echo "Error: push failed. The commit is local only; the branch is NOT on the remote." >&2
    echo "Re-run this script - it will detect the missing upstream and retry the push." >&2
    exit 1
}

if [[ "$NOTHING_TO_COMMIT" == "true" ]]; then
    echo "Pushed existing commits; nothing new to commit."
fi

# Optionally trigger new review. Only exit 1 from bot-enabled.sh means the user
# turned Gemini off; exit 2 means its config couldn't be read (already warned),
# which must not be silently reported as a deliberate opt-out.
if [[ "$TRIGGER_REVIEW" == "true" ]]; then
    GEMINI_RC=0
    "$SCRIPT_DIR/bot-enabled.sh" gemini || GEMINI_RC=$?
    if [[ "$GEMINI_RC" -eq 1 ]]; then
        echo "Gemini is disabled for this repo (# Configuration .bots.gemini = false). Not triggering."
    else
        # Get repo info via gh's own detection (handles non-default remote names + forks).
        REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || { echo "Warning: Could not determine repository." >&2; })
        # Get PR number from current branch
        PR_NUMBER=$(gh pr view -R "$REPO" --json number --jq '.number' 2>/dev/null || echo "")
        if [[ -n "$PR_NUMBER" ]]; then
            echo "Triggering Gemini review on PR #$PR_NUMBER..."
            gh pr comment "$PR_NUMBER" -R "$REPO" --body "/gemini review"
        else
            echo "Warning: Could not determine PR number to trigger review"
        fi
    fi
fi

echo "Done."
