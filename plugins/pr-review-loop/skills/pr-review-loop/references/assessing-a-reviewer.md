# Assessing a pr-review-loop Reviewer

Hand this file to a Claude together with one reviewer definition, or a whole
`.reviewers/` directory (or legacy `AGENT-REVIEWERS.md`). It assesses each reviewer against Anthropic's
[Skill authoring best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices)
and against the pr-review-loop reviewer contract, and returns a report in the
format at the end. For a whole skill, use
[assessing-a-skill.md](../../../../../docs/assessing-a-skill.md).

You are assessing, not editing. Do not change the definition or the working tree.

## What a reviewer is

A reviewer is a prompt that pr-review-loop spawns once per round to review a
PR's changed files, record findings, and return a manifest. It comes in three
forms:

| Form | Where | Model comes from |
|---|---|---|
| Reviewer file | `.reviewers/<name>.md`: a 12-line header (`# <name>`, `model:`, `verification:`, `**Checks:**`, `**Spawn when:**`, `**Contents:**`), then the spec | the header's `model:` line |
| Starter | `plugins/pr-review-loop/agents/<name>.md`, frontmatter `name`, `description`, `model`, `spawn_when`, `color`; copied into a repo's `.reviewers/` | frontmatter |
| Legacy | `## <name>` under `# Agents` in an `AGENT-REVIEWERS.md` | a `model: <name>` line in the first five lines of the section |

Accepted models are `sonnet`, `haiku`, `opus` or a full `claude-*` ID. Anything
else, including `inherit` or a missing line, becomes `sonnet`.

The reviewer's prompt is assembled from three parts. Know which part owns what
before judging the definition:

1. **The spawn template** (`plugins/pr-review-loop/skills/pr-review-loop/SKILL.md`,
   "Spawning Agent Reviewers"). It already supplies the proof requirement,
   "never modify the working tree", the scope and changed-file list, and the
   whole workflow: check prior comments, honour reasoned declines, reopen,
   record with `record-finding.sh`, return a `<severity> | <file>:<line> | <title>`
   manifest or "No issues found".
2. **The definition body** — the only part the author writes.
3. **Nothing else.** `discover-agents.sh` gives each reviewer its own file (or
   section) only. A repo's `.reviewers/README.md`, `# Guidelines` or `# Context`
   reaches the orchestrator, never the reviewer.

The orchestrator decides whether to spawn a reviewer from its header alone, the
first 12 lines of its file. The rest of the file only reaches the reviewer.

## Workflow

Copy this checklist into your response and tick it off:

```
Assessment progress:
- [ ] 1. Locate the definition(s) and the spawn template
- [ ] 2. Run the contract checks
- [ ] 3. Judge against the criteria
- [ ] 4. Check the roster (if assessing a whole file)
- [ ] 5. Run or design the evaluations
- [ ] 6. Write the report
```

**1. Locate.** Read the definition and the current spawn template in full.
Run `scripts/discover-agents.sh <PR>` if a PR is available: it prints what was
actually loaded, with each reviewer's resolved model and scope. Trust its
output over your reading of the files; `~/.claude/skills/` is usually a symlink
and the path you infer may not be the path it reads.

**2. Contract checks.** Measure these.

| Check | Pass when |
|---|---|
| Header (reviewer files) | The first 12 lines hold `# <name>` matching the file name, `**Checks:**` (one line, what it flags) and `**Spawn when:**` (decidable from a diff: paths, imports, file types, kinds of change, plus a skip rule if the spec has one; "when relevant" fails), with no TODO. `**Contents:**` lists the spec's sections when it has two or more. |
| Contents on long files | A reviewer file (or `.reviewers/README.md`) over 100 lines has a `**Contents:**` line in its header naming every section. Claude reads files with `head -n 100`, so whatever the contents line doesn't name past line 100 goes unread. Measure with `wc -l`. |
| Verification line | The header's `verification:` line (or, for a legacy section, the first body line) is `verification: mutation`, `evidence-query`, `judgement` or `mixed`, followed by how this reviewer proves its findings. Missing = **undeclared**. |
| `mixed` is earned | `mixed` names which kinds of finding are mutations and which are evidence-queries, not just the word. |
| Model | Resolves to the model the author intended (check `discover-agents.sh` output). A `model:` line after line five is ignored. |
| No default shadowing (legacy only) | In an `AGENT-REVIEWERS.md`, a `##` name equal to a shipped default (`code-reviewer`, `code-simplifier`, `comment-analyzer`, `pr-test-analyzer`, `silent-failure-hunter`, `type-design-analyzer`) replaces that default entirely. Pass only if the section is a full replacement, not a tweak or a bare `verification:` line. |
| No template restatement | The body does not repeat the proof paragraph, the posting workflow, the manifest format or the tree rule. Repeats ship twice to every spawn. |
| Self-contained | Every repo rule the reviewer needs is in its own file, not only in `.reviewers/README.md` or `# Guidelines`. |
| Portable (starters and templates) | It runs in a repo without beads, and without CI tools it does not name as prerequisites. |
| Proof fits the tree rule | A mutation proof says to mutate a scratch copy, never the working tree. |
| Description (starters only) | Third person, says what it reviews and when to use it, ≤1,024 chars. |

**3. Criteria.** Cite the line for every finding.

### Focus

One reviewer, one lens. The first lines say what it reviews in a sentence
("**Your focus:** …"). A reviewer that checks security, style and test coverage
is three reviewers, and each lens gets less attention than it would alone.

