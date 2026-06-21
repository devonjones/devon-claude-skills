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
# BEST-EFFORT: this must never fail or block the review loop. Any error (no jq,
# not a git repo, write failure) silently no-ops. Records append to
# ~/.dream/<git-root-basename>/markers/pr-review-loop.jsonl (or $DREAM_HOME).
# See the dream plugin's references/MARKER-CONTRACT.md for the schema.

_emit() {
  command -v jq >/dev/null 2>&1 || return 0
  [ "$#" -ge 1 ] || return 0
  local kind="$1"; shift

  local root slug home dir ts
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || root="$PWD"
  slug="$(basename "$root")"
  home="${DREAM_HOME:-$HOME/.dream/$slug}"
  dir="$home/markers"
  mkdir -p "$dir" 2>/dev/null || return 0
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local jqargs=(--arg ts "$ts" --arg skill "pr-review-loop" --arg kind "$kind")
  local filter='{ts:$ts, skill:$skill, kind:$kind}'
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    # Only accept jq-identifier-shaped keys: a hyphen (or other non-identifier
    # char) anywhere would make the jq filter `{a-b:$a-b}` a parse error and
    # silently drop the marker. Anchored regex rejects it fully (a glob like
    # [a-zA-Z_]* only checks the first char).
    [[ "$k" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || continue
    jqargs+=(--arg "$k" "$v")
    filter="$filter + {$k:\$$k}"
  done

  jq -cn "${jqargs[@]}" "$filter" >> "$dir/pr-review-loop.jsonl" 2>/dev/null || return 0
}

_emit "$@" 2>/dev/null || true
exit 0
