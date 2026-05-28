#!/usr/bin/env bash
# Discover AGENT-REVIEWERS.md files for all changed files in a PR, merge
# with shipped default specialist reviewers, and report configuration state.
#
# Walks up from each changed file's directory to repo root, collecting
# agent definitions with hierarchical scoping (lower directories override).
# Loads default specialist reviewers from plugins/pr-review-loop/agents/.
# Parses the root AGENT-REVIEWERS.md's # Configuration section (if present)
# for `defaults_version_checked`, `disabled`, and `overlap_acknowledged`.
#
# Agent merge rules (C+E semantics):
#   - All defaults spawn by default
#   - User agents with the same name as a default REPLACE the default (override)
#   - Defaults in the `disabled` list do NOT spawn
#   - Defaults NOT overridden or disabled still spawn (additive)
#   - User agents with no matching default name simply add to the list
#
# Output JSON shape:
# {
#   "agents": [{name, scope, source, instructions, description?, model?, color?, kind, changed_files}, ...],
#     # kind: "default" | "user" | "user-override"
#     # description, model, color carried only on `default` entries (from frontmatter)
#   "context": [{section, scope, source, content}, ...],
#   "configuration": {
#     "defaults_version_checked": "1.2.0" | null,
#     "current_plugin_version": "1.2.0",
#     "stale_pin": true | false,
#     "disabled_defaults": ["pr-test-analyzer", ...],   // raw user input; may include unknown names
#     "disabled_defaults_unknown": [],                  // entries that don't match any default (typos)
#     "overlaps_acknowledged": {"my_pci_auditor": {overlaps_with, reason}, ...},
#     "independent_validator": {                         // ydy: per-finding validation step
#       "enabled": true,                                 // default true; user can disable
#       "skip_for": ["code-simplifier", ...],            // flagger names that bypass validation
#       "uncertain_action": "post_with_annotation"       // post_with_annotation | post_silently | drop
#     },
#     "spawned_count": 7,
#     "default_count": 6,
#     "override_count": 1,
#     "user_count": 1,
#     "overridden_default_names": ["code-reviewer"]
#   },
#   "language_detection": null                          // 98b: present only when no
#     # OR                                              // AGENT-REVIEWERS.md exists. Drives
#     # {                                               // the install-template offer in
#     #   "matched": [                                  // pre-loop setup.
#     #     {"language": "golang", "subtree": "backend", "template": "golang.md"},
#     #     {"language": "python", "subtree": "frontend", "template": "python.md"}
#     #   ],
#     #   "same_directory_polyglot": false              // true iff two matches share subtree
#     # }
# }
#
# Usage: discover-agents.sh <pr-number>

set -euo pipefail

PR_NUMBER="${1:?Usage: discover-agents.sh <pr-number>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

# Plugin version comes from the plugin's own .claude-plugin/plugin.json.
# Warn loudly when missing or empty — an empty current_plugin_version
# corrupts the stale_pin comparison (every pin would either always-mismatch
# or always-match a falsy value), so the user needs to see this.
PLUGIN_JSON="$SCRIPT_DIR/../../../.claude-plugin/plugin.json"
if [[ -f "$PLUGIN_JSON" ]]; then
    CURRENT_PLUGIN_VERSION="$(jq -r '.version // ""' "$PLUGIN_JSON")"
    if [[ -z "$CURRENT_PLUGIN_VERSION" ]]; then
        echo "Warning: plugin.json at $PLUGIN_JSON has no version field — stale_pin check will be unreliable" >&2
    fi
else
    echo "Warning: plugin.json not found at $PLUGIN_JSON — stale_pin check will be unreliable" >&2
    CURRENT_PLUGIN_VERSION=""
fi

# Get changed files in the PR. Let gh errors propagate (set -e) so a missing
# gh, unauthenticated user, or bad PR number fails loudly instead of silently
# returning an empty agent list.
#
# Test override: PR_REVIEW_LOOP_TEST_CHANGED_FILES lets callers pass a
# newline-separated file list instead of invoking gh. Used by the test suite
# and for offline development.
if [[ -n "${PR_REVIEW_LOOP_TEST_CHANGED_FILES+set}" ]]; then
    CHANGED_FILES="$PR_REVIEW_LOOP_TEST_CHANGED_FILES"
