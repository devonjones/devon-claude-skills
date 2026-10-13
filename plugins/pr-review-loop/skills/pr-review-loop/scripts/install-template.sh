#!/usr/bin/env bash
# Install language reviewer packs into a repository's .reviewers/ directories.
#
# Each <language>:<subtree> pair copies agent-reviewer-templates/<language>/
# (one file per reviewer, plus README.md) into <subtree>/.reviewers/. The
# starter reviewers each pack lists in its STARTERS file are written to the
# root .reviewers/, and the packs' settings are merged into
# .reviewers/config.json.
#
# Transactional: everything is staged first, and nothing is written if any
# staged file already exists in the repo. A repo that still has a root
# AGENT-REVIEWERS.md is refused; convert it first (convert-reviewers.py repo).
# Two packs at the same subtree are refused (their reviewer names collide).
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

REPO_ROOT="."
PAIRS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root) REPO_ROOT="${2:?--repo-root requires a path}"; shift 2 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --*) echo "Error: unknown flag '$1'" >&2; exit 2 ;;
        *) PAIRS+=("$1"); shift ;;
    esac
done

if [[ ${#PAIRS[@]} -eq 0 ]]; then
    echo "Error: no <lang>:<subtree> pairs provided" >&2
    echo "Usage: install-template.sh [--repo-root <path>] <lang>:<subtree> [...]" >&2
    exit 2
fi
[[ -d "$REPO_ROOT" ]] || { echo "Error: repo root '$REPO_ROOT' is not a directory" >&2; exit 2; }
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
[[ -d "$TEMPLATES_DIR" ]] || { echo "Error: templates directory not found at $TEMPLATES_DIR" >&2; exit 2; }

if [[ -f "$REPO_ROOT/AGENT-REVIEWERS.md" ]]; then
    echo "Error: $REPO_ROOT/AGENT-REVIEWERS.md exists; convert it first (convert-reviewers.py repo), then install" >&2
    exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf -- "$STAGE"' EXIT
declare -A SUBTREE_SEEN
STARTERS=()
CONFIGS=()
# An existing config.json is merged with the packs' settings, not clobbered.
[[ -f "$REPO_ROOT/.reviewers/config.json" ]] && CONFIGS+=("$(cat "$REPO_ROOT/.reviewers/config.json")")
for pair in "${PAIRS[@]}"; do
    [[ "$pair" == *:* ]] || { echo "Error: bad pair '$pair' — expected <lang>:<subtree>" >&2; exit 2; }
    lang="${pair%%:*}"
    subtree="${pair#*:}"
    if [[ -z "$lang" || -z "$subtree" ]]; then
        echo "Error: bad pair '$pair' — language and subtree both required" >&2; exit 2
    fi
    if [[ "$lang" == */* || "$lang" == .* ]]; then
        echo "Error: invalid language name '$lang' (no slashes or leading dots allowed)" >&2; exit 2
    fi
    if [[ "$subtree" == */../* || "$subtree" == ../* || "$subtree" == */.. || "$subtree" == /* ]]; then
        echo "Error: invalid subtree '$subtree' (no '..' traversal or absolute paths allowed)" >&2; exit 2
    fi
    pack="$TEMPLATES_DIR/$lang"
    [[ -d "$pack" ]] || { echo "Error: no template found for language '$lang' at $pack" >&2; exit 2; }
    subtree="${subtree%/}"; [[ "$subtree" == "./" || -z "$subtree" ]] && subtree="."
    [[ -d "$REPO_ROOT/$subtree" ]] || { echo "Error: subtree directory does not exist: $REPO_ROOT/$subtree" >&2; exit 2; }
    if [[ -n "${SUBTREE_SEEN[$subtree]:-}" ]]; then
        echo "Error: multiple packs targeting subtree '$subtree' — same-directory polyglot must be resolved manually (agent names collide)" >&2
        exit 1
    fi
    SUBTREE_SEEN[$subtree]=1

    mkdir -p "$STAGE/$subtree/.reviewers"
    cp -f "$pack"/*.md "$STAGE/$subtree/.reviewers/"
    [[ -f "$pack/STARTERS" ]] && mapfile -t -O "${#STARTERS[@]}" STARTERS < "$pack/STARTERS"
    [[ -f "$pack/config.json" ]] && CONFIGS+=("$(cat "$pack/config.json")")
    echo "Staged ${lang} -> ${subtree}/.reviewers/" >&2
done

# Starters a pack already defines at the root are its own, not the starter;
# starters the repo already has stay as they are.
WANT=()
for s in $(printf '%s\n' "${STARTERS[@]}" | sort -u); do
    [[ -f "$STAGE/.reviewers/$s.md" || -f "$REPO_ROOT/.reviewers/$s.md" ]] || WANT+=("$s")
done
if [[ ${#WANT[@]} -gt 0 ]]; then
    python3 "$SCRIPT_DIR/convert-reviewers.py" starters --into "$STAGE" "${WANT[@]}" >/dev/null
fi

if [[ ${#CONFIGS[@]} -gt 0 ]]; then
    MERGED="$(printf '%s\n' "${CONFIGS[@]}" | jq -s '
        def merge_overlap(a; b):
            if a.overlaps_with != b.overlaps_with then
                error("overlap_acknowledged conflict: overlaps_with differs (\"" + a.overlaps_with + "\" vs \"" + b.overlaps_with + "\")")
            else a + {reason: ([a.reason, b.reason] | map(select(. != null and . != "")) | unique | join(" | "))} end;
        (reduce .[] as $c ({}; . + ($c | del(.overlap_acknowledged)))) as $rest |
        $rest + reduce .[] as $c ({};
            .overlap_acknowledged = reduce ($c.overlap_acknowledged // {} | to_entries[]) as $e (
                (.overlap_acknowledged // {});
                if has($e.key) then . + {($e.key): merge_overlap(.[$e.key]; $e.value)} else . + {($e.key): $e.value} end))
        | with_entries(select(.value != {}))')" || { echo "Error: failed to merge pack configuration" >&2; exit 1; }
    if [[ "$MERGED" != "{}" ]]; then
        mkdir -p "$STAGE/.reviewers"
        printf '%s\n' "$MERGED" > "$STAGE/.reviewers/config.json"
    fi
fi

CLASH=""
while IFS= read -r f; do
    [[ "$f" == .reviewers/config.json ]] && continue   # the merge above included it
    [[ -e "$REPO_ROOT/$f" ]] && CLASH+="  $f"$'\n'
done < <(cd "$STAGE" && find . -type f | sed 's|^\./||' | sort)
if [[ -n "$CLASH" ]]; then
    printf 'Error: these already exist; refusing to overwrite anything:\n%s' "$CLASH" >&2
    exit 1
fi

cp -rf "$STAGE"/. "$REPO_ROOT"/
[[ ${#WANT[@]} -gt 0 ]] && echo "Starters -> .reviewers/: ${WANT[*]}" >&2
echo "Done. Installed ${#PAIRS[@]} pack(s)." >&2
