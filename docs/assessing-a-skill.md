# Assessing a Skill

Hand this file to a Claude together with a skill directory. It assesses the
skill against Anthropic's
[Skill authoring best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices)
and returns a report in the format at the end. For a pr-review-loop reviewer,
use [assessing-a-reviewer.md](assessing-a-reviewer.md) instead.

You are assessing, not editing. Do not change the skill's files.

## Workflow

Copy this checklist into your response and tick it off:

```
Assessment progress:
- [ ] 1. Inventory the skill directory
- [ ] 2. Run the mechanical checks
- [ ] 3. Read SKILL.md and every file it references
- [ ] 4. Judge against each criterion
- [ ] 5. Run or design the evaluations
- [ ] 6. Write the report
```

**1. Inventory.** List every file. Note which ones SKILL.md links to, which
ones nothing links to, and which scripts exist.

**2. Mechanical checks.** Measure these; do not estimate them.

| Check | Limit | How |
|---|---|---|
| `name` | ≤64 chars, `[a-z0-9-]` only, no XML tags, no "anthropic"/"claude" | read frontmatter |
| `description` | non-empty, ≤1,024 chars, no XML tags | `wc -c` on the value |
| SKILL.md body | <500 lines | `wc -l` |
| Reference depth | every reference file linked directly from SKILL.md | grep links in each referenced file |
| Long references | files >100 lines open with a table of contents | `wc -l`, then read the head |
| Paths | forward slashes only | grep for `\` in file references |
| Unlinked files | none, or each is justified | inventory vs. links |

**3. Read everything SKILL.md points to, in full.** A `head -100` preview
looks complete and is not. If a file is truncated in your view, re-read it to
the end before judging it.

**4. Judge each criterion below.** Cite file and line for every finding.

**5. Evaluations.** See [Evaluations](#evaluations).

**6. Report** in the format at the end.

## Criteria

### Conciseness

Claude is already smart. Each paragraph must pay for its tokens. Flag:

- Explanations of things Claude knows (what a PDF is, what git does).
- The same fact stated twice in different words.
- Preamble ("This section describes…") and filler.
- History and motivation that a reader of the skill does not need to act.

Do not flag deliberate repetition of a critical rule, complete code examples,
or precision that needs specific wording.

### Degrees of freedom

Match specificity to fragility. Fragile, order-sensitive, or destructive
operations need exact commands (low freedom). Context-dependent work like
design or review needs heuristics (high freedom). Flag both mismatches:
a fragile step left to judgement, and a judgement task straitjacketed into
a script.

### Description and name

The description is the only thing Claude sees when choosing among 100+ skills.

- Third person ("Processes Excel files…"), never "I can…" or "You can…".
- Says **what** the skill does **and when** to use it, with the concrete
  trigger terms a user would type (file types, tool names, phrases).
- Not vague ("Helps with documents").
- Name is specific (gerund form preferred: `processing-pdfs`), consistent with
  sibling skills, not `helper`/`utils`/`tools`.

Test it: write three user requests that should trigger the skill and two
near-misses that should not. Does the description separate them?

### Structure and progressive disclosure

- SKILL.md is an overview that points to detail files, not the detail itself.
- Detail is split by domain or by condition, so a task loads only what it needs.
- References are one level deep from SKILL.md.
- Files are named for their content (`form_validation_rules.md`, not `doc2.md`).
- It is clear whether Claude should **run** a script or **read** it.

### Workflows and feedback loops

- Multi-step tasks have numbered steps; long ones offer a copyable checklist.
- Quality-critical steps have a validate → fix → repeat loop, and the skill
  says not to proceed until validation passes.
- Decision points are explicit ("Creating new? → …  Editing? → …").
- Batch or destructive operations use plan → validate plan → execute.

### Content

- No time-sensitive statements ("before August 2025…"); legacy material sits
  in a clearly marked old-patterns section.
- One term per concept throughout. List any concept with two or more names.
- Examples are concrete input/output pairs, not abstract descriptions.
- One default per choice, with an escape hatch, not a menu of alternatives.
- Output templates where format matters, marked strict or flexible.

### Scripts (skip if none)

- Scripts handle their own errors with useful messages instead of failing
  and leaving Claude to diagnose.
- No unexplained constants; every magic number has a reason.
- Required packages and tools are listed with install commands.
- MCP tools use fully qualified `Server:tool` names.
- Validators print specific, actionable errors.

### Model fit

A skill is an addition to a model. Ask for each model it will run on:
Haiku — enough guidance? Sonnet — clear and efficient? Opus — over-explained?

## Evaluations

The best-practices standard is at least three evaluations, tested on every
model the skill targets, against a no-skill baseline.

If the skill ships evaluations, run them where possible and report the
results. If it does not, write three in this shape and include them in the
report:

```json
{
  "skills": ["<skill-name>"],
  "query": "<a realistic user request>",
  "files": ["<fixture paths, if any>"],
  "expected_behavior": [
    "<observable outcome 1>",
    "<observable outcome 2>"
  ]
}
```

Choose scenarios that target the skill's riskiest instructions, not its
happy path. Each `expected_behavior` entry must be checkable by looking at
the output.

## Evidence

Label every finding with how you know it:

- **measured** — you ran a command; quote the command and the number.
- **observed** — you ran the skill or an evaluation and saw the behaviour.
- **judgement** — your opinion of clarity or design. Say so.

A judgement written as a measurement ("SKILL.md is too long") is a defect in
the report. "SKILL.md is 612 lines (`wc -l`), over the 500 limit" is a finding.
Before reporting a check as passing, confirm the check could have failed.

## Report format

```markdown
# Skill assessment: <name>

## Verdict
<Ship / Ship with fixes / Rework> — <one sentence why>

## Mechanical checks
| Check | Result | Value |
|---|---|---|
| name | pass/fail | … |
| description | pass/fail | <n> chars |
| SKILL.md body | pass/fail | <n> lines |
| reference depth | pass/fail | … |
| TOC on long refs | pass/fail | … |
| paths | pass/fail | … |

## Findings
Ordered most severe first.

1. **<P1|P2|P3>** `<file>:<line>` — <problem>. <fix>. *(measured|observed|judgement)*

## Description test
Should trigger: <3 requests> — <would it?>
Should not trigger: <2 near-misses> — <would it?>

## Evaluations
<results, or three proposed evaluations as JSON>

## Not assessed
<anything you could not check, and why>
```

Severity: **P1** breaks discovery or produces wrong behaviour; **P2** wastes
context or makes Claude likely to misread an instruction; **P3** polish.
