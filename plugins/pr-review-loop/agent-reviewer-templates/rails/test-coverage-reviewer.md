# test-coverage-reviewer
**Checks:** Changed app/**/*.rb (controllers, models, jobs, mailers, services, helpers) with no matching test/ or spec/ change; untested public methods, bug fixes, scopes, routes
**Spawn when:** Diff modifies app/**/*.rb. Skip view-only, config, schema, formatting/comment-only, or attr_accessor-only changes.
**Contents:** Rails-specific placement rules · What to flag · Do NOT flag · Acceptable substitutes

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
