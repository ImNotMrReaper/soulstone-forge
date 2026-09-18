#!/usr/bin/env bash
# Soul Stone Dynamic Seamless Modular Storage Engine
set -e

USER_NAME="mr-reaper"
USER_HOME="/home/$USER_NAME"
SD_MOUNT="/mnt/sdcard"
UUID="d13ea8f7-ccfa-45c2-bbb6-af57fd6472e2"
SD_DEV="/dev/disk/by-uuid/$UUID"

# Companion Modular Storage Mappings
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
        if ls -A "$target" >/dev/null 2>&1; then
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

    # Clean ~/Soul Stone portal mount if stale
    if is_mounted "$USER_HOME/Soul Stone"; then
        if ! is_mount_healthy "$USER_HOME/Soul Stone"; then
            umount -l "$USER_HOME/Soul Stone" 2>/dev/null || true
        fi
    fi

    # Clean dead mounts on /mnt/sdcard if device is unreadable
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

    while is_mounted "$USER_HOME/SD Card"; do
        umount -l "$USER_HOME/SD Card" 2>/dev/null || break
    done

    while is_mounted "$SD_MOUNT"; do
        umount -l "$SD_MOUNT" 2>/dev/null || break
    done
}

attach() {
    log "Attaching Soul Stone companion modular storage..."
    mkdir -p "$SD_MOUNT"

    # 1. Clean any dead mounts first
    clean_stale_mounts

    # 2. Mount root filesystem if not already mounted
    if ! is_mount_healthy "$SD_MOUNT"; then
        if [ -b "$SD_DEV" ]; then
            while is_mounted "$SD_MOUNT"; do
                umount -l "$SD_MOUNT" 2>/dev/null || break
            done
            mount -t btrfs -o compress-force=zstd:3,noatime,autodefrag,space_cache=v2 "$SD_DEV" "$SD_MOUNT"
            log "Mounted $SD_DEV to $SD_MOUNT"
        else
            log "Error: Soul Stone block device $SD_DEV not found."
            exit 1
        fi
    fi

    # 3. Process each directory mapping
    for mapping in "${MAPPINGS[@]}"; do
        IFS="|" read -r sd_sub local_path <<< "$mapping"
        local sd_path="$SD_MOUNT/$sd_sub"

        mkdir -p "$sd_path"
        chown -R "$USER_NAME:$USER_NAME" "$sd_path" 2>/dev/null || true

        if [ -L "$local_path" ]; then
            rm -f "$local_path"
            mkdir -p "$local_path"
            chown "$USER_NAME:$USER_NAME" "$local_path"
        elif [ ! -e "$local_path" ]; then
            mkdir -p "$local_path"
            chown "$USER_NAME:$USER_NAME" "$local_path"
        elif [ -b "/dev/mapper/soulstone_crypt" ]; then
            mount -t btrfs -o compress-force=zstd:3,noatime,autodefrag,space_cache=v2 "/dev/mapper/soulstone_crypt" "$SD_MOUNT"
        else
            log "Device $SD_DEV not found or not unlocked. Cannot attach."
            return 1
        fi
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

    # 4. Single ~/Soul Stone folder with custom SD card icon
    local home_portal="$USER_HOME/Soul Stone"
    if [ -L "$home_portal" ]; then
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
    su - "$USER_NAME" -c 'gio set "/home/'"$USER_NAME"'/Soul Stone" metadata::custom-icon "file:///home/'"$USER_NAME"'/.local/share/icons/sdcard.png" 2>/dev/null || true'

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
        echo "Root: MOUNTED on $SD_MOUNT ($(findmnt -n -o SOURCE "$SD_MOUNT" 2>/dev/null || echo "$SD_DEV"))"
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

case "$1" in
    attach)
        attach
        ;;
    detach)
        detach
        ;;
    clean)
        clean_stale_mounts
        ;;
    force-detach)
        force_detach_all
        ;;
    status)
        status
        ;;
    *)
        echo "Usage: $0 {attach|detach|clean|force-detach|status}"
        exit 1
        ;;
esac
