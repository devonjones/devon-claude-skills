# Converting a repo to `.reviewers/`

**Contents:** 1. Snapshot the roster · 2. Convert · 3. Choose starters · 4. Assess every reviewer · 5. Verify · 6. Commit

You are moving a repo's reviewers from `AGENT-REVIEWERS.md` to the default
layout, where each reviewer is its own file. `SKILL.md` ("Reviewer Files")
has the format. This file is the procedure: convert, choose starters, assess,
verify, commit.

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
python3 scripts/convert-reviewers.py repo           # dry run: prints the plan
python3 scripts/convert-reviewers.py repo --write
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
- **`# Configuration`** becomes `.reviewers/config.json`. `disabled` and
  `defaults_version_checked` are dropped, because nothing runs in the new
  layout unless its file is there.
- **Every `AGENT-REVIEWERS.md`** is deleted.

Read the plan's `note` lines before running `--write`. One matters most: a
`.reviewers/*.md` file that no index entry named never ran before, and **runs
after conversion**. Ask the user whether it should run, or delete it.

Then stage the result (`git add -A`) without committing. Step 4 diffs against
it to see exactly what the assessment changed.

## 3. Choose starters

In the old layout, the shipped defaults (`code-reviewer`, `pr-test-analyzer`,
…) ran on every repo unless `disabled`. In the new layout nothing runs unless
its file is in `.reviewers/`. The plan's `starters:` line names the defaults
that were running on this repo. Ask the user which to keep, then:

```bash
python3 scripts/convert-reviewers.py starters               # list them, with what each checks
python3 scripts/convert-reviewers.py starters --into . code-reviewer pr-test-analyzer
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

Use a fresh agent, not your own context: it judges the files as the
orchestrator and the reviewers will see them, without your memory of the old
layout. Afterwards, confirm only header lines changed since you staged:

```bash
git diff -U0 | grep '^[-+][^-+]' | grep -vE '^[-+]\*\*(Checks|Spawn when):\*\*'   # expect nothing
```

Hand the report to the user. File its findings as
tickets; don't apply them in this change.

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
the old layout until they rebase. Both layouts work, so nothing breaks in the
meantime.
