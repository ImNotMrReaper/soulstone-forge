#!/usr/bin/env bash
# Soul Stone On-Demand File & Folder Linker
# Allows users to right-click any file/folder in Nautilus to link/unlink to Soul Stone

set -e

SD_MOUNT="/mnt/sdcard"
LINKED_BASE="$SD_MOUNT/Linked"
SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
SPACE_MARGIN=$((256 * 1024 * 1024))   # keep this much free on the destination

# Determine target user: the caller when unprivileged (Nautilus), else the sudo user.
if [ "$(id -u)" != 0 ]; then
    RUN_USER="$(id -un)"
elif [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    RUN_USER="$SUDO_USER"
else
    RUN_USER="$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' | grep -v 'gdm\|root' | head -n1)"
    [ -z "$RUN_USER" ] && RUN_USER="mr-reaper"
fi

USER_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
[ -z "$USER_HOME" ] && USER_HOME="/home/$RUN_USER"
USER_UID="$(id -u "$RUN_USER" 2>/dev/null || echo 1000)"
USER_GID="$(id -g "$RUN_USER" 2>/dev/null || echo 1000)"

# Desktop notification. Arguments go straight to notify-send (never through a shell),
# so file names with quotes or $(...) cannot break or inject into the command.
send_notify() {
    local urgency="$1" icon="$2" title="$3" msg="$4"
    [ -n "${SS_QUIET:-}" ] && return 0
    command -v notify-send >/dev/null 2>&1 || return 0
    if [ "$(id -u)" = "$USER_UID" ]; then
        notify-send -a "Soul Stone" -u "$urgency" -i "$icon" -- "$title" "$msg" 2>/dev/null || true
    else
        runuser -u "$RUN_USER" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" \
            notify-send -a "Soul Stone" -u "$urgency" -i "$icon" -- "$title" "$msg" 2>/dev/null || true
    fi
}

# fail MSG: report to the terminal/journal AND the desktop (Nautilus shows no stdout), then stop.
fail() {
    echo "[SoulStone] $*" >&2
    logger -t soulstone-link "$*" 2>/dev/null || true
    send_notify "critical" "dialog-error" "Soul Stone" "$*"
    exit 1
}

is_sd_healthy() {
    mountpoint -q "$SD_MOUNT" 2>/dev/null && timeout 1.5 ls -A "$SD_MOUNT" >/dev/null 2>&1
}

# is_on_soulstone PATH: the item already lives on the Soul Stone filesystem (inside an
# overlay such as ~/Documents, the ~/Soul Stone portal, or /mnt/sdcard itself).
# Only meaningful while the SD is mounted.
is_on_soulstone() {
    local p; p="$(realpath -m -- "$1")"
    while [ ! -e "$p" ] && [ "$p" != / ]; do p="$(dirname -- "$p")"; done
    [ "$(stat -c %d -- "$p" 2>/dev/null)" = "$(stat -c %d -- "$SD_MOUNT" 2>/dev/null)" ]
}

# need_space ITEM DEST_DIR: fail unless DEST_DIR's filesystem can hold ITEM plus a margin.
need_space() {
    local need avail
    need="$(du -sb -- "$1" 2>/dev/null | cut -f1)"
    avail="$(df -B1 --output=avail -- "$2" 2>/dev/null | tail -n1 | tr -d ' ')"
    [ -n "$need" ] && [ -n "$avail" ] || return 0
    if [ "$need" -gt $((avail - SPACE_MARGIN)) ]; then
        fail "Not enough space for '$(basename -- "$1")': needs $(numfmt --to=iec "$need"), $(numfmt --to=iec "$avail") free on $(df --output=target -- "$2" | tail -n1). Nothing was moved."
    fi
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
    # Hidden items (.bashrc, .profile, .git, app state) must stay on the internal drive:
    # an ejected card would break the shell or the app that owns them.
    case "/$rel" in
        */.*) ss_warn "refusing to link hidden item '~/$rel' (settings and app data stay on the internal drive)"; return 1 ;;
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
    [ -n "$target" ] || fail "Usage: soulstone-link link <path>..."
    target="${target%/}"
    local base_name="$(basename -- "$target")"

    is_sd_healthy || fail "Soul Stone is offline. Connect and unlock it to link '$base_name'."
    [ -e "$target" ] || [ -L "$target" ] || fail "'$target' does not exist."

    if is_linked "$target"; then
        send_notify "normal" "drive-removable-media" "Soul Stone" "'$base_name' is already linked to Soul Stone."
        exit 0
    fi

    local why
    why="$(ss_link_target_ok "$target" 2>&1)" || fail "Can't link '$base_name': ${why##*WARN\] }"
    [ -L "$target" ] && fail "'$base_name' is a shortcut (symlink). Link the item it points to instead."
    is_on_soulstone "$target" && fail "'$base_name' is already stored on Soul Stone (it lives in a Soul Stone folder), so there is nothing to move."
    need_space "$target" "$SD_MOUNT"

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
        ss_safe_migrate "$target" "$sd_dest" "$stash" \
            || fail "Could not move every file of '$base_name' to Soul Stone. The folder was left in place and nothing was deleted. Stash: $stash"
        # Only empty directories remain; ss_remove_empty_tree refuses if any file is left.
        ss_remove_empty_tree "$target" \
            || fail "'$base_name' still holds data after the move, so it was not replaced with a link."
        ln -s -- "$sd_dest" "$target" \
            || fail "Moved '$base_name' to Soul Stone but could not create the link. The data is safe at $sd_dest."
        chown -h "$USER_UID:$USER_GID" "$target" 2>/dev/null || true
    else
        if [ -e "$sd_dest" ] || [ -L "$sd_dest" ]; then
            fail "'$base_name' already exists on Soul Stone at $sd_dest. Refusing to overwrite it."
        fi
        mv -n -- "$target" "$sd_dest" || fail "Could not move '$base_name' to Soul Stone. Nothing was changed."
        [ -e "$target" ] && fail "'$base_name' could not be moved (still in place). Nothing was changed."
        chown "$USER_UID:$USER_GID" "$sd_dest" 2>/dev/null || true
        if ! ln -s -- "$sd_dest" "$target"; then
            mv -n -- "$sd_dest" "$target"   # put the file back rather than leave it unreachable
            fail "Could not create the link for '$base_name'. The file was put back."
        fi
        chown -h "$USER_UID:$USER_GID" "$target" 2>/dev/null || true
    fi

    send_notify "normal" "drive-removable-media" "Soul Stone" "Linked '$base_name' to Soul Stone."
    echo "[SoulStone] Linked '$target' -> '$sd_dest'"
}

