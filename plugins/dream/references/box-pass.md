# Box lesson pass

The standing instructions for the nightly `dream-nightly` run, which reads the
box file that `dream box` just wrote. Ares's pilot found that each repo already
saves its own memories well. The gap is lessons that recur across repos and
never spread between them, so most nights should file nothing.

## Bookkeeping

- Start with `bd dolt pull` in `~/Projects/devon-claude-skills`.
- Before filing a bead in a repo, run `bd dolt pull` there, and `bd dolt push`
  after.
- Log each delivery in `~/.dream/<repo-slug>/review/delivered.md` (date, lesson,
  owner tab, outcome). Check that file before sending, and never resend.

## Mine

Read the box file. In each digest, `user_turns` has the human's words with the
assistant text they answered (`after`). Dedup every lesson against the repo's
`memory_dirs`, its CLAUDE.md and AGENTS.md, `bd memories`, `~/.claude/CLAUDE.md`
and every `~/.claude/projects/*/memory`.

## Deliver

- A per-repo lesson becomes a bead in the owner repo (`-l dream`) and a message
  to the owner tab. A repo without beads gets the message only. When several
  tabs share one cwd, message each tab whose area the lesson concerns.
- Spreading a memory to the other repos it applies to is the main product.
- A lesson seen in 2+ repos goes to mission-control, prefixed `dream:`.
- A bug in the dream tooling becomes a bead under `devon-claude-skills-88b`, and
  the box's skills tab hears about it.
- A pattern seen only once: watch it, don't send it.
- Finish with a short report to mission-control: repos read, beads filed,
  messages sent.

Never edit other repos, open PRs, print secrets, or quote vault or paid text.
