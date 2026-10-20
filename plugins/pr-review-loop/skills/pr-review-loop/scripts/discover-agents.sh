#!/usr/bin/env bash
# Discover AGENT-REVIEWERS.md files for all changed files in a PR, merge
# with shipped default specialist reviewers, and report configuration state.
#
# Walks up from each changed file's directory to repo root, collecting
# agent definitions with hierarchical scoping (lower directories override within their subtree).
# Loads default specialist reviewers from plugins/pr-review-loop/agents/.
# Parses the root AGENT-REVIEWERS.md's # Configuration section (if present)
# for `defaults_version_checked`, `disabled`, and `overlap_acknowledged`.
#
# Agent merge rules (C+E semantics):
#   - All defaults spawn by default
#   - User agents with the same name as a default REPLACE it for the files they own;
#     the default still reviews the rest of the diff (dropped only if nothing is left)
#   - Defaults in the `disabled` list do NOT spawn
#   - Defaults NOT overridden or disabled still spawn (additive)
#   - User agents with no matching default name simply add to the list
#
# Output JSON shape:
# {
#   "agents": [{name, scope, source, instructions, summary?, spec?, bin?, description?, model?, color?, kind, changed_files, engine, pi_models?}, ...],
#     # A user agent whose spec lives in .reviewers/<name>.md next to the
#     #   AGENT-REVIEWERS.md that names it: instructions = that file, summary =
#     #   its H2 body (what it checks, when to spawn it), spec = the file's
#     #   repo-relative path, bin = .reviewers/bin when that directory exists.
#     # kind: "default" | "user" | "user-override"
#     # engine: "claude" | "pi" (from # Configuration .pi); pi_models (fallback chain) only for "pi"
#     # model: every agent has one - frontmatter for defaults, a `model:` line in
#     #   the first lines of a user agent's summary or spec, else "sonnet". Never absent:
#     #   an absent model made the orchestrator spawn on its own (session) model.
#     # description, color carried only on `default` entries (from frontmatter)
#   "context": [{section, scope, source, content}, ...],
#   "configuration": {
#     "defaults_version_checked": "1.2.0" | null,
#     "current_plugin_version": "1.2.0",
#     "stale_pin": true | false,
#     "disabled_defaults": ["pr-test-analyzer", ...],   // raw user input; may include unknown names
#     "disabled_defaults_unknown": [],                  // entries that don't match any default (typos)
#     "overlaps_acknowledged": {"my_pci_auditor": {overlaps_with, reason}, ...},
#     "independent_validator": {                         // ydy: per-finding validation step
#       "enabled": false,                                // default false; validation is opt-in
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
#        discover-agents.sh --base <ref>     # local mode: diff <ref>...HEAD, no PR

set -euo pipefail

BASE_REF=""
if [[ "${1:-}" == "--base" ]]; then
    BASE_REF="${2:?Usage: discover-agents.sh --base <ref>}"
    PR_NUMBER=""
else
    PR_NUMBER="${1:?Usage: discover-agents.sh <pr-number> | --base <ref>}"
fi

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

# DEFAULTS_VERSION is the plugin version in which the default reviewers last
# changed. A pin at or above it is current, so ordinary version bumps don't
# force a re-audit. Bump that file only when the defaults change. Missing
# file → fall back to the plugin version (every bump re-audits).
DEFAULTS_VERSION_FILE="$SCRIPT_DIR/../../../DEFAULTS_VERSION"
DEFAULTS_VERSION="$(tr -d '[:space:]' < "$DEFAULTS_VERSION_FILE" 2>/dev/null || true)"
if [[ -z "$DEFAULTS_VERSION" ]]; then
    echo "Warning: $DEFAULTS_VERSION_FILE missing or empty — any plugin version change will mark the pin stale" >&2
    DEFAULTS_VERSION="$CURRENT_PLUGIN_VERSION"
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
elif [[ -n "$BASE_REF" ]]; then
    CHANGED_FILES=$(git diff --name-only "$BASE_REF"...HEAD)
