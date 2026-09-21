#!/usr/bin/env bash
# Soul Stone Dynamic Seamless Modular Storage Engine (Production Hardened Edition)
# Supports Ubuntu 24.04+ (Noble Numbat)
set -e

# 1. Deterministic User Resolution (Always target primary desktop user, never root)
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    USER_NAME="$SUDO_USER"
elif [ -n "$PKEXEC_UID" ]; then
    USER_NAME="$(id -un "$PKEXEC_UID" 2>/dev/null || echo "mr-reaper")"
else
    # Find active logged-in graphical user or UID 1000
    USER_NAME="$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' | grep -v 'gdm\|root' | head -n1)"
    [ -z "$USER_NAME" ] && USER_NAME="$(getent passwd | awk -F: '$3 == 1000 {print $1}')"
    [ -z "$USER_NAME" ] && USER_NAME="mr-reaper"
fi

USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
[ -z "$USER_HOME" ] && USER_HOME="/home/$USER_NAME"

USER_UID="$(id -u "$USER_NAME" 2>/dev/null || echo 1000)"
USER_GID="$(id -g "$USER_NAME" 2>/dev/null || echo 1000)"

SD_MOUNT="/mnt/sdcard"
LUKS_UUID="8636c4f3-09c8-42ce-bf9b-fe273be32b3f"
BTRFS_UUID="18ceeb84-5abf-4456-88a2-d2f2fb2255f0"

# Tuned Flash Mount Options (Low write-amplification for SD cards)
BTRFS_MOUNT_OPTS="compress=zstd:1,noatime,lazytime,space_cache=v2,commit=120"

# Modular Storage Mappings (Companion User Directories)
MAPPINGS=(
    "Archives|$USER_HOME/Archives"
    "Documents|$USER_HOME/Documents"
    "Downloads|$USER_HOME/Downloads"
    "Pictures|$USER_HOME/Pictures"
    "Music|$USER_HOME/Music"
    "Videos|$USER_HOME/Videos"
    "Movies|$USER_HOME/Movies"
    "Projects|$USER_HOME/Projects"
    "Projects/Pycharm Projects|$USER_HOME/Pycharm Projects"
    "Projects/Arduino Projects|$USER_HOME/Arduino Projects"
    "Projects/Godot Projects|$USER_HOME/Godot Projects"
    "Games|$USER_HOME/Games"
)

log() {
    echo "[SoulStone $(date '+%Y-%m-%d %H:%M:%S')] $*" | logger -t soulstone-storage || true
    echo "[SoulStone] $*"
}

is_mounted() {
    mountpoint -q "$1" 2>/dev/null
}