else
    CHANGED_FILES=$(gh pr diff "$PR_NUMBER" --name-only)
fi

# Note: an empty CHANGED_FILES used to early-exit with empty output.
# After bfd, defaults still spawn even on an empty diff (degenerate PR),
# so we fall through to the merge step which handles empty files fine.

# Collect unique directories containing changed files
DIRS=()
while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    dir="$(dirname "$file")"
    DIRS+=("$dir")
done <<< "$CHANGED_FILES"

# Deduplicate directories
UNIQUE_DIRS=()
while IFS= read -r d; do
    [[ -n "$d" ]] && UNIQUE_DIRS+=("$d")
done < <(printf '%s\n' "${DIRS[@]}" | sort -u)

# For each directory, walk up to repo root collecting AGENT-REVIEWERS.md paths
AGENT_FILES=()
SEEN_AGENT_FILES="|"

_seen() { [[ "$SEEN_AGENT_FILES" == *"|$1|"* ]]; }
_mark() { SEEN_AGENT_FILES="${SEEN_AGENT_FILES}$1|"; }

for dir in "${UNIQUE_DIRS[@]}"; do
    current="$dir"
    while true; do
        agent_file="$REPO_ROOT/$current/AGENT-REVIEWERS.md"
        if [[ -f "$agent_file" ]] && ! _seen "$agent_file"; then
            AGENT_FILES+=("$agent_file")
            _mark "$agent_file"
        fi

        # Move up one directory
        if [[ "$current" == "." ]]; then
            break
        fi
        current="$(dirname "$current")"
    done
done

# Note: we no longer early-exit here when no AGENT-REVIEWERS.md is found.
# Defaults still spawn even without any user customization.

