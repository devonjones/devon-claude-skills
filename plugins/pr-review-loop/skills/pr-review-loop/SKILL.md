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

    The autonomous loop workflow:

    **Phase 1: Gemini Review Loop**
    1. Get summary of comments: scripts/summarize-reviews.sh <PR>
    2. Check for unresolved comments: scripts/get-review-comments.sh <PR> --with-ids --wait
    3. For EACH comment: evaluate critically, then:
       - If worthwhile: fix it, reply "Fixed - [description]"
       - If bad suggestion: reply "Won't fix - [reason]"
       - If GOOD but out of scope: check `bd --version`, if beads available create ticket with full context (see "Out of Scope Suggestions" section), reply "Out of scope - tracked in BD-XXX"
    4. Commit and push: scripts/commit-and-push.sh "fix: address review comments" (NEVER use raw git commands)
    5. Trigger next review: scripts/trigger-review.sh <PR> --wait
    6. Repeat steps 1-5 until Gemini reaches "final verification" state (no actionable feedback)

    **Phase 2: Agent Reviewers (if AGENT-REVIEWERS.md exists)**
    7. Check for AGENT-REVIEWERS.md in the repo
    8. Parse agent definitions, spawn ALL non-retired agents as parallel Tasks (see "Agent Reviewers" section)
    9. Wait for all agent Tasks to return
    10. Address agent comments (same fix/wontfix/out-of-scope flow as step 3)
    11. If fixes were made: commit-and-push, trigger Gemini review, go to step 1
    12. Track per-agent diminishing returns - retire agents that produce no actionable feedback

    **Phase 3: Completion**
    13. When Gemini is stable AND all agents are retired or stable:
        - Report all beads tickets created during the review loop (if any)
        - Ask user about merge

    Critical rules:
    - ALWAYS use commit-and-push.sh, NEVER git commit/push
    - ALWAYS reply to every comment using reply-to-comment.sh
    - ALWAYS use --wait flags when polling for reviews (5min timeout)
    - Be skeptical of review suggestions - not all should be implemented
    - For good suggestions out of scope: create beads ticket if `bd --version` succeeds
    - Track created beads tickets to report at completion
    - Track state with TodoWrite (Gemini loop state + per-agent state)
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

Track review cycles. After 2-3 iterations, evaluate:
- Are new comments addressing real issues or nitpicks?
- Are we fixing the same type of issue repeatedly?
- Is the reviewer finding fewer/lower-priority issues?

**ONE MORE LOOP rule**: When you reach a point where there are no unresolved comments (or only "Won't fix" responses), do ONE additional review cycle to catch any final feedback Gemini may have held back.

**Tracking state**: Use TodoWrite to track whether you're in the "final verification loop". Create a todo like "Final verification loop - if no actionable feedback, ready to merge".

**Reset condition**: If the final verification loop produces feedback you actually fix (not just "Won't fix"), remove the "final verification loop" todo - you need a fresh "one more" after pushing those fixes.

