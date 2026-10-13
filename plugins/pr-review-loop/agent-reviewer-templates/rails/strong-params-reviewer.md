# strong-params-reviewer
**Checks:** Controller params reaching create/update/new/assign_attributes without require().permit(), permit!, column-wildcard permits, unpermitted nested attributes
**Spawn when:** Diff touches app/controllers/*.rb and uses params with create/update/new/assign_attributes or edits a *_params method. Skip read-only actions.
**Contents:** Core rules · What to flag · Severity guidance · Don't flag · When flagging, suggest

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
