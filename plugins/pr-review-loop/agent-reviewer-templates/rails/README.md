# Guidelines

A reviewer pack for Ruby on Rails projects. Each section under `# Agents` below is an independent reviewer prompt with its own scope, set of patterns to flag, and disposition.

## How the pack runs

Each reviewer runs independently and reports findings without coordination.

**Per-reviewer file scope:**

| Reviewer | Files in scope |
|----------|----------------|
| `test-coverage-reviewer` | `app/**/*.rb` (any change requires matching `test/**` or `spec/**`) |
| `n-plus-one-query-reviewer` | `app/controllers/**/*.rb`, `app/views/**/*.{erb,haml,slim}`, `app/jobs/**/*.rb`, `app/mailers/**/*.rb` |
| `strong-params-reviewer` | `app/controllers/**/*.rb` |
| `migration-safety-reviewer` | `db/migrate/**/*.rb`, `db/schema.rb` |
| `callback-overuse-reviewer` | `app/models/**/*.rb` |
| `mass-assignment-reviewer` | `app/controllers/**/*.rb`, `app/services/**/*.rb`, `app/interactors/**/*.rb` |
| `route-bloat-reviewer` | `config/routes.rb`, `config/routes/**/*.rb` |
| `clarity-reviewer` | `*.md`, `app/**/*.rb` (comments and docstrings only) |

Skip reviewers whose file scope doesn't match the PR diff.

## Tooling assumed in CI

Reviewers do not duplicate work already done by CI. Each Rails project running this pack should have these in CI:

- `bundle exec rubocop` — Ruby style + safety lints (rubocop-rails, rubocop-performance, rubocop-rspec strongly recommended)
- `bundle exec brakeman` — security scanner; catches mass-assignment, SQL injection, command injection patterns
- `bundle exec rails test` or `bundle exec rspec` — test suite (one of the two; this pack works with either)
- `bundle audit` (or equivalent) — dependency CVE scan
- `bundle exec rails db:migrate:status` or migration-dry-run in CI — catches missing migrations against current schema

A missing tool is itself a **P1** finding on the first PR that brushes against its scope. For example, if CI doesn't run `brakeman` and the PR touches a controller, `mass-assignment-reviewer` flags the CI gap as well as the code.

## Severity convention

Every finding must be tagged with a beads-style priority matching the pr-review-loop's Priority Mapping:

| Priority | Disposition | Examples |
|----------|-------------|----------|
| **P1** | Blocking — must fix before merge | Mass-assignment vulnerability, irreversible migration without rollback, dropping a column still referenced by app code, SQL injection via raw string interpolation |
| **P2** | Should fix in this PR | N+1 query in hot path, missing FK index, missing strong-params guard, callback that touches a different model |
| **P3** | Advisory — deferrable with a beads ticket | Route bloat (`resources` with unused actions), clarity nits, comment rot, deprecated-but-still-working API use |

**Default severity per reviewer:**

- `mass-assignment-reviewer`, `migration-safety-reviewer`: **P1** by default; specific findings (e.g., adding a nullable column) may be P2.
- `strong-params-reviewer`, `n-plus-one-query-reviewer`: **P2** by default; specific findings (raw SQL with interpolation) may be P1.
- `test-coverage-reviewer`, `callback-overuse-reviewer`: **P2** by default.
- `route-bloat-reviewer`, `clarity-reviewer`: **P3** by default.

A reviewer may promote or demote a specific finding from its default, but must state why.

## Output format

Findings must be structured. Use this template:

```
[<reviewer>] [<severity>] <one-line title>

File: app/path/to/file.rb:LINE
Quote:
    <1-5 lines of code or text being flagged>

Issue: <one or two sentences on what's wrong>
Suggested fix:
    <concrete diff or rewritten code/text>
Reason (optional): <only if not obvious>
```

Example:

```
[n-plus-one-query-reviewer] [P2] N+1 query in posts index view

File: app/views/posts/index.html.erb:14
Quote:
    <% @posts.each do |post| %>
      <%= post.author.name %>
    <% end %>

Issue: Iterating @posts and accessing post.author triggers one SELECT
per post for the authors. With @posts.count > 1, this is a classic N+1.
Suggested fix: In PostsController#index, change `@posts = Post.all` to
`@posts = Post.includes(:author)`. Verify with bullet or rack-mini-profiler.
```

## Deferring findings with beads

To defer a P2 or P3 finding to a follow-up:

1. Create a beads ticket capturing reviewer name, severity, file, and quote.
2. Link the ticket in the PR description or as a reply to the reviewer's comment.
3. The reviewer accepts the deferral only when the beads ticket exists.

**P1 findings are not deferrable** — they must be fixed in-PR.

---