**Exit condition**: If the "final verification loop" todo exists AND you get no actionable feedback (only nitpicks/won't-fix responses), you're done - ask about merge.

**After the final loop**, ask the user: "We've completed the review cycles. Ready to merge, or want to address more?"

## Autonomous Loop Workflow

**CRITICAL RULES - NEVER VIOLATE THESE:**
1. **ALWAYS use `commit-and-push.sh`** - NEVER `git commit` or `git push` (see table at top of document)
2. **ALWAYS reply to EVERY comment** using `reply-to-comment.sh` - never leave a comment without a reply
3. **ALWAYS use `--wait` flag** when checking for comments - this ensures proper 5-minute polling
4. **PR creation automatically triggers Gemini review** - use `get-review-comments.sh --wait` to wait for the first review

### The Loop

```
PHASE 1: GEMINI LOOP
1. Get unresolved comments (use --wait to poll for up to 5 minutes)
2. For EACH comment:
   - Fix it → reply "Fixed - ..."
   - Bad suggestion → reply "Won't fix - ..."
   - Good but out of scope → create beads ticket (if available), reply "Out of scope - tracked in BD-XXX"
3. Use commit-and-push.sh (NEVER raw git commands)
4. Trigger next review with --wait: trigger-review.sh <PR> --wait
5. Go to step 1
6. When Gemini stable (no new actionable feedback after ONE MORE loop): proceed to Phase 2

PHASE 2: AGENT REVIEWERS (if AGENT-REVIEWERS.md exists)
7. Parse AGENT-REVIEWERS.md, spawn non-retired agents as parallel Tasks
8. Wait for all agents to return
9. Address agent comments (same as step 2)
10. If any fixes: commit-and-push, go to step 4 (triggers Gemini, restarts loop)
11. Track per-agent diminishing returns, retire unproductive agents
12. Repeat steps 7-11 until all agents retired or stable

PHASE 3: COMPLETION
13. Report all beads tickets created during the loop (if any)
14. Ask user about merge
```

### Step-by-step

**1. Check for unresolved comments (ALWAYS use --wait for first check after PR creation or push):**
```bash
scripts/summarize-reviews.sh <PR>
scripts/get-review-comments.sh <PR> --with-ids --wait
```
The `--wait` flag polls every 30s for up to 5 minutes, waiting for Gemini to respond. Do NOT skip this or use a shorter timeout.

**2. For EACH unresolved comment (MANDATORY - never skip this):**
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

**3. Commit and push (ALWAYS use the script, NEVER raw git):**
```bash
scripts/commit-and-push.sh "fix: description"
```
This script runs pre-commit, commits with proper footer, and pushes.

**4. Trigger next review and wait for response:**
```bash
scripts/trigger-review.sh <PR> --wait
```
The `--wait` flag polls for up to 5 minutes until new comments appear. Do NOT use sleep or manual polling.

**5. When new reviews detected, go to step 1**

## Reply Templates

**ALWAYS reply to every comment using `reply-to-comment.sh`.** Use these templates:
- Fixed: "Fixed - [description]"
- Won't fix (bad suggestion): "Won't fix - [reason]"
- Out of scope (good suggestion): "Out of scope - tracked in BD-XXX" (see below)
- Deferred: "Good catch, tracking in #issue"
- Acknowledged: "Acknowledged - [explanation]"

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

After Gemini reviews stabilize, run custom agent reviewers defined in `AGENT-REVIEWERS.md` files.

### AGENT-REVIEWERS.md Format

```markdown
# Agents

## security-reviewer
Focus on security vulnerabilities: injection attacks, auth bypasses, secrets in code,
unsafe deserialization, path traversal, etc. Flag anything that could be exploited.

## dry-reviewer
Identify code duplication. Look for repeated logic that could be abstracted.
Consider whether abstraction would actually improve maintainability.

## error-handling-reviewer
Check for missing error handling, swallowed exceptions, unclear error messages,
and inconsistent error patterns across the codebase.
```

Each `## <agent-name>` heading defines a reviewer. The text that follows is the agent's specialized instructions.

### Hierarchical Scoping

`AGENT-REVIEWERS.md` files can exist at any directory level. Agents are scoped to their directory and below.

**Resolution rules:**
1. For each changed file, collect `AGENT-REVIEWERS.md` files from its directory up to repo root
2. Merge agents - **lower directory definitions override same-named agents from above**
3. Each agent only reviews changes **within its directory scope and below**
4. Root-level agents see all changes; subdirectory agents see only their subtree

**Example structure:**
```
/AGENT-REVIEWERS.md                    # clarity-reviewer, dry-reviewer
/plugins/AGENT-REVIEWERS.md            # dry-reviewer (overrides root), plugin-structure-reviewer
/plugins/auth/AGENT-REVIEWERS.md       # security-reviewer
```

**Result for a PR touching `plugins/auth/login.py` and `plugins/utils.py`:**
- `clarity-reviewer` (from root) → sees all changes
- `dry-reviewer` (from `/plugins/`, overrides root) → sees all changes under `/plugins/`
- `plugin-structure-reviewer` (from `/plugins/`) → sees all changes under `/plugins/`
- `security-reviewer` (from `/plugins/auth/`) → sees only changes under `/plugins/auth/`

**Discovery algorithm:**
```bash
# For each unique directory containing changed files:
# 1. Walk up to repo root collecting AGENT-REVIEWERS.md paths
# 2. Parse each file, building agent map (lower wins on name collision)
# 3. Track each agent's scope (directory where it was defined)
```

### When to Run Agent Reviewers

After the Gemini review loop reaches its "final verification" state (no new actionable feedback), discover agent reviewers:

```bash
# Get list of changed files
gh pr diff <PR> --name-only

# For each unique parent directory, check for AGENT-REVIEWERS.md up to repo root
```

If any agents are found, spawn them **in parallel** before asking about merge.

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

After spawning agent reviewers and they all return:

1. **Address agent comments** using the same flow as Gemini comments:
   - Fix → reply "Fixed - ..."
   - Won't fix (bad) → reply "Won't fix - ..."
   - Out of scope (good) → create beads ticket if available, reply "Out of scope - tracked in BD-XXX"

2. **Commit and push** if any fixes were made:
   ```bash
   scripts/commit-and-push.sh "fix: address agent reviewer feedback"
   ```

3. **Trigger next Gemini review** (this may surface new issues from the fixes):
   ```bash
   scripts/trigger-review.sh <PR> --wait
   ```

4. **Continue the main loop** - address Gemini feedback, then run agent reviewers again

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
  See: https://github.com/anthropics/beads
