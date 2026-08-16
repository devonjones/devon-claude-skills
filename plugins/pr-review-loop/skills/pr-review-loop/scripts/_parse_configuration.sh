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
# Usage: _parse_configuration.sh <path-to-AGENT-REVIEWERS.md> [--bots-only <bot-name>]
#
# --bots-only answers the narrow question "is this bot on?" (bot-enabled.sh)
# rather than "is this whole config sound?" (the pre-loop check). Only failures
# that make the answer untrustworthy are fatal: a broken `overlap_acknowledged`
# entry, or another bot's non-boolean value, can't discard a perfectly readable
# `bots.gemini: false` and silently switch the bot back on. Warnings that DO
# bear on the answer — unknown top-level keys (a misspelled `bots`), unknown bot
# names, dropped entries — still print. It also treats an unreadable config as a
# hard failure (exit 1) instead of degrading to `{}`, because for this caller
# "I couldn't read your config" and "your config says the bot is on" are not the
# same answer.
#
# Name the bot you're asking about: without it, an unreadable value for THAT bot
# degrades to the softer warn-and-continue path instead of a hard failure.

set -euo pipefail

FILE="${1:?Usage: _parse_configuration.sh <path-to-AGENT-REVIEWERS.md> [--bots-only <bot-name>]}"
BOTS_ONLY=false
# The bot the caller is actually asking about, when it named one. Entries for
# OTHER bots can be dropped when unreadable; this one cannot — "I can't read
# your setting for gemini" must not come back as "gemini is on".
BOTS_ONLY_FOR=""
case "${2:-}" in
    "")          ;;
    --bots-only) BOTS_ONLY=true; BOTS_ONLY_FOR="${3:-}" ;;
    # Silently ignoring a typo'd flag would fall back to full-config gating —
    # the exact behavior --bots-only exists to prevent.
    *) echo "Error: unknown argument '$2' (expected --bots-only)" >&2; exit 1 ;;
esac

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
    END {
        # Defensive: warn on malformed input. `in_fence == 1` at EOF covers
        # two cases:
        #   (a) the json fence opened and never closed — RAW_JSON contains
        #       partial json and the downstream jq parse fails with a less
        #       obvious error
        #   (b) a non-json prose fence opened and never closed — RAW_JSON
        #       is empty and the wrapper silently returns `{}` (see the
        #       `[[ -z "$RAW_JSON" ]]` branch below)
        # Case (b) is the silent-config-loss failure mode the warning makes
        # visible. Case (a) just makes the existing jq error easier to read.
        if (in_fence) {
            print "Warning: unclosed code fence in " FILENAME > "/dev/stderr"
        }
    }
' "$FILE")"

if [[ -z "$RAW_JSON" ]]; then
    # "No # Configuration section at all" is a legitimate empty config. "The
    # user clearly meant to write one and it didn't parse" is not — under
    # --bots-only that would silently report a disabled bot as enabled.
    #
    # This pattern is deliberately LOOSER than the awk's heading rule above:
    # matching it exactly would only ever fire for headings the awk already
    # accepted, so every heading-shape mistake (`## Configuration`,
    # `# Configuration:`, an indented heading) would sail past into the silent
    # default. Anything heading-shaped enough to signal intent lands on the
    # loud path instead.
    # The warning is unconditional: in full-config mode an unread section means
    # discover-agents.sh silently ignores the user's `disabled` list and runs
    # reviewers they retired, which deserves a diagnostic just as much. Only the
    # hard failure is mode-gated, since the pre-loop check has to keep going.
    if grep -qiE '^[[:space:]]*#{1,6}[[:space:]]*Configuration[[:space:]]*:?[[:space:]]*$' "$FILE"; then
        echo "Warning: $FILE looks like it has a # Configuration section, but no json block could be read from it." >&2
        echo "Warning:   Expected an H1 '# Configuration' heading followed by a closed, lowercase \`\`\`json fence." >&2
        if [[ "$BOTS_ONLY" == "true" ]]; then
            exit 1
        fi
    fi
    echo "{}"
    exit 0
fi

# Validate JSON shape via jq. If parse fails, capture the actual jq error so
# the user can see WHERE the malformed JSON is, then fall back to {} so the
# loop can proceed. The `if !` form suppresses `set -e` abort so the
# diagnostic surfaces instead of the script crashing.
#
# `-s` is load-bearing: bare `jq -e .` accepts a JSON *stream*, so a block
# holding two top-level objects (a forgotten closing fence between two ```json
# blocks leaves every fence balanced, so the awk never warns) validates fine and
# then gets re-emitted as two documents. Downstream, `.bots.gemini` yields one
# line per document and a `== "false"` comparison against "false\ntrue" quietly
# fails — a disabled bot switching itself back on with nothing on stderr.
if ! JQ_PARSE_ERR="$(printf '%s\n' "$RAW_JSON" | jq -se '
    if length == 1 and (.[0] | type) == "object" then .[0]
    elif length != 1 then error("expected one top-level JSON object, got \(length)")
    else error("top-level value must be an object, got \(.[0] | type)") end
' 2>&1 > /dev/null)"; then
    echo "Warning: # Configuration section in $FILE contains invalid JSON: $JQ_PARSE_ERR" >&2
    if [[ "$BOTS_ONLY" == "true" ]]; then
        exit 1
    fi
    echo "{}"
    exit 0
