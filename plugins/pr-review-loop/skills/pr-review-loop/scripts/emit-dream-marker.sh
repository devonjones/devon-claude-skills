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
# ~/.dream/<git-root-basename>/markers/pr-review-loop.jsonl (or $DREAM_HOME).
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
  # Slug from the MAIN checkout, not the worktree: --show-toplevel returns the
  # worktree dir, so a round run from a worktree (the mandated workflow in some
  # repos) wrote to ~/.dream/<worktree-name>/ — an orphan slug the dream skill
  # never reads. The common dir is shared by every worktree of a repo, so its
  # parent is the one stable identity. Mirrors dreamlib/config.py:main_checkout.
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || root="$PWD"
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  case "$common" in
    */.git) root="${common%/.git}" ;;
  esac
  slug="$(basename "$root")"
  home="${DREAM_HOME:-$HOME/.dream/$slug}"
  dir="$home/markers"
  mkdir -p "$dir" 2>/dev/null || { _warn "marker dropped: cannot create $dir"; return 0; }
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local jqargs=(--arg ts "$ts" --arg skill "pr-review-loop" --arg kind "$kind")
  local filter='{ts:$ts, skill:$skill, kind:$kind}'
  local kv k v
  for kv in "$@"; do
    case "$kv" in
      *=*) ;;
      *) _warn "field ignored: '$kv' has no '=' (expected key=value)"; continue ;;
    esac
    k="${kv%%=*}"; v="${kv#*=}"
    # Only accept jq-identifier-shaped keys: a hyphen (or other non-identifier
    # char) anywhere would make the jq filter `{a-b:$a-b}` a parse error and
    # silently drop the marker. Anchored regex rejects it fully (a glob like
    # [a-zA-Z_]* only checks the first char).
    [[ "$k" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || { _warn "field ignored: '$k' is not a valid key"; continue; }
    # ts, skill and kind are set by this script. jq keeps the first binding of a
    # repeated --arg, so a caller's value was already ignored - but silently.
    case "$k" in ts|skill|kind) _warn "field ignored: '$k' is reserved"; continue ;; esac
    # Keep the disposition on the MARKER-CONTRACT enum at the source.
    [ "$k" = "disposition" ] && v="$(_normalize_disposition "$v")"
    jqargs+=(--arg "$k" "$v")
    filter="$filter + {$k:\$$k}"
  done

  local line
  line="$(jq -cn "${jqargs[@]}" "$filter" 2>/dev/null)" \
    || { _warn "marker dropped: could not build the record"; return 0; }
  { printf '%s\n' "$line" >> "$dir/pr-review-loop.jsonl"; } 2>/dev/null \
    || _warn "marker dropped: cannot write $dir/pr-review-loop.jsonl"
}

_emit "$@" || true
exit 0
