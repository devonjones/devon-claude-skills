#!/bin/bash
# Sync a single source-entry directory to Dropbox via rclone.
#
# Usage: sync_to_dropbox.sh <absolute-entry-dir> [--dry-run]
#
# Handles two source-entry shapes:
#   video entries: ~/ObsidianVaults/<vault>/sources/videos/<channel>/<entry-dir>/
#                  → dropbox:ObsidianVaults/<vault>/sources/videos/<channel>/<entry-dir>/
#   book leaves:   ~/ObsidianVaults/<vault>/sources/books/<book-dir>/
#                  → dropbox:ObsidianVaults/<vault>/sources/books/<book-dir>/
#
# rclone sync is destructive (it deletes anything in target that isn't in
# source). This script is the ONLY sanctioned way to invoke rclone from the
# skill — it refuses to sync if the source path doesn't match a recognized
# convention, preventing the agent from accidentally targeting dropbox: (root)
# or any enclosing dir that holds unrelated user data.
#
# The path-shape rules are checked BEFORE rclone runs. There is no escape
# hatch: a user with a different vault layout should run rclone manually
# outside the skill rather than try to subvert this script.
#
# Exit codes:
#   0 - sync succeeded
#   1 - validation failed or rclone returned non-zero

set -euo pipefail

ENTRY_DIR="${1:?Usage: sync_to_dropbox.sh <absolute-entry-dir> [--dry-run]}"
shift || true

DRY_RUN=()
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=(--dry-run)
    shift || true
fi

# Resolve to absolute path with symlinks expanded; reject anything that
# doesn't resolve to an existing directory.
if [[ ! -e "$ENTRY_DIR" ]]; then
    echo "Error: entry dir does not exist: $ENTRY_DIR" >&2
    exit 1
fi
ENTRY_DIR="$(cd "$ENTRY_DIR" && pwd -P)"
if [[ ! -d "$ENTRY_DIR" ]]; then
    echo "Error: entry dir is not a directory: $ENTRY_DIR" >&2
    exit 1
fi

# Path shape begins with: <home>/ObsidianVaults/<vault>/...
EXPECTED_PREFIX="${HOME}/ObsidianVaults"

# `cd` resolves macOS /private/var vs /var symlinks, but $HOME may not have
# the same form — re-resolve EXPECTED_PREFIX the same way.
if [[ -d "$EXPECTED_PREFIX" ]]; then
    EXPECTED_PREFIX="$(cd "$EXPECTED_PREFIX" && pwd -P)"
fi

