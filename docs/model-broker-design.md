# Model broker for Pi reviewers

Bead: `devon-claude-skills-jjn`. Status: design, decisions settled by Devon on
2026-10-19.

## Problem

Flat-rate plans (Z.ai GLM, Qwen Token Plan, Claude) lose any quota still unused
when their period resets. Today `pi-review.sh` runs each agent's chain in the
order it was configured. The one exception is Z.ai, which gets moved to the
front while its weekly window is behind pace and skipped altogether at 90% of
any window (`PI_REVIEW_PLAN_CAP`). Devon has called the 90% skip wrong: the
reviews should go out even if that means paying overage. Qwen and Claude have
no pacing at all.

## Decisions

| | Question | Decision |
|---|---|---|
| a | Scope | Reviewers only. The broker lives inside `pi-review.sh`; we split it out only if another tool needs it. |
| b | Where suitability lives | Per user in `~/.config/pr-review-loop/models.json`. A repo's `.reviewers/config.json` `.pi.agents` overrides it per agent. |
| c | A plan past its quota (Qwen in particular) | Keep using it and pay the overage: Qwen stays in the chain at paid rates once its quota is gone, and so does Z.ai. A plan is never skipped for being full; it only drops behind plans that still have quota. The exhausted-TTL fallthrough still applies only when the provider itself rejects a request. |
| d | Judging suitability | `eval-reviewer.sh` replays now. Planted-bug test PRs later (bead `ua1`). |

## Design

### 1. Suitability: which models may run each agent

An agent's chain lists the models that passed `eval-reviewer.sh` for that
agent, plus `claude` / `claude:<model>`. The chain decides whether a model is
used at all. The broker only changes the order.

- **User default:** `~/.config/pr-review-loop/models.json`.
  ```json
  {
    "agents": {
      "*":            ["zai/glm-4.6", "qwen-token-plan/qwen3.8-max", "claude"],
      "code-reviewer": ["zai/glm-4.6", "claude:sonnet"]
    },
    "plans": {
      "zai":    {"models": "^zai/",    "reader": "zai"},
      "qwen":   {"models": "^qwen-token-plan/", "reader": "qwen"},
      "claude": {"models": "^claude(:|$)", "reader": "claude", "shared": true}
    }
  }
  ```
  `"*"` is the chain for any agent that isn't listed. A model that matches no
  plan is pay-per-token.
- **Repo override:** `.reviewers/config.json` `.pi.agents.<agent>` (the format
  that exists today), `true`, `false` or `.pi.all` overrides the user's entry
  for that agent.
- `eval-reviewer.sh assign` takes `--user` and writes `agents` into the user
  file. Without the flag it prints the repo block, as it does today.
- `discover-agents.sh` resolves each agent the same way every time:
  - The repo decides first when it names the agent or routes everything:
    - its `.pi.agents.<agent>` chain is used as is;
    - `true`, or `.pi.all` with no entry for the agent, means the repo's
      `.pi.model`;
    - `false` keeps the agent on Claude.
  - Otherwise the user's `agents.<agent>` decides, then the user's
    `agents."*"`. A user `false` keeps the agent on Claude.

  A user chain routes the agent to Pi in every repo. The result is emitted as
  `pi_models`, and the output shape doesn't change.

### 2. Plan state: readers

Each reader prints `{"used": 0..1, "elapsed": 0..1}` for the plan's **longest**
window, or `{}` when the plan can't be read. The longest window is the one
whose unused quota is lost at reset. A short window that fills up is handled
by the existing fallthrough: the provider rejects the request and the
exhausted-TTL cache skips that provider.

Results are cached for 5 minutes in `$PI_REVIEW_CACHE_DIR/quota/<plan>.json`,
as `zai_quota` does now.

| Reader | Source | Notes |
|---|---|---|
| `zai` | `GET api.z.ai/api/monitor/usage/quota/limit`, key on stdin | Existing code. Unit 6 = weekly window. |
| `qwen` | `bl auth status` then `bl usage token-plan --output json` | `per1MonthPercentage` is a ratio. `per1MonthResetTime` is epoch ms. A lapsed login gives `{}` and a warning to run `bl auth login --console`. |
| `claude` | openusage export (`seven_day` used and reset) | Waiting on herdr-athena for a stable interface. Until it lands, the reader returns `{}`. |

### 3. Ordering

For each model, `slack = elapsed - used` on its plan. Positive slack means the
plan is behind pace and holding quota that will go to waste. Pay-per-token
models and unreadable plans get `slack = 0`. The chain is then stable-sorted by:

1. A `shared` plan (Claude is shared with interactive work) goes last unless
   its slack is greater than 0.25.
2. Higher slack first.
3. Original chain order.

Nothing is ever removed from the chain (decision c). A plan past 100% simply
sorts behind every plan that still has quota. `PI_REVIEW_PLAN_CAP` and
`near_cap` are deleted.

Until the Claude reader lands, only the part of the chain before its first
`claude` entry is sorted. Nothing after that entry runs anyway, because reaching
it hands the review to the Claude Task.

`pi-review.sh` logs a reorder to stderr. The `reviewer-fired` dream marker's
`tried=` already records the order the models were tried in.

### 4. Tests

- An ordering table: fixture readings, then the expected order. Cases cover a
  behind plan going first, Claude staying last at small slack and moving up at
  large slack, an unreadable plan holding its place, and a plan over 100%
  staying in the chain.
- Each reader against a canned response, including an auth or API failure
  returning `{}`.
- Chain resolution: repo overrides user, a named agent overrides `"*"`, and
  `.pi.model` is the fallback.

## Rollout

1. Readers and ordering in `pi-review.sh`, then delete the plan cap. Shippable
   without the Claude reader.
2. User `models.json`, resolution in `discover-agents.sh`, and
   `eval-reviewer.sh assign --user`.
3. The Claude reader, once herdr-athena publishes the openusage interface.

## Not doing

- A broker service shared across tools (decision a).
- Predicting per-review token cost from slack. Ordering by slack is enough
  while plans refill on fixed windows.
