---
name: pr-review-loop
description: |
  Manage the PR review feedback loop: monitor CI checks, fetch review comments, and iterate on fixes.
  Use when: (1) pushing changes to a PR and waiting for CI/reviews, (2) user says "new reviews available",
  (3) iterating on PR feedback from Gemini, Cursor, Claude, or other reviewers, (4) monitoring PR status.

  Supports multiple review bots: Gemini Code Assist, Cursor Bugbot, and Claude agent fallback.
  Also supports custom agent reviewers defined in AGENT-REVIEWERS.md for focused reviews (security, DRY, etc.).
  Automatically detects priority levels from different bot formats and handles rate limits.

  RECOMMENDED: Spawn a Task agent (subagent_type: general-purpose) to execute the review loop autonomously.
  See "Recommended Usage: Run as Task Agent" section for the prompt template.

  CRITICAL: When using this skill, NEVER use raw git commit/push commands. ALWAYS use commit-and-push.sh script.
  The user has NOT granted permission for raw git commands - only the script is allowed.
---

# PR Review Loop

## ⛔ STOP - READ THIS FIRST ⛔

**YOU DO NOT HAVE PERMISSION TO USE RAW GIT COMMANDS.**

| ❌ FORBIDDEN | ✅ USE INSTEAD |
|--------------|----------------|
| `git commit` | `scripts/commit-and-push.sh "msg"` |
| `git commit -m "..."` | `scripts/commit-and-push.sh "msg"` |
| `git push` | `scripts/commit-and-push.sh "msg"` |
| `git push origin` | `scripts/commit-and-push.sh "msg"` |

**If you use `git commit` or `git push` directly, it will be BLOCKED.**

---

## ⭐ Recommended Usage: Run as Task Agent

**The PR review loop should be executed as a background Task, not in the main conversation.**

When the user creates a PR or wants to iterate on reviews, spawn a Task agent to handle the loop autonomously:

```yaml
Task tool:
  subagent_type: general-purpose
  model: sonnet
  description: PR review loop for #<PR>
  prompt: |
    Execute the PR review feedback loop for PR #<PR>.

    **Setup (first round only):**
    - Check for AGENT-REVIEWERS.md files in changed directories (up to repo root)
    - Load non-Agents H1 sections (e.g., # Guidelines, # Context) as review context
    - Apply hierarchical scoping: lower directories override same-named sections

    **Each round of the loop:**

    1. **Get Gemini comments**:
       - scripts/summarize-reviews.sh <PR>
       - scripts/get-review-comments.sh <PR> --with-ids --wait

    2. **Address Gemini comments** - For EACH comment:
       - If worthwhile: fix it, reply "Fixed - [description]"
       - If bad suggestion: reply "Won't fix - [reason]"
       - If GOOD but out of scope: check `bd --version`, if beads available create ticket with full context (see "Out of Scope Suggestions"), reply "Out of scope - tracked in BD-XXX"

    3. **Check for other bot PR comments** (Claude, Cursor, Copilot):
       - These post single PR comments (not line comments) with multiple issues
       - Parse the structured markdown to extract individual issues
       - Reply with `gh pr comment` addressing each issue (see "Comment Formats" section)

    4. **Run agent reviewers** (if AGENT-REVIEWERS.md exists and agents not retired):
       - Spawn non-retired agents as parallel Tasks
       - Wait for all agents to return
       - Address agent comments (same fix/wontfix/out-of-scope flow)
       - Track per-agent diminishing returns - retire agents with no actionable feedback

    5. **Commit and push** (if any fixes were made):
       - scripts/commit-and-push.sh "fix: address review comments"

    6. **Trigger next review round**:
       - scripts/trigger-review.sh <PR> --wait
       - Go to step 1

    **Completion:**
    When a full round produces no actionable feedback (only nitpicks/won't-fix) AND this was already the "final verification" round:
    - Report all beads tickets created during the review loop (if any)
    - Ask user about merge

    Critical rules:
    - ALWAYS use commit-and-push.sh, NEVER git commit/push
    - For LINE comments (Gemini, agents): reply using reply-to-comment.sh
    - For PR comments (Claude): reply using gh pr comment with consolidated response
    - ALWAYS use --wait flags when polling for reviews (5min timeout)
    - Be skeptical of review suggestions - not all should be implemented
    - For good suggestions out of scope: create beads ticket if `bd --version` succeeds
    - Track created beads tickets to report at completion
    - Track state with TodoWrite (loop state + per-agent state)
    - Spawn agent reviewers in PARALLEL (multiple Task calls in one message)
```