if [[ "$ENTRY_DIR" != "$EXPECTED_PREFIX"/* ]]; then
    echo "Error: source must be under $EXPECTED_PREFIX/" >&2
    echo "  got: $ENTRY_DIR" >&2
    exit 1
fi

RELATIVE="${ENTRY_DIR#"$EXPECTED_PREFIX"/}"
IFS='/' read -ra PARTS <<< "$RELATIVE"

# Detect source type by component count and structure.
#   videos: 5 components (vault / sources / videos / channel / entry)
#   books:  4 components (vault / sources / books / book)
if [[ ${#PARTS[@]} -eq 5 \
      && "${PARTS[1]}" == "sources" \
      && "${PARTS[2]}" == "videos" ]]; then
    SOURCE_TYPE="video"
    VAULT_NAME="${PARTS[0]}"
    CHANNEL_NAME="${PARTS[3]}"
    ENTRY_NAME="${PARTS[4]}"
    if [[ -z "$VAULT_NAME" || -z "$CHANNEL_NAME" || -z "$ENTRY_NAME" ]]; then
        echo "Error: vault, channel, and entry names must all be non-empty" >&2
        exit 1
    fi
    TARGET="dropbox:ObsidianVaults/$VAULT_NAME/sources/videos/$CHANNEL_NAME/$ENTRY_NAME/"
    PARENT_REMOTE="dropbox:ObsidianVaults/$VAULT_NAME/sources/videos/$CHANNEL_NAME/"
    PARENT_DESC="channel"
    PARENT_HINT="If this is the first entry from this channel, bootstrap the channel dir manually:
    rclone mkdir '$PARENT_REMOTE'
  and then re-run the sync."
elif [[ ${#PARTS[@]} -eq 4 \
        && "${PARTS[1]}" == "sources" \
        && "${PARTS[2]}" == "books" ]]; then
    SOURCE_TYPE="book"
    VAULT_NAME="${PARTS[0]}"
    BOOK_NAME="${PARTS[3]}"
    if [[ -z "$VAULT_NAME" || -z "$BOOK_NAME" ]]; then
        echo "Error: vault and book names must both be non-empty" >&2
        exit 1
    fi
    TARGET="dropbox:ObsidianVaults/$VAULT_NAME/sources/books/$BOOK_NAME/"
    PARENT_REMOTE="dropbox:ObsidianVaults/$VAULT_NAME/sources/books/"
    PARENT_DESC="books root"
    PARENT_HINT="If this is the first book in this vault, bootstrap the books root manually:
    rclone mkdir '$PARENT_REMOTE'
  and then re-run the sync."
else
    echo "Error: path does not match a recognized source-entry shape" >&2
    echo "  expected one of:" >&2
    echo "    $EXPECTED_PREFIX/<vault>/sources/videos/<channel>/<entry>" >&2
    echo "    $EXPECTED_PREFIX/<vault>/sources/books/<book>" >&2
    echo "  got: $RELATIVE (${#PARTS[@]} components)" >&2
    exit 1
fi

# Defense in depth: refuse too-broad targets. The composition above can only
# produce a per-entry path, but the cost of being wrong (wiping unrelated
# Dropbox content) is too high to skip this check.
case "$TARGET" in
    "dropbox:" \
    | "dropbox:ObsidianVaults/" \
    | "dropbox:ObsidianVaults/$VAULT_NAME/" \
    | "dropbox:ObsidianVaults/$VAULT_NAME/sources/" \
    | "dropbox:ObsidianVaults/$VAULT_NAME/sources/videos/" \
    | "dropbox:ObsidianVaults/$VAULT_NAME/sources/books/" \
    | "$PARENT_REMOTE")
        echo "Error: refusing to sync to a too-broad target: $TARGET" >&2
        exit 1
        ;;
esac

# Channel-only check for videos (kept separate so the error message can say
# "channel" specifically). For books we treat this as a no-op since the
# books-root check below covers the same typo surface.
if [[ "$SOURCE_TYPE" == "video" \
      && "$TARGET" == "dropbox:ObsidianVaults/$VAULT_NAME/sources/videos/$CHANNEL_NAME/" ]]; then
    echo "Error: refusing to sync to a too-broad target: $TARGET" >&2
    exit 1
fi

# Confirm rclone is available before we promise success.
if ! command -v rclone >/dev/null 2>&1; then
    echo "Error: rclone is not installed (expected on PATH)" >&2
    echo "  install: https://rclone.org/install/" >&2
    exit 1
fi

# Confirm the dropbox: remote is configured.
if ! rclone listremotes 2>/dev/null | grep -qx "dropbox:"; then
    echo "Error: rclone remote 'dropbox:' is not configured" >&2
    echo "  run: rclone config" >&2
    exit 1
fi

# Sanity check that the destination vault dir already exists on Dropbox.
# This catches a typo'd vault name that would otherwise create a brand-new
# dir on Dropbox and silently orphan the entry away from the user's actual
# data. The creation is intentionally manual — the script will never
# auto-create the vault dir, even with a flag.
VAULT_REMOTE="dropbox:ObsidianVaults/$VAULT_NAME/"
if ! rclone lsd "$VAULT_REMOTE" >/dev/null 2>&1; then
    echo "Error: vault dir does not exist on Dropbox: $VAULT_REMOTE" >&2
    echo "  This usually means you mistyped the vault name. Local vault is:" >&2
    echo "    $EXPECTED_PREFIX/$VAULT_NAME/" >&2
    echo "  If this really is a brand-new vault you've never synced before, bootstrap it manually:" >&2
    echo "    rclone mkdir '$VAULT_REMOTE'" >&2
    echo "  and then re-run the sync." >&2
    exit 1
fi

# Sanity check that the parent dir (channel for videos, books-root for books)
# already exists on Dropbox — catches the most common typo modes.
if ! rclone lsd "$PARENT_REMOTE" >/dev/null 2>&1; then
    echo "Error: $PARENT_DESC dir does not exist on Dropbox: $PARENT_REMOTE" >&2
    echo "  This usually means a typo or first-time setup." >&2
    echo "  $PARENT_HINT" >&2
    exit 1
fi

echo "Syncing $SOURCE_TYPE entry to Dropbox:"
echo "  source: $ENTRY_DIR/"
echo "  target: $TARGET"
if [[ ${#DRY_RUN[@]} -gt 0 ]]; then
    echo "  (--dry-run: rclone will report changes without making them)"
fi
echo ""

rclone sync "${DRY_RUN[@]}" "$ENTRY_DIR/" "$TARGET"
