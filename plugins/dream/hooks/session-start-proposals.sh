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

echo "⚠️  Dream: ${n} unreviewed recommendation file(s) in ${home}/review/pending/:"
while IFS= read -r f; do
  [ -n "$f" ] && echo "    • ${f}"
done < <(ls -1t "${pending[@]}" 2>/dev/null | head -3)
[ "$n" -gt 3 ] && echo "    … and $((n - 3)) more"
echo "    Dismiss a run once actioned by archiving it:"
echo "    mkdir -p \"${home}/review/reviewed\" && mv \"${home}/review/pending/\"<file> \"${home}/review/reviewed/\""
echo "(Assistant: surface this to the user now, at the start of the session.)"
exit 0
