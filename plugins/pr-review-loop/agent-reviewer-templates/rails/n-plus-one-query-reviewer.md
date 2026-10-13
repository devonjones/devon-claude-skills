# n-plus-one-query-reviewer
**Checks:** N+1 queries: loops over ActiveRecord relations or collection partials that touch associations not eager-loaded, missed counter caches, per-element queries
**Spawn when:** Diff touches Rails controllers, views/partials, jobs, or mailers that iterate (each/map/select/render collection) over relations. Skip diffs with no iteration over records.
**Contents:** What to flag · Do NOT flag · Severity guidance · When flagging, suggest

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
