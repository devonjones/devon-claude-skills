#!/usr/bin/env bash
# Is an external review bot enabled for this repo?
#
# Reads the `bots` map from the # Configuration block of the root
# AGENT-REVIEWERS.md. Cursor defaults to ENABLED; only an explicit `false`
# turns it off. Gemini defaults to DISABLED; only an explicit `true` turns it on:
#
#   { "bots": { "gemini": true, "cursor": false } }
#
# Usage: bot-enabled.sh <gemini|cursor>
# Exit:
#   0 — enabled (explicitly true, or no entry and the bot defaults on)
#   1 — disabled (explicitly false, or no entry and the bot defaults off)
#   2 — could not determine; a warning naming the reason goes to stderr
#
# Callers must treat 2 as "enabled" (a config we can't read must never
# silently switch a bot off) but must NOT report it as a config decision, so
# they compare the return code against 1 rather than testing for success:
# inline in trigger-review.sh, via a `bot_disabled`
# helper in get-review-comments.sh (which asks twice). Exit 2 is deliberately
# distinct from 0 so "your config is broken" can't masquerade as "you turned
# this off", which is exactly the failure a silent `|| exit 0` would hide.

set -euo pipefail

BOT="${1:?Usage: bot-enabled.sh <bot-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Exit code when the config has no entry for this bot.
DEFAULT_RC=0
[[ "$BOT" == "gemini" ]] && DEFAULT_RC=1

if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    echo "Warning: bot-enabled.sh: not inside a git repository — cannot read # Configuration .bots.$BOT" >&2
    exit 2
fi

CONFIG="$REPO_ROOT/AGENT-REVIEWERS.md"
[[ -f "$REPO_ROOT/.reviewers/config.json" ]] && CONFIG="$REPO_ROOT/.reviewers/config.json"
# No config file is not an error: the bot's default applies, not exit 2.
[[ -f "$CONFIG" ]] || exit "$DEFAULT_RC"

# --bots-only fails only on what makes the bot answer untrustworthy, so an
# unrelated broken entry elsewhere in # Configuration — or another bot's typo'd
# value — can't discard a readable `bots.<name>: false` and quietly switch this
# bot back on. It still warns about anything that bears on the answer (a
# misspelled `bots` key, unknown bot names, dropped entries). Its stderr is NOT
# swallowed — those warnings are the only signal the user gets that their off
# switch didn't take.
if ! CONFIG_JSON="$("$SCRIPT_DIR/_parse_configuration.sh" "$CONFIG" --bots-only "$BOT")"; then
    echo "Warning: bot-enabled.sh: could not read the .bots block in $CONFIG (see above) — treating $BOT as enabled" >&2
    exit 2
fi

# `.bots[$b] // true` would swallow an explicit `false` (jq treats false as
# falsy), so read the raw value: true, false, or null for no entry.
if ! ENABLED="$(jq -r --arg b "$BOT" '.bots[$b]' <<<"$CONFIG_JSON" 2>&1)"; then
    echo "Warning: bot-enabled.sh: could not read .bots.$BOT ($ENABLED) — treating $BOT as enabled" >&2
    exit 2
fi

case "$ENABLED" in
    true) exit 0 ;;
    false) exit 1 ;;
    *) exit "$DEFAULT_RC" ;;
esac
