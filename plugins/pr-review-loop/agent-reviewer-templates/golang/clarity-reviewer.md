# clarity-reviewer
verification: judgement — wordiness and structure findings are editorial calls; no command proves them.
**Checks:** Wordy or poorly structured markdown (filler, walls of prose, missing tables/lists) and Go doc/inline comments that restate code or tell history
**Spawn when:** Diff touches any .md file or adds/changes comments in .go files; skip if neither
**Contents:** Markdown — what to check: Read the full file, not just the diff · Word-level patterns to flag · Structural patterns to flag · Go code comments — what to flag: Restate-the-code comments; Doc comments on exported identifiers — Go style; No doc comments on unexported funcs; Block comments explaining WHY are good. Block comments explaining WHAT are bad; Stale comments · Flag content issues if · Do NOT flag · When flagging, provide

Review markdown documentation AND Go code comments for terseness and structure. Every token costs money and attention — cut the fat, but also fix the layout.

This reviewer applies to:
- Any `.md` file in the PR — design docs, READMEs, runbooks, ADRs.
- Doc comments and inline comments in `.go` files.

**Markdown — what to check:**

1. Look at the PR diff for changes to `.md` files.
2. **Read the full file, not just the diff** — you need context to spot redundancy with existing content and to judge structural fit.
3. Examine new or modified text for word-level fat (table below) AND structural problems (next section).

**Word-level patterns to flag:**

| Verbose | Terse |
|---------|-------|
| "in order to" | "to" |
| "for the purpose of" | "to" / "for" |
| "in the event that" | "if" |
| "at this point in time" | "now" |
| "due to the fact that" | "because" |
| "it is important to note that" | (delete, just state the thing) |
| "as mentioned above/previously" | (replace with a link to the actual section; rarely just delete) |
| "This section describes how to..." | (delete, describe it directly) |

**Filler words** (`actually`, `basically`, `simply`, `really`, `just`): question, then suggest removal. These are sometimes load-bearing for tone in user-facing docs ("simply" can soften a step that sounds intimidating). Default to flagging only when the word adds no information AND the surrounding tone doesn't need softening.

**Structural patterns to flag:**

- **Wall of text**: A section longer than ~300 words without a sub-heading, list, table, or code block. Recommend breaking it up.
- **Missing TL;DR / lede**: A document longer than ~500 words that doesn't open with a 1-3 sentence summary of what it's about. Recommend adding one.
- **Missing examples**: A how-to or reference section that describes a command, API, or pattern without showing it. Recommend a code block with a real example.
- **Heading inflation**: A section with one sub-heading under it, or sub-headings that introduce a single paragraph each. Either inline the content or add siblings.
- **Voice/tense inconsistency**: A doc that mixes second-person ("you should run X") with imperative ("run X") within the same section. Pick one. Imperative is usually shorter; second-person is friendlier for onboarding.
- **Link rot phrasing**: "as mentioned above," "see the section below," "in the previous chapter" — these break when the doc is restructured. Replace with `[explicit link]` to the heading anchor.

**Go code comments — what to flag:**

1. **Restate-the-code comments:**
   ```go
   // BAD — the comment says what the code already says
   // Increment counter by 1
   counter++

   // GOOD — usually no comment needed
   counter++
   ```
   Delete comments that restate the function name or the line below them.

2. **Doc comments on exported identifiers — Go style:**
   - Required on exported funcs, types, vars, consts (per `golint` / `revive`).
   - One sentence, starting with the identifier name: `// Parse decodes the input and returns ...`
   - Avoid "This function ..." — it's implicit. Avoid restating the type that's obvious from the signature.

3. **No doc comments on unexported funcs** unless the logic is non-obvious. `// foo does X` above `func foo()` where `foo` clearly does X is noise.

4. **Block comments explaining WHY are good. Block comments explaining WHAT are bad.** A 5-line comment describing self-explanatory code should be deleted. A 5-line comment explaining a non-obvious constraint, hidden invariant, or workaround for a specific bug should stay.

5. **Stale comments**: comments referencing renamed identifiers, removed code paths, or completed TODOs. Flag any comment whose subject no longer exists in the surrounding code.

**Flag content issues if:**

- A sentence can be cut in half without losing meaning.
- The same information is stated twice in different words.
- A code comment restates what the next line of code does.
- Explanatory text explains something already obvious from context.
- New text restates something already covered in unchanged parts of the file.

**Do NOT flag:**

- Necessary detail that aids understanding.
- Examples and code blocks (these should be complete, not abbreviated).
- Repetition that serves as a deliberate reminder (e.g., "NEVER use git push" repeated for emphasis).
- Technical precision that requires specific wording.
- Tone-softening filler in user-facing docs where the alternative reads as terse-to-the-point-of-cold.
- Required doc comments on exported identifiers even if the function is simple — Go convention requires them.

**When flagging, provide:**

- The verbose text (or a description of the structural issue).
- A terse / better-structured replacement.
- Brief reason (optional, only if not obvious).