else
    CHANGED_FILES=$(gh pr diff "$PR_NUMBER" --name-only)
fi

# Nobody hand-writes lockfiles, minified bundles, source maps or beads exports,
# so no reviewer reads them.
GENERATED_RE='(^|/)(uv\.lock|poetry\.lock|Pipfile\.lock|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb|Cargo\.lock|go\.sum|Gemfile\.lock|composer\.lock|flake\.lock|\.terraform\.lock\.hcl)$|\.min\.(js|css)$|\.map$|(^|/)\.beads/'
EXCLUDED_FILES=$(grep -E "$GENERATED_RE" <<< "$CHANGED_FILES" || true)
CHANGED_FILES=$(grep -v -E "$GENERATED_RE" <<< "$CHANGED_FILES" || true)

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

# A converted repo (a root .reviewers/ holding at least one reviewer file, and no
# root AGENT-REVIEWERS.md) runs exactly the reviewer files it has.
REVIEWERS_LAYOUT=false
if [[ ! -f "$REPO_ROOT/AGENT-REVIEWERS.md" ]] \
    && find "$REPO_ROOT/.reviewers" -maxdepth 1 -name '*.md' ! -name README.md 2>/dev/null | grep -q .; then
    REVIEWERS_LAYOUT=true
fi

# The root .reviewers/ applies to every diff, empty or all-generated included.
REVIEWER_DIRS=()
[[ -d "$REPO_ROOT/.reviewers" ]] && { REVIEWER_DIRS+=("$REPO_ROOT/./.reviewers"); _mark "$REPO_ROOT/./.reviewers"; }
for dir in "${UNIQUE_DIRS[@]}"; do
    current="$dir"
    while true; do
        agent_file="$REPO_ROOT/$current/AGENT-REVIEWERS.md"
        if [[ -f "$agent_file" ]] && ! _seen "$agent_file"; then
            AGENT_FILES+=("$agent_file")
            _mark "$agent_file"
        fi
        reviewer_dir="$REPO_ROOT/$current/.reviewers"
        if [[ -d "$reviewer_dir" ]] && ! _seen "$reviewer_dir"; then
            REVIEWER_DIRS+=("$reviewer_dir")
            _mark "$reviewer_dir"
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
    # opening/closing fence) and skip the H1/H2-detection branches. Two
    # distinct failure modes this guards against:
    #   - A fenced H1 like `# BAD` triggers the H1 rule (which sets
    #     `in_agents = 0` since "BAD" != "Agents"), dropping every agent
    #     defined below — the catastrophic case.
    #   - A fenced H2 like `## Example` triggers the H2 rule and creates a
    #     spurious agent named "Example" — visible but wrong.
    /^```/ {
        in_fence = !in_fence
        if (content != "") content = content "\n" $0
        else content = $0
        next
    }

    !in_fence && /^#[[:space:]]+/ {
        flush()
        h1_name = $0
        sub(/^#[[:space:]]+/, "", h1_name)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", h1_name)
        current_h1 = h1_name
        in_agents = (h1_name == "Agents")
        current_h2 = ""
        content = ""
        next
    }

    !in_fence && /^##[[:space:]]+/ && in_agents {
        flush()
        current_h2 = $0
        sub(/^##[[:space:]]+/, "", current_h2)
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
        # Defensive: surface malformed input. An unclosed code fence
        # silently swallows subsequent H1/H2 into the prior section
        # content — same silent-data-loss class as the fence-unaware
        # bug fixed by this awk, just triggered by malformed input.
        if (in_fence) {
            print "Warning: unclosed code fence in " source > "/dev/stderr"
        }
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

# A reviewer with a .reviewers/<name>.md beside the index that names it takes
# that file as its full spec; the H2 body becomes its summary.
if [[ -n "$ALL_SECTIONS" ]]; then
    ALL_SECTIONS=$(
        while IFS= read -r section; do
            if [[ "$(jq -r .type <<< "$section")" == agent ]]; then
                name=$(jq -r .name <<< "$section")
                [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || echo "Warning: '## $name' under # Agents in $(jq -r .source <<< "$section") is not a reviewer name, but every H2 there is spawned as one; move notes out of # Agents" >&2
                dir=$(dirname "$(jq -r .source <<< "$section")")
                [[ "$dir" == "." ]] && dir="" || dir="$dir/"
                spec="${dir}.reviewers/$name.md"
                if [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ && -f "$REPO_ROOT/$spec" ]]; then
                    bin="${dir}.reviewers/bin"
                    [[ -d "$REPO_ROOT/$bin" ]] || bin=""
                    section=$(jq -c --rawfile body "$REPO_ROOT/$spec" --arg spec "$spec" --arg bin "$bin" \
                        '. + {summary: .instructions, instructions: $body, spec: $spec}
                           + (if $bin == "" then {} else {bin: $bin} end)' <<< "$section")
                fi
            fi
            printf '%s\n' "$section"
        done <<< "$ALL_SECTIONS"
    )
fi

# Every other .reviewers/<name>.md is a reviewer in its own right: the whole
# file is its spec and its first REVIEWER_HEADER_LINES lines are its summary,
# which is all the orchestrator reads to decide whether to spawn it.
# .reviewers/README.md is context for the orchestrator, like a # Guidelines H1.
REVIEWER_HEADER_LINES=12
for rdir in "${REVIEWER_DIRS[@]}"; do
    rel_dir="${rdir#$REPO_ROOT/}"; rel_dir="${rel_dir#./}"
    base="$(dirname "$rel_dir")"
    [[ "$base" == "." ]] && scope="/" || scope="/$base/"
    for spec in "$rdir"/*.md; do
        [[ -f "$spec" ]] || continue
        name="$(basename "$spec" .md)"
        rel_spec="$rel_dir/$name.md"
        if [[ "$name" == README ]]; then
            section=$(jq -nc --rawfile body "$spec" --arg scope "$scope" --arg source "$rel_spec" \
                '{type: "context", section: ("Reviewers README " + $scope), scope: $scope, source: $source, content: $body}')
            ALL_SECTIONS+=$'\n'"$section"
            continue
        fi
        # Indexed by an H2 beside it: already attached above as that H2's spec.
        if [[ -n "$ALL_SECTIONS" ]] && jq -e --arg spec "$rel_spec" 'select(.spec == $spec)' <<< "$ALL_SECTIONS" >/dev/null 2>&1; then
            continue
        fi
        # Until the repo converts, only AGENT-REVIEWERS.md decides what runs.
        if [[ "$REVIEWERS_LAYOUT" == false ]]; then
            echo "Warning: $rel_spec has no '## $name' entry in an AGENT-REVIEWERS.md, so it does not run (it would after converting to .reviewers/)" >&2
            continue
        fi
        [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
            || echo "Warning: $rel_spec: '$name' is not a reviewer name (kebab-case), but it is spawned as one" >&2
        header="$(head -n "$REVIEWER_HEADER_LINES" "$spec")"
        grep -qE '^\**(Spawn when|When to spawn):?\**' <<< "$header" \
            || echo "Warning: $rel_spec has no 'Spawn when:' line in its first $REVIEWER_HEADER_LINES lines, so the orchestrator cannot tell when it applies" >&2
        ! grep -qE '^\**(Checks|Spawn when):?\**:? *TODO' <<< "$header" \
            || echo "Warning: $rel_spec has a TODO in its header; fill in what it checks and when to spawn it" >&2
        if [[ "$(wc -l < "$spec")" -gt 100 ]] && ! grep -qE '^\**Contents:?\**' <<< "$header"; then
            echo "Warning: $rel_spec is over 100 lines with no 'Contents:' line in its header; Claude reads files with head -n 100, so name its sections" >&2
        fi
        bin="$rel_dir/bin"
        [[ -d "$rdir/bin" ]] || bin=""
        section=$(jq -nc --rawfile body "$spec" --arg name "$name" --arg scope "$scope" --arg source "$rel_spec" \
            --arg summary "$(head -n "$REVIEWER_HEADER_LINES" "$spec")" --arg bin "$bin" \
            '{type: "agent", name: $name, scope: $scope, source: $source, instructions: $body,
              summary: $summary, spec: $source} + (if $bin == "" then {} else {bin: $bin} end)')
        ALL_SECTIONS+=$'\n'"$section"
    done
done
ALL_SECTIONS="${ALL_SECTIONS#$'\n'}"

# Build JSON array of changed files for scoping
CHANGED_FILES_JSON=$(jq -n --arg files "$CHANGED_FILES" '$files | split("\n") | map(select(. != ""))')
EXCLUDED_FILES_JSON=$(jq -n --arg files "$EXCLUDED_FILES" '$files | split("\n") | map(select(. != ""))')

# Load defaults from plugins/pr-review-loop/agents/*.md.
# A converted repo (root .reviewers/, no root AGENT-REVIEWERS.md) runs exactly
# the reviewers it has: the shipped defaults are starter files it copied in or
# chose not to, so none is added here and there is no defaults pin to go stale.
if [[ "$REVIEWERS_LAYOUT" == true ]]; then
    DEFAULTS_JSON='[]'
else
    DEFAULTS_JSON=$("$SCRIPT_DIR/_load_defaults.sh")
fi
DEFAULTS_COUNT=$(echo "$DEFAULTS_JSON" | jq 'length')
if [[ "$DEFAULTS_COUNT" -eq 0 && "$REVIEWERS_LAYOUT" == false ]]; then
    echo "Warning: zero default specialist reviewers loaded — plugin install may be incomplete" >&2
fi

# Parse # Configuration from the ROOT AGENT-REVIEWERS.md only (project-level state).
# Subdirectory AGENT-REVIEWERS.md files may exist but their configuration is ignored.
# .reviewers/config.json, when present, replaces it.
ROOT_AGENT_REVIEWERS="$REPO_ROOT/AGENT-REVIEWERS.md"
ROOT_CONFIG="$ROOT_AGENT_REVIEWERS"
if [[ -f "$REPO_ROOT/.reviewers/config.json" ]]; then
    ROOT_CONFIG="$REPO_ROOT/.reviewers/config.json"
    if [[ -f "$ROOT_AGENT_REVIEWERS" ]] && grep -qE '^#[[:space:]]+Configuration[[:space:]]*$' "$ROOT_AGENT_REVIEWERS"; then
        echo "Warning: both .reviewers/config.json and a # Configuration in AGENT-REVIEWERS.md exist; only config.json is read" >&2
    fi
fi
if [[ -f "$ROOT_CONFIG" ]]; then
    if ! CONFIGURATION_JSON=$("$SCRIPT_DIR/_parse_configuration.sh" "$ROOT_CONFIG"); then
        # Parser exited non-zero (e.g., missing required `reason` field)
        echo "Error: invalid configuration in $ROOT_CONFIG — see message above" >&2
        exit 1
    fi
else
    CONFIGURATION_JSON='{}'
fi

# Per-user model chains, ~/.config/pr-review-loop/models.json:
#   {"agents": {"<agent>" | "*": <chain> | false}}
# A chain is validated as in # Configuration .pi. It routes the agent to pi in
# every repo; the repo's .pi beats it agent by agent (a repo chain, true,
# false, or .all), and "*" covers agents the file does not name.
USER_MODELS="${PR_REVIEW_LOOP_MODELS:-$HOME/.config/pr-review-loop/models.json}"
USER_CHAINS='{}'
if [[ -f "$USER_MODELS" ]]; then
    USER_CHAINS="$(jq -c '
        def entry: type == "string" and (test("^[^/\\s]+/\\S+$") or test("^claude(:(sonnet|haiku|opus))?$"));
        def chain: entry or (type == "array" and length > 0 and all(.[]; entry));
        if type == "object" and ((has("agents") | not) or (.agents | type) == "object")
           and all((.agents // {})[]; . == false or chain)
        then .agents // {} else error("bad") end' "$USER_MODELS" 2>/dev/null)" && [[ -n "$USER_CHAINS" ]] \
        || { echo "Error: $USER_MODELS: .agents must map agent names (or \"*\") to provider/id, claude[:sonnet|haiku|opus], a non-empty list of them, or false" >&2; exit 1; }
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
if [[ ${#AGENT_FILES[@]} -eq 0 && ${#REVIEWER_DIRS[@]} -eq 0 ]] && [[ ! -f "$ROOT_AGENT_REVIEWERS" && ! -d "$REPO_ROOT/.reviewers" ]]; then
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
                    matched: ($matches | map(. + {template: .language})),
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
        !in_fence && /^#[[:space:]]+Configuration[[:space:]]*$/ { found = 1; exit }
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
if [[ "$REVIEWERS_LAYOUT" == true ]]; then
    [[ -n "$UNKNOWN_DISABLED" ]] && echo "Warning: 'disabled' has no effect in the .reviewers/ layout (no reviewer runs unless its file is there): $UNKNOWN_DISABLED" >&2
elif [[ -n "$UNKNOWN_DISABLED" ]]; then
    echo "Warning: # Configuration disabled list names that don't match any default reviewer: $UNKNOWN_DISABLED" >&2
    echo "Warning:   Available defaults: $(echo "$DEFAULTS_JSON" | jq -r 'map(.name) | join(", ")')" >&2
fi

# Prepare input for jq:
#   {sections: [...], defaults: [...], configuration: {...}, current_version: "...",
#    language_detection: null | {...}}
# Neither argv nor one env var may exceed MAX_ARG_STRLEN (128KB on Linux).
# The sections carry every reviewer's full spec, so they go in on stdin; the
# rest is small enough for env.
SECTIONS_JSON="$([[ -z "$ALL_SECTIONS" ]] && echo "[]" || (printf '%s\n' "$ALL_SECTIONS" | jq -s '.'))"
JQ_INPUT=$(
    printf '%s' "$SECTIONS_JSON" |
    DEFAULTS_JSON="$DEFAULTS_JSON" \
    CONFIGURATION_JSON="$CONFIGURATION_JSON" \
    USER_CHAINS_JSON="$USER_CHAINS" \
    FILES_JSON="$CHANGED_FILES_JSON" \
    EXCLUDED_JSON="$EXCLUDED_FILES_JSON" \
    LANGUAGE_DETECTION_JSON="$LANGUAGE_DETECTION_JSON" \
    jq --arg current_version "$CURRENT_PLUGIN_VERSION" --arg defaults_version "$DEFAULTS_VERSION" \
       --argjson reviewers_layout "$REVIEWERS_LAYOUT" '
        {
            sections: .,
            defaults: (env.DEFAULTS_JSON | fromjson),
            configuration: (env.CONFIGURATION_JSON | fromjson),
            user_chains: (env.USER_CHAINS_JSON | fromjson),
            files: (env.FILES_JSON | fromjson),
            excluded: (env.EXCLUDED_JSON | fromjson),
            current_version: $current_version,
            defaults_version: $defaults_version,
            reviewers_layout: $reviewers_layout,
            language_detection: (env.LANGUAGE_DETECTION_JSON | fromjson)
        }'
)

echo "$JQ_INPUT" | jq '
    # "1.4.2" → [1,4,2]; prerelease suffix ignored. null on anything unparseable.
    def semver: try (split("-")[0] | split(".") | map(tonumber)) catch null;

    # ---- 1. Parse the existing AGENT-REVIEWERS.md output (sections) ----
    .sections as $sections |
    .defaults as $defaults |
    .configuration as $config |
    .user_chains as $user_chains |
    .files as $files |
    .excluded as $excluded |
    .current_version as $current_version |
    .defaults_version as $defaults_version |
    .reviewers_layout as $reviewers_layout |
    .language_detection as $language_detection |

    # ---- 2. Resolve user agents from sections (hierarchical scope) ----
    # A lower definition overrides a same-named one above it only inside its
    # own subtree: each changed file goes to the deepest same-named definition
    # whose scope contains it, and a parent keeps every file no deeper
    # definition claims. So a root test-coverage-reviewer still reviews the
    # Ruby files in a diff that also touches app/javascript/, where a
    # same-named JS reviewer takes the JS files. A name none of whose
    # definitions owns a file keeps just its deepest definition (step 6 then
    # drops it, except on an empty diff).
    def in_scope($s): if $s == "/" then true else startswith($s | ltrimstr("/")) end;
    ([$sections[] | select(.type == "agent")] |
        group_by(.name) |
        map(sort_by(.scope | split("/") | length) | reverse |
            (reduce .[] as $agent (
                {claimed: [], out: []};
                [$files[] | select(in_scope($agent.scope))] as $mine |
                .claimed as $claimed |
                [$mine[] | . as $f | select(any($claimed[]; . == $f) | not)] as $own |
                .claimed += $own | .out += [$agent + {changed_files: $own}]
            ) | .out) as $defs |
            ([$defs[] | select(.changed_files | length > 0)] | if length > 0 then . else [$defs[0]] end)
        ) | flatten
    ) as $user_agents_raw |

    # User agent names (used for same-name override detection)
    ($user_agents_raw | map(.name) | unique) as $user_agent_names |
    ($defaults | map(.name)) as $default_agent_names |

    # ---- 3. Determine overrides ----
    # Defaults that get replaced because user has same-name agent
    ($user_agent_names | map(. as $n | select($default_agent_names | index($n)))) as $overridden_default_names |

    # Disabled defaults (from configuration)
    ($config.disabled // []) as $disabled_defaults |

    # ---- 4. Effective defaults: not disabled; overridden only where claimed ----
    # A same-named user agent replaces a default only for the files it owns
    # (step 2), so a subtree override leaves the default on the rest of the
    # diff. A default with nothing left is dropped. Precedence: if a default
    # appears in BOTH the disabled list AND is overridden by a same-name user
    # agent, the user agent still runs (as user-override); the default never does.
    ($defaults
        | map(select(.name as $n | ($disabled_defaults | index($n)) == null))
        | map(. + {kind: "default"})
        | map(.name as $n | . + {changed_files: (
            [$user_agents_raw[] | select(.name == $n) | .changed_files[]] as $claimed |
            .scope as $s |
            (if $s == "/" then $files
             else [$files[] | select(startswith($s | ltrimstr("/")))]
             end) | map(. as $f | select(any($claimed[]; . == $f) | not))
          )})
        | map(select(.name as $n | (($overridden_default_names | index($n)) == null) or (.changed_files | length > 0)))
    ) as $effective_defaults |

    # ---- 5. User agents: tagged as override if name matches a default, else plain user ----
    # Shape asymmetry note: user agents only carry {name, scope, source,
    # instructions, kind, changed_files}. Defaults additionally carry
    # {description, model, color} from their YAML frontmatter (see
    # _load_defaults.sh). User agents come from AGENT-REVIEWERS.md markdown
    # H2 sections which have no frontmatter; their `instructions` is the
    # full body, or the .reviewers/<name>.md spec when there is one. A user
    # agent names its model with a `model: <name>` line in the first five
    # lines of its summary or, failing that, its spec; step 6 gives every
    # agent without one "sonnet", so none inherits the orchestrator session model.
    ($user_agents_raw
        | map(.name as $n | . + {kind: (if ($default_agent_names | index($n)) != null then "user-override" else "user" end)})
        | map({name, scope, source, instructions, kind, changed_files}
               + (if .summary then {summary, spec} else {} end)
               + (if .bin then {bin} else {} end)
               + {model: ([.summary // "", .instructions]
                          | map(split("\n")[0:5]
                                | map(capture("^\\s*model:\\s*[\"]?(?<m>[A-Za-z0-9._:-]+)[\"]?\\s*$").m) | first)
                          | map(select(. != null)) | first // null)})
    ) as $user_agents |

    # ---- 6. Final merged agent list, each stamped with its engine ----
    # A reviewer with nothing in its scope is not spawned. The exception is a
    # genuinely empty diff, where defaults still run (bfd); a diff that was
    # all generated files spawns nobody.
    # engine "pi" runs the agent through pi-review.sh down its pi_models chain
    # instead of a Claude Task. Per-agent `pi.agents` entries beat `pi.all`, and
    # both beat the per-user models.json chains; the
    # parser has already rejected a pi route with no model to run on. A chain
    # that starts with "claude" is just a Claude agent; "claude:<model>" also
    # sets the Task model, so config can downshift a Claude agent by cost.
    ($config.pi // {}) as $pi |
    ($user_agents + $effective_defaults) as $candidates |
    (if ($files | length) == 0 and ($excluded | length) == 0 then $candidates
     else $candidates | map(select(.changed_files | length > 0)) end
        | map(.name as $n | (($pi.agents // {})[$n]) as $v |
            (if ($v | type) == "string" or ($v | type) == "array" then $v
             elif $v == true then $pi.model
             elif $v == false then null
             elif $pi.all == true then $pi.model
             else (if $user_chains | has($n) then $user_chains[$n] else $user_chains["*"] end) | if . == false then null else . end
             end | if type == "string" then [.] else . end) as $pm |
            if $pm == null then . + {engine: "claude"}
            elif ($pm[0] | test("^claude(:|$)")) | not then . + {engine: "pi", pi_models: $pm}
            # "claude:haiku" first: a Claude agent, on that model.
            elif $pm[0] | startswith("claude:") then . + {engine: "claude", model: ($pm[0] | ltrimstr("claude:"))}
            else . + {engine: "claude"} end
            # Every agent gets a Claude model, sonnet unless it names a real one;
            # "inherit" or anything unknown would hand the Task the session model.
            | .model = (if (.model // "" | test("^(sonnet|haiku|opus|claude-[a-z0-9.-]+)$")) then .model else "sonnet" end))
    ) as $merged_agents |

    # ---- 7. Stale-pin check ----
    # Stale only if the pin predates the last defaults change. Missing or
    # unparseable pin → stale.
    (($config.defaults_version_checked // null | if type == "string" then semver else null end) as $pin |
        ($reviewers_layout | not) and ($pin == null or $pin < ($defaults_version | semver))) as $stale_pin |

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
            defaults_version: $defaults_version,
            stale_pin: $stale_pin,
            layout: (if $reviewers_layout then "reviewers" else "agent-reviewers" end),
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
                          then $iv.enabled else false end),
                skip_for: (if ($iv | type == "object") and ($iv | has("skip_for"))
                           then $iv.skip_for else [] end),
                uncertain_action: (if ($iv | type == "object") and ($iv | has("uncertain_action"))
                                   then $iv.uncertain_action else "post_with_annotation" end)
            }),
            excluded_files: $excluded,
            not_dispatched_no_files: (($candidates | map(.name)) - ($merged_agents | map(.name))),
            spawned_count: ($merged_agents | length),
            default_count: ($effective_defaults | length),
            override_count: ($overridden_default_names | length),
            user_count: ($user_agents | map(select(.kind == "user") | .name) | unique | length),
            overridden_default_names: $overridden_default_names,
            pi_count: ($merged_agents | map(select(.engine == "pi")) | length),
            # pi.agents entries naming no agent on the roster (typos, disabled defaults)
            pi_agents_unknown: ((($pi.agents // {}) | keys) - ($candidates | map(.name)))
        },
        language_detection: $language_detection
    }
'