This keeps the main conversation clean while the agent autonomously handles the review cycles.

---

Streamline the push-review-fix cycle for PRs with automated reviewers.

## Supported Review Bots

| Bot | Trigger | Priority Format |
|-----|---------|-----------------|
| **Gemini Code Assist** | `/gemini review` comment | `![critical]`, `![high]`, `![medium]`, `![low]` |
| **Cursor Bugbot** | Auto on push | `<!-- **High Severity** -->`, `### Bug:` |
| **Claude** | Manual via script | `**Critical**`, `### Critical Issues` |

Priority detection automatically parses all formats when summarizing and fetching comments.

## Comment Formats: Line Comments vs PR Comments

Different bots use different comment formats:

### Line Comments (Gemini, Cursor)
- Posted on specific lines of the diff
- Each issue is a separate comment thread
- Reply using `reply-to-comment.sh <PR> <comment-id> "Fixed"`
- Thread auto-resolves when replied to

### PR Comments (Claude)
- Single large comment on the PR (not on specific lines)
- Contains multiple issues organized by sections (e.g., "Issues & Concerns")
- Issues reference file:line locations in prose (e.g., "**Location:** `role_summaries_controller.rb:60`")
- Reply to the comment addressing multiple issues at once

**Handling Claude's PR comments:**

1. **Fetch the comment** to get the comment ID:
   ```bash
   gh pr view <PR> --json comments --jq '.comments[] | select(.author.login == "claude") | {id: .id, body: .body}'
   ```

2. **Parse issues** from the structured markdown:
   - Look for numbered headings like `### **1. BREAKING CHANGE: ...**`
   - Extract file:line references from `**Location:**` lines
   - Note priority indicators: 🚨 (critical), ⚠️ (warning), etc.

3. **Reply with a consolidated response** addressing each issue:
   ```bash
   gh pr comment <PR> --body "## Response to Claude Review

   **Issue 1 (Breaking API change):** Fixed - added deprecation support for old parameter name

   **Issue 2 (Missing validation):** Fixed - added ALLOWED_VIEW_ROLES validation

   **Issue 3 (Logic change):** Won't fix - this is intentional, documented in PR description

   **Issue 4 (Missing tests):** Fixed - added RSpec tests for SystemRoles methods
   "
   ```

4. **Individual issues** can also be addressed via separate replies if preferred:
   ```bash
   gh pr comment <PR> --body "**Re: Issue #2 (Missing Input Validation):** Fixed in commit abc123 - added validation for view_role parameter"
   ```

The key difference: Claude comments don't have "threads" to resolve - you reply to the main PR comment referencing which issues you're addressing.

## Critical: Be Skeptical of Reviews

**Not all suggestions are good.** Evaluate each review comment critically:

- Does this actually improve the code, or is it pedantic?
- Is this suggestion appropriate for the project's context?
- Would implementing this introduce unnecessary complexity?

**Skip suggestions that are:**
- Platform-specific when not applicable (Windows comments for Linux-only code)
- Overly defensive (excessive null checks, unlikely edge cases)
- Stylistic preferences that don't match project conventions
- Adding documentation for self-explanatory code

When in doubt, ask the user rather than blindly applying changes.

## Diminishing Returns Detection

Track review rounds. After 2-3 iterations, evaluate:
- Are new comments addressing real issues or nitpicks?
- Are we fixing the same type of issue repeatedly?
- Are reviewers finding fewer/lower-priority issues?

**ONE MORE LOOP rule**: When a full round (Gemini + other bots + agent reviewers) produces no actionable feedback (or only "Won't fix" responses), do ONE additional round to catch any final feedback.

**Tracking state**: Use TodoWrite to track whether you're in the "final verification round". Create a todo like "Final verification round - if no actionable feedback, ready to merge".

**Reset condition**: If the final verification round produces feedback you actually fix (not just "Won't fix"), remove the "final verification round" todo - you need a fresh "one more" after pushing those fixes.

