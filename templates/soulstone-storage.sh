#!/usr/bin/env bash
# Soul Stone Dynamic Seamless Modular Storage Engine (Lossless Encrypted Edition)
set -e

USER_NAME="mr-reaper"
USER_HOME="/home/$USER_NAME"
SD_MOUNT="/mnt/sdcard"
LUKS_UUID="8636c4f3-09c8-42ce-bf9b-fe273be32b3f"
BTRFS_UUID="18ceeb84-5abf-4456-88a2-d2f2fb2255f0"

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
    if [ -b "/dev/disk/by-uuid/$BTRFS_UUID" ]; then
        echo "/dev/disk/by-uuid/$BTRFS_UUID"
        return 0
    fi
    local luks_map
    luks_map=$(find /dev/mapper -name "luks-*" 2>/dev/null | head -n 1)
    if [ -n "$luks_map" ] && [ -b "$luks_map" ]; then
        echo "$luks_map"
        return 0
    fi
    local label_dev
    label_dev=$(blkid -L "Soul Stone" 2>/dev/null || true)
    if [ -n "$label_dev" ] && [ -b "$label_dev" ]; then
        echo "$label_dev"
        return 0
    fi
    return 1
}

attach() {
    log "Attaching Soul Stone full modular storage..."
    mkdir -p "$SD_MOUNT"

    clean_stale_mounts

    local dev
    dev=$(get_active_device || true)

    if ! is_mount_healthy "$SD_MOUNT"; then
        if [ -n "$dev" ] && [ -b "$dev" ]; then
            while is_mounted "$SD_MOUNT"; do
                umount -l "$SD_MOUNT" 2>/dev/null || break
            done
            mount -t btrfs -o compress-force=zstd:3,noatime,autodefrag,space_cache=v2,x-gvfs-show,x-gvfs-name=Soul\\040Stone "$dev" "$SD_MOUNT"
        elif [ -d "/media/$USER_NAME/Soul Stone" ] && is_mount_healthy "/media/$USER_NAME/Soul Stone"; then
            mount --bind "/media/$USER_NAME/Soul Stone" "$SD_MOUNT"
        else
            log "No decrypted Soul Stone volume found. Attempting cryptsetup..."
            if [ -b "/dev/disk/by-uuid/$LUKS_UUID" ] && [ -f "/etc/soulstone/soulstone.key" ]; then
                cryptsetup open --key-file=/etc/soulstone/soulstone.key "/dev/disk/by-uuid/$LUKS_UUID" soulstone_crypt 2>/dev/null || true
                if [ -b "/dev/mapper/soulstone_crypt" ]; then
                    mount -t btrfs -o compress-force=zstd:3,noatime,autodefrag,space_cache=v2,x-gvfs-show,x-gvfs-name=Soul\\040Stone "/dev/mapper/soulstone_crypt" "$SD_MOUNT"
                fi
            fi
        fi
    fi

    if ! is_mount_healthy "$SD_MOUNT"; then
        log "Could not mount Soul Stone. Aborting."
        return 1
    fi

    # Set root permissions
    chown "$USER_NAME:$USER_NAME" "$SD_MOUNT"
    chmod 755 "$SD_MOUNT"

    # Set custom volume icon on root mount
    if [ -f "$USER_HOME/.local/share/icons/sdcard.png" ]; then
        cp -f "$USER_HOME/.local/share/icons/sdcard.png" "$SD_MOUNT/.VolumeIcon.png" 2>/dev/null || true
        chown "$USER_NAME:$USER_NAME" "$SD_MOUNT/.VolumeIcon.png" 2>/dev/null || true
    fi

    # 1. Bind-mount standard companion folders
    for mapping in "${MAPPINGS[@]}"; do
        IFS="|" read -r sd_sub local_path <<< "$mapping"
        target_dir="$SD_MOUNT/$sd_sub"

        mkdir -p "$target_dir"
        chown -R "$USER_NAME:$USER_NAME" "$target_dir"
        mkdir -p "$local_path"
        chown -R "$USER_NAME:$USER_NAME" "$local_path"

        # Auto-sync any files created locally while offline
        if [ -d "$local_path" ] && [ "$(ls -A "$local_path" 2>/dev/null)" ]; then
            if ! is_mounted "$local_path"; then
                log "Migrating offline files: $local_path -> $target_dir (Lossless)..."
                rsync -av --remove-source-files "$local_path/" "$target_dir/" 2>/dev/null || true
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
        chown "$USER_NAME:$USER_NAME" "$home_portal"
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
    force_detach_all
    log "Soul Stone detached cleanly."
}

status() {
    echo "=== Soul Stone Status ==="
    if is_mounted "$SD_MOUNT"; then
        echo "Root: MOUNTED on $SD_MOUNT ($(findmnt -n -o SOURCE "$SD_MOUNT" 2>/dev/null || echo "Active"))"
    else
        echo "Root: NOT MOUNTED"
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
    fi
}

case "${1:-status}" in
    attach)
        attach
        ;;
    detach)
        detach
        ;;
    status)
        status
        ;;
    *)
        echo "Usage: $0 {attach|detach|status}"
        exit 1
        ;;
esac
