# Configuration

```json
{
  "defaults_version_checked": "1.5.0",
  "disabled": [
    "silent-failure-hunter",
    "comment-analyzer",
    "code-simplifier"
  ],
  "overlap_acknowledged": {
    "test-coverage-reviewer": {
      "overlaps_with": "pr-test-analyzer",
      "reason": "Different lenses: test-coverage-reviewer enforces Rails-specific test placement rules (controller→test/controllers, model→test/models, etc.) and require-before-merge discipline. pr-test-analyzer scores behavioral gaps on a criticality 1-10 axis. Both contribute independent signal during review loops."
    }
  }
}
```

**Why each default is disabled:**

- **`silent-failure-hunter`** — covered by `n-plus-one-query-reviewer` (catches the Rails-flavor silent failure: missing eager-loading causing latency degradation that doesn't error). `rescue => e` discouragement is a Rails community convention not separately enforced by this pack.
- **`comment-analyzer`** — covered by `clarity-reviewer`. Rails code is conventional enough that the generic comment-analyzer over-flags; the pack's clarity-reviewer scopes to the conventions that matter for Rails (route comments, callback rationale, schema-comment freshness).
- **`code-simplifier`** — Rails developers have strong existing simplification conventions (Sandi Metz's rules, Rails idioms). The generic code-simplifier conflicts with Rails-canon patterns (e.g., flags `ActiveRecord::Relation` chains as "complex" when they're idiomatic). Disabled to avoid noise.

The defaults `code-reviewer` (CLAUDE.md compliance + significant bugs) and `type-design-analyzer` (encapsulation, invariant design) are kept as-is — they cover scopes our pack does not.

---

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

# Agents

## test-coverage-reviewer

Review code changes to **require unit tests for all new or modified Ruby code in `app/`**. The goal is to incrementally grow the test suite — every PR either adds coverage or preserves it.

**Core rule: Every PR that modifies `app/**/*.rb` must include matching test changes in `test/**` or `spec/**`.**

This is NOT optional. PRs without tests for new/modified `app/` code should be blocked.

**Rails-specific placement rules:**

| Source path | Required test path |
|-------------|---------------------|
| `app/controllers/<name>_controller.rb` | `test/controllers/<name>_controller_test.rb` or `spec/controllers/` or `spec/requests/` |
| `app/models/<name>.rb` | `test/models/<name>_test.rb` or `spec/models/` |
| `app/jobs/<name>_job.rb` | `test/jobs/<name>_job_test.rb` or `spec/jobs/` |
| `app/mailers/<name>_mailer.rb` | `test/mailers/<name>_mailer_test.rb` or `spec/mailers/` |
| `app/services/<name>.rb` (or `app/interactors/`, `app/queries/`) | `test/services/` or `spec/services/` (mirror the source dir) |
| `app/helpers/<name>_helper.rb` | `test/helpers/<name>_helper_test.rb` or `spec/helpers/` |

If the PR touches one of these source paths but doesn't touch the matching test path, flag it.

**What to flag:**

- New public methods on models/controllers/services without tests verifying their behavior
- Modified public methods without tests verifying the modification
- Bug fixes without a regression test
- New API endpoints (new routes) without request/controller tests
- New scopes on models without scope tests

**Do NOT flag:**

- View-only changes (HTML/ERB/HAML/Slim) — view tests are valuable but not blocking
- Config file changes (`config/**/*.yml`, `config/initializers/**`)
- Schema changes (`db/schema.rb` — migration-safety-reviewer handles this)
- Trivial changes (formatting, comments, route reorder without behavior change)
- Simple getter/setter additions (`attr_accessor`)
- Private methods that are pure delegation

**Acceptable substitutes:**

- A beads ticket tracking the test addition (link in the PR description)
- An existing integration/request test that explicitly exercises the new behavior (cite the test file:line in the PR description)

## n-plus-one-query-reviewer

Review controller actions, view templates, jobs, and mailers for **N+1 query patterns** — the dominant performance failure mode in Rails apps.

**Core pattern to flag:** any iteration over an ActiveRecord collection (`each`, `map`, `select`, `find_each`, etc.) where the body accesses an association that wasn't eager-loaded.

```ruby
# BAD — one SELECT for posts, then N SELECTs for authors
@posts = Post.all
@posts.each do |post|
  puts post.author.name
end

# GOOD — one SELECT for posts, one JOIN for authors
@posts = Post.includes(:author)
@posts.each do |post|
  puts post.author.name
end
```

**What to flag:**

- `.each`/`.map`/`.select` over an `ActiveRecord::Relation` followed by `.<association_name>` access where the controller setup doesn't `.includes` / `.preload` / `.eager_load`
- View partials rendering a collection (`render @posts`) where the controller didn't preload associations the partial accesses
- Counter cache misses: `@posts.each { |p| p.comments.count }` instead of using `:counter_cache`
- `find_each` over a collection that immediately joins another table inside the block (use `includes` + `in_batches` instead)
- Custom `.collect` blocks that fire one query per element

**Do NOT flag:**

- `.first`, `.last`, `.find(id)` on already-eager-loaded records
- Aggregation queries (`.sum`, `.count` on a relation, not on each element)
- Single-record loads (no iteration → no N+1)
- Code that explicitly handles batching (`find_in_batches` with explicit per-batch preload)

**Severity guidance:**

- **P1** if the N+1 is on a public-facing controller action in a hot path (index pages, dashboards, API list endpoints)
- **P2** for admin pages, jobs (latency tolerated), and views rendered with small collections
- Always **P2 minimum** — even slow admin code rots over time

**When flagging, suggest:**

- The specific `.includes(...)` / `.preload(...)` call to add
- Where to add it (which controller line / which model scope)
- A verification step: run with `bullet` gem in dev or check `log/development.log` for repeated SELECTs

## strong-params-reviewer

Review controller actions for **strong parameters discipline**. Rails' strong parameters mechanism is the primary defense against mass-assignment vulnerabilities; bypassing it is a security gap.

**Core rules:**

1. Any `params[:resource]` passed to `.create`, `.update`, `.new`, or `assign_attributes` must go through `params.require(:resource).permit(...)` first.
2. The `.permit(...)` list must be EXPLICIT — no wildcard, no `.permit!`, no permitting arrays of every model attribute without justification.
3. Nested attributes (`accepts_nested_attributes_for`) must permit the nested attribute keys explicitly (`some_attrs: [:id, :name]`).

**What to flag:**

```ruby
# BAD — no permit at all (mass-assignment vulnerability)
User.create(params[:user])

# BAD — .permit! bypasses the whitelist entirely
def user_params
  params.require(:user).permit!
end

# BAD — permitting every column is no better than no permit
def user_params
  params.require(:user).permit(User.column_names)
end

# GOOD — explicit allowlist
def user_params
  params.require(:user).permit(:name, :email, :role)
end
```

**Severity guidance:**

- **P1** if the unpermitted assignment can set sensitive attributes (admin flags, ownership IDs, password digests, role columns)
- **P2** for unpermitted assignment on low-risk attributes (display names, optional bio fields) — still must be fixed but less urgent
- **P2** for `.permit!` and column-wildcard permits even when current attributes are benign — the surface grows with each new column

**Don't flag:**

- Controllers that use a service object / form object that does its own validation (cite the form object in the reply)
- Read-only actions (`index`, `show`) that don't pass params to AR writes
- Test fixtures that mass-assign in tests (test code is not a production attack surface)

**When flagging, suggest:**

- The explicit `permit(...)` call with the attribute list inferred from the model's `t.column` declarations
- For nested attrs: the nested key shape (`addresses_attributes: [:id, :street, :_destroy]`)

## migration-safety-reviewer

Review database migrations in `db/migrate/` for **deployability under zero-downtime constraints**. A migration that runs cleanly in development can still break production deploys when the app processes traffic mid-migration.

**Patterns to flag:**

### Adding a NOT NULL column without default → P1

```ruby
# BAD — instantly breaks any row INSERT from app code running on old schema
add_column :users, :status, :string, null: false

# GOOD (phase 1) — add nullable, backfill, then make NOT NULL in a later migration
add_column :users, :status, :string
```

For a follow-up phase-2 migration: backfill all NULL rows, then `change_column_null :users, :status, false`.

### Adding an indexed column to a large table inline → P2

`add_index` on a large table locks the table during creation in MySQL/PostgreSQL. Use `algorithm: :concurrently` on PostgreSQL (requires disabling the transaction):

```ruby
class AddIndexConcurrent < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!
  def change
    add_index :users, :email, algorithm: :concurrently
  end
end
```

### New foreign key column without index → P2

Any `add_reference` / `add_belongs_to` / `add_column ..., :integer` that names a FK column should include `index: true` or a follow-up `add_index`.

### Dropping a column still referenced by app code → P1

`remove_column` must be preceded (in a prior deploy) by removing all app code that reads/writes the column. Otherwise a rolling deploy hits ActiveRecord errors mid-cutover.

If the diff drops a column AND the same PR removes the last app-code reference, flag — these should be split across two deploys.

### Rename without alias → P1

`rename_column` breaks during the rolling deploy window. Use `alias_attribute :new_name, :old_name` in the model AND keep the old column for one deploy cycle, then drop in a later migration.

### Irreversible migrations without explicit `def up` / `def down` → P2

If `change` would not auto-reverse (data transformations, raw SQL), prefer explicit `up`/`down` or `reversible do |dir|` so `rails db:rollback` works.

**Don't flag:**

- Creating new tables (`create_table`) — no rollout risk because no code reads from them yet
- Adding nullable columns without defaults (safe)
- Index creation on small tables (locking is brief)
- Migrations marked `disable_ddl_transaction!` for the right reason (concurrent index)

**When flagging, suggest:**

- The specific phasing: "split into two migrations, deploy each separately"
- The model-level fallback (`alias_attribute`, default value in callback) for the rolling deploy window

## callback-overuse-reviewer

Review ActiveRecord models for **callback misuse** — when too much business logic lives in `before_*` / `after_*` hooks, it becomes hard to test, hard to disable, and creates implicit coupling across models.

**Patterns to flag:**

### Callbacks that touch other models → P2

```ruby
# BAD — Order#after_create reaches into User
class Order < ApplicationRecord
  belongs_to :user
  after_create :send_confirmation_email
  after_create :credit_loyalty_points  # writes to User

  private
  def credit_loyalty_points
    user.update!(loyalty_points: user.loyalty_points + amount)  # ← coupling
  end
end
```

Suggest: extract to a service object or background job (`CreditLoyaltyPointsJob.perform_later(self)`).

### `before_save` for non-validation business logic → P2

```ruby
# BAD — business logic in a before_save means you can't test the save in isolation
before_save :charge_customer_card  # external API call

# GOOD — explicit method call from the controller / service
def save_and_charge!
  return false unless save
  CardCharger.charge!(self)
end
```

### Too many callbacks on the same model → P2

If a model has 4+ callbacks (especially mixing `before_validation`, `before_save`, `after_create`, `after_commit`), the save sequence becomes opaque. Flag and suggest consolidating into a service object or breaking the model down.

### `after_commit` on `:destroy` without `unless: -> { destroyed_by_association? }` → P2

Cascading destroys trigger after_commit hooks that may try to access already-destroyed associations.

**Don't flag:**

- Validations (`validate :method_name`) — that IS the intended callback use
- `before_validation` for data normalization (downcase email, strip whitespace) — appropriate use
- `after_create_commit` queueing a background job (light coupling, async)
- Touching `updated_at` via `touch:` on a belongs_to (Rails idiom)

**When flagging, suggest:**

- The specific extraction target (service object, job, controller action)
- A test that would have caught this implicit coupling

## mass-assignment-reviewer

Review controllers, services, and interactors for **mass-assignment patterns that bypass strong parameters**. Complements strong-params-reviewer by catching the cases where params have been laundered through intermediate hashes.

**Patterns to flag:**

```ruby
# BAD — params merged into a hash, then mass-assigned (bypasses strong params)
attrs = params[:user].to_h.merge(role: 'guest')
User.create(attrs)

# BAD — Service object accepting a raw hash from params
class UserCreator
  def call(attrs)
    User.create(attrs)  # ← no permit, no whitelist
  end
end
UserCreator.new.call(params[:user].to_unsafe_h)

# BAD — `attributes=` from a hash that includes params
@user.attributes = some_safe_attrs.merge(params[:user])
```

**What to flag:**

- Any path from `params` to a model write that does not go through `.permit(...)`
- `.to_unsafe_h` followed by a model write
- Service/interactor signatures that accept a raw hash from controllers (force them to take typed arguments instead)

**Severity guidance:**

- **P1** if the bypass can set sensitive attributes (role, owner_id, admin, etc.)
- **P2** otherwise

**Don't flag:**

- `params.to_unsafe_h` used for logging or comparison (no model write)
- Hashes constructed entirely from named arguments (no `params` involvement)
- Service objects taking typed keyword arguments (`def call(name:, email:)`) — those are safe

**When flagging, suggest:**

- Refactor the service to accept named arguments
- Add an explicit `.permit(...)` call at the controller boundary
- For the merge pattern: build the safe hash AFTER `.permit`, never before

## route-bloat-reviewer

Review `config/routes.rb` for **over-broad route declarations** that expose more endpoints than the app implements.

**Patterns to flag:**

```ruby
# BAD — declares 7 routes (index, show, new, create, edit, update, destroy)
# even though PostsController only implements index and show
resources :posts

# GOOD — explicit scope matches what's implemented
resources :posts, only: [:index, :show]
```

**What to flag:**

- `resources :foo` (or `resource :foo`) without `only:` / `except:` when the matching controller doesn't implement all 7 (or all 4 for singular) RESTful actions
- Nested `resources` that go more than 1 level deep (`/posts/1/comments/2/replies/3`) — usually a smell; suggest flattening
- Wildcard route catch-alls (`match '*path'`) without auth/throttling — security surface
- Duplicate routes (the same path declared twice with different constraints) — order-dependent, fragile

**Don't flag:**

- `resources :foo` where the controller does implement all actions (verify by reading the controller file)
- `member do` / `collection do` blocks adding custom actions — appropriate when the action is genuinely RESTful
- `mount EngineName => '/path'` — engine mounting, not a route declaration

**When flagging, suggest:**

- The exact `only:` / `except:` array based on the controller's defined actions
- For deep nesting: flatten to shallow nesting (`shallow: true`) or split into separate top-level resources

## clarity-reviewer

Review markdown documentation and Ruby comments for **terseness, factual accuracy, and reflection-of-code-truth**. Every token costs money and attention — cut the fat.

**What to check:**

1. PR diff for changes to `.md` files (README, docs) and Ruby files (comments/docstrings)
2. Comments in Ruby that no longer match the code they document (rot)
3. Method names that lie about their behavior (`save_user` that does much more than save)
4. README sections referencing removed gems, deprecated commands, or stale schema shapes

**Flag issues if:**

- A sentence can be cut in half without losing meaning
- A comment restates what the method name already says (`# saves the user` above `def save_user`)
- A docstring references a parameter the method no longer takes
- A README section walks through a workflow that no longer matches the code

**Do NOT flag:**

- Comments documenting non-obvious design decisions (why this is unrescued, why this loop can't use parallel processing)
- README examples that work as written
- Module/class-level doc-blocks that explain the abstraction's purpose
- Deliberate repetition of critical rules (security warnings, gotchas)

**When flagging, provide:**

- The verbose / stale text
- A terse / corrected replacement
- Brief reason if not obvious