**Exit condition**: If the "final verification round" todo exists AND the round produces no actionable feedback (only nitpicks/won't-fix responses), you're done - ask about merge.

**After the final round**, ask the user: "We've completed the review cycles. Ready to merge, or want to address more?"

## Autonomous Loop Workflow

**CRITICAL RULES - NEVER VIOLATE THESE:**
1. **ALWAYS use `commit-and-push.sh`** - NEVER `git commit` or `git push` (see table at top of document)
2. **ALWAYS reply to EVERY comment**:
   - Line comments (Gemini, agents): use `reply-to-comment.sh`
   - PR comments (Claude): use `gh pr comment` with consolidated response
3. **ALWAYS use `--wait` flag** when checking for comments - this ensures proper 5-minute polling
4. **PR creation automatically triggers Gemini review** - use `get-review-comments.sh --wait` to wait for the first review

### The Loop

Each round includes all reviewers before triggering the next cycle:

```
EACH ROUND:
1. Get unresolved Gemini LINE comments (use --wait to poll for up to 5 minutes)
2. Address Gemini line comments:
   - Fix it → reply "Fixed - ..."
   - Bad suggestion → reply "Won't fix - ..."
   - Good but out of scope → create beads ticket (if available), reply "Out of scope - tracked in BD-XXX"
3. Check for other bot PR comments (Claude, Cursor, Copilot):
   - These are single PR comments containing multiple issues
   - Parse the structured markdown to extract individual issues
   - Reply to the PR comment addressing each issue (see "Comment Formats" section)
4. Run agent reviewers (if AGENT-REVIEWERS.md exists and agents not retired):
   - Spawn non-retired agents as parallel Tasks
   - Wait for all agents to return
   - Address agent comments (fix/wontfix/out-of-scope flow)
   - Track per-agent diminishing returns, retire unproductive agents
5. Use commit-and-push.sh (NEVER raw git commands) - if any fixes were made
6. Trigger next review: trigger-review.sh <PR> --wait
7. Go to step 1

COMPLETION:
When a full round produces no actionable feedback (Gemini + other bots + agents all stable)
AND this was the "final verification" round:
8. Report all beads tickets created during the loop (if any)
9. Ask user about merge
```

### Step-by-step (Each Round)

**1. Check for unresolved Gemini line comments (ALWAYS use --wait for first check after PR creation or push):**
```bash
scripts/summarize-reviews.sh <PR>
scripts/get-review-comments.sh <PR> --with-ids --wait
```
The `--wait` flag polls every 30s for up to 5 minutes, waiting for Gemini to respond. Do NOT skip this or use a shorter timeout.

**2. Address Gemini line comments (MANDATORY - never skip this):**
- Evaluate if suggestion is worthwhile
- Apply fix locally OR decide to skip
- **ALWAYS reply using the script** - this resolves the thread:
```bash
scripts/reply-to-comment.sh <PR> <comment-id> "Fixed - description"
# OR for bad/inappropriate suggestions:
scripts/reply-to-comment.sh <PR> <comment-id> "Won't fix - reason"
# OR for good suggestions outside PR scope - see "Out of Scope Suggestions" section:
scripts/reply-to-comment.sh <PR> <comment-id> "Out of scope - tracked in BD-XXX"
```

**3. Check for other bot PR comments (Claude, Cursor, Copilot):**

These bots post single PR comments (not line comments) containing multiple issues:
```bash
# Find Claude's review comment
gh pr view <PR> --json comments --jq '.comments[] | select(.author.login == "claude") | {id: .id, body: .body[:500]}'
```

For each issue in the comment:
- Parse the structured markdown (numbered issues, file:line references)
- Apply fix/wontfix/out-of-scope decision for each issue
- Reply to the PR comment with a consolidated response:
```bash
gh pr comment <PR> --body "## Response to Claude Review

**Issue 1 (name):** Fixed - description
**Issue 2 (name):** Won't fix - reason
**Issue 3 (name):** Out of scope - tracked in BD-XXX
"
```

**4. Run agent reviewers (if AGENT-REVIEWERS.md exists):**
- Spawn non-retired agents as parallel Tasks
- Wait for all agents to return
- Address agent comments (fix/wontfix/out-of-scope flow)
- Track per-agent diminishing returns

**5. Commit and push (ALWAYS use the script, NEVER raw git) - if any fixes were made:**
```bash
scripts/commit-and-push.sh "fix: description"
```
This script runs pre-commit, commits with proper footer, and pushes.

**6. Trigger next review and wait for response:**
```bash
scripts/trigger-review.sh <PR> --wait
```
The `--wait` flag polls for up to 5 minutes until new comments appear. Do NOT use sleep or manual polling.

**7. When new reviews detected, go to step 1**

## Reply Templates

### For Line Comments (Gemini, agent reviewers)
**ALWAYS reply using `reply-to-comment.sh`.** Templates:
- Fixed: "Fixed - [description]"
- Won't fix (bad suggestion): "Won't fix - [reason]"
- Out of scope (good suggestion): "Out of scope - tracked in BD-XXX" (see below)
- Deferred: "Good catch, tracking in #issue"
- Acknowledged: "Acknowledged - [explanation]"

### For PR Comments (Claude)
Reply using `gh pr comment` with a consolidated response:
```markdown
## Response to Claude Review

**Issue 1 (Breaking API change):** Fixed - added backward compatibility

**Issue 2 (Missing validation):** Fixed - added input validation in controller

**Issue 3 (Behavior change):** Won't fix - intentional, see PR description

**Issue 4 (Missing tests):** Out of scope - tracked in BD-XXX
```

## Out of Scope Suggestions (Beads Integration)

When a review suggestion is **good but outside the scope of this PR**, capture it for later rather than losing it.

**Decision tree:**
1. Is this suggestion valid and would improve the code? → If NO, use "Won't fix"
2. Does it belong in this PR? → If YES, fix it
3. It's a good suggestion but out of scope → Create a beads ticket if available

**Check if beads is installed:**
```bash
bd --version
```

**If beads is available, create a ticket:**
```bash
bd create
```

Include in the ticket:
- **Title**: Brief description of the suggested improvement
- **Description**: Must include ALL context needed to fix the issue later:
  - The original review comment text
  - File path and line number(s) affected
  - PR number and link for context
  - The gh command to fetch the exact comment:
    ```
    gh api /repos/{owner}/{repo}/pulls/{PR}/comments/{comment-id}
    ```
  - Any relevant code snippets or context from the current PR

**Then reply to the comment:**
```bash
scripts/reply-to-comment.sh <PR> <comment-id> "Out of scope - tracked in BD-XXX"
```

**Track the ticket** for reporting at the end of the review loop. Keep a list of all created tickets (ID and title) to include in the completion summary.

**If beads is NOT installed**, just reply without creating a ticket:
```bash
scripts/reply-to-comment.sh <PR> <comment-id> "Out of scope for this PR"
```

## Triggering Reviews by Bot Type

### Gemini Code Assist (Default)
```bash
scripts/trigger-review.sh <PR> --gemini --wait
```
Gemini has a daily quota. When exceeded, the skill automatically detects this and suggests alternatives.

### Cursor Bugbot
```bash
scripts/trigger-review.sh <PR> --cursor --wait
```
Cursor auto-reviews on push, so `--cursor` just waits for comments to appear (typically 1-2 minutes).

### Claude Agent (Fallback)
```bash
scripts/trigger-review.sh <PR> --claude
```
Uses a Claude agent to review the PR and post comments. Useful when:
- Gemini is rate-limited
- You want a different perspective
- Cursor isn't configured on the repo

### Claude Review Workflow

When using Claude fallback:

1. **Run the script to get the prompt:**
   ```bash
   scripts/claude-review.sh <PR>
   ```

2. **Use the Task tool with the generated prompt:**
   ```
   Task tool:
     subagent_type: general-purpose
     description: Review PR #<PR>
     prompt: (copy from /tmp/claude_review_prompt_<PR>.txt)
   ```

3. **The agent will post the review as a PR comment**

4. **Continue the normal review loop** - address comments using `reply-to-comment.sh`

## Agent Reviewers (Custom Focused Reviews)

Run custom agent reviewers defined in `AGENT-REVIEWERS.md` files as part of each review round.

### AGENT-REVIEWERS.md Format

Two types of H1 sections:

1. **`# Agents`** - Defines custom agent reviewers (H2 headings become agent names)
2. **Any other H1 section** - Treated as context/instructions for the main review loop (like CLAUDE.md)

```markdown
# Agents

## security-reviewer
Focus on security vulnerabilities: injection attacks, auth bypasses, secrets in code,
unsafe deserialization, path traversal, etc. Flag anything that could be exploited.

## dry-reviewer
Identify code duplication. Look for repeated logic that could be abstracted.
Consider whether abstraction would actually improve maintainability.

# Guidelines

When reviewing this codebase:
- All database queries must use parameterized statements
- Prefer composition over inheritance
- Error messages should never expose internal paths or stack traces

# Context

This is a Ruby on Rails API backend. The frontend is a separate React app.
Authentication uses JWT tokens stored in httpOnly cookies.
```

**How sections are used:**
- `# Agents` → H2 headings define agent reviewers with their specialized instructions
- Other H1 sections (`# Guidelines`, `# Context`, etc.) → Passed to the main pr-review-loop task as context, similar to CLAUDE.md content

### Hierarchical Scoping

`AGENT-REVIEWERS.md` files can exist at any directory level. Agents and context sections are scoped to their directory and below.

**Resolution rules:**
1. For each changed file, collect `AGENT-REVIEWERS.md` files from its directory up to repo root
2. Resolve sections by H1 name - **lower directory definitions override same-named sections from above**
3. For `# Agents`: each agent only reviews changes **within its directory scope and below**
4. For other H1 sections: winning version of each section (per override rule) is combined and passed to the review loop
5. Root-level definitions see all changes; subdirectory definitions see only their subtree

**Example structure:**
```
/AGENT-REVIEWERS.md                    # Agents: clarity-reviewer, dry-reviewer
                                       # Guidelines: general repo rules
/plugins/AGENT-REVIEWERS.md            # Agents: dry-reviewer (overrides root), plugin-structure-reviewer
                                       # Guidelines: plugin-specific rules (overrides root)
/plugins/auth/AGENT-REVIEWERS.md       # Agents: security-reviewer
                                       # Context: auth-specific context
```

**Result for a PR touching `plugins/auth/login.py` and `plugins/utils.py`:**

*Agents:*
- `clarity-reviewer` (from root) → sees all changes
- `dry-reviewer` (from `/plugins/`, overrides root) → sees all changes under `/plugins/`
- `plugin-structure-reviewer` (from `/plugins/`) → sees all changes under `/plugins/`
- `security-reviewer` (from `/plugins/auth/`) → sees only changes under `/plugins/auth/`

*Context for main review loop:*
- For `plugins/auth/login.py`: combines `# Guidelines` from `/plugins/` + `# Context` from `/plugins/auth/`
- For `plugins/utils.py`: uses `# Guidelines` from `/plugins/`

**Discovery algorithm:**
```bash
# For each unique directory containing changed files:
# 1. Walk up to repo root collecting AGENT-REVIEWERS.md paths
# 2. Parse each file, building agent map (lower wins on name collision)
# 3. Track each agent's scope (directory where it was defined)
```

### When to Run Agent Reviewers

Agent reviewers run as part of **each review round**, after addressing Gemini and other bot comments.

On the first round (or when new agents are discovered), discover agent reviewers:

```bash
# Get list of changed files
gh pr diff <PR> --name-only

# For each unique parent directory, check for AGENT-REVIEWERS.md up to repo root
```

Spawn non-retired agents **in parallel** at step 4 of each round. Track per-agent state to avoid re-running retired agents.

### Spawning Agent Reviewers

For each agent discovered (after merging and scoping), spawn a Task:

```yaml
Task tool:
  subagent_type: general-purpose
  model: sonnet
  description: <agent-name> review for PR #<PR>
  prompt: |
    You are the "<agent-name>" code reviewer for PR #<PR>.

    Your focus: <instructions from AGENT-REVIEWERS.md>

    **Your scope: <scope-path>/**
    You should ONLY review changes to files under this path. Ignore changes outside your scope.

    ## Your workflow:

    1. **Check your prior comments** (if any):
       ```bash
       scripts/get-agent-comments.sh <PR> <agent-name> --with-replies
       ```

    2. **Evaluate replies to your prior comments**:
       - If the response is reasonable (good explanation, valid fix, or acceptable tradeoff), do NOT re-raise
       - If the response is UNREASONABLE (dismissive, incorrect, or ignores the issue), reopen:
         ```bash
         scripts/reopen-comment.sh <PR> <comment-id> <agent-name> "Reopening - <reason why response is insufficient>"
         ```

    3. **Review the PR diff** (filter to your scope):
       ```bash
       gh pr diff <PR> -- '<scope-path>/*'
       ```
       If scope is repo root, use `gh pr diff <PR>` without path filter.

    4. **Post NEW findings** as line comments (only issues not already raised, only files in your scope):
       ```bash
       scripts/post-line-comment.sh <PR> <file> <line> <agent-name> "Issue description and suggestion"
       ```
       The script automatically adds `<!-- Agent: <agent-name> -->` signature.

    5. **Return** - Do NOT fix anything. Your job is review only.

    ## Important:
    - Be thorough but not pedantic - only flag real issues within your focus area
    - Consider project context - not all best practices apply everywhere
    - If you have no findings and all prior comments have reasonable responses, simply return "No issues found"

    Available scripts: See pr-review-loop skill documentation for full script reference.
```

**Spawn all agents in parallel** - use multiple Task tool calls in a single message.

### Main Loop Integration

Agent reviewers are part of each round, running after Gemini and other bot comments are addressed:

1. **After agent Tasks return**, address agent comments using the same flow as Gemini:
   - Fix → reply "Fixed - ..."
   - Won't fix (bad) → reply "Won't fix - ..."
   - Out of scope (good) → create beads ticket if available, reply "Out of scope - tracked in BD-XXX"

2. **Update per-agent tracking** based on results (productive / final-verification / retired)

3. **After all comments in the round are addressed** (Gemini + other bots + agents):
   - Commit and push if any fixes: `scripts/commit-and-push.sh "fix: address review comments"`
   - Trigger next review: `scripts/trigger-review.sh <PR> --wait`
   - Start the next round

### Diminishing Returns for Agent Reviewers

Apply the same heuristic as Gemini, but **per agent**:

- Track each agent with TodoWrite: `"<agent-name>: final verification loop"`
- After 2-3 cycles where an agent produces only nitpicks or "Won't fix" responses, enter final verification for that agent
- If an agent's final verification produces actual fixes, reset its state
- If an agent's final verification produces no actionable feedback, **stop calling that agent**

Example tracking:
```
- "security-reviewer: 2 cycles, still productive" (keep calling)
- "dry-reviewer: final verification loop" (one more, then retire if no actionable feedback)
- "error-handling-reviewer: retired" (no longer called)
```

### Selective Agent Execution

As agents reach diminishing returns, stop calling them. The main loop should:

1. Parse `AGENT-REVIEWERS.md` to get all agent names
2. Track per-agent state (productive / final-verification / retired)
3. Only spawn Tasks for non-retired agents
4. Update state after each cycle based on results

This keeps the review loop efficient while ensuring all perspectives are heard at least once.

## Rate Limit Detection

The scripts automatically detect Gemini quota limits by checking for:
> "You have reached your daily quota limit"

When detected, the script suggests:
1. Use Cursor if available: `--cursor --wait`
2. Use Claude fallback: `--claude`

## Scripts

| Script | Purpose |
|--------|---------|
| `commit-and-push.sh "msg"` | **ALWAYS USE** - Never use raw git commit/push |
| `reply-to-comment.sh <PR> <id> "msg"` | **ALWAYS USE** - Reply and auto-resolve every comment |
| `get-review-comments.sh <PR> [--with-ids] [--wait]` | **USE --wait** - Fetch comments, polls 5min if --wait |
| `trigger-review.sh [PR] [--gemini\|--cursor\|--claude] [--wait]` | **USE --wait** - Trigger review and poll for response |
| `summarize-reviews.sh <PR> [--all]` | Summary of unresolved by priority/file |
| `watch-pr.sh <PR>` | Background monitor (optional, for long-running watches) |
| `claude-review.sh <PR>` | Generate Claude agent prompt for code review |
| `check-gemini-quota.sh <PR>` | Check if Gemini is rate-limited |
| `resolve-comment.sh <node-id> [reason]` | Manually resolve a thread |
| `post-line-comment.sh <PR> <file> <line> <agent> "msg"` | Post line comment with agent signature |
| `get-agent-comments.sh <PR> <agent> [--with-replies]` | Fetch agent's own comments and replies |
| `reopen-comment.sh <PR> <comment-id> <agent> "reason"` | Reply to resolved thread with Claude attribution |

## Permission Setup

To enable autonomous loops, user should grant access:
```
Bash(scripts/commit-and-push.sh:*)
Bash(scripts/reply-to-comment.sh:*)
Bash(scripts/trigger-review.sh:*)
Bash(scripts/post-line-comment.sh:*)
Bash(scripts/get-agent-comments.sh:*)
Bash(scripts/reopen-comment.sh:*)
```

## Prerequisites

- `gh` CLI authenticated
- `jq` - JSON processor for parsing GitHub API responses
  Install with: `apt install jq` (Ubuntu/Debian) or `brew install jq` (macOS)
- `pre-commit` (optional) - If `.pre-commit-config.yaml` exists in the repo, pre-commit will be run.
  If pre-commit is not installed, a warning is shown but commits proceed.
  Install with: `pip install pre-commit && pre-commit install`
- `bd` (beads) (optional) - Issue tracker for capturing out-of-scope suggestions as tickets.
  If not installed, out-of-scope suggestions are handled with "Out of scope for this PR" replies.
  See: https://github.com/steveyegge/beads
