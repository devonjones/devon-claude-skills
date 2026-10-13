# Guidelines

This is a Claude Code skills marketplace repository. When reviewing PRs:

- Skills must be self-contained within their plugin directory
- All shell scripts must use `set -euo pipefail`
- Error messages must go to stderr (`>&2`)
- Scripts should handle both success and failure cases gracefully
- New dependencies require installation instructions in SKILL.md
- SKILL.md and `references/*.md` files are **agent instruction documents**, not traditional code — evaluate for agent clarity and accuracy
- Before asserting a factual claim is wrong (software version, API endpoint), verify it — training data may be stale
- Check prior review comments and responses before re-raising the same issue — if a "Won't fix" response has sound reasoning, do not repeat the concern
- If a `.beads/` directory exists, check its contents before flagging pre-existing issues as immediate demands
