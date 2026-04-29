#!/bin/bash
# Check CI status for a PR, waiting for checks to complete
# Usage: check-ci.sh <pr-number> [--wait] [--timeout SECONDS]
#
# Checks all CI/CD checks on a PR. With --wait, polls until all checks complete.
# On failure, fetches and displays failure logs for diagnosis.
#
# Options:
#   --wait             Poll until all checks complete (default: just check current state)
#   --timeout SECONDS  Max wait time (default: 600 = 10 minutes)
#
# Exit codes:
#   0 - All checks passed (or no checks found)
#   1 - One or more checks failed (failure details on stdout)
#   2 - Timeout waiting for checks to complete

set -euo pipefail

PR_NUMBER="${1:?Usage: check-ci.sh <pr-number> [--wait] [--timeout SECONDS]}"
shift || true

WAIT_MODE=false
TIMEOUT=600
POLL_INTERVAL=20

# Grace window before concluding "no CI configured" via the check-suites API.
# GitHub Actions and most third-party CI providers register a check-suite for
# the HEAD commit within seconds of a push; if zero suites exist after this
# window, no CI is configured for this commit and there's nothing to wait for.
NO_CI_GRACE_S=20

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --wait)
            WAIT_MODE=true
            shift
            ;;
        --timeout)
            TIMEOUT="${2:?--timeout requires a value}"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Derive repo slug from origin so -R works on forks with both origin and upstream remotes
REPO=$(git remote get-url origin 2>/dev/null | sed 's/.*github\.com[:\/]//' | sed 's/\.git$//') || REPO=""
REPO_FLAG=""
if [[ -n "$REPO" ]]; then
    REPO_FLAG="-R $REPO"
fi

# Function to get check status summary
# Returns: "pending", "passing", or "failing"
get_check_status() {
    local checks_json
    checks_json=$(gh pr checks "$PR_NUMBER" $REPO_FLAG --json name,state,bucket 2>/dev/null) || {
        echo "no_checks"
        return
    }

    local total pending fail pass
    total=$(echo "$checks_json" | jq 'length')

    if [[ "$total" -eq 0 ]]; then
        echo "no_checks"
        return
    fi

    pending=$(echo "$checks_json" | jq '[.[] | select(.state == "PENDING" or .state == "QUEUED" or .state == "IN_PROGRESS" or .state == "WAITING" or .state == "REQUESTED" or .state == "ACTION_REQUIRED")] | length')
    fail=$(echo "$checks_json" | jq '[.[] | select(.state == "FAILURE" or .state == "ERROR" or .state == "TIMED_OUT" or .state == "CANCELLED" or .state == "STARTUP_FAILURE")] | length')
    pass=$(echo "$checks_json" | jq '[.[] | select(.state == "SUCCESS" or .state == "NEUTRAL" or .state == "SKIPPED")] | length')

    if [[ "$pending" -gt 0 ]]; then
        echo "pending:$pending/$total"
    elif [[ "$fail" -gt 0 ]]; then
        echo "failing:$fail/$total"
    else
        echo "passing:$pass/$total"
    fi
}

# Function to get details of failed checks
get_failure_details() {
    local checks_json
    checks_json=$(gh pr checks "$PR_NUMBER" $REPO_FLAG --json name,state,link,bucket 2>/dev/null) || return

    local failed_checks
    failed_checks=$(echo "$checks_json" | jq -r '.[] | select(.state == "FAILURE" or .state == "ERROR" or .state == "TIMED_OUT" or .state == "CANCELLED" or .state == "STARTUP_FAILURE") | "\(.name)\t\(.state)\t\(.link)"')

    if [[ -z "$failed_checks" ]]; then
        return
    fi

    echo "=== FAILED CI CHECKS ==="
    echo ""

    # Track run IDs we've already fetched logs for — multiple failed checks
    # can belong to the same workflow run (parallel jobs), and --log-failed
    # returns logs for the whole run, so we'd otherwise print them N times.
    local seen_runs="|"

    while IFS=$'\t' read -r name state link; do
        echo "--- $name ($state) ---"
        echo "Link: $link"

        # Try to extract run ID from the link and get failure logs
        # (use sed, not grep -oP, for portability — -P is not in BSD grep on macOS)
        local run_id
        run_id=$(echo "$link" | sed -n 's|.*runs/\([0-9][0-9]*\).*|\1|p')

        if [[ -n "$run_id" ]]; then
            if [[ "$seen_runs" == *"|$run_id|"* ]]; then
                echo "(logs for run $run_id already printed above)"
            else
                echo ""
                echo "Failure logs (last 80 lines):"
                echo ""
                # Get failed job logs - limit output to avoid overwhelming
                gh run view "$run_id" $REPO_FLAG --log-failed 2>/dev/null | tail -80 || echo "(Could not fetch logs)"
                seen_runs="${seen_runs}${run_id}|"
            fi
        fi
        echo ""
    done <<< "$failed_checks"
}

