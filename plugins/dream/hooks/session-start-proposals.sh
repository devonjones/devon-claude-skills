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

# Outstanding = top-level proposal files not yet archived. The globs are
# non-recursive, so anything moved into a reviewed/ subdir stops counting.
mapfile -t pending < <(
  {
    ls -1 "$home"/review/PROPOSALS-*.md 2>/dev/null
    ls -1 "$home"/reviews/ROSTER-PROPOSALS.md "$home"/reviews/*PROPOSALS*.md 2>/dev/null
  } | sort -u
)
n=${#pending[@]}
[ "$n" -eq 0 ] && exit 0

echo "⚠️  Dream: ${n} outstanding recommendation file(s) await your review in ${home}/:"
while IFS= read -r f; do
  [ -n "$f" ] && echo "    • ${f}"
done < <(ls -1t "${pending[@]}" 2>/dev/null | head -3)
[ "$n" -gt 3 ] && echo "    … and $((n - 3)) more"
echo "    Dismiss reviewed items by moving them into a reviewed/ subfolder"
echo "    (mkdir -p \"${home}/review/reviewed\" && mv <file> there) or deleting them."
echo "(Assistant: surface this to the user now, at the start of the session.)"
exit 0
