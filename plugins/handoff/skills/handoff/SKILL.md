---
name: handoff
description: |
  Compact the current conversation into a handoff document so a fresh agent
  (new session, different machine, or a teammate's chat) can pick up the
  in-flight work without ramping from zero.

  Use when: (1) ending a long session with state that won't survive
  compaction or memory alone, (2) handing work to a teammate or a
  different agent (Claude Code → Codex, Claude → Cursor), (3) parking
  work for later when the to-resume context is too large to reconstruct
  from git history + beads alone.

argument-hint: "What will the next session focus on? (optional)"
---

# Handoff

Write a handoff document that captures the **live, transient state** of the current conversation so a fresh agent can resume without re-deriving it. Save the doc to a per-run path under the user's OS temp directory; output the path so the user can hand it to the next agent.

## Output location

```
$TMPDIR/claude-handoffs/<UTC-timestamp>-<short-topic-slug>.md
```

Falls back to `/tmp/claude-handoffs/` if `$TMPDIR` is unset. Create the directory if missing. The timestamp + slug means multiple handoffs from the same project don't collide and the user can `ls -lt` to find the most recent.

Print the absolute path to the user (the last line of your response). They will paste it into the next session's first message.

## What goes in the doc

Frontmatter:

```markdown
---
created: <ISO-8601 UTC>
source-cwd: <pwd>
source-branch: <git branch --show-current, if in a git repo>
next-focus: <user's argument, or "(unspecified)">
---
```

Then sections, IN THIS ORDER:

### 1. One-line summary

What is the next agent picking up? Single sentence. If the user passed an argument, this MUST reflect their intent for the next session, not a recap of the current one.

### 2. State of play

Three buckets, each with bullet points (omit empty buckets):

- **Done** — what's already shipped (merged PRs, closed tickets, applied edits with commit refs)
- **In flight** — what's mid-stream (open PRs by number+URL, branches with uncommitted work, background tasks still polling)
- **Blocked** — what's waiting on something the next agent or human needs to act on

For each in-flight item, name the **next concrete action**. ("Run gh pr merge 25" beats "Merge PR #25 when ready".)

### 3. Live state to capture (don't expect git/beads to have it)

This is the section that justifies the handoff existing at all. Include:

- **Background tasks**: any `Bash run_in_background` jobs you started, `CronCreate` schedules, `Monitor` streams, `ScheduleWakeup` timers. List the task ID, what it's waiting for, and where its output goes. The next agent won't have these references otherwise.
- **Decisions made + rationale**: any judgment calls you made that aren't visible from the diff/commit messages alone (e.g., "chose AskUserQuestion over plan-mode after probing ExitPlanMode behavior"). Cite WHY, not just what — the why is what gets lost on rehydration.
- **Won't-fix / reclassifications**: review findings you declined to fix with explicit reasoning. The next agent might re-encounter the same finding.
- **Open questions** you couldn't resolve and the user hasn't answered yet.

### 4. References (don't duplicate; point)

For each artifact the next agent should read:

- PR URLs: `gh pr view <N>` shows description + state
- Beads tickets: `bd show <id>` for in-progress / blocked work
- Commits: `git log <range>` for the recent history
- Memory files: `~/.claude/projects/<project-id>/memory/<file>.md` for cross-session context
- Skill or plugin paths: `~/.claude/plugins/cache/<...>/SKILL.md`
- External docs: full URLs (don't paraphrase what's at the link)

**Do NOT duplicate content already in any of these.** Quote a line only if the next agent absolutely needs that exact wording to make a decision.

### 5. Suggested skills for the next agent

Skills the next agent will likely want to invoke. Be specific to what's actually installed and relevant:

- If the user is in a git repo with open PRs → `pr-review-loop`
- If beads is initialized in the repo → `beads:beads`, `beads:ready`
- If pulling artifacts to/from cloud → relevant skill (gcp-oauth, etc.)
- The user can extend this list — include skills they've mentioned in this conversation

### 6. Resume command

Single line the user can paste into the next session as the opening message, e.g.:

```
Read the handoff at /tmp/claude-handoffs/2026-05-21T14-30Z-handoff-rebase-cto-review.md and continue from "In flight".
```

## Rules

### Reference, don't duplicate

If the information already lives in git, beads, or memory, **link to it; do not paraphrase**. The handoff is a bridge to those sources, not a replacement for them. A 50-line handoff that points at the right artifacts beats a 500-line one that retells the artifacts' contents.

### Redact sensitive material

Before saving, scan the doc for:

- API keys, OAuth tokens, session tokens (anything matching common prefixes: `sk-`, `gho_`, `ghp_`, `xoxb-`, `xoxp-`, etc.)
- Passwords, private keys, certificates
- Personally identifiable information unrelated to the work (real names, emails) IF the conversation surfaced any — replace with `<redacted>`
- Customer or company-internal identifiers if the next agent might be working in a public context

If anything sensitive can't be redacted without breaking continuity, NOTE it explicitly: `<redacted: contact user for value>`.

### Tailor to the user's argument

If the user passed `/handoff <focus>`, that's the **driver** for the doc. The "One-line summary" must match it; "State of play" should highlight what's relevant to that focus; "Suggested skills" should be picked for it. Don't dump the entire session if the user only wants to hand off one slice.

If the user passed no argument, write a general-purpose handoff covering whatever's in-flight.

### Keep it scannable

The receiving agent will read this cold. Use clear headers, short paragraphs, and concrete action verbs ("Run X", "Read Y", "Decide whether to Z"). Avoid narrative-style retrospectives ("I was in the middle of...") in favor of structured bullets.

## What NOT to include

- A blow-by-blow of the conversation history (the receiving agent doesn't need to retrace your steps)
- Full file contents that haven't changed (point at the file path instead)
- Internal monologue about why you tried something that didn't work (unless it informs what to do next)
- Praise/sentiment about the user or the work (irrelevant signal for the next agent)
- A "TL;DR" section — the One-line summary IS the TL;DR

## After saving

Output to the user:

1. The absolute file path of the handoff doc
2. A one-line confirmation of what was captured ("Wrote handoff for PR #25 dogfood + open beads ticket fv0 to ...")
3. The Resume command (section 6 above) so they can copy-paste it

Do NOT output the full handoff content in your message — the user can read the file. The conversation has already been long enough; your final message stays short.