# Single check (no wait)
if [[ "$WAIT_MODE" == "false" ]]; then
    status=$(get_check_status)
    case "$status" in
        no_checks)
            echo "No CI checks found on PR #$PR_NUMBER"
            exit 0
            ;;
        passing:*)
            echo "✓ All CI checks passed (${status#passing:})"
            exit 0
            ;;
        pending:*)
            echo "⏳ CI checks still running (${status#pending:} pending)"
            echo "Use --wait to poll until completion"
            exit 0
            ;;
        failing:*)
            echo "✗ CI checks failed (${status#failing:} failed)"
            echo ""
            get_failure_details
            exit 1
            ;;
    esac
fi

# Wait mode - poll until all checks complete
echo "Waiting for CI checks on PR #$PR_NUMBER..."
echo "Polling every ${POLL_INTERVAL}s, timeout ${TIMEOUT}s"
echo ""

ELAPSED=0

# Resolve the PR HEAD SHA once so we can probe the check-suites API for the
# specific commit being checked. Without it we fall back to plain polling.
HEAD_SHA=$(gh pr view "$PR_NUMBER" $REPO_FLAG --json headRefOid --jq .headRefOid 2>/dev/null) || HEAD_SHA=""

# Brief initial wait - CI takes a moment to register new checks after push
sleep 5
ELAPSED=5

while [[ $ELAPSED -lt $TIMEOUT ]]; do
    status=$(get_check_status)

    case "$status" in
        no_checks)
            # If no check-runs have appeared after the grace window, look at
            # the check-suites API directly. A "real" CI suite has either
            # produced check-runs already or moved past `queued` into
            # `in_progress` / `completed`. Suites that stay queued with zero
            # runs are idle integrations (e.g. Codecov on a no-coverage push,
            # Renovate on a non-dependency change) that will never report
            # back. If every suite is in that state after the grace window,
            # there's nothing to wait for.
            if [[ $ELAPSED -ge $NO_CI_GRACE_S && -n "$HEAD_SHA" && -n "$REPO" ]]; then
                # A real CI suite either has produced check-runs already
                # (latest_check_runs_count > 0) or is actively progressing
                # (status == in_progress). Suites that stay queued without
                # runs, or that complete fast with zero runs (e.g. Renovate
                # finding nothing to update), are idle integrations — there's
                # nothing to wait on.
                #
                # On transient API failures, default to 1 (keep waiting) and
                # warn — false-exiting on a network blip would let a real
                # failing CI go unnoticed, which is worse than waiting.
                active_suites=$(gh api "repos/${REPO}/commits/${HEAD_SHA}/check-suites" --jq '
                    [.check_suites[]?
                     | select(.latest_check_runs_count > 0
                              or .status == "in_progress")
                    ] | length
                ' 2>/dev/null) || {
                    echo "warning: check-suites API call failed; assuming CI is active and continuing to poll" >&2
                    active_suites=1
                }
                if [[ "$active_suites" -eq 0 ]]; then
                    echo "No active CI for commit ${HEAD_SHA:0:7} (no check-suites running after ${ELAPSED}s) — exiting"
                    exit 0
                fi
            fi
            echo "No CI checks found yet (${ELAPSED}s elapsed)"
            ;;
        passing:*)
            echo "✓ All CI checks passed (${status#passing:})"
            exit 0
            ;;
        pending:*)
            echo "⏳ Checks running (${status#pending:} pending, ${ELAPSED}s elapsed)"
            ;;
        failing:*)
            # get_check_status only returns failing:* when no checks are pending,
            # so we can report and exit immediately.
            echo "✗ CI checks failed (${status#failing:} failed)"
            echo ""
            get_failure_details
            exit 1
            ;;
    esac

    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

# Timeout - report final state
echo ""
echo "⏰ Timeout after ${TIMEOUT}s"
echo ""
status=$(get_check_status)
case "$status" in
    failing:*)
        echo "✗ CI checks failed"
        echo ""
        get_failure_details
        exit 1
        ;;
    pending:*)
        echo "⏳ Checks still running after timeout"
        exit 2
        ;;
    *)
        echo "Final status: $status"
        exit 0
        ;;
esac
