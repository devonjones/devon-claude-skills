#!/usr/bin/env bash
# Install language-specific AGENT-REVIEWERS.md templates into a repository.
#
# Given one or more <language>:<subtree> pairs, copies the matching templates
# into <subtree>/AGENT-REVIEWERS.md and writes a merged # Configuration block
# to the repo-root AGENT-REVIEWERS.md.
#
# Per-subtree files get only # Agents + # Guidelines (no # Configuration —
# root owns config). When a single pack is installed AT root (subtree = .),
# the file gets # Configuration + # Agents + # Guidelines in one document.
#
# Refuses to overwrite any existing AGENT-REVIEWERS.md at root or subtree
# (transactional — checks ALL targets before writing anything).
#
# Refuses to install multiple packs at the same subtree (the
# same-directory polyglot case requires manual disambiguation, since
# the agents from different packs share names).
#
# Usage:
#   install-template.sh [--repo-root <path>] <lang>:<subtree> [<lang>:<subtree> ...]
#
# Example:
#   install-template.sh golang:backend python:frontend
#   install-template.sh golang:.    # Single language at root

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/../../../agent-reviewer-templates"
PLUGIN_JSON="$SCRIPT_DIR/../../../.claude-plugin/plugin.json"

REPO_ROOT="."
PAIRS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root)
            REPO_ROOT="${2:?--repo-root requires a path}"
            shift 2
            ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --*)
            echo "Error: unknown flag '$1'" >&2
            exit 2
            ;;
        *)
            PAIRS+=("$1")
            shift
            ;;
    esac
done

