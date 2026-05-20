#!/usr/bin/env bash
# Detect language manifests in a repository to recommend AGENT-REVIEWERS.md
# templates.
#
# Walks the repo from --repo-root (default: cwd), looking for known
# language-manifest files at any depth, skipping common ignored dirs
# (.git, node_modules, vendor, etc.). For each (language, subtree) pair
# found, emits a JSON object with the matched language, the subtree
# (directory containing the manifest, relative to repo root), and the
# canonical manifest filename for that pair.
#
# Output: a JSON array on stdout. Empty array if no manifests found.
#
# Example output:
#   [
#     {"language": "golang", "subtree": "backend", "manifest": "go.mod"},
#     {"language": "python", "subtree": "frontend", "manifest": "pyproject.toml"}
#   ]
#
# Deduplication: when multiple manifests for the same language live in
# the same subtree (e.g., pyproject.toml AND setup.py), the canonical
# one wins. Priority within Python is pyproject.toml > setup.py >
# requirements.txt.
#
# Usage:
#   detect-language.sh [--repo-root <path>]

set -euo pipefail

REPO_ROOT="."
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
        *)
            echo "Error: unknown argument '$1'" >&2
            echo "Usage: detect-language.sh [--repo-root <path>]" >&2
            exit 2
            ;;
    esac
done

if [[ ! -d "$REPO_ROOT" ]]; then
    echo "Error: repo root '$REPO_ROOT' is not a directory" >&2
    exit 2
fi

REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

# Manifest → (language, priority). Priority is 0=canonical, higher=fallback.
# Languages and priorities here are the source of truth for detection.
manifest_to_lang_priority() {
    case "$1" in
        go.mod)           echo "golang 0" ;;
        pyproject.toml)   echo "python 0" ;;
        setup.py)         echo "python 1" ;;
        requirements.txt) echo "python 2" ;;
        *)                return 1 ;;
    esac
}

# Build the list of manifests we want to find.
all_manifests=(go.mod pyproject.toml setup.py requirements.txt)

# Directories to skip during the walk.
skip_dirs=(.git node_modules vendor .venv venv __pycache__ dist build target .beads .next .tox .mypy_cache .pytest_cache .ruff_cache)

# Build the find prune expression.
prune_args=()
for d in "${skip_dirs[@]}"; do
    prune_args+=(-name "$d" -prune -o)
done

# Build the -name expression for the find search. Conditionally insert
# `-o` between terms rather than appending then unsetting the trailing
# element — the latter is fragile if `all_manifests` is ever empty.
name_args=()
for m in "${all_manifests[@]}"; do
    [[ ${#name_args[@]} -gt 0 ]] && name_args+=(-o)
    name_args+=(-name "$m")
done

# Defensive guard: an empty name_args would make `find ... \( \)` a
# syntax error. Today all_manifests is hardcoded non-empty, but if
# the manifest list ever becomes config-driven, this guard prevents
# a confusing crash.
if [[ ${#name_args[@]} -eq 0 ]]; then
    echo "[]"
    exit 0
fi

# Run find inside the repo root so paths are clean relative.
found_files="$(
    cd "$REPO_ROOT"
    find . "${prune_args[@]}" -type f \( "${name_args[@]}" \) -print 2>/dev/null \
    | sed 's|^\./||'
)"

# Convert each found path into a JSON object {language, subtree, manifest, priority}
# then sort + dedup so the canonical manifest wins per (language, subtree).
entries_json="["
sep=""
while IFS= read -r relpath; do
    [[ -z "$relpath" ]] && continue
    mfile="$(basename "$relpath")"
    subtree="$(dirname "$relpath")"

    # Look up language + priority for this manifest. Skip if unknown.
    if ! lookup="$(manifest_to_lang_priority "$mfile")"; then
        continue
    fi
    lang="${lookup% *}"
    priority="${lookup##* }"

    entry="$(jq -cn \
        --arg language "$lang" \
        --arg subtree "$subtree" \
        --arg manifest "$mfile" \
        --argjson priority "$priority" \
        '{language: $language, subtree: $subtree, manifest: $manifest, priority: $priority}')"
    entries_json+="${sep}${entry}"
    sep=","
done <<< "$found_files"
entries_json+="]"

# Sort by (language, subtree, priority); keep first per (language, subtree);
# drop the priority field from the output.
printf '%s\n' "$entries_json" | jq '
    sort_by([.language, .subtree, .priority])
    | unique_by([.language, .subtree])
    | map(del(.priority))
'
