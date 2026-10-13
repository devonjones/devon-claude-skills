# migration-safety-reviewer
**Checks:** Zero-downtime migration hazards: NOT NULL without default, non-concurrent index, FK without index, remove/rename_column in use, irreversible change
**Spawn when:** Diff adds or edits files in db/migrate/. Skip diffs with no migration files.
**Contents:** Patterns to flag · Adding a NOT NULL column without default → P1 · Adding an indexed column to a large table inline → P2 · New foreign key column without index → P2 · Dropping a column still referenced by app code → P1 · Rename without alias → P1 · Irreversible migrations without explicit `def up` / `def down` → P2 · Don't flag · When flagging, suggest

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