### Flag and don't-flag lists

The shape used across this repo:

- **What to check** — concrete things to look for, in the order to look.
- **Flag issues if** — specific, observable conditions.
- **Do NOT flag** — the false positives this lens attracts. This list matters
  as much as the flag list: it is what keeps a reviewer from burning a round
  on noise. A reviewer with no don't-flag list is a P2.
- **When flagging, provide** — what a finding must contain (location, fix,
  severity).

Flag conditions should be decidable. "Flag poor error handling" is not;
"flag a `catch` that neither re-raises nor logs the error" is.

### Degrees of freedom

Review is mostly high freedom: heuristics over scripts. Low freedom belongs
where the lens has a hard rule (a required header, a banned call) — state the
rule exactly. Flag a judgement call written as a hard rule, and a hard rule
left as "consider whether".

### Proof

The template requires every behavioural claim to be demonstrated, but the
definition decides whether that is possible. Check that the reviewer's lens
names how *its* findings get proven: what it runs, greps or counts. A prose
reviewer can still grep for the two sentences it says are redundant. A
reviewer whose every finding must be labelled judgement should be declared
`judgement`, honestly.

### Scope and severity

- Says what is in scope (changed files; pre-existing issues in touched files
  under touch-it-you-own-it) and what is out (untouched files).
- Distinguishes new defects from pre-existing gaps when severity should differ.
- Severity levels map to the loop's P1/P2/P3 so the convergence rule can read them.

### Conciseness and terminology

Same bar as a skill: the reviewing model is smart. No explaining what a SQL
injection is. One term per concept. Concrete BAD/GOOD examples beat abstract
description when the lens is about a code pattern.

### Model fit

Reviewers run on Sonnet unless they declare otherwise, and may run on
non-Claude models through the Pi engine (`# Configuration .pi`). A definition
that only works on Opus is a cost bug; one that leans on Claude-specific
behaviour breaks under Pi. Say which models you assessed it for.

## Roster checks

When assessing a whole roster (a `.reviewers/` directory, or a legacy
`AGENT-REVIEWERS.md`):

- **Overlap.** Two reviewers flagging the same thing double the comments.
  Each real overlap is either removed (delete one reviewer's file; in a legacy
  repo, add the default to `# Configuration .disabled`), or recorded in
  `overlap_acknowledged` with a `reason`. Read the configuration itself
  (`.reviewers/config.json`, or `# Configuration`), not prose describing it.
- **Coverage.** Name any lens the repo plainly needs that nobody covers.
- **Undeclared reviewers.** List them. Undeclared on purpose is acceptable;
  undeclared by oversight is a finding.
- **Hierarchy.** Reviewers in a subtree's `.reviewers/` (or `AGENT-REVIEWERS.md`) see only their subtree,
  and a lower definition overrides a same-named one above. Check that the
  override is intended.
- **Branch.** The charter is read from the PR branch. A roster change on `main`
  does not govern a PR cut before it.

## Evaluations

At least three, on the model the reviewer runs on:

1. **Seeded defect.** A small diff containing one defect squarely in the lens.
   Expected: one finding at the right line, with proof.
2. **Near-miss.** A diff that looks like the defect but is correct (an
   intentional fallback, a documented exception). Expected: no finding.
3. **Out of lens.** A diff with a real defect outside the lens. Expected:
   no finding from this reviewer.

```json
{
  "reviewer": "<name>",
  "model": "<sonnet|haiku|opus|claude-*|pi model>",
  "diff": "<fixture path>",
  "expected_behavior": [
    "Posts exactly one finding at <file>:<line>",
    "The finding states how it was proven, or labels itself judgement"
  ]
}
```

A reviewer that flags case 2 or 3 is noisy; one that misses case 1 is blind.
If the repo records per-reviewer validator acceptance rates
(`.beads/pr-review-loop/findings/`), report them: a low rate is real-world
evidence of false positives.

## Evidence

Label every finding with how you know it:

- **measured** — you ran a command; quote the command and the result.
- **observed** — you ran the reviewer or an evaluation and saw the behaviour.
- **judgement** — your opinion of clarity or design. Say so.

Before reporting a check as passing, confirm it could have failed. A truncated
listing looks exactly like a complete one: count, don't skim.

## Report format

```markdown
# Reviewer assessment: <name or file>

## Verdict
<Keep / Refine / Retire> — <one sentence why>

## Contract checks
| Reviewer | Verification | Model | Shadows default | Restates template | Self-contained |
|---|---|---|---|---|---|
| <name> | <kind or undeclared> | <resolved> | no/yes | no/yes | yes/no |

## Findings
Ordered most severe first.

1. **<P1|P2|P3>** `<file>:<line>` <reviewer> — <problem>. <fix>. *(measured|observed|judgement)*

## Roster (whole-file assessments only)
Overlaps: …
Gaps: …
Undeclared: …

## Evaluations
<results, or three proposed evaluations as JSON>

## Not assessed
<anything you could not check, and why>
```

Severity: **P1** the reviewer will not run as intended (shadowed default,
wrong model, rules it never receives) or will produce wrong findings; **P2**
noisy, unprovable or duplicated findings; **P3** polish.

Verdict: **Keep** — sound as is. **Refine** — fix the findings. **Retire** —
its lens is covered elsewhere or it cannot produce provable findings.
