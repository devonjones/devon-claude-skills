#!/usr/bin/env bash
# Emit one dream marker for the `dream` plugin to mine later.
#
# Usage:
#   emit-dream-marker.sh <kind> key=value [key=value ...]
# e.g.
#   emit-dream-marker.sh reviewer-finding pr=702 round=1 \
#       reviewer=complexity-reviewer severity=P3 file=x.py line=42 \
#       disposition=wont_fix disposition_by=user finding="…" reason="…" validator=valid
#
# BEST-EFFORT: this must never fail or block the review loop, so it always
# exits 0. It is NOT silent: a dropped marker or a dropped field prints one
# line to stderr saying why, because a marker that silently fails to write is
# indistinguishable from one that was never needed. Records append to
# ~/.dream/<slug>/markers/pr-review-loop.jsonl (or $DREAM_HOME); the slug is the
# repo's common git dir name, the same from every worktree.
# See the dream plugin's references/MARKER-CONTRACT.md for the schema.

# Fold an off-contract disposition onto the MARKER-CONTRACT enum so the durable
# stream stays contract-clean (dream's acceptance math buckets exact enum
# values; anything else is silently invisible). Mirrors
# dreamlib/reviews.py:_normalize_disposition. Normalize first (lowercase, drop
# apostrophes, runs of space/hyphen -> _), so `wont-fix` / `won't fix` fold to
# the contract `wont_fix` without a case arm.
_normalize_disposition() {
  local d
  d="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d "'" \
        | sed -E 's/[[:space:]-]+/_/g')"
  case "$d" in
    verified|approved) printf 'acknowledged' ;;
    adopted)           printf 'fixed' ;;
    declined|wontfix)  printf 'wont_fix' ;;
    deferred)          printf 'out_of_scope' ;;
    abandoned)         printf 'unresolved' ;;
    *)                 printf '%s' "$d" ;;
  esac
}

_warn() { printf 'emit-dream-marker: %s\n' "$*" >&2; }

_emit() {
  command -v jq >/dev/null 2>&1 || { _warn "marker dropped: jq not installed"; return 0; }
  [ "$#" -ge 1 ] || { _warn "marker dropped: no kind given"; return 0; }
  local kind="$1"; shift

  local root common slug home dir ts
  # Slug from the common git dir, which every worktree of a repo shares
  # (--show-toplevel differs per worktree): /repo/.git -> repo, otherwise the
  # common dir's own name minus .git. Mirrors dreamlib/config.py:main_checkout.
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || root="$PWD"
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  common="${common%/}"
  [ -n "$common" ] && root="${common%.git}"
  slug="$(basename "$root")"
  home="${DREAM_HOME:-$HOME/.dream/$slug}"
  dir="$home/markers"
  mkdir -p "$dir" 2>/dev/null || { _warn "marker dropped: cannot create $dir"; return 0; }
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Fields go in as named args and come out through $ARGS.named, so a field
  # name is never read as a jq variable - $ENV is the whole process environment
  # and $__loc__ a source location.
  local jqargs=(--arg ts "$ts" --arg skill "pr-review-loop" --arg kind "$kind")
  local kv k v seen=" "
  for kv in "$@"; do
    case "$kv" in
      *=*) ;;
      *) _warn "field ignored: '$kv' has no '=' (expected key=value)"; continue ;;
    esac
    k="${kv%%=*}"; v="${kv#*=}"
    [[ "$k" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || { _warn "field ignored: '$k' is not a valid key"; continue; }
    case "$k" in ts|skill|kind) _warn "field ignored: '$k' is set by this script"; continue ;; esac
    case "$seen" in *" $k "*) _warn "field ignored: '$k' given twice, keeping the first"; continue ;; esac
    seen="$seen$k "
    # Keep the disposition on the MARKER-CONTRACT enum at the source.
    [ "$k" = "disposition" ] && v="$(_normalize_disposition "$v")"
    jqargs+=(--arg "$k" "$v")
  done

  local line
  line="$(jq -cn "${jqargs[@]}" '$ARGS.named' 2>/dev/null)" \
    || { _warn "marker dropped: could not build the record"; return 0; }
  { printf '%s\n' "$line" >> "$dir/pr-review-loop.jsonl"; } 2>/dev/null \
    || _warn "marker dropped: cannot write $dir/pr-review-loop.jsonl"
}

_emit "$@" || true
exit 0