# Parse each AGENT-REVIEWERS.md file and extract agents + context sections.
# Uses awk to split on H1/H2 headings and classify sections.
#
# Output per file: JSON lines with type (agent|context), name, scope, content, source
parse_agent_file() {
    local file="$1"
    local rel_path="${file#$REPO_ROOT/}"
    local scope_dir
    scope_dir="$(dirname "$rel_path")"
    if [[ "$scope_dir" == "." ]]; then
        scope_dir="/"
    else
        scope_dir="/$scope_dir/"
    fi

    awk -v scope="$scope_dir" -v source="$rel_path" '
    function json_escape(s) {
        gsub(/\\/, "&&", s)
        gsub(/"/, "\\\"", s)
        gsub(/\n/, "\\n", s)
        gsub(/\r/, "\\r", s)
        gsub(/\t/, "\\t", s)
        return s
    }

    function flush() {
        if (current_h2 != "" && content != "") {
            printf "{\"type\":\"agent\",\"name\":\"%s\",\"scope\":\"%s\",\"source\":\"%s\",\"instructions\":\"%s\"}\n", json_escape(current_h2), json_escape(scope), json_escape(source), json_escape(content)
            current_h2 = ""
            content = ""
        } else if (current_h1 != "" && current_h1 != "Agents" && content != "") {
            printf "{\"type\":\"context\",\"section\":\"%s\",\"scope\":\"%s\",\"source\":\"%s\",\"content\":\"%s\"}\n", json_escape(current_h1), json_escape(scope), json_escape(source), json_escape(content)
            content = ""
        }
    }

    BEGIN {
        in_agents = 0
        current_h2 = ""
        current_h1 = ""
        content = ""
        in_fence = 0
    }

    # Toggle fence state on any line starting with three backticks. Inside a
    # fence, treat the line as content (so the rendered agent body keeps its
    # opening/closing fence) and skip the H1/H2-detection branches. Without
    # this, an agent body containing a fenced `# BAD` or `## Example` line
    # silently flushes mid-agent and (worse) flips `in_agents` off when the
    # bogus h1 does not equal "Agents", dropping every agent defined below.
    /^```/ {
        in_fence = !in_fence
        if (content != "") content = content "\n" $0
        else content = $0
        next
    }

    !in_fence && /^# / {
        flush()
        h1_name = substr($0, 3)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", h1_name)
        current_h1 = h1_name
        in_agents = (h1_name == "Agents")
        current_h2 = ""
        content = ""
        next
    }

    !in_fence && /^## / && in_agents {
        flush()
        current_h2 = substr($0, 4)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", current_h2)
        content = ""
        next
    }

    {
        if (content != "") content = content "\n" $0
        else content = $0
    }

    END {
        flush()
    }
    ' "$file"
}

# Collect all parsed sections from all files. Capturing the loop's output
# with command substitution is O(n) vs repeated string concatenation (O(n²)).
ALL_SECTIONS=""
if [[ ${#AGENT_FILES[@]} -gt 0 ]]; then
    ALL_SECTIONS=$(
        for file in "${AGENT_FILES[@]}"; do
            parse_agent_file "$file"
        done
    )
fi

# Build JSON array of changed files for scoping
CHANGED_FILES_JSON=$(jq -n --arg files "$CHANGED_FILES" '$files | split("\n") | map(select(. != ""))')

# Load defaults from plugins/pr-review-loop/agents/*.md.
DEFAULTS_JSON=$("$SCRIPT_DIR/_load_defaults.sh")
DEFAULTS_COUNT=$(echo "$DEFAULTS_JSON" | jq 'length')
if [[ "$DEFAULTS_COUNT" -eq 0 ]]; then
    echo "Warning: zero default specialist reviewers loaded — plugin install may be incomplete" >&2
fi

# Parse # Configuration from the ROOT AGENT-REVIEWERS.md only (project-level state).
# Subdirectory AGENT-REVIEWERS.md files may exist but their configuration is ignored.
ROOT_AGENT_REVIEWERS="$REPO_ROOT/AGENT-REVIEWERS.md"
if [[ -f "$ROOT_AGENT_REVIEWERS" ]]; then
    if ! CONFIGURATION_JSON=$("$SCRIPT_DIR/_parse_configuration.sh" "$ROOT_AGENT_REVIEWERS"); then
        # Parser exited non-zero (e.g., missing required `reason` field)
        echo "Error: invalid # Configuration in $ROOT_AGENT_REVIEWERS — see message above" >&2
        exit 1
    fi
else
    CONFIGURATION_JSON='{}'
fi

# 98b: language detection. Only fires when NO AGENT-REVIEWERS.md exists
# (neither at root nor discovered via the changed-file walk-up). When the
# repo already has config, the user has clearly opted into manual setup
# and we don't interrupt with template suggestions.
#
# Empty PRs (no changed files) skip the walk entirely, so we also need
# the explicit root-file check to avoid a false trigger when root config
# exists but PR has no files.
LANGUAGE_DETECTION_JSON='null'
if [[ ${#AGENT_FILES[@]} -eq 0 ]] && [[ ! -f "$ROOT_AGENT_REVIEWERS" ]]; then
    if [[ -x "$SCRIPT_DIR/detect-language.sh" ]]; then
        # Capture stdout; let stderr flow through so the user sees any errors.
        # Detect script is deterministic and shouldn't fail on a readable repo,
        # but if it does, fall back to null rather than crashing the loop.
        if RAW_DETECT=$("$SCRIPT_DIR/detect-language.sh" --repo-root "$REPO_ROOT" 2>/dev/null); then
            # Transform: add template field per entry; compute same_directory_polyglot flag.
            # Pass JSON via env to avoid MAX_ARG_STRLEN (~128KB on Linux) on
            # huge repos where the manifest list grows.
            LANGUAGE_DETECTION_JSON=$(RAW_DETECT="$RAW_DETECT" jq -n '
                (env.RAW_DETECT | fromjson) as $matches
                | {
                    matched: ($matches | map(. + {template: (.language + ".md")})),
                    same_directory_polyglot: (
                        # True iff two matches share a subtree with different languages
                        ($matches
                            | group_by(.subtree)
                            | map(select(length > 1 and ([.[].language] | unique | length > 1)))
                            | length) > 0
                    )
                }
            ')
        fi
    fi
fi

# Warn if subdirectory AGENT-REVIEWERS.md files have a # Configuration section —
# their configuration is silently ignored, so surface that fact to the user.
# Compare canonical paths via realpath so `/./` segments don't false-positive.
# Detection is fence-aware: a `# Configuration` inside a fenced example in an
# agent body is content, not a heading, and shouldn't trigger the warning.
ROOT_AGENT_REVIEWERS_CANON="$(realpath "$ROOT_AGENT_REVIEWERS" 2>/dev/null || echo "$ROOT_AGENT_REVIEWERS")"
for f in "${AGENT_FILES[@]}"; do
    f_canon="$(realpath "$f" 2>/dev/null || echo "$f")"
    [[ "$f_canon" == "$ROOT_AGENT_REVIEWERS_CANON" ]] && continue
    if awk '
        BEGIN { in_fence = 0; found = 0 }
        /^```/ { in_fence = !in_fence; next }
        !in_fence && /^# Configuration[[:space:]]*$/ { found = 1; exit }
        END { exit (found ? 0 : 1) }
    ' "$f"; then
        echo "Warning: # Configuration section found in $f — ignored (only the root AGENT-REVIEWERS.md's configuration is honored)" >&2
    fi
done

# Warn on disabled names that don't match any default — likely typos.
# Without this, e.g. `disabled: ["pr-test-analyser"]` (British spelling)
# would silently no-op.
# Pass JSON via env to avoid MAX_ARG_STRLEN on large repos.
UNKNOWN_DISABLED=$(
    DEFAULTS_JSON="$DEFAULTS_JSON" \
    CONFIGURATION_JSON="$CONFIGURATION_JSON" \
    jq -nr '
        (env.DEFAULTS_JSON | fromjson) as $defaults
        | (env.CONFIGURATION_JSON | fromjson) as $config
        | ($defaults | map(.name)) as $known
        | (($config.disabled // []) - $known)
        | join(", ")
    ')
if [[ -n "$UNKNOWN_DISABLED" ]]; then
    echo "Warning: # Configuration disabled list names that don't match any default reviewer: $UNKNOWN_DISABLED" >&2
    echo "Warning:   Available defaults: $(echo "$DEFAULTS_JSON" | jq -r 'map(.name) | join(", ")')" >&2
fi

# Prepare input for jq:
#   {sections: [...], defaults: [...], configuration: {...}, current_version: "...",
#    language_detection: null | {...}}
# Pass JSON via env (not --argjson) to avoid MAX_ARG_STRLEN (~128KB on
# Linux). ALL_SECTIONS and DEFAULTS_JSON are the most likely to grow:
# many user agents in AGENT-REVIEWERS.md, or many shipped defaults.
SECTIONS_JSON="$([[ -z "$ALL_SECTIONS" ]] && echo "[]" || (printf '%s\n' "$ALL_SECTIONS" | jq -s '.'))"
JQ_INPUT=$(
    SECTIONS_JSON="$SECTIONS_JSON" \
    DEFAULTS_JSON="$DEFAULTS_JSON" \
    CONFIGURATION_JSON="$CONFIGURATION_JSON" \
    FILES_JSON="$CHANGED_FILES_JSON" \
    LANGUAGE_DETECTION_JSON="$LANGUAGE_DETECTION_JSON" \
    jq -n --arg current_version "$CURRENT_PLUGIN_VERSION" '
        {
            sections: (env.SECTIONS_JSON | fromjson),
            defaults: (env.DEFAULTS_JSON | fromjson),
            configuration: (env.CONFIGURATION_JSON | fromjson),
            files: (env.FILES_JSON | fromjson),
            current_version: $current_version,
            language_detection: (env.LANGUAGE_DETECTION_JSON | fromjson)
        }'
)

echo "$JQ_INPUT" | jq '
    # ---- 1. Parse the existing AGENT-REVIEWERS.md output (sections) ----
    .sections as $sections |
    .defaults as $defaults |
    .configuration as $config |
    .files as $files |
    .current_version as $current_version |
    .language_detection as $language_detection |

    # ---- 2. Resolve user agents from sections (existing hierarchical-scope logic) ----
    ([$sections[] | select(.type == "agent")] |
        sort_by(.scope | split("/") | length) | reverse |
        reduce .[] as $agent (
            {seen: {}, result: []};
            if .seen[$agent.name] then .
            else .seen[$agent.name] = true | .result += [$agent]
            end
        ) | .result
    ) as $user_agents_raw |

    # User agent names (used for same-name override detection)
    ($user_agents_raw | map(.name)) as $user_agent_names |
    ($defaults | map(.name)) as $default_agent_names |

    # ---- 3. Determine overrides ----
    # Defaults that get replaced because user has same-name agent
    ($user_agent_names | map(. as $n | select($default_agent_names | index($n)))) as $overridden_default_names |

    # Disabled defaults (from configuration)
    ($config.disabled // []) as $disabled_defaults |

    # ---- 4. Effective defaults: not overridden, not disabled ----
    # Precedence: if a default appears in BOTH the disabled list AND is
    # also overridden by a same-name user agent, the user agent still runs
    # (as user-override). The default itself is filtered out by EITHER rule.
    ($defaults
        | map(select(.name as $n | ($overridden_default_names | index($n)) == null))
        | map(select(.name as $n | ($disabled_defaults | index($n)) == null))
        | map(. + {kind: "default"})
        | map(. + {changed_files: (
            .scope as $s |
            if $s == "/" then $files
            else [$files[] | select(startswith($s | ltrimstr("/")))]
            end
          )})
    ) as $effective_defaults |

    # ---- 5. User agents: tagged as override if name matches a default, else plain user ----
    # Shape asymmetry note: user agents only carry {name, scope, source,
    # instructions, kind, changed_files}. Defaults additionally carry
    # {description, model, color} from their YAML frontmatter (see
    # _load_defaults.sh). User agents come from AGENT-REVIEWERS.md markdown
    # H2 sections which have no frontmatter; their `instructions` is the
    # full body. Consumers (the spawn template in SKILL.md) handle the
    # absent model field by falling back to the orchestrator default.
    ($user_agents_raw
        | map(.name as $n | . + {kind: (if ($default_agent_names | index($n)) != null then "user-override" else "user" end)})
        | map(.scope as $s | . + {changed_files: (
            if $s == "/" then $files
            else [$files[] | select(startswith($s | ltrimstr("/")))]
            end
          )})
        | map({name, scope, source, instructions, kind, changed_files})
    ) as $user_agents |

    # ---- 6. Final merged agent list ----
    ($user_agents + $effective_defaults) as $merged_agents |

    # ---- 7. Stale-pin check ----
    (($config.defaults_version_checked // null) != $current_version) as $stale_pin |

    # ---- 8. Compose output ----
    {
        agents: $merged_agents,
        context: (
            [$sections[] | select(.type == "context")] |
            sort_by(.scope | split("/") | length) | reverse |
            reduce .[] as $ctx (
                {seen: {}, result: []};
                if .seen[$ctx.section] then .
                else .seen[$ctx.section] = true | .result += [$ctx]
                end
            ) | .result |
            map({section, scope, source, content})
        ),
        configuration: {
            defaults_version_checked: ($config.defaults_version_checked // null),
            current_plugin_version: $current_version,
            stale_pin: $stale_pin,
            disabled_defaults: $disabled_defaults,
            disabled_defaults_unknown: ($disabled_defaults - $default_agent_names),
            overlaps_acknowledged: ($config.overlap_acknowledged // {}),
            # Resolve independent_validator with defaults filled in. The
            # orchestrator can rely on all fields being present.
            # Note: use explicit `has` checks instead of `//` because the //
            # operator treats false as falsy and would mis-default an
            # explicit `enabled: false` to true.
            independent_validator: ($config.independent_validator as $iv | {
                enabled: (if ($iv | type == "object") and ($iv | has("enabled"))
                          then $iv.enabled else true end),
                skip_for: (if ($iv | type == "object") and ($iv | has("skip_for"))
                           then $iv.skip_for else [] end),
                uncertain_action: (if ($iv | type == "object") and ($iv | has("uncertain_action"))
                                   then $iv.uncertain_action else "post_with_annotation" end)
            }),
            spawned_count: ($merged_agents | length),
            default_count: ($effective_defaults | length),
            override_count: ($overridden_default_names | length),
            user_count: ($user_agents | map(select(.kind == "user")) | length),
            overridden_default_names: $overridden_default_names
        },
        language_detection: $language_detection
    }
'
