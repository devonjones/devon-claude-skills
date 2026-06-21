#!/usr/bin/env bash
# Dream — SessionStart hook: warn when this project has outstanding dreaming
# recommendations (proposals / reviewer roster) that have not been reviewed yet.
#
# Lives in the dream plugin so it is versioned with the skill. Symlink it into a
# project's .claude/hooks/ and register it as a SessionStart "command" hook.
#
# Self-contained: it derives the SAME per-project slug the dream tool uses
# (git-root basename — see dreamlib/config.project_slug) so it points at the same
# ~/.dream/<slug>/ home, with no dependency on the dream scripts being importable.
#
# Contract: always exits 0 and never errors out — a SessionStart hook must never
# block a session. Plain stdout is added to the session context, so the message
# is phrased for the assistant to relay to the user.
set -u

# stdin carries the SessionStart JSON payload; we don't need it. Drain it so the
# hook never blocks on a pipe.
cat >/dev/null 2>&1 || true

proj="${CLAUDE_PROJECT_DIR:-$PWD}"
root="$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null)" || exit 0
slug="$(basename "$root")"
home="${DREAM_HOME:-$HOME/.dream/$slug}"
[ -d "$home" ] || exit 0

# Outstanding = per-run proposal files sitting in review/pending/. The user
# dismisses a run by moving its file into review/reviewed/ (or deleting it), so
# this glob only needs the pending/ dir.
mapfile -t pending < <(ls -1 "$home"/review/pending/*.md 2>/dev/null)
n=${#pending[@]}
[ "$n" -eq 0 ] && exit 0

echo ""
echo "🔴🔴🔴 ════════════════════════════════════════════════════════ 🔴🔴🔴"
echo "   DREAM — ACTION NEEDED: ${n} UNREVIEWED RECOMMENDATION FILE(S)"
echo "🔴🔴🔴 ════════════════════════════════════════════════════════ 🔴🔴🔴"
echo "   In ${home}/review/pending/ :"
while IFS= read -r f; do
  [ -n "$f" ] && echo "      • $(basename "$f")"
done < <(ls -1t "${pending[@]}" 2>/dev/null | head -5)
[ "$n" -gt 5 ] && echo "      … and $((n - 5)) more"
echo "   Dismiss once actioned:  mv the file into ${home}/review/reviewed/"
echo "═══════════════════════════════════════════════════════════════════════"
echo ""
echo "ASSISTANT — MANDATORY, DO THIS FIRST: Before responding to anything else,"
echo "OPEN your reply with a prominent alert that dream recommendations are"
echo "awaiting review. Use a bold markdown heading (e.g. \"## 🔴 Dream:"
echo "recommendations awaiting your review\"), then list the pending file(s) and"
echo "the one-line dismiss instruction. This is a standing reminder the user"
echo "explicitly asked to be made noticeable — do NOT bury it as a casual 'by the"
echo "way' aside, a footnote, or a trailing sentence. It leads the message."
exit 0
