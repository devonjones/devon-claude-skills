# js-vs-ts-policy-reviewer
**Checks:** Existing review comments pushing a .js file to TypeScript (convert to .ts, add types); records each as a P3 out-of-scope policy finding. Does not review code.
**Spawn when:** Every PR that has at least one .js/.jsx/.mjs/.cjs file in the diff; skip when the diff has no JS files or the PR description cites a JS-to-TS migration issue.
**Contents:** Core policy · What this reviewer flags · Implementation note · Does NOT flag

**This is a policy-enforcement reviewer, not a code reviewer.** It runs on every PR and watches for OTHER reviewers' findings that push JS → TS migration. It also pushes back if a human reviewer flags a `.js` file purely for being JS.

**Core policy:**

This codebase is intentionally **language-pluralistic**. JS and TS code coexist by design. Files chosen as `.js` are reviewed as JS; files chosen as `.ts` are reviewed as TS. **No reviewer should propose converting a `.js` file to `.ts` as part of a normal code-review pass.**

**What this reviewer flags:**

When any other reviewer (or a human comment) suggests converting a file from JS to TS:

```
[js-vs-ts-policy-reviewer] [P3] JS→TS migration suggestion is out of scope

Reviewer <name> suggested converting <file.js> to TypeScript. This is
out of scope for routine code review. JS and TS coexistence is an
intentional choice in this codebase.

If a team-wide JS→TS migration is in progress, link the tracking issue
(e.g., `BD-XXX: JS→TS migration phase 2`) and the migration can be
addressed as deliberate, scoped work — not as a per-PR nag.

Downgrading this finding to P3 and recommending it be dropped from
the review loop's exit-condition consideration.
```

**Implementation note:**

This reviewer scans the PR's existing review comments (the orchestrator supplies the PR number and review-fetching tooling at spawn time) for migration-pushing language. It runs in parallel with other reviewers and only sees findings from earlier rounds; strict last-ordering is not required.

Migration-pushing language to scan for:

- "should be TypeScript"
- "convert to .ts"
- "use TypeScript instead"
- "add types" *in the context of a .js file*
- "rename .js to .ts"

When such a suggestion is found, **emit the policy comment as a standard agent-reviewer finding** (via `record-finding.sh` against the file/line the original suggestion targeted). The orchestrator's main loop handles linking back to the source thread and dispositioning it as P3 / out-of-scope. This reviewer does not directly reply to or resolve other reviewers' comments.

**Does NOT flag:**

- Suggestions to add JSDoc type annotations to `.js` files (that's a non-migrating type-discipline path)
- Suggestions to migrate a SPECIFIC file as part of a documented migration initiative (PR description cites the tracking issue)
- TS-specific findings on `.ts` files (those are appropriate per the typescript-strictness-reviewer)
