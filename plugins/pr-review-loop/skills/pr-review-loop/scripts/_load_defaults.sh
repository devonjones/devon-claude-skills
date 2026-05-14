#!/usr/bin/env bash
# Load default specialist agents from the plugin's agents/ directory.
# Each file under <plugin>/agents/<name>.md is parsed as a native subagent:
#   - YAML frontmatter between --- markers (name, description, model, color)
#   - Body: everything after the closing ---
#
# Output: JSON array on stdout, one object per default agent:
#   [
#     {
#       "name": "silent-failure-hunter",
#       "description": "...",
#       "model": "opus",
#       "color": "yellow",
#       "scope": "/",
#       "source": "plugins/pr-review-loop/agents/silent-failure-hunter.md",
#       "instructions": "<body>",
#       "kind": "default"
#     },
#     ...
#   ]
#
# Usage: _load_defaults.sh [--agents-dir <path>]
# Default agents dir is <script-dir>/../../../agents (i.e., plugins/pr-review-loop/agents)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Normalize the default path so the `..` segments don't leak into output
DEFAULT_AGENTS_DIR="$(cd "$SCRIPT_DIR/../../../agents" 2>/dev/null && pwd)" || DEFAULT_AGENTS_DIR=""

AGENTS_DIR="$DEFAULT_AGENTS_DIR"
if [[ "${1:-}" == "--agents-dir" ]]; then
    AGENTS_DIR="$(cd "${2:?Usage: _load_defaults.sh [--agents-dir <path>]}" && pwd)"
fi

if [[ ! -d "$AGENTS_DIR" ]]; then
    echo "[]"
    exit 0
fi

# Find all .md files in the agents dir (not recursive — defaults are flat)
shopt -s nullglob
agent_files=("$AGENTS_DIR"/*.md)
shopt -u nullglob

if [[ ${#agent_files[@]} -eq 0 ]]; then
    echo "[]"
    exit 0
fi

# Find the repo root so we can compute a stable source path
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"

# Parse each file: extract frontmatter scalars + body. Output JSON line per file.
parse_default() {
    local file="$1"
    local rel_path
    if [[ -n "$REPO_ROOT" ]]; then
        rel_path="${file#$REPO_ROOT/}"
    else
        rel_path="$file"
    fi

    awk -v source="$rel_path" '
    function json_escape(s) {
        gsub(/\\/, "\\\\", s)
        gsub(/"/, "\\\"", s)
        gsub(/\n/, "\\n", s)
        gsub(/\r/, "\\r", s)
        gsub(/\t/, "\\t", s)
        return s
    }
    BEGIN {
        in_frontmatter = 0
        seen_frontmatter = 0
        name = ""; description = ""; model = ""; color = ""
        body = ""
    }
    # First --- opens frontmatter; second --- closes it
    /^---[[:space:]]*$/ {
        if (!seen_frontmatter) {
            in_frontmatter = 1
            seen_frontmatter = 1
            next
        } else if (in_frontmatter) {
            in_frontmatter = 0
            next
        }
    }
    # Inside frontmatter: parse top-level scalars only
    in_frontmatter {
        if (match($0, /^([a-zA-Z_][a-zA-Z0-9_]*):[[:space:]]*(.*)$/, m)) {
            key = m[1]
            val = m[2]
            # Strip surrounding quotes if present
            sub(/^"/, "", val); sub(/"$/, "", val)
            sub(/^'\''/, "", val); sub(/'\''$/, "", val)
            if (key == "name") name = val
            else if (key == "description") description = val
            else if (key == "model") model = val
            else if (key == "color") color = val
        }
        next
    }
    # After frontmatter closes: accumulate body
    {
        if (body == "") body = $0
        else body = body "\n" $0
    }
    END {
        # Skip leading blank lines from body
        sub(/^\n+/, "", body)
        printf "{\"name\":\"%s\",\"description\":\"%s\",\"model\":\"%s\",\"color\":\"%s\",\"scope\":\"/\",\"source\":\"%s\",\"instructions\":\"%s\",\"kind\":\"default\"}\n", \
            json_escape(name), json_escape(description), json_escape(model), json_escape(color), \
            json_escape(source), json_escape(body)
    }
    ' "$file"
}

# Collect all per-file JSON lines, then wrap in array via jq
{
    for f in "${agent_files[@]}"; do
        parse_default "$f"
    done
} | jq -s '.'
