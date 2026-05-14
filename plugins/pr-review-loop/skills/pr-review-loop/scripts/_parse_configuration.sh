#!/usr/bin/env bash
# Parse the # Configuration section out of an AGENT-REVIEWERS.md file.
# The section must contain a fenced ```json code block; only the JSON
# inside is parsed and emitted.
#
# Expected layout:
#
#   # Configuration
#
#   ```json
#   {
#     "defaults_version_checked": "1.2.0",
#     "disabled": ["pr-test-analyzer"],
#     "overlap_acknowledged": {
#       "my_pci_auditor": {
#         "overlaps_with": "security-reviewer",
#         "reason": "PCI-specific scope"
#       }
#     }
#   }
#   ```
#
# Output: validated JSON on stdout, or `{}` if no # Configuration section
# or no JSON block found.
#
# Validation: rejects overlap_acknowledged entries missing a non-empty
# `reason` field (per bd memory bfd-design-locked) — error to stderr,
# exit non-zero.
#
# Usage: _parse_configuration.sh <path-to-AGENT-REVIEWERS.md>

set -euo pipefail

FILE="${1:?Usage: _parse_configuration.sh <path-to-AGENT-REVIEWERS.md>}"

if [[ ! -f "$FILE" ]]; then
    echo "{}"
    exit 0
fi

# Extract the fenced JSON block within the # Configuration H1 section.
# Logic:
#   - On `# Configuration`, enter configuration section
#   - On any other `# `, leave configuration section
#   - Inside configuration section, when we see ```json, capture lines
#     until the closing ```
RAW_JSON="$(awk '
    BEGIN { in_config = 0; in_fence = 0 }
    /^# Configuration[[:space:]]*$/ { in_config = 1; next }
    # Any other H1 ends the Configuration section.
    /^# / { in_config = 0 }
    in_config && /^```json[[:space:]]*$/ { in_fence = 1; next }
    in_config && in_fence && /^```[[:space:]]*$/ { in_fence = 0; in_config = 0; exit }
    in_config && in_fence { print }
' "$FILE")"

if [[ -z "$RAW_JSON" ]]; then
    echo "{}"
    exit 0
fi

# Validate JSON shape via jq. If parse fails, capture the actual jq error so
# the user can see WHERE the malformed JSON is, then fall back to {} so the
# loop can proceed. The `if !` form suppresses `set -e` abort so the
# diagnostic surfaces instead of the script crashing.
if ! JQ_PARSE_ERR="$(echo "$RAW_JSON" | jq -e . 2>&1 > /dev/null)"; then
    echo "Warning: # Configuration section in $FILE contains invalid JSON: $JQ_PARSE_ERR" >&2
    echo "{}"
    exit 0
fi

# Warn on unknown top-level keys. The schema is closed: a typo like
# "diabled" instead of "disabled" would otherwise be silently dropped.
# Allowed keys are documented in SKILL.md's "# Configuration" section.
UNKNOWN_KEYS="$(echo "$RAW_JSON" | jq -r '
    [keys[] | select(. != "defaults_version_checked" and . != "disabled" and . != "overlap_acknowledged")]
    | join(", ")
')"
if [[ -n "$UNKNOWN_KEYS" ]]; then
    echo "Warning: # Configuration in $FILE has unknown top-level keys (likely typos): $UNKNOWN_KEYS" >&2
    echo "Warning:   Allowed keys: defaults_version_checked, disabled, overlap_acknowledged" >&2
fi

# Validate overlap_acknowledged entries have a non-empty `reason`.
# bd memory bfd-design-locked: reason is REQUIRED.
# Treat null, missing, and "" all as invalid.
INVALID_ENTRIES="$(echo "$RAW_JSON" | jq -r '
    .overlap_acknowledged // {}
    | to_entries
    | map(select((.value.reason // "") | length == 0))
    | map(.key)
    | join(", ")
')"

if [[ -n "$INVALID_ENTRIES" ]]; then
    echo "Error: overlap_acknowledged entries missing required 'reason' field in $FILE: $INVALID_ENTRIES" >&2
    exit 1
fi

echo "$RAW_JSON" | jq -c .
