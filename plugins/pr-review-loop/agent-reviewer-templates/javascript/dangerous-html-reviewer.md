# dangerous-html-reviewer
verification: judgement — findings rest on reading the changed code for unsanitized sinks; the spec asks for no command, mutation or query proof.
**Checks:** XSS and injection sinks: unsanitized dangerouslySetInnerHTML or innerHTML, eval/new Function on dynamic input, SQL built with template-string interpolation.
**Spawn when:** Diff adds JS/TS/JSX/TSX using dangerouslySetInnerHTML, innerHTML, eval, new Function, or db.query/raw SQL with ${} interpolation. Skip diffs with none of these.
**Contents:** Patterns to flag · `dangerouslySetInnerHTML` without sanitization → P1 · `element.innerHTML = userInput` → P1 · `eval()` or `new Function(string)` on dynamic input → P1 · Template-string SQL → P1 · Don't flag · When flagging, suggest

Review JSX/TSX and string-template code for **XSS surfaces and code-injection patterns**.

**Patterns to flag:**

### `dangerouslySetInnerHTML` without sanitization → P1

```jsx
// BAD — unsanitized user input becomes HTML
<div dangerouslySetInnerHTML={{ __html: comment.body }} />

// GOOD — sanitize first
import DOMPurify from 'dompurify'
<div dangerouslySetInnerHTML={{ __html: DOMPurify.sanitize(comment.body) }} />

// BEST — don't use dangerouslySetInnerHTML at all; render as text
<div>{comment.body}</div>
```

### `element.innerHTML = userInput` → P1

Same XSS surface as `dangerouslySetInnerHTML`. Always sanitize, or use `textContent` for text.

### `eval()` or `new Function(string)` on dynamic input → P1

Code injection. Almost no legitimate use case in app code.

### Template-string SQL → P1

```js
// BAD — SQL injection
db.query(`SELECT * FROM users WHERE id = ${userId}`)

// GOOD — parameterized query
db.query('SELECT * FROM users WHERE id = $1', [userId])
```

Most ORMs do this automatically (Prisma, Drizzle, Kysely). Raw `db.query` with template interpolation is the smell.

**Don't flag:**

- `dangerouslySetInnerHTML` with a constant string at build time (e.g., embedded SVG)
- Template literals for non-SQL string building (logs, file paths, URL construction with `encodeURIComponent`)
- `eval` inside test code that's testing eval-like behavior

**When flagging, suggest:**

- The sanitization library appropriate to the framework (DOMPurify for browser, sanitize-html for Node)
- The parameterized query syntax for the project's DB driver
