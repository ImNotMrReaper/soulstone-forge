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

    # Clean ~/SD Card portal mount if stale
    if is_mounted "$USER_HOME/SD Card"; then
        if ! is_mount_healthy "$USER_HOME/SD Card"; then
            umount -l "$USER_HOME/SD Card" 2>/dev/null || true
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
        fi

        # If local path is dead or not mounted, clean and bind-mount
        if ! is_mount_healthy "$local_path"; then
            umount -l "$local_path" 2>/dev/null || true

            if [ -d "$local_path" ] && [ "$(ls -A "$local_path" 2>/dev/null)" ]; then
                log "Migrating offline files: $local_path -> $sd_path..."
                rsync -av --remove-source-files "$local_path/" "$sd_path/" 2>/dev/null || true
                find "$local_path" -mindepth 1 -type d -empty -delete 2>/dev/null || true
            fi

            # Mount with x-gvfs-hide so it does NOT appear as an external drive in the dock!
            mount --bind "$sd_path" "$local_path"
            mount -o remount,bind,x-gvfs-hide "$local_path"
            log "Bind-mounted (hidden from dock): $sd_path -> $local_path"
        fi
    done

    # 4. Single ~/SD Card folder with custom icon
    local home_portal="$USER_HOME/SD Card"
    rm -f "$USER_HOME/SD_Card"
    if [ -L "$home_portal" ]; then
        rm -f "$home_portal"
    fi
    mkdir -p "$home_portal"
    chown "$USER_NAME:$USER_NAME" "$home_portal"

    if ! is_mount_healthy "$home_portal"; then
        umount -l "$home_portal" 2>/dev/null || true
        mount --bind "$SD_MOUNT" "$home_portal"
        mount -o remount,bind,x-gvfs-hide "$home_portal"
    fi
    su - "$USER_NAME" -c 'gio set "/home/'"$USER_NAME"'/SD Card" metadata::custom-icon "file:///home/'"$USER_NAME"'/.local/share/icons/sdcard.png" 2>/dev/null || true'

    log "Soul Stone companion modular storage attached cleanly."
}

detach() {
    log "Detaching Soul Stone modular storage..."
    force_detach_all
    log "Soul Stone detached cleanly."
}

status() {
    echo "=== Soul Stone Status ==="
    if is_mount_healthy "$SD_MOUNT"; then
        echo "Root: MOUNTED on $SD_MOUNT ($(findmnt -n -o SOURCE "$SD_MOUNT"))"
    else
        echo "Root: UNMOUNTED / STALE"
    fi
    echo "--- Active Directory Overlays ---"
    for mapping in "${MAPPINGS[@]}"; do
        IFS="|" read -r sd_sub local_path <<< "$mapping"
        local sd_path="$SD_MOUNT/$sd_sub"
        if is_mount_healthy "$local_path"; then
            echo " [ACTIVE NATIVE] $local_path -> $sd_path"
        else
            echo " [OFFLINE LOCAL]  $local_path (internal drive)"
        fi
    done
    if is_mount_healthy "$USER_HOME/SD Card"; then
        echo " [ACTIVE PORTAL] $USER_HOME/SD Card -> $SD_MOUNT"
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
