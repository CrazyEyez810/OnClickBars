#!/bin/bash
# Copies your addons and their account settings from the WoW Forever beta
# folder into the live client's folder, so the first login on launch day
# already has everything. Run it with WoW closed.
#
#   ./launch-day-copy.sh              finds the live folder by itself
#   ./launch-day-copy.sh _forever_    or name it
#   ./launch-day-copy.sh --dry-run    shows what it would copy

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/_classic_beta_"
DRY=0
DEST_NAME=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        *) DEST_NAME="$arg" ;;
    esac
done

run() {
    if [ "$DRY" = 1 ]; then echo "would run: $*"; else "$@"; fi
}

if pgrep -f "World of Warcraft.*\.app/Contents/MacOS" >/dev/null 2>&1; then
    echo "WoW is running. Close it first: it writes its settings on exit and would undo this copy."
    exit 1
fi

# Find the live client folder: a client folder that isn't one we already know.
if [ -z "$DEST_NAME" ]; then
    candidates=()
    for dir in "$ROOT"/_*_; do
        name="$(basename "$dir")"
        case "$name" in
            _classic_beta_|_classic_era_|_retail_|_ptr_|_xptr_|_classic_ptr_|_classic_era_ptr_) continue ;;
        esac
        [ -d "$dir" ] && candidates+=("$name")
    done
    if [ "${#candidates[@]}" -eq 0 ]; then
        echo "No live client folder found next to _classic_beta_. Install WoW Forever, start it once, close it, then run this again."
        exit 1
    elif [ "${#candidates[@]}" -gt 1 ]; then
        echo "Several client folders found: ${candidates[*]}"
        echo "Run it again with the live one, for example: ./launch-day-copy.sh ${candidates[0]}"
        exit 1
    fi
    DEST_NAME="${candidates[0]}"
fi
DEST="$ROOT/$DEST_NAME"
[ -d "$DEST" ] || { echo "Folder not found: $DEST"; exit 1; }
[ "$DEST" != "$SRC" ] || { echo "That is the beta folder itself."; exit 1; }

# The account folder from the beta (the one with saved addon settings).
SRC_ACCOUNT=""
for dir in "$SRC"/WTF/Account/*/; do
    name="$(basename "$dir")"
    [ "$name" = "SavedVariables" ] && continue
    [ -d "$dir/SavedVariables" ] && SRC_ACCOUNT="$name"
done
[ -n "$SRC_ACCOUNT" ] || { echo "No account settings found in the beta folder."; exit 1; }

# Use the live account folder if the game already made one, else the same name.
DEST_ACCOUNT="$SRC_ACCOUNT"
if [ -d "$DEST/WTF/Account" ]; then
    existing=()
    for dir in "$DEST"/WTF/Account/*/; do
        [ -d "$dir" ] || continue
        name="$(basename "$dir")"
        [ "$name" = "SavedVariables" ] && continue
        existing+=("$name")
    done
    if [ "${#existing[@]}" -eq 1 ]; then DEST_ACCOUNT="${existing[0]}"; fi
fi

echo "From: $SRC  (account $SRC_ACCOUNT)"
echo "To:   $DEST  (account $DEST_ACCOUNT)"

# Back up anything already in the live folder before overwriting it.
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$DEST/_onclickbars_backup_$STAMP"
if [ -d "$DEST/Interface/AddOns" ] || [ -d "$DEST/WTF/Account/$DEST_ACCOUNT/SavedVariables" ]; then
    run mkdir -p "$BACKUP"
    [ -d "$DEST/Interface/AddOns" ] && run cp -R "$DEST/Interface/AddOns" "$BACKUP/AddOns"
    [ -d "$DEST/WTF/Account/$DEST_ACCOUNT/SavedVariables" ] && \
        run cp -R "$DEST/WTF/Account/$DEST_ACCOUNT/SavedVariables" "$BACKUP/SavedVariables"
    echo "Backed up the live folder's current addons and settings to $BACKUP"
fi

# Addons.
run mkdir -p "$DEST/Interface/AddOns"
run rsync -a "$SRC/Interface/AddOns/" "$DEST/Interface/AddOns/"

# Account-wide addon settings (OneClickBars profiles and saved setup, RestedXP,
# Questie, Leatrix Plus, ForeverAuras, WeaponSwingTimer and the rest).
run mkdir -p "$DEST/WTF/Account/$DEST_ACCOUNT/SavedVariables"
count=0
for file in "$SRC/WTF/Account/$SRC_ACCOUNT/SavedVariables/"*.lua; do
    [ -f "$file" ] || continue
    run cp "$file" "$DEST/WTF/Account/$DEST_ACCOUNT/SavedVariables/"
    count=$((count + 1))
done

addons=$(find "$SRC/Interface/AddOns" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
echo "Copied $addons addon folders and $count addon settings files."
echo "Next: start WoW, make your character, and log in. OneClickBars loads your bars, keybindings,"
echo "macros, game settings, Edit Mode layout and addon settings, then asks once to reload: press Enter."