is_mount_healthy() {
    local target="$1"
    if mountpoint -q "$target" 2>/dev/null; then
        if timeout 1.5 ls -A "$target" >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

clean_stale_mounts() {
    log "Flushing any dead/stale mounts..."
    for mapping in "${MAPPINGS[@]}"; do
        IFS="|" read -r sd_sub local_path <<< "$mapping"
        if is_mounted "$local_path"; then
            if ! is_mount_healthy "$local_path"; then
                umount -l "$local_path" 2>/dev/null || true
            fi
        fi
    done

    # Also clean any stale root mounts
    for rdir in /root/Archives /root/Documents /root/Downloads /root/Pictures /root/Music /root/Videos /root/Movies /root/Projects /root/Games; do
        if is_mounted "$rdir"; then
            umount -l "$rdir" 2>/dev/null || true
        fi
    done

    if is_mounted "$USER_HOME/Soul Stone"; then
        if ! is_mount_healthy "$USER_HOME/Soul Stone"; then
            umount -l "$USER_HOME/Soul Stone" 2>/dev/null || true
        fi
    fi

    if is_mounted "$SD_MOUNT"; then
        if ! is_mount_healthy "$SD_MOUNT"; then
            umount -l "$SD_MOUNT" 2>/dev/null || true
        fi
    fi
}

force_detach_all() {
    log "Force detaching all overlays..."
    for mapping in "${MAPPINGS[@]}"; do
        IFS="|" read -r sd_sub local_path <<< "$mapping"
        while is_mounted "$local_path"; do
            umount -l "$local_path" 2>/dev/null || break
        done
    done

    for rdir in /root/Archives /root/Documents /root/Downloads /root/Pictures /root/Music /root/Videos /root/Movies /root/Projects /root/Games; do
        while is_mounted "$rdir"; do
            umount -l "$rdir" 2>/dev/null || break
        done
    done

    while is_mounted "$USER_HOME/Soul Stone"; do
        umount -l "$USER_HOME/Soul Stone" 2>/dev/null || break
    done

    while is_mounted "$SD_MOUNT"; do
        umount -l "$SD_MOUNT" 2>/dev/null || break
    done
}

get_active_device() {
    if is_mounted "$SD_MOUNT"; then
        echo "$SD_MOUNT"
        return 0
    fi
    if [ -b "/dev/mapper/soulstone_crypt" ]; then
        echo "/dev/mapper/soulstone_crypt"
        return 0
    fi
    local dev
    dev="$(blkid -t UUID="$BTRFS_UUID" -o device 2>/dev/null | head -n1)"
    if [ -n "$dev" ] && [ -b "$dev" ]; then
        echo "$dev"
        return 0
    fi
    dev="$(blkid -t LABEL="Soul Stone" -o device 2>/dev/null | head -n1)"
    if [ -n "$dev" ] && [ -b "$dev" ]; then
        echo "$dev"
        return 0
    fi
    return 1
}

apply_flash_nodatacow() {
    local dev_path="$SD_MOUNT"
    if [ -d "$dev_path/Projects" ]; then
        chattr -R +C "$dev_path/Projects" 2>/dev/null || true
    fi
    if [ -d "$dev_path/Games/wineprefix" ]; then
        chattr -R +C "$dev_path/Games/wineprefix" 2>/dev/null || true
    fi
    if [ -d "$dev_path/Games/Heroic/Prefixes" ]; then
        chattr -R +C "$dev_path/Games/Heroic/Prefixes" 2>/dev/null || true
    fi
}

attach() {
    log "Initiating Soul Stone native overlay attachment for user '$USER_NAME'..."
    mkdir -p "$SD_MOUNT"

    clean_stale_mounts

    if ! is_mount_healthy "$SD_MOUNT"; then
        local dev
        dev="$(get_active_device || true)"
        if [ -n "$dev" ] && [ -b "$dev" ]; then
            while is_mounted "$SD_MOUNT"; do
                umount -l "$SD_MOUNT" 2>/dev/null || break
            done
            mount -t btrfs -o "$BTRFS_MOUNT_OPTS" "$dev" "$SD_MOUNT"
        else
            log "Checking for encrypted Soul Stone volume..."
            if [ -b "/dev/disk/by-uuid/$LUKS_UUID" ] && [ -f "/etc/soulstone/soulstone.key" ]; then
                cryptsetup open --key-file=/etc/soulstone/soulstone.key "/dev/disk/by-uuid/$LUKS_UUID" soulstone_crypt 2>/dev/null || true
                if [ -b "/dev/mapper/soulstone_crypt" ]; then
                    mount -t btrfs -o "$BTRFS_MOUNT_OPTS" "/dev/mapper/soulstone_crypt" "$SD_MOUNT"
                fi
            fi
        fi
    fi

    if ! is_mount_healthy "$SD_MOUNT"; then
        log "No physical Soul Stone drive found or could not mount. Aborting attach."
        return 1
    fi

    # Set user ownership and permissions
    chown "$USER_UID:$USER_GID" "$SD_MOUNT"
    chmod 755 "$SD_MOUNT"

    # Set custom volume icon on root mount
    if [ -f "$USER_HOME/.local/share/icons/sdcard.png" ]; then
        cp -f "$USER_HOME/.local/share/icons/sdcard.png" "$SD_MOUNT/.VolumeIcon.png" 2>/dev/null || true
        chown "$USER_UID:$USER_GID" "$SD_MOUNT/.VolumeIcon.png" 2>/dev/null || true
    fi

    apply_flash_nodatacow

    # 1. Bind-mount standard companion folders with non-destructive conflict reconciliation
    local conflict_dir="$USER_HOME/.soulstone_conflicts/$(date +%Y%m%d_%H%M%S)"

    for mapping in "${MAPPINGS[@]}"; do
        IFS="|" read -r sd_sub local_path <<< "$mapping"
        target_dir="$SD_MOUNT/$sd_sub"

        mkdir -p "$target_dir"
        chown -R "$USER_UID:$USER_GID" "$target_dir"
        mkdir -p "$local_path"
        chown -R "$USER_UID:$USER_GID" "$local_path"

        # Reconcile any files created locally while offline
        if [ -d "$local_path" ] && [ "$(ls -A "$local_path" 2>/dev/null)" ]; then
            if ! is_mounted "$local_path"; then
                log "Reconciling offline files: $local_path -> $target_dir (Safe Sync)..."
                mkdir -p "$conflict_dir"
                rsync -avbu --backup-dir="$conflict_dir" --remove-source-files "$local_path/" "$target_dir/" 2>/dev/null || true
                find "$local_path" -depth -mindepth 1 -type d -empty -delete 2>/dev/null || true
            fi
        fi

        # Mount bind overlay with x-gvfs-hide
        if ! is_mounted "$local_path"; then
            mount --bind -o x-gvfs-hide "$target_dir" "$local_path"
            log "Bind-mounted (hidden from dock): $target_dir -> $local_path"
        fi
    done

    # 2. Single ~/Soul Stone home portal with custom SD card icon
    local home_portal="$USER_HOME/Soul Stone"
    rm -rf "$USER_HOME/SD Card" 2>/dev/null || true
    if [ -L "$home_portal" ] || [ -f "$home_portal" ]; then
        rm -f "$home_portal"
    fi
    if ! [ -d "$home_portal" ]; then
        mkdir -p "$home_portal"
        chown "$USER_UID:$USER_GID" "$home_portal"
    fi

    if ! is_mounted "$home_portal"; then
        mount --bind "$SD_MOUNT" "$home_portal"
        log "Attached single home portal: $home_portal -> $SD_MOUNT"
    fi

    # Set GNOME custom icon on ~/Soul Stone
    su - "$USER_NAME" -c "gio set '$USER_HOME/Soul Stone' metadata::custom-icon 'file://$USER_HOME/.local/share/icons/sdcard.png' 2>/dev/null || true"

    log "Soul Stone successfully attached and active!"
}

detach() {
    log "Detaching Soul Stone modular storage..."
    sync
    force_detach_all
    log "Soul Stone detached cleanly."
}

eject() {
    log "Gracefully ejecting Soul Stone..."
    sync
    force_detach_all
    if [ -b "/dev/mapper/soulstone_crypt" ]; then
        cryptsetup close soulstone_crypt 2>/dev/null || true
    fi
    log "Soul Stone safely unmounted and closed."
    if command -v notify-send >/dev/null 2>&1; then
        su - "$USER_NAME" -c 'notify-send -i media-flash-sd "Soul Stone" "Safe to remove SD card." 2>/dev/null || true'
    fi
}

status() {
    echo "=== Soul Stone Status ==="
    if is_mounted "$SD_MOUNT"; then
        echo "Root: MOUNTED on $SD_MOUNT"
    else
        echo "Root: NOT MOUNTED (Physical card disconnected or offline)"
    fi

    echo "--- Active Directory Overlays ---"
    for mapping in "${MAPPINGS[@]}"; do
        IFS="|" read -r sd_sub local_path <<< "$mapping"
        if is_mounted "$local_path"; then
            echo " [ACTIVE NATIVE] $local_path -> $SD_MOUNT/$sd_sub"
        else
            echo " [OFFLINE LOCAL]  $local_path (internal drive)"
        fi
    done

    if is_mount_healthy "$USER_HOME/Soul Stone"; then
        echo " [ACTIVE PORTAL] $USER_HOME/Soul Stone -> $SD_MOUNT"
    else
        echo " [OFFLINE PORTAL] $USER_HOME/Soul Stone"
    fi
}

case "${1:-status}" in
    attach)
        attach
        ;;
    detach)
        detach
        ;;
    eject)
        eject
        ;;
    status)
        status
        ;;
    *)
        echo "Usage: $0 {attach|detach|eject|status}"
        exit 1
        ;;
esac
