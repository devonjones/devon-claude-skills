#!/usr/bin/env bash
# Is an external review bot enabled for this repo?
#
# Reads the `bots` map from the # Configuration block of the root
# AGENT-REVIEWERS.md. Bots default to ENABLED; only an explicit `false`
# turns one off:
#
#   { "bots": { "gemini": false } }
#
# Usage: bot-enabled.sh <gemini|cursor>
# Exit: 0 = enabled (also when there's no repo/config to read), 1 = disabled

set -euo pipefail

BOT="${1:?Usage: bot-enabled.sh <bot-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
CONFIG="$REPO_ROOT/AGENT-REVIEWERS.md"
[[ -f "$CONFIG" ]] || exit 0

CONFIG_JSON="$("$SCRIPT_DIR/_parse_configuration.sh" "$CONFIG" 2>/dev/null)" || exit 0
# `// true` would swallow an explicit `false` (jq treats false as falsy), so
# test key presence instead.
ENABLED="$(jq -r --arg b "$BOT" '
    (.bots // {}) as $bots
    | if ($bots | type) == "object" and ($bots | has($b)) then $bots[$b] else true end
' <<<"$CONFIG_JSON" 2>/dev/null || echo true)"

if [[ "$ENABLED" == "false" ]]; then
    exit 1
fi
exit 0
