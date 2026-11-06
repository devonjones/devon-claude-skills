# Box lesson pass

The standing instructions for the nightly `dream-nightly` run, which reads the
box file that `dream box` just wrote, from the skills repo (`DREAM_REPO`, the
run's working directory). Per-repo memory capture already works; the gap is
lessons that recur across repos and never spread, so most nights file nothing.

## Bookkeeping

- Start with `bd dolt pull` in the skills repo.
- Before filing a bead in a repo, run `bd dolt pull` there, and `bd dolt push`
  after.
- Log each delivery in `~/.dream/<repo-slug>/review/delivered.md` (date, lesson,
  owner tab, outcome). Check that file before sending, and never resend.

## Mine

Read the box file. In each digest, `user_turns` has the human's words with the
assistant text they answered (`after`). A digest holds the whole session, so
read only turns whose `ts` falls inside the run's `--days` window. Skip relayed
peer text (lines that start like `[from X]`, `[A MC -> B MC]` or
`cryo-backend:`), which the human pasted but did not write.

Dedup every lesson against the repo's `memory_dirs`, its CLAUDE.md, AGENTS.md
and `docs/` (and sibling repos' `docs/`), `bd memories`, `~/.claude/CLAUDE.md`
and every `~/.claude/projects/*/memory`. Those dirs start with `-`, so grep
`./*/memory/`: a bare `*/memory/` is read as grep options and matches nothing.

## Deliver

- If `~/.dream/routing.md` exists, its routes win (for example, a repo group
  that reports to one coordinator tab).
- A per-repo lesson becomes a bead in the owner repo (`-l dream`) and a message
  to the owner tab. A repo without beads gets the message only. When several
  tabs share one cwd, message each tab whose area the lesson concerns.
- A lesson seen in 2+ repos goes to mission-control, prefixed `dream:`.
- A bug in the dream tooling becomes a `-l dream` bead in the skills repo, and
  the box's skills tab hears about it.
- A pattern seen only once: watch it, don't send it.
- Finish with a short report to mission-control: repos read, beads filed,
  messages sent.

Send every message with `SendMessage`, addressing tabs by the names `ListAgents`
shows. If a tab is not listed, don't retry: log the lesson in `delivered.md` as
undelivered and name it in the mission-control report.

Never edit other repos, open PRs, print secrets, or quote vault or paid text.
