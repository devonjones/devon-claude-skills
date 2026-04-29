#!/bin/bash
# Sync a single video-entry directory to Dropbox via rclone.
#
# Usage: sync_to_dropbox.sh <absolute-entry-dir> [--dry-run]
#
# Enforces the youtube-synthesizer convention:
#   source must be:  ~/ObsidianVaults/<vault>/sources/videos/<channel>/<entry-dir>/
#   target becomes:  dropbox:ObsidianVaults/<vault>/sources/videos/<channel>/<entry-dir>/
#
# rclone sync is destructive (it deletes anything in target that isn't in
# source). This script is the ONLY sanctioned way to invoke rclone from the
# skill — it refuses to sync if the source path doesn't match the convention,
# preventing the agent from accidentally targeting dropbox: (root) or any
# enclosing dir that holds unrelated user data.
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

# Path shape: <home>/ObsidianVaults/<vault>/sources/videos/<entry-dir>
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

if [[ ${#PARTS[@]} -ne 5 ]]; then
    echo "Error: expected exactly 5 path components after $EXPECTED_PREFIX/" >&2
    echo "  got: $RELATIVE (${#PARTS[@]} components)" >&2
    echo "  expected shape: <vault>/sources/videos/<channel>/<entry-dir>" >&2
    exit 1
fi

VAULT_NAME="${PARTS[0]}"
SOURCES_LITERAL="${PARTS[1]}"
VIDEOS_LITERAL="${PARTS[2]}"
CHANNEL_NAME="${PARTS[3]}"
ENTRY_NAME="${PARTS[4]}"

if [[ "$SOURCES_LITERAL" != "sources" ]]; then
    echo "Error: expected component 2 to be 'sources', got '$SOURCES_LITERAL'" >&2
    exit 1
fi
if [[ "$VIDEOS_LITERAL" != "videos" ]]; then
    echo "Error: expected component 3 to be 'videos', got '$VIDEOS_LITERAL'" >&2
    exit 1
fi
if [[ -z "$VAULT_NAME" || -z "$CHANNEL_NAME" || -z "$ENTRY_NAME" ]]; then
    echo "Error: vault, channel, and entry names must all be non-empty" >&2
    exit 1
fi

TARGET="dropbox:ObsidianVaults/$VAULT_NAME/sources/videos/$CHANNEL_NAME/$ENTRY_NAME/"

# Sanity check the target one more time — this is paranoia, since the
# composition above can only produce a per-entry path, but the cost of
# being wrong (wiping unrelated Dropbox content) is too high to skip.
if [[ "$TARGET" == "dropbox:" \
   || "$TARGET" == "dropbox:ObsidianVaults/" \
   || "$TARGET" == "dropbox:ObsidianVaults/$VAULT_NAME/" \
   || "$TARGET" == "dropbox:ObsidianVaults/$VAULT_NAME/sources/" \
   || "$TARGET" == "dropbox:ObsidianVaults/$VAULT_NAME/sources/videos/" \
   || "$TARGET" == "dropbox:ObsidianVaults/$VAULT_NAME/sources/videos/$CHANNEL_NAME/" ]]; then
    echo "Error: refusing to sync to a too-broad target: $TARGET" >&2
    exit 1
fi

# Confirm rclone is available before we promise success
if ! command -v rclone >/dev/null 2>&1; then
    echo "Error: rclone is not installed (expected on PATH)" >&2
    echo "  install: https://rclone.org/install/" >&2
    exit 1
fi

# Confirm the dropbox: remote is configured
if ! rclone listremotes 2>/dev/null | grep -qx "dropbox:"; then
    echo "Error: rclone remote 'dropbox:' is not configured" >&2
    echo "  run: rclone config" >&2
    exit 1
fi

# Sanity check that the destination vault and channel dirs already exist on
# Dropbox. This catches the most common dangerous failure mode: a typo'd
# vault or channel name that would otherwise create a brand-new dir on
# Dropbox and silently orphan the entry away from the user's actual data.
# Both creations are intentionally manual gestures — the script will never
# auto-create either, even with a flag, because an auto-create path could be
# triggered by mistake.
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

CHANNEL_REMOTE="dropbox:ObsidianVaults/$VAULT_NAME/sources/videos/$CHANNEL_NAME/"
if ! rclone lsd "$CHANNEL_REMOTE" >/dev/null 2>&1; then
    echo "Error: channel dir does not exist on Dropbox: $CHANNEL_REMOTE" >&2
    echo "  This usually means you mistyped the channel name, or this is the first" >&2
    echo "  entry from this channel. Bootstrap the channel dir manually:" >&2
    echo "    rclone mkdir '$CHANNEL_REMOTE'" >&2
    echo "  and then re-run the sync." >&2
    exit 1
fi

echo "Syncing entry to Dropbox:"
echo "  source: $ENTRY_DIR/"
echo "  target: $TARGET"
if [[ ${#DRY_RUN[@]} -gt 0 ]]; then
    echo "  (--dry-run: rclone will report changes without making them)"
fi
echo ""

rclone sync "${DRY_RUN[@]}" "$ENTRY_DIR/" "$TARGET"
