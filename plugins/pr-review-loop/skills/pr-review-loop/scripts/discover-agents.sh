#!/usr/bin/env bash
# Discover AGENT-REVIEWERS.md files for all changed files in a PR.
# Walks up from each changed file's directory to repo root, collecting
# agent definitions with hierarchical scoping (lower directories override).
#
# Usage: discover-agents.sh <pr-number>
#
# Output: JSON array of agents with name, scope, instructions, and source file.
# Also outputs context sections (non-Agents H1 sections) per scope.
#
# Example output:
# {
#   "agents": [
#     {"name": "security-reviewer", "scope": "/", "source": "/AGENT-REVIEWERS.md", "instructions": "..."},
#     {"name": "sql-injection-reviewer", "scope": "/services/api/", "source": "/services/api/AGENT-REVIEWERS.md", "instructions": "..."}
#   ],
#   "context": [
#     {"scope": "/", "section": "Guidelines", "content": "..."},
#     {"scope": "/services/api/", "section": "Guidelines", "content": "..."}
#   ]
# }

set -euo pipefail

PR_NUMBER="${1:?Usage: discover-agents.sh <pr-number>}"

REPO_ROOT="$(git rev-parse --show-toplevel)"

# Get changed files in the PR. Let gh errors propagate (set -e) so a missing
# gh, unauthenticated user, or bad PR number fails loudly instead of silently
# returning an empty agent list.
CHANGED_FILES=$(gh pr diff "$PR_NUMBER" --name-only)

if [[ -z "$CHANGED_FILES" ]]; then
    echo '{"agents":[],"context":[]}'
    exit 0
fi

# Collect unique directories containing changed files
DIRS=()
while IFS= read -r file; do
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

if [[ ${#AGENT_FILES[@]} -eq 0 ]]; then
    echo '{"agents":[],"context":[]}'
    exit 0
fi

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
    }

    /^# / {
        flush()
        h1_name = substr($0, 3)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", h1_name)
        current_h1 = h1_name
        in_agents = (h1_name == "Agents")
        current_h2 = ""
        content = ""
        next
    }

    /^## / && in_agents {
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
ALL_SECTIONS=$(
    for file in "${AGENT_FILES[@]}"; do
        parse_agent_file "$file"
    done
)

if [[ -z "$ALL_SECTIONS" ]]; then
    echo '{"agents":[],"context":[]}'
    exit 0
fi

# Merge agents: lower scope (more specific path) wins on name collision.
# Sort by scope depth (deeper first), then deduplicate by name keeping first.
# Collect context sections (no dedup needed — all are passed through).
# Build a JSON array of changed files for scoping
CHANGED_FILES_JSON=$(jq -n --arg files "$CHANGED_FILES" '$files | split("\n") | map(select(. != ""))')

printf '%s\n' "$ALL_SECTIONS" | jq -s --argjson files "$CHANGED_FILES_JSON" '
    {
        agents: (
            [.[] | select(.type == "agent")] |
            # Sort by scope depth descending (deeper = more specific = wins)
            sort_by(.scope | split("/") | length) | reverse |
            # Deduplicate by name (first occurrence wins = deepest scope)
            reduce .[] as $agent (
                {seen: {}, result: []};
                if .seen[$agent.name] then .
                else .seen[$agent.name] = true | .result += [$agent]
                end
            ) | .result |
            map({name, scope, source, instructions,
                changed_files: (
                    .scope as $s |
                    if $s == "/" then $files
                    else [$files[] | select(startswith($s | ltrimstr("/")))]
                    end
                )
            })
        ),
        context: (
            [.[] | select(.type == "context")] |
            sort_by(.scope | split("/") | length) | reverse |
            reduce .[] as $ctx (
                {seen: {}, result: []};
                if .seen[$ctx.section] then .
                else .seen[$ctx.section] = true | .result += [$ctx]
                end
            ) | .result |
            map({section, scope, source, content})
        )
    }
'
