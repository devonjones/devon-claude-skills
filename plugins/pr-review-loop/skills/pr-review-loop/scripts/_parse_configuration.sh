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
    /^# / && !/^# Configuration[[:space:]]*$/ { in_config = 0 }
    in_config && /^```json[[:space:]]*$/ { in_fence = 1; next }
    in_config && in_fence && /^```[[:space:]]*$/ { in_fence = 0; in_config = 0; exit }
    in_config && in_fence { print }
' "$FILE")"

if [[ -z "$RAW_JSON" ]]; then
    echo "{}"
    exit 0
fi

# Validate JSON shape via jq. If parse fails, surface error + return {} so
# the loop can proceed (but emit a warning to stderr).
if ! echo "$RAW_JSON" | jq -e . > /dev/null 2>&1; then
    echo "Warning: # Configuration section in $FILE contains invalid JSON" >&2
    echo "{}"
    exit 0
fi

# Validate overlap_acknowledged entries have a non-empty `reason`.
# bd memory bfd-design-locked: reason is REQUIRED.
INVALID_ENTRIES="$(echo "$RAW_JSON" | jq -r '
    .overlap_acknowledged // {}
    | to_entries
    | map(select(.value.reason == null or .value.reason == ""))
    | map(.key)
    | join(", ")
')"

if [[ -n "$INVALID_ENTRIES" ]]; then
    echo "Error: overlap_acknowledged entries missing required 'reason' field in $FILE: $INVALID_ENTRIES" >&2
    exit 1
fi

echo "$RAW_JSON" | jq -c .
