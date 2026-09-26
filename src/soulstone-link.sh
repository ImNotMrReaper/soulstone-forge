#!/usr/bin/env bash
# Soul Stone On-Demand File & Folder Linker
# Allows users to right-click any file/folder in Nautilus to link/unlink to Soul Stone

set -e

SD_MOUNT="/mnt/sdcard"
LINKED_BASE="$SD_MOUNT/Linked"

# Determine target user
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    RUN_USER="$SUDO_USER"
else
    RUN_USER="$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' | grep -v 'gdm\|root' | head -n1)"
    [ -z "$RUN_USER" ] && RUN_USER="mr-reaper"
fi

USER_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
[ -z "$USER_HOME" ] && USER_HOME="/home/$RUN_USER"
USER_UID="$(id -u "$RUN_USER" 2>/dev/null || echo 1000)"
USER_GID="$(id -g "$RUN_USER" 2>/dev/null || echo 1000)"

send_notify() {
    local urgency="$1"
    local icon="$2"
    local title="$3"
    local msg="$4"
    if command -v notify-send >/dev/null 2>&1; then
        su - "$RUN_USER" -c "notify-send -u '$urgency' -i '$icon' '$title' '$msg' 2>/dev/null || true"
    fi
}

is_sd_healthy() {
    mountpoint -q "$SD_MOUNT" 2>/dev/null && timeout 1.5 ls -A "$SD_MOUNT" >/dev/null 2>&1
}

# >>> soulstone-safe-migrate (identical copy in soulstone-storage and soulstone-link; tests enforce this) >>>
ss_warn() { echo "[SoulStone][WARN] $*" >&2; logger -t soulstone-storage "WARN: $*" 2>/dev/null || true; }

# Prints one user-data entry still under DIR (anything except directories, sockets, fifos).
ss_leftovers() {
    find "$1" -mindepth 1 ! -type d ! -type s ! -type p -print -quit 2>/dev/null
}

# ss_safe_migrate SRC DST STASH
# Moves the FILES under SRC into DST without ever deleting user data:
#   - rsync must exit 0 (failures are no longer swallowed by `|| true`)
#   - a DST file that gets replaced is kept in STASH/replaced-on-target
#   - a SRC file skipped because DST is newer is moved to STASH/older-local
#   - SRC directories stay in place (offline skeleton parity); nothing is pruned
# Returns 0 only when SRC holds no files afterwards; the caller must not overlay,
# replace or remove SRC on a non-zero return.
ss_safe_migrate() {
    local src="${1%/}" dst="${2%/}" stash="$3"
    if [ ! -d "$src" ] || [ ! -d "$dst" ] || [ -z "$stash" ]; then
        ss_warn "safe_migrate: bad arguments (src='$src' dst='$dst')"
        return 1
    fi
    mkdir -p "$stash" || return 1
    if ! rsync -a -u -b --backup-dir="$stash/replaced-on-target" --remove-source-files "$src/" "$dst/"; then
        ss_warn "rsync failed migrating $src -> $dst; unmoved files were left in place"
        return 1
    fi
    if [ -n "$(ss_leftovers "$src")" ]; then
        ss_warn "newer copies already exist in $dst; stashing older local files in $stash/older-local"
        rsync -a --remove-source-files "$src/" "$stash/older-local/" || return 1
    fi
    [ -z "$(ss_leftovers "$src")" ]
}

# ss_valid_name NAME: single path component, no leading dot, safe charset.
ss_valid_name() {
    [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9._\ -]*$ ]] && [ "$1" != "Soul Stone" ]
}

# ss_remove_empty_tree DIR: delete DIR only if it contains no user data (empty dirs only).
ss_remove_empty_tree() {
    [ -z "$(ss_leftovers "$1")" ] || return 1
    find "$1" -depth -type d -empty -delete 2>/dev/null
    [ ! -e "$1" ]
}
# <<< soulstone-safe-migrate <<<

