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
#   - Track `in_fence` for ANY fenced code block (not just the json one) so
#     `^# ` lines inside narrative-example fences don't falsely close the
#     Configuration section before the json block is reached.
#   - On `# Configuration` (outside fences), enter configuration section.
#   - On any other `# ` (outside fences), leave configuration section.
#   - Inside configuration section, when we see ```json, capture lines
#     until the next ``` (which is the closing of the json fence).
RAW_JSON="$(awk '
    BEGIN { in_config = 0; in_fence = 0; in_json = 0 }
    # Track every fence open/close so heading detection stays accurate even
    # when prose preceding the json block contains fenced `^# ` examples.
    /^```/ {
        # Close the captured json fence.
        if (in_json && /^```[[:space:]]*$/) {
            in_json = 0
            in_fence = 0
            in_config = 0
            exit
        }
        # Opening the json fence inside the Configuration section.
        if (in_config && !in_fence && /^```json[[:space:]]*$/) {
            in_fence = 1
            in_json = 1
            next
        }
        # Any other fence: just toggle the generic tracker.
        in_fence = !in_fence
        next
    }
    !in_fence && /^#[[:space:]]+Configuration[[:space:]]*$/ { in_config = 1; next }
    # Any other H1 (outside fences) ends the Configuration section.
    !in_fence && /^#[[:space:]]+/ { in_config = 0 }
    in_json { print }
' "$FILE")"

if [[ -z "$RAW_JSON" ]]; then
    echo "{}"
    exit 0
fi

# Validate JSON shape via jq. If parse fails, capture the actual jq error so
# the user can see WHERE the malformed JSON is, then fall back to {} so the
# loop can proceed. The `if !` form suppresses `set -e` abort so the
# diagnostic surfaces instead of the script crashing.
if ! JQ_PARSE_ERR="$(printf '%s\n' "$RAW_JSON" | jq -e . 2>&1 > /dev/null)"; then
    echo "Warning: # Configuration section in $FILE contains invalid JSON: $JQ_PARSE_ERR" >&2
    echo "{}"
    exit 0
fi

# Warn on unknown top-level keys. The schema is closed: a typo like
# "diabled" instead of "disabled" would otherwise be silently dropped.
# Allowed keys are documented in SKILL.md's "# Configuration" section.
UNKNOWN_KEYS="$(printf '%s\n' "$RAW_JSON" | jq -r '
    [keys[] | select(
        . != "defaults_version_checked"
        and . != "disabled"
        and . != "overlap_acknowledged"
        and . != "independent_validator"
    )]
    | join(", ")
')"
if [[ -n "$UNKNOWN_KEYS" ]]; then
    echo "Warning: # Configuration in $FILE has unknown top-level keys (likely typos): $UNKNOWN_KEYS" >&2
    echo "Warning:   Allowed keys: defaults_version_checked, disabled, overlap_acknowledged, independent_validator" >&2
fi

# Validate overlap_acknowledged entries have a non-empty `reason`.
# bd memory bfd-design-locked: reason is REQUIRED.
# Treat null, missing, and "" all as invalid.
INVALID_ENTRIES="$(printf '%s\n' "$RAW_JSON" | jq -r '
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

# Validate independent_validator block (per bd memory ydy-design-locked).
# Allowed shape:
#   { enabled: bool, skip_for: [str], uncertain_action: enum }
# Allowed uncertain_action values: post_with_annotation | post_silently | drop
# Reject when the block is non-object; warn on unknown nested keys (typos
# like `enabld` would otherwise be silently dropped).
#
# Use `select(has("X"))` instead of `// empty` to avoid false-as-falsy bug:
# `.x.y // empty` swallows null AND false, letting an explicit `enabled: false`
# bypass the boolean type check. has() distinguishes "key absent" from "key
# present with value false". Also use `printf '%s\n'` instead of `echo` to
# pipe $RAW_JSON safely (echo can mis-handle backslashes / leading hyphens).
IV_TYPE="$(printf '%s\n' "$RAW_JSON" | jq -r '
    if has("independent_validator") then .independent_validator | type else empty end
')"
if [[ -n "$IV_TYPE" && "$IV_TYPE" != "object" ]]; then
    echo "Error: # Configuration .independent_validator in $FILE must be an object (got $IV_TYPE)" >&2
    exit 1
fi
IV_UNKNOWN_KEYS="$(printf '%s\n' "$RAW_JSON" | jq -r '
    .independent_validator | select(type == "object")
    | [keys[] | select(
        . != "enabled" and . != "skip_for" and . != "uncertain_action"
    )] | join(", ")
')"
if [[ -n "$IV_UNKNOWN_KEYS" ]]; then
    echo "Warning: # Configuration .independent_validator in $FILE has unknown nested keys (likely typos): $IV_UNKNOWN_KEYS" >&2
    echo "Warning:   Allowed nested keys: enabled, skip_for, uncertain_action" >&2
fi

# Validate enum on uncertain_action when present.
IV_BAD_ACTION="$(printf '%s\n' "$RAW_JSON" | jq -r '
    .independent_validator | select(type == "object" and has("uncertain_action"))
    | .uncertain_action
    | select(. != "post_with_annotation" and . != "post_silently" and . != "drop")
    | tojson
')"
if [[ -n "$IV_BAD_ACTION" ]]; then
    echo "Error: # Configuration .independent_validator.uncertain_action in $FILE has invalid value $IV_BAD_ACTION" >&2
    echo "Error:   Allowed values: post_with_annotation, post_silently, drop" >&2
    exit 1
fi

# Validate enabled is boolean when present.
IV_BAD_ENABLED="$(printf '%s\n' "$RAW_JSON" | jq -r '
    .independent_validator | select(type == "object" and has("enabled"))
    | .enabled
    | select(type != "boolean")
    | tojson
')"
if [[ -n "$IV_BAD_ENABLED" ]]; then
    echo "Error: # Configuration .independent_validator.enabled in $FILE must be a boolean (got $IV_BAD_ENABLED)" >&2
    exit 1
fi

# Validate skip_for is array of strings when present.
IV_BAD_SKIP="$(printf '%s\n' "$RAW_JSON" | jq -r '
    .independent_validator | select(type == "object" and has("skip_for"))
    | .skip_for
    | if type != "array" then "must be an array (got " + (type) + ")"
      elif any(.[]; type != "string") then "must be an array of strings (got non-string entry)"
      else empty end
')"
if [[ -n "$IV_BAD_SKIP" ]]; then
    echo "Error: # Configuration .independent_validator.skip_for in $FILE: $IV_BAD_SKIP" >&2
    exit 1
fi

printf '%s\n' "$RAW_JSON" | jq -c .