if [[ ${#PAIRS[@]} -eq 0 ]]; then
    echo "Error: no <lang>:<subtree> pairs provided" >&2
    echo "Usage: install-template.sh [--repo-root <path>] <lang>:<subtree> [...]" >&2
    exit 2
fi

if [[ ! -d "$REPO_ROOT" ]]; then
    echo "Error: repo root '$REPO_ROOT' is not a directory" >&2
    exit 2
fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

if [[ ! -d "$TEMPLATES_DIR" ]]; then
    echo "Error: templates directory not found at $TEMPLATES_DIR" >&2
    exit 2
fi

# Detect the current plugin version (for defaults_version_checked).
CURRENT_PLUGIN_VERSION=""
if [[ -f "$PLUGIN_JSON" ]]; then
    CURRENT_PLUGIN_VERSION="$(jq -r '.version // ""' "$PLUGIN_JSON")"
fi
if [[ -z "$CURRENT_PLUGIN_VERSION" ]]; then
    echo "Error: could not read plugin version from $PLUGIN_JSON" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Phase 1: validate all pairs and target paths (transactional — no writes).
# ---------------------------------------------------------------------------

# Parse pairs into parallel arrays: LANGS, SUBTREES, TEMPLATES, TARGETS
LANGS=()
SUBTREES=()
TEMPLATES=()
TARGETS=()
declare -A SUBTREE_SEEN

for pair in "${PAIRS[@]}"; do
    if [[ "$pair" != *:* ]]; then
        echo "Error: bad pair '$pair' — expected <lang>:<subtree>" >&2
        exit 2
    fi
    lang="${pair%%:*}"
    subtree="${pair#*:}"

    if [[ -z "$lang" || -z "$subtree" ]]; then
        echo "Error: bad pair '$pair' — language and subtree both required" >&2
        exit 2
    fi

    template_path="$TEMPLATES_DIR/${lang}.md"
    if [[ ! -f "$template_path" ]]; then
        echo "Error: no template found for language '$lang' at $template_path" >&2
        exit 2
    fi

    # Normalise the subtree path so "." and "./" and "foo/" all canonicalise.
    if [[ "$subtree" == "." || "$subtree" == "./" ]]; then
        target_dir="$REPO_ROOT"
        norm_subtree="."
    else
        # Strip trailing slash
        subtree="${subtree%/}"
        target_dir="$REPO_ROOT/$subtree"
        norm_subtree="$subtree"
    fi

    if [[ ! -d "$target_dir" ]]; then
        echo "Error: subtree directory does not exist: $target_dir" >&2
        exit 2
    fi

    target="$target_dir/AGENT-REVIEWERS.md"

    if [[ -f "$target" ]]; then
        echo "Error: $target already exists — refusing to overwrite" >&2
        exit 1
    fi

    if [[ -n "${SUBTREE_SEEN[$norm_subtree]:-}" ]]; then
        echo "Error: multiple packs targeting subtree '$norm_subtree' — same-directory polyglot must be resolved manually (agent names collide)" >&2
        exit 1
    fi
    SUBTREE_SEEN[$norm_subtree]=1

    LANGS+=("$lang")
    SUBTREES+=("$norm_subtree")
    TEMPLATES+=("$template_path")
    TARGETS+=("$target")
done

# Also check that the root AGENT-REVIEWERS.md doesn't exist (unless one of
# the pairs IS the root install, in which case the root target was already
# checked above).
ROOT_TARGET="$REPO_ROOT/AGENT-REVIEWERS.md"
ROOT_PAIR_INDEX=-1
for i in "${!SUBTREES[@]}"; do
    if [[ "${SUBTREES[$i]}" == "." ]]; then
        ROOT_PAIR_INDEX="$i"
        break
    fi
done

if [[ "$ROOT_PAIR_INDEX" -eq -1 ]] && [[ -f "$ROOT_TARGET" ]]; then
    echo "Error: $ROOT_TARGET already exists — refusing to overwrite (root file holds the merged # Configuration)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Phase 2: extract pieces from each template and compute merged config.
# ---------------------------------------------------------------------------

# extract_section <template-path> <section-name>
# Emits everything between `# <section-name>` and the next `# ` H1 (exclusive).
extract_section() {
    local file="$1" section="$2"
    awk -v section="$section" '
        BEGIN { in_section = 0 }
        /^# / {
            if (in_section) { in_section = 0 }
            heading = substr($0, 3)
            # Trim trailing whitespace
            sub(/[[:space:]]+$/, "", heading)
            if (heading == section) { in_section = 1; next }
        }
        in_section { print }
    ' "$file"
}

# extract_config_json <template-path>
# Reuses _parse_configuration.sh for consistency with the rest of the loop.
extract_config_json() {
    "$SCRIPT_DIR/_parse_configuration.sh" "$1"
}

# Collect per-pack configs into a single JSON array we can fold over in jq.
configs_array="["
sep=""
for tpl in "${TEMPLATES[@]}"; do
    cfg="$(extract_config_json "$tpl")"
    configs_array+="${sep}${cfg}"
    sep=","
done
configs_array+="]"

# Compute the merged config:
#   - defaults_version_checked: current plugin version
#   - disabled: union of all packs' disabled arrays (sorted, deduped)
#   - overlap_acknowledged: union; conflict on same key with different value is fatal
MERGED_CONFIG="$(printf '%s\n' "$configs_array" | jq --arg version "$CURRENT_PLUGIN_VERSION" '
    # Merge two overlap_acknowledged entries for the same agent name.
    # Both must agree on the .overlaps_with target. If they do, the
    # .reason strings are concatenated (distinct values, " | " separated)
    # so each pack contributes its language-specific rationale.
    def merge_overlap_entry(existing; incoming):
        if existing.overlaps_with != incoming.overlaps_with then
            error("overlap_acknowledged conflict for agent: overlaps_with differs (\"" + existing.overlaps_with + "\" vs \"" + incoming.overlaps_with + "\")")
        else
            existing + {
                reason: (
                    [existing.reason, incoming.reason]
                    | map(select(. != null and . != ""))
                    | unique
                    | join(" | ")
                )
            }
        end;

    reduce .[] as $c ({
        defaults_version_checked: $version,
        disabled: [],
        overlap_acknowledged: {}
    };
        .disabled = (.disabled + ($c.disabled // [])) |
        .overlap_acknowledged = (
            reduce ($c.overlap_acknowledged // {} | to_entries[]) as $entry (
                .overlap_acknowledged;
                if has($entry.key) then
                    . + {($entry.key): merge_overlap_entry(.[$entry.key]; $entry.value)}
                else
                    . + {($entry.key): $entry.value}
                end
            )
        )
    )
    | .disabled = (.disabled | unique)
')"

if [[ -z "$MERGED_CONFIG" ]]; then
    echo "Error: failed to compute merged # Configuration" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Phase 3: write per-subtree files and the root config file.
# ---------------------------------------------------------------------------

# Per-subtree files: write # Agents + # Guidelines for each pack at its subtree.
# Special case: if the pair's subtree is ".", the per-subtree file IS the root
# file, so it also gets the merged # Configuration.
for i in "${!LANGS[@]}"; do
    tpl="${TEMPLATES[$i]}"
    target="${TARGETS[$i]}"
    subtree="${SUBTREES[$i]}"

    agents_body="$(extract_section "$tpl" "Agents")"
    guidelines_body="$(extract_section "$tpl" "Guidelines")"

    {
        if [[ "$subtree" == "." ]]; then
            printf '# Configuration\n\n```json\n%s\n```\n\n' "$MERGED_CONFIG"
        fi
        printf '# Agents\n%s\n' "$agents_body"
        if [[ -n "$guidelines_body" ]]; then
            printf '# Guidelines\n%s\n' "$guidelines_body"
        fi
    } > "$target"

    echo "Installed ${LANGS[$i]} template -> $target" >&2
done

# Root config-only file (only when no pair targets root).
if [[ "$ROOT_PAIR_INDEX" -eq -1 ]]; then
    {
        printf '# Configuration\n\n```json\n%s\n```\n' "$MERGED_CONFIG"
    } > "$ROOT_TARGET"
    echo "Installed merged # Configuration -> $ROOT_TARGET" >&2
fi

echo "Done. Installed ${#LANGS[@]} template(s)." >&2
