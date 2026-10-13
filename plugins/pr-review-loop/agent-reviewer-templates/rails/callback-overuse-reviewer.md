# callback-overuse-reviewer
**Checks:** ActiveRecord callbacks that hit other models, hold business logic in before_save, pile up (4+), or use after_commit on destroy without destroyed_by_association?
**Spawn when:** Diff changes app/models/*.rb and adds or edits before_/after_ callbacks (before_save, after_create, after_commit...). Skip models with no callback changes.
**Contents:** Patterns to flag · Callbacks that touch other models → P2 · `before_save` for non-validation business logic → P2 · Too many callbacks on the same model → P2 · `after_commit` on `:destroy` without `unless: -> { destroyed_by_association? }` → P2 · Don't flag · When flagging, suggest

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
