# mass-assignment-reviewer
**Checks:** Paths from params to a model write that bypass .permit: to_unsafe_h then create/update, params merged into hashes, services taking raw hashes
**Spawn when:** Diff touches app/controllers, app/services, or app/interactors and passes params, to_unsafe_h, or a raw attrs hash into create/update/new/attributes=.
**Contents:** Patterns to flag · What to flag · Severity guidance · Don't flag · When flagging, suggest

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
