#!/usr/bin/env bash
# Forward-harvest of reviewer findings for one project — run by cron.
#
# Usage: harvest-cron.sh <project-dir>
#
# Captures durable reviewer findings (log <task-notification><result> blocks)
# plus /tmp subagent transcripts while they exist. /tmp is cleared ON REBOOT, so
# this is best-effort opportunistic capture; the durable, authoritative source
# going forward is the dream-marker stream (.dream/markers/). Idempotent (dedup
# by task-id), so running daily is safe and cheap.
set -euo pipefail

PROJECT="${1:?usage: harvest-cron.sh <project-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT"
# dream_home lives outside the repo at ~/.dream/<slug>; log alongside it.
STATE="$HOME/.dream/$(basename "$PROJECT")"
mkdir -p "$STATE"
{
  echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) harvest run ($PROJECT) ==="
  "$HERE/dream" reviews-harvest 2>&1
} >> "$STATE/harvest-cron.log" 2>&1