cmd_unlink() {
    local target="$1"
    [ -n "$target" ] || fail "Usage: soulstone-link unlink <path>..."
    target="${target%/}"
    local base_name="$(basename -- "$target")"
    if [ -L "$target" ]; then
        # The symlink is the only pointer to the data, so it stays until a verified copy exists.
        is_sd_healthy || fail "Soul Stone is offline. Connect it to unlink '$base_name'. Nothing was changed."
        local sd_dest="$(readlink -f -- "$target")"
        case "$sd_dest" in
            "$LINKED_BASE"/?*) ;;
            *) fail "'$base_name' points to '$sd_dest', which Soul Stone Link did not create. Leaving it alone." ;;
        esac
        [ -e "$sd_dest" ] || fail "'$base_name' points to '$sd_dest', which is missing on Soul Stone. Leaving the link in place."
        local staging="$target.soulstone-restoring"
        if [ -e "$staging" ] || [ -L "$staging" ]; then
            fail "'$staging' already exists (an earlier unlink was interrupted?). Check it and remove it by hand."
        fi
        need_space "$sd_dest" "$(dirname -- "$target")"
        if [ -d "$sd_dest" ]; then
            mkdir "$staging"
            if ! rsync -a -- "$sd_dest/" "$staging/" \
               || [ -n "$(rsync -a --dry-run --itemize-changes -- "$sd_dest/" "$staging/" 2>&1)" ]; then
                fail "Copying '$base_name' back to the internal drive failed or did not verify. The Soul Stone copy and the link were kept. Partial copy: $staging"
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
                fail "Copying '$base_name' back did not verify. The Soul Stone copy and the link were kept."
            fi
            chown "$USER_UID:$USER_GID" "$staging"
            rm -f -- "$target"
            mv -T -- "$staging" "$target"
            rm -f -- "$sd_dest"
        else
            fail "'$sd_dest' is not a regular file or folder. Leaving the link in place."
        fi
        send_notify "normal" "drive-harddisk" "Soul Stone" "Unlinked '$base_name' (restored to internal SSD)."
        echo "[SoulStone] Unlinked '$target' from '$sd_dest'"
        exit 0
    elif mountpoint -q "$target"; then
        send_notify "normal" "dialog-warning" "Soul Stone" "'$base_name' is an active system overlay mount. Manage it via ~/.config/soulstone/overlays.conf."
        exit 0
    else
        fail "'$base_name' is not linked to Soul Stone."
    fi
}

# run_batch link|unlink PATH...: one lock for the whole batch; each item runs in its own
# process so `set -e` and `exit` stay per-item, then one summary notification.
run_batch() {
    local cmd="$1"; shift
    [ $# -gt 0 ] || fail "Usage: soulstone-link $cmd <path>..."
    if [ -z "${SS_NOLOCK:-}" ]; then
        exec 9>"${XDG_RUNTIME_DIR:-/tmp}/soulstone-link.$(id -u).lock"
        flock -w 120 9 || fail "Another Soul Stone link operation is still running. Try again in a moment."
    fi
    if [ $# -eq 1 ]; then "cmd_$cmd" "$1"; return; fi
    local p done=0 failed=()
    for p in "$@"; do
        if SS_QUIET=1 SS_NOLOCK=1 bash "$SELF" "$cmd" "$p"; then done=$((done + 1)); else failed+=("$(basename -- "$p")"); fi
    done
    local verb="Linked"; [ "$cmd" = unlink ] && verb="Unlinked"
    if [ ${#failed[@]} -eq 0 ]; then
        send_notify "normal" "drive-removable-media" "Soul Stone" "$verb $done items."
    else
        send_notify "critical" "dialog-warning" "Soul Stone" "$verb $done of $#. Failed: ${failed[*]}. Run 'soulstone-link $cmd <item>' in a terminal for details; nothing was lost."
        return 1
    fi
}

# Run the CLI only when executed, so tests can source the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "$1" in
        link|unlink)
            cmd="$1"; shift
            run_batch "$cmd" "$@"
            ;;
        is-linked)
            is_linked "$2"
            ;;
        *)
            echo "Usage: $0 {link|unlink} <path>... | is-linked <path>"
            exit 1
            ;;
    esac
fi
