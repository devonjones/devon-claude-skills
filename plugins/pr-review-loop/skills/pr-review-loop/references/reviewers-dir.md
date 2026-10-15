# Converting a repo to `.reviewers/`

**Contents:** 1. Snapshot the roster · 2. Convert · 3. Choose starters · 4. Assess every reviewer · 5. Verify · 6. Commit

You are moving a repo's reviewers from `AGENT-REVIEWERS.md` to the default
layout, where each reviewer is its own file. `SKILL.md` ("Reviewer Files")
has the format.

**Conversion moves text; it does not edit it.** The script keeps every
reviewer's name, spec text, model and verification line. Rewording a reviewer
is a separate change. The assessment in step 4 tells you what to change, and
you file it, you don't apply it here.

## 1. Snapshot the roster

On a clean tree, from the repo root:

```bash
PR_REVIEW_LOOP_TEST_CHANGED_FILES="$(git ls-files)" scripts/discover-agents.sh 0 > /tmp/reviewers-before.json
```

Listing every tracked file as changed puts every reviewer in scope, so the
snapshot holds the whole roster.

## 2. Convert

```bash
scripts/convert-reviewers.py repo           # dry run: prints the plan
scripts/convert-reviewers.py repo --write
```

For every `AGENT-REVIEWERS.md`, it writes `.reviewers/<name>.md` beside that
file for each `## <name>` under `# Agents`:

- **The header** is the file's first 12 lines: `# <name>`, then the `model:`
  and `verification:` lines moved up from the body, then `**Checks:**`,
  `**Spawn when:**` and a generated `**Contents:**`. The orchestrator chooses
  reviewers from these lines alone.
- **Checks and Spawn when** come from the index text when there was any
  (`**What it checks:**`, `**When to spawn:**`). Otherwise they are `TODO`,
  which step 4 fills in.
- **An existing `.reviewers/<name>.md`** keeps its text as the body, and its
  index entry becomes the header.

It also moves files around:

- **Prose under `# Agents`** goes to `.reviewers/README.md`, including H2s that
  aren't reviewers, like `## Retired reviewers`. So do other H1s
  (`# Guidelines`, `# Context`). README.md is context for the orchestrator.
- **`# Configuration`** becomes `.reviewers/config.json`, minus `disabled` and
  `defaults_version_checked`.
- **Every `AGENT-REVIEWERS.md`** is deleted.

Read the plan's `note` lines before running `--write`. One matters most: a
`.reviewers/*.md` file that no index entry named never ran before, and **runs
after conversion**. Ask the user whether it should run, or delete it.

Read each new file's header and the line under it before staging. Step 4's
diff can't show a cut-short Checks or Spawn when line, because it compares
against this conversion.

Then stage the conversion without committing, by path rather than `git add -A`
(SKILL.md ⛔ rule 2): `git add -- ':(glob)**/.reviewers/**' ':(glob)**/AGENT-REVIEWERS.md'`.
Step 4 diffs against it to see exactly what the assessment changed.

## 3. Choose starters

The plan's `starters:` line names the defaults that ran on this repo. Ask the
user which to keep, then:

```bash
scripts/convert-reviewers.py starters               # list them, with what each checks
scripts/convert-reviewers.py starters --into . code-reviewer pr-test-analyzer
```

Keep a starter's name unchanged. Its eval history, dream scorecard and any
`.pi.agents` entry are keyed on that name.

## 4. Assess every reviewer

Spawn one fresh subagent per roster, or one per few reviewers if the roster is
large. Have it read [`assessing-a-reviewer.md`](assessing-a-reviewer.md) in full
and then assess each converted reviewer against it. Tell it to:

- replace every `TODO` in a `**Checks:**` or `**Spawn when:**` line with one
  line derived from that reviewer's own spec. Spawn when must be decidable from
  a diff alone. Edit no other line.
- write its full report to a file, and return a short verdict per reviewer
  plus the most important problems.

Use a fresh agent, not your own context. Afterwards, confirm only header
lines changed since you staged:

```bash
git diff -U0 | grep '^[-+][^-+]' | grep -vE '^[-+]\*\*(Checks|Spawn when):\*\*'   # expect nothing
```

Hand the report to the user, and file its findings as tickets.

## 5. Verify

```bash
PR_REVIEW_LOOP_TEST_CHANGED_FILES="$(git ls-files; find . -path '*/.reviewers/*' -type f)" \
  scripts/discover-agents.sh 0 > /tmp/reviewers-after.json 2> /tmp/reviewers-after.err
cat /tmp/reviewers-after.err                                        # expect nothing
jq -r .configuration.layout /tmp/reviewers-after.json               # expect: reviewers
diff <(jq -r '.agents[] | select(.kind != "default") | "\(.name) \(.model)"' /tmp/reviewers-before.json | sort) \
     <(jq -r '.agents[] | "\(.name) \(.model)"' /tmp/reviewers-after.json | sort)
```

The diff should show only the prose H2s the plan moved to README.md, the
starters you chose, and any previously unindexed files you kept. Anything else
means a reviewer was lost or renamed.

## 6. Commit

Commit the `.reviewers/` directories, the deleted indexes and the filled
headers together, in one commit. `discover-agents.sh` reads the working tree,
so a half-converted tree is what the next review round would run. Open PRs keep
the old layout until they rebase.