# ss_link_target_ok PATH: only real items inside $HOME may be linked.
ss_link_target_ok() {
    local real; real="$(realpath -m -- "$1")"
    case "$real" in
        "$USER_HOME"|"$USER_HOME/") ss_warn "refusing to link the home directory itself"; return 1 ;;
        "$USER_HOME"/*) ;;
        *) ss_warn "refusing to link '$real': outside $USER_HOME"; return 1 ;;
    esac
    local rel="${real#$USER_HOME/}" top="${real#$USER_HOME/}"; top="${top%%/*}"
    case "$top" in
        .ssh|.gnupg|.config|.local|.cache|.var|snap|"Soul Stone"|.soulstone_conflicts)
            ss_warn "refusing to link protected location '~/$top'"; return 1 ;;
    esac
    case "$rel" in
        Documents/Notes/Locked|Documents/Notes/Locked/*) ss_warn "refusing to link the locked notes vault"; return 1 ;;
    esac
    if mountpoint -q "$real" 2>/dev/null; then
        ss_warn "refusing to link '$real': it is an active mount point"; return 1
    fi
    return 0
}

is_linked() {
    local target="$1"
    [ -e "$target" ] || [ -L "$target" ] || return 1
    if [ -L "$target" ]; then
        local dest="$(readlink -f "$target" || true)"
        if [[ "$dest" == "$SD_MOUNT"* ]] || [[ "$dest" == "$USER_HOME/Soul Stone"* ]]; then
            return 0
        fi
    fi
    if mountpoint -q "$target"; then
        local src_dev="$(findmnt -n -o SOURCE "$target" 2>/dev/null || true)"
        if [[ "$src_dev" == *"soulstone"* ]]; then
            return 0
        fi
    fi
    return 1
}

cmd_link() {
    local target="$1"
    if [ -z "$target" ]; then
        echo "Usage: soulstone-link link <path>"
        exit 1
    fi

    if ! is_sd_healthy; then
        send_notify "critical" "media-flash-sd" "Soul Stone Offline" "Please connect and unlock Soul Stone to link items."
        echo "[SoulStone] SD card is offline."
        exit 1
    fi

    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        echo "Error: Target '$target' does not exist."
        exit 1
    fi

    if is_linked "$target"; then
        send_notify "normal" "drive-removable-media" "Soul Stone" "'$(basename "$target")' is already linked to Soul Stone."
        exit 0
    fi

    ss_link_target_ok "$target" || exit 1

    local base_name="$(basename "$target")"
    local rel_path
    if [[ "$target" == "$USER_HOME/"* ]]; then
        rel_path="${target#$USER_HOME/}"
    else
        rel_path="$base_name"
    fi

    local sd_dest="$LINKED_BASE/$rel_path"
    mkdir -p "$(dirname "$sd_dest")"
    mkdir -p "$LINKED_BASE"

    if [ -d "$target" ] && ! [ -L "$target" ]; then
        mkdir -p "$sd_dest"
        chown -R "$USER_UID:$USER_GID" "$sd_dest"
        local stash="$USER_HOME/.soulstone_conflicts/$(date +%Y%m%d_%H%M%S)"
        if ! ss_safe_migrate "$target" "$sd_dest" "$stash"; then
            echo "[SoulStone] Could not move every file to Soul Stone; '$target' was left as it is (nothing deleted). Stash: $stash"
            exit 1
        fi
        # Only empty directories remain; ss_remove_empty_tree refuses if any file is left.
        if ! ss_remove_empty_tree "$target"; then
            echo "[SoulStone] '$target' still holds data after migration; not replacing it with a link."
            exit 1
        fi
        ln -s "$sd_dest" "$target"
        chown -h "$USER_UID:$USER_GID" "$target"
    else
        if [ -e "$sd_dest" ] || [ -L "$sd_dest" ]; then
            echo "[SoulStone] '$sd_dest' already exists on Soul Stone; refusing to overwrite it."
            exit 1
        fi
        mv -n -- "$target" "$sd_dest"
        chown "$USER_UID:$USER_GID" "$sd_dest"
        ln -s "$sd_dest" "$target"
        chown -h "$USER_UID:$USER_GID" "$target"
    fi

    send_notify "normal" "drive-removable-media" "Soul Stone" "Linked '$base_name' to Soul Stone."
    echo "[SoulStone] Linked '$target' -> '$sd_dest'"
}

cmd_unlink() {
    local target="$1"
    if [ -z "$target" ]; then
        echo "Usage: soulstone-link unlink <path>"
        exit 1
    fi

    local base_name="$(basename "$target")"
    if [ -L "$target" ]; then
        # The symlink is the only pointer to the data, so it stays until a verified copy exists.
        if ! is_sd_healthy; then
            send_notify "critical" "media-flash-sd" "Soul Stone Offline" "Connect Soul Stone to unlink '$base_name'. Nothing was changed."
            echo "[SoulStone] SD card is offline; '$target' left untouched."
            exit 1
        fi
        local sd_dest="$(readlink -f -- "$target")"
        case "$sd_dest" in
            "$LINKED_BASE"/?*) ;;
            *) echo "[SoulStone] '$target' points to '$sd_dest', which is not under $LINKED_BASE; not managed by soulstone-link, leaving it alone."; exit 1 ;;
        esac
        if [ ! -e "$sd_dest" ]; then
            echo "[SoulStone] '$sd_dest' does not exist on Soul Stone; leaving the link in place."
            exit 1
        fi
        local staging="$target.soulstone-restoring"
        if [ -e "$staging" ] || [ -L "$staging" ]; then
            echo "[SoulStone] '$staging' already exists (interrupted earlier unlink?); remove it by hand after checking it."
            exit 1
        fi
        if [ -d "$sd_dest" ]; then
            mkdir "$staging"
            if ! rsync -a -- "$sd_dest/" "$staging/" \
               || [ -n "$(rsync -a --dry-run --itemize-changes -- "$sd_dest/" "$staging/" 2>&1)" ]; then
                echo "[SoulStone] Copy back to the internal drive failed or did not verify; Soul Stone copy and link kept. Partial copy: $staging"
                exit 1
            fi
            chown "$USER_UID:$USER_GID" "$staging"
            rm -f -- "$target"
            mv -T -- "$staging" "$target"
            # Verified identical copy now lives at $target, so the SD copy can go
            # (path is strictly under $LINKED_BASE, checked above; never crosses mounts).
            rm -rf --one-file-system -- "$sd_dest"
        elif [ -f "$sd_dest" ]; then
            cp -a -- "$sd_dest" "$staging"
            if ! cmp -s -- "$sd_dest" "$staging"; then
                rm -f -- "$staging"
                echo "[SoulStone] Copy back did not verify; Soul Stone copy and link kept."
                exit 1
            fi
            chown "$USER_UID:$USER_GID" "$staging"
            rm -f -- "$target"
            mv -T -- "$staging" "$target"
            rm -f -- "$sd_dest"
        else
            echo "[SoulStone] '$sd_dest' is not a regular file or directory; leaving the link in place."
            exit 1
        fi
        send_notify "normal" "drive-harddisk" "Soul Stone" "Unlinked '$base_name' (restored to internal SSD)."
        echo "[SoulStone] Unlinked '$target' from '$sd_dest'"
        exit 0
    elif mountpoint -q "$target"; then
        send_notify "normal" "dialog-warning" "Soul Stone" "'$base_name' is an active system overlay mount. Manage it via ~/.config/soulstone/overlays.conf."
        exit 0
    else
        echo "Target is not linked to Soul Stone."
        exit 1
    fi
}

# Run the CLI only when executed, so tests can source the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "$1" in
        link)
            cmd_link "$2"
            ;;
        unlink)
            cmd_unlink "$2"
            ;;
        is-linked)
            is_linked "$2"
            ;;
        *)
            echo "Usage: $0 {link|unlink|is-linked} <path>"
            exit 1
            ;;
    esac
fi
