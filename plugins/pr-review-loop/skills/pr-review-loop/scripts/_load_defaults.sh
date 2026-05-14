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
# Diagnostics: warns to stderr (and SKIPS the offending file) when an agent
# file has a malformed or missing frontmatter or an empty `name` — a default
# loaded with empty fields would lead to a confusing failure far from the
# root cause, so failing loudly here is safer.
#
# Usage: _load_defaults.sh [--agents-dir <path>]
# Default agents dir is <script-dir>/../../../agents (i.e., plugins/pr-review-loop/agents)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Normalize the default path so the `..` segments don't leak into output.
# Warn if the agents directory can't be resolved — a broken install would
# otherwise silently load zero defaults.
if DEFAULT_AGENTS_DIR="$(cd "$SCRIPT_DIR/../../../agents" 2>/dev/null && pwd)"; then
    :
else
    echo "Warning: default agents dir not found at $SCRIPT_DIR/../../../agents — plugin install may be incomplete" >&2
    DEFAULT_AGENTS_DIR=""
fi

AGENTS_DIR="$DEFAULT_AGENTS_DIR"
if [[ "${1:-}" == "--agents-dir" ]]; then
    AGENTS_DIR="$(cd "${2:?Usage: _load_defaults.sh [--agents-dir <path>]}" && pwd)"
fi

if [[ ! -d "$AGENTS_DIR" ]]; then
    echo "Warning: agents directory does not exist: $AGENTS_DIR — no default reviewers will load" >&2
    echo "[]"
    exit 0
fi

# Find all .md files in the agents dir (not recursive — defaults are flat)
shopt -s nullglob
agent_files=("$AGENTS_DIR"/*.md)
shopt -u nullglob

if [[ ${#agent_files[@]} -eq 0 ]]; then
    echo "Warning: no agent files found in $AGENTS_DIR — no default reviewers will load" >&2
    echo "[]"
    exit 0
fi

# Find the repo root so we can compute a stable source path
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"

# Parse one agent file. Returns:
#   stdout: JSON line for the agent, OR empty if invalid (with stderr warning)
#   exit 0 always (warnings are non-fatal)
#
# Uses portable substr-based frontmatter parsing (works on both gawk and BSD
# awk on macOS). The gawk-only `match(s, /re/, arr)` capture-group form is
# avoided here so /usr/bin/awk on macOS produces the same output.
parse_default() {
    local file="$1"
    local rel_path
    if [[ -n "$REPO_ROOT" ]]; then
        rel_path="${file#$REPO_ROOT/}"
    else
        rel_path="$file"
    fi

    awk -v source="$rel_path" -v warn_target="/dev/stderr" '
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
    # Inside frontmatter: parse top-level scalars only.
    # Portable parser: match "key: value" via substr (no gawk capture arrays).
    in_frontmatter {
        line = $0
        # Find the first colon — frontmatter keys are identifiers followed by ":"
        colon = index(line, ":")
        if (colon < 2) next
        key = substr(line, 1, colon - 1)
        # Validate key is an identifier (alpha/underscore + alphanumeric)
        if (key !~ /^[a-zA-Z_][a-zA-Z0-9_]*$/) next
        # Trim whitespace and strip optional surrounding quotes from value
        val = substr(line, colon + 1)
        sub(/^[[:space:]]+/, "", val)
        sub(/[[:space:]]+$/, "", val)
        sub(/^"/, "", val); sub(/"$/, "", val)
        sub(/^'\''/, "", val); sub(/'\''$/, "", val)
        if (key == "name") name = val
        else if (key == "description") description = val
        else if (key == "model") model = val
        else if (key == "color") color = val
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
        # Reject files with malformed/missing frontmatter or empty name.
        # A nameless agent would fail far from the root cause downstream.
        if (!seen_frontmatter) {
            print "Warning: " source " has no YAML frontmatter (no --- markers); skipping" > warn_target
            exit 0
        }
        if (in_frontmatter) {
            print "Warning: " source " frontmatter never closes (missing second ---); skipping" > warn_target
            exit 0
        }
        if (name == "") {
            print "Warning: " source " has empty or missing `name` field in frontmatter; skipping" > warn_target
            exit 0
        }
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