fi
# Normalize to that single document so every filter below sees one object.
RAW_JSON="$(printf '%s\n' "$RAW_JSON" | jq -sc '.[0]')"

# Warn on unknown top-level keys. The schema is closed: a typo like
# "diabled" instead of "disabled" would otherwise be silently dropped.
# Allowed keys are documented in SKILL.md's "# Configuration" section.
UNKNOWN_KEYS="$(printf '%s\n' "$RAW_JSON" | jq -r '
    [keys[] | select(
        . != "defaults_version_checked"
        and . != "disabled"
        and . != "overlap_acknowledged"
        and . != "independent_validator"
        and . != "bots"
    )]
    | join(", ")
')"
# Not suppressed under --bots-only, even though it repeats per bot per script: a
# misspelled `bots` key ("bot", "Bots") is invisible to the .bots-name check
# below, so this warning is the only signal that an off switch didn't take.
if [[ -n "$UNKNOWN_KEYS" ]]; then
    echo "Warning: # Configuration in $FILE has unknown top-level keys (likely typos): $UNKNOWN_KEYS" >&2
    echo "Warning:   Allowed keys: defaults_version_checked, disabled, overlap_acknowledged, independent_validator, bots" >&2
fi

# Validate the `bots` block: map of KNOWN bot name -> boolean. Bots default to
# enabled, so both a mistyped value (`"false"` as a string) and a mistyped key
# (`gemni`) would leave the bot running while the user believes they turned it
# off. Unknown names are a warning, matching how the `disabled` list treats
# names that match no known reviewer.

# A non-object `bots` is unrecoverable in both modes: there are no per-bot
# settings to salvage, so no answer about any bot can be trusted.
BOTS_TYPE_BAD="$(printf '%s\n' "$RAW_JSON" | jq -r '
    if has("bots") and (.bots | type) != "object"
        then "must be an object (got " + (.bots | type) + ")"
        else empty end
')"
if [[ -n "$BOTS_TYPE_BAD" ]]; then
    echo "Error: # Configuration .bots in $FILE: $BOTS_TYPE_BAD" >&2
    exit 1
fi

# Non-boolean VALUES are per-entry, so they're a hard error only for the
# config-wide check. Under --bots-only, failing the whole map would let one
# bot's typo (`"cursor": "no"`) discard another's perfectly readable
# `"gemini": false` and quietly switch Gemini back on — the same
# unrelated-entry-defeats-the-off-switch shape as the block-level fix above.
# Drop the unreadable entries instead, loudly, and answer from the rest.
BOTS_BAD="$(printf '%s\n' "$RAW_JSON" | jq -r '
    (.bots // {}) | to_entries | map(select(.value | type != "boolean")) | map(.key) | join(", ")
')"
if [[ -n "$BOTS_BAD" ]]; then
    if [[ "$BOTS_ONLY" == "true" ]]; then
        # ...unless the unreadable entry IS the bot being asked about, in which
        # case there is no readable answer to give and exit 0 would be a lie.
        # The membership test runs in jq against the real keys: string-munging
        # the joined list would conflate a key like "gemini " with "gemini".
        ASKED_BAD="$(printf '%s\n' "$RAW_JSON" | jq -r --arg b "$BOTS_ONLY_FOR" '
            if $b != "" and ((.bots // {}) | has($b)) and ((.bots[$b] | type) != "boolean")
                then "yes" else "" end
        ')"
        if [[ -n "$ASKED_BAD" ]]; then
            echo "Error: # Configuration .bots.$BOTS_ONLY_FOR in $FILE is not a boolean" >&2
            exit 1
        fi
        # No filtering of the emitted map: a dropped entry and a non-boolean one
        # both read as "not false" at the lookup, so stripping them changes
        # nothing observable. The warning is the whole point.
        echo "Warning: # Configuration .bots in $FILE: values must be booleans: $BOTS_BAD" >&2
        echo "Warning:   Ignoring those entries; the bots they name stay enabled." >&2
    else
        echo "Error: # Configuration .bots in $FILE: values must be booleans: $BOTS_BAD" >&2
        exit 1
    fi
fi

# Known external review bots. Keep in sync with SKILL.md "Supported Review Bots"
# and the `--gemini` / `--cursor` flags in trigger-review.sh.
BOTS_UNKNOWN="$(printf '%s\n' "$RAW_JSON" | jq -r '
    .bots | select(type == "object")
    | [keys[] | select(. != "gemini" and . != "cursor")] | join(", ")
')"
if [[ -n "$BOTS_UNKNOWN" ]]; then
    echo "Warning: # Configuration .bots in $FILE names unknown bots (likely typos): $BOTS_UNKNOWN" >&2
    echo "Warning:   Known bots: gemini, cursor. Unknown names have no effect — the bot stays enabled." >&2
fi

# --bots-only stops here: the `bots` block is validated, and the remaining
# checks belong to config-wide soundness, not to "is this bot on?". Letting
# them fail here would throw away a readable bots block over an unrelated typo.
if [[ "$BOTS_ONLY" == "true" ]]; then
    printf '%s\n' "$RAW_JSON" | jq -c .
    exit 0
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
