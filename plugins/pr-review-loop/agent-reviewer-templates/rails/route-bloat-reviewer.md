# route-bloat-reviewer
verification: mixed — missing only:/except: is proven by reading the controller's defined actions (evidence-query); nesting, wildcard and duplicate routes are judgement.
**Checks:** Over-broad routes: resources without only:/except: beyond implemented actions, nesting over 1 level, unguarded wildcard catch-alls, duplicate routes
**Spawn when:** Diff modifies config/routes.rb. Skip all other diffs.
**Contents:** Patterns to flag · What to flag · Don't flag · When flagging, suggest

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
