#!/usr/bin/env bash
# Soul Stone Dynamic Seamless Modular Storage Engine (Production Hardened Edition v2.1)
# Supports Ubuntu 24.04+ (Noble Numbat)
set -e

# 1. Deterministic User Resolution (Always target primary desktop user, never root)
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    USER_NAME="$SUDO_USER"
elif [ -n "$PKEXEC_UID" ]; then
    USER_NAME="$(id -un "$PKEXEC_UID" 2>/dev/null || echo "mr-reaper")"
else
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

# Dynamic Configuration Path
CONFIG_DIR="$USER_HOME/.config/soulstone"
CONFIG_FILE="$CONFIG_DIR/overlays.conf"

# IDE Compatibility Dirs (Managed as symlinks into ~/Projects to prevent mount loops)
IDE_DIRS=("Pycharm Projects" "Arduino Projects" "Godot Projects")

load_mappings() {
    MAPPINGS=()
    if [ -f "$CONFIG_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            if [[ "$line" == *"|"* ]]; then
                IFS="|" read -r sub loc <<< "$line"
                if [[ "$loc" = /* ]]; then
                    MAPPINGS+=("$sub|$loc")
                else
                    MAPPINGS+=("$sub|$USER_HOME/$loc")
                fi
            else
                MAPPINGS+=("$line|$USER_HOME/$line")
            fi
        done < "$CONFIG_FILE"
    fi

    # Fallback to golden defaults if config is empty or missing
    if [ "${#MAPPINGS[@]}" -eq 0 ]; then
        MAPPINGS=(
            "Archives|$USER_HOME/Archives"
            "Documents|$USER_HOME/Documents"
            "Downloads|$USER_HOME/Downloads"
            "Pictures|$USER_HOME/Pictures"
            "Music|$USER_HOME/Music"
            "Videos|$USER_HOME/Videos"
            "Movies|$USER_HOME/Movies"
            "Projects|$USER_HOME/Projects"
            "Games|$USER_HOME/Games"
        )
    fi
}

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
    load_mappings
    for mapping in "${MAPPINGS[@]}"; do
        IFS="|" read -r sd_sub local_path <<< "$mapping"
        if is_mounted "$local_path"; then
            if ! is_mount_healthy "$local_path"; then
                umount -l "$local_path" 2>/dev/null || true
            fi
        fi
    done

    for ide_dir in "${IDE_DIRS[@]}"; do
        if is_mounted "$USER_HOME/$ide_dir"; then
            umount -l "$USER_HOME/$ide_dir" 2>/dev/null || true
        fi
    done

    # Clean any stale root mounts
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
    load_mappings
    for ide_dir in "${IDE_DIRS[@]}"; do
        while is_mounted "$USER_HOME/$ide_dir"; do
            umount -l "$USER_HOME/$ide_dir" 2>/dev/null || break
        done
    done

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
    load_mappings

    if ! is_mount_healthy "$SD_MOUNT"; then
        local dev
        dev="$(get_active_device || true)"
        if [ -n "$dev" ] && [ -b "$dev" ]; then
            while is_mounted "$SD_MOUNT"; do
                umount -l "$SD_MOUNT" 2>/dev/null || break
            done
            mount -t btrfs -o "$BTRFS_MOUNT_OPTS" "$dev" "$SD_MOUNT"
            mount --make-rprivate "$SD_MOUNT"
        else
            log "Checking for encrypted Soul Stone volume..."
            if [ -b "/dev/disk/by-uuid/$LUKS_UUID" ] && [ -f "/etc/soulstone/soulstone.key" ]; then
                cryptsetup open --key-file=/etc/soulstone/soulstone.key "/dev/disk/by-uuid/$LUKS_UUID" soulstone_crypt 2>/dev/null || true
                if [ -b "/dev/mapper/soulstone_crypt" ]; then
                    mount -t btrfs -o "$BTRFS_MOUNT_OPTS" "/dev/mapper/soulstone_crypt" "$SD_MOUNT"
                    mount --make-rprivate "$SD_MOUNT"
                fi
            fi
        fi
    else
        mount --make-rprivate "$SD_MOUNT" 2>/dev/null || true
    fi

    if ! is_mount_healthy "$SD_MOUNT"; then
        log "No physical Soul Stone drive found or could not mount. Aborting attach."
        return 1
    fi

    chown "$USER_UID:$USER_GID" "$SD_MOUNT"
    chmod 755 "$SD_MOUNT"

    if [ -f "$USER_HOME/.local/share/icons/sdcard.png" ]; then
        cp -f "$USER_HOME/.local/share/icons/sdcard.png" "$SD_MOUNT/.VolumeIcon.png" 2>/dev/null || true
        chown "$USER_UID:$USER_GID" "$SD_MOUNT/.VolumeIcon.png" 2>/dev/null || true
    fi

    apply_flash_nodatacow

    # 1. Bind-mount configured companion folders with safe conflict reconciliation
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
                find "$local_path" -depth -mindepth 1 -type d -not -path "*/Workspaces*" -not -path "*/.obsidian*" -empty -delete 2>/dev/null || true
            fi
        fi

        # Mount bind overlay with x-gvfs-hide and make-private to prevent peer propagation loops
        if ! is_mounted "$local_path"; then
            mount --bind -o x-gvfs-hide "$target_dir" "$local_path"
            mount --make-private "$local_path"
            log "Bind-mounted (hidden from dock): $target_dir -> $local_path"
        fi
    done

    # 2. Symlink IDE project directories into home for seamless IDE compatibility
    for ide_dir in "${IDE_DIRS[@]}"; do
        local ide_target="$USER_HOME/Projects/$ide_dir"
        local ide_link="$USER_HOME/$ide_dir"
        mkdir -p "$ide_target"
        chown -R "$USER_UID:$USER_GID" "$ide_target"
        if is_mounted "$ide_link"; then
            umount -l "$ide_link" 2>/dev/null || true
        fi
        if [ -d "$ide_link" ] && ! [ -L "$ide_link" ]; then
            if [ "$(ls -A "$ide_link" 2>/dev/null)" ]; then
                rsync -avbu --remove-source-files "$ide_link/" "$ide_target/" 2>/dev/null || true
            fi
            rm -rf "$ide_link" 2>/dev/null || true
        fi
        ln -sfn "$ide_target" "$ide_link"
        chown -h "$USER_UID:$USER_GID" "$ide_link"
    done

    # 3. Single ~/Soul Stone home portal with custom SD card icon
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
        mount --make-rprivate "$home_portal"
        log "Attached single home portal: $home_portal -> $SD_MOUNT"
    fi

    # Set GNOME custom icon on ~/Soul Stone
    su - "$USER_NAME" -c "gio set '$USER_HOME/Soul Stone' metadata::custom-icon 'file://$USER_HOME/.local/share/icons/sdcard.png' 2>/dev/null || true"

    # Update directory skeleton snapshot for offline host parity
    update_directory_skeleton

    # Clean any offline notice files
    rm -f "$USER_HOME/Projects/.STORAGE_OFFLINE_NOTICE.txt" "$USER_HOME/Documents/.STORAGE_OFFLINE_NOTICE.txt" 2>/dev/null || true

    # Auto-verify and heal AI-Vault canonical symlinks
    if [ -x "$USER_HOME/.local/bin/vault-steward" ]; then
        su - "$USER_NAME" -c "$USER_HOME/.local/bin/vault-steward --fix" >/dev/null 2>&1 || true
    fi

    log "Soul Stone successfully attached and active!"
    if command -v notify-send >/dev/null 2>&1; then
        su - "$USER_NAME" -c 'notify-send -i media-flash-sd "Soul Stone" "SD Card connected. Folders mounted." 2>/dev/null || true'
    fi
}

update_directory_skeleton() {
    local skeleton_file="$CONFIG_DIR/directory_skeleton.txt"
    mkdir -p "$CONFIG_DIR"
    if [ -d "$SD_MOUNT" ]; then
        python3 -c "
import os
sd = '$SD_MOUNT'
skeleton = '$skeleton_file'
companion_dirs = ['Documents', 'Projects', 'Pictures', 'Music', 'Videos', 'Movies', 'Archives', 'Downloads', 'Games']
dirs = []
for c in companion_dirs:
    p = os.path.join(sd, c)
    if os.path.isdir(p):
        dirs.append(c)
        for root, d_list, _ in os.walk(p):
            d_list[:] = [d for d in d_list if d not in ['.Trash-1000', '.git', '__pycache__', '.cache', 'node_modules']]
            for d in d_list:
                full = os.path.join(root, d)
                dirs.append(os.path.relpath(full, sd))
dirs.sort()
with open(skeleton, 'w') as f:
    f.write('\n'.join(dirs) + '\n')
" 2>/dev/null || true
        chown "$USER_UID:$USER_GID" "$skeleton_file" 2>/dev/null || true
    fi
}

ensure_local_directories() {
    log "Ensuring all native companion directories and full subdirectories exist locally on computer..."
    local skeleton_file="$CONFIG_DIR/directory_skeleton.txt"
    if [ -f "$skeleton_file" ]; then
        python3 -c "
import os
home = '$USER_HOME'
uid = int('$USER_UID')
gid = int('$USER_GID')
try:
    with open('$skeleton_file', 'r', encoding='utf-8', errors='ignore') as f:
        for line in f:
            rel = line.strip()
            if not rel:
                continue
            path = os.path.join(home, rel)
            if not os.path.isdir(path):
                os.makedirs(path, exist_ok=True)
                try:
                    os.chown(path, uid, gid)
                except Exception:
                    pass
except Exception:
    pass
" 2>/dev/null || true
    else
        mkdir -p "$USER_HOME/Projects/Arduino Projects"
        mkdir -p "$USER_HOME/Projects/Godot Projects"
        mkdir -p "$USER_HOME/Projects/Pycharm Projects"
        mkdir -p "$USER_HOME/Documents/backups/timeshift"
        mkdir -p "$USER_HOME/Downloads"
        mkdir -p "$USER_HOME/Pictures/Screenshots"
        mkdir -p "$USER_HOME/Pictures/Wallpapers"
        mkdir -p "$USER_HOME/Music"
        mkdir -p "$USER_HOME/Videos"
        mkdir -p "$USER_HOME/Movies"
        mkdir -p "$USER_HOME/Archives"
        mkdir -p "$USER_HOME/Games/Heroic"
    fi

    # Ensure Timeshift symlinks in local Backups folder
    local local_ts="$USER_HOME/Documents/backups/timeshift"
    mkdir -p "$local_ts"
    ln -sfn /timeshift/snapshots "$local_ts/snapshots" 2>/dev/null || true
    ln -sfn /timeshift/snapshots-boot "$local_ts/snapshots-boot" 2>/dev/null || true
    ln -sfn /timeshift/snapshots-daily "$local_ts/snapshots-daily" 2>/dev/null || true
    ln -sfn /timeshift/snapshots-ondemand "$local_ts/snapshots-ondemand" 2>/dev/null || true
    ln -sfn /var/log/timeshift "$local_ts/logs" 2>/dev/null || true
    chown -R "$USER_UID:$USER_GID" "$USER_HOME/Documents/backups" 2>/dev/null || true

    for ide_dir in "${IDE_DIRS[@]}"; do
        local ide_target="$USER_HOME/Projects/$ide_dir"
        local ide_link="$USER_HOME/$ide_dir"
        mkdir -p "$ide_target"
        ln -sfn "$ide_target" "$ide_link"
        chown -h "$USER_UID:$USER_GID" "$ide_link"
    done

    # Leave explicit offline notices in skeleton directories so users/AIs know storage is unmounted
    local notice_content="===================================================================
⚠️ SOUL STONE ENCRYPTED STORAGE IS CURRENTLY OFFLINE / DETACHED
===================================================================
- The files inside this directory on the internal SSD are only an
  empty placeholder skeleton so local apps don't crash when offline.
- Your real source code, .git history, and documents are securely stored
  on the Soul Stone encrypted partition (/dev/sdb2).
- When Soul Stone mounts, your real files will be transparently overlaid
  over this skeleton.
- DO NOT PANIC. No files have been deleted.
==================================================================="
    echo "$notice_content" > "$USER_HOME/Projects/.STORAGE_OFFLINE_NOTICE.txt" 2>/dev/null || true
    echo "$notice_content" > "$USER_HOME/Documents/.STORAGE_OFFLINE_NOTICE.txt" 2>/dev/null || true
    chown "$USER_UID:$USER_GID" "$USER_HOME/Projects/.STORAGE_OFFLINE_NOTICE.txt" "$USER_HOME/Documents/.STORAGE_OFFLINE_NOTICE.txt" 2>/dev/null || true
}

detach() {
    log "Detaching Soul Stone modular storage..."
    sync
    force_detach_all
    if [ -b "/dev/mapper/soulstone_crypt" ]; then
        cryptsetup close soulstone_crypt 2>/dev/null || true
    fi
    ensure_local_directories
    log "Soul Stone detached cleanly."
    if command -v notify-send >/dev/null 2>&1; then
        su - "$USER_NAME" -c 'notify-send -i media-flash-sd "Soul Stone" "SD card unmounted cleanly." 2>/dev/null || true'
    fi
}

eject() {
    log "Gracefully ejecting Soul Stone..."
    sync
    force_detach_all
    if [ -b "/dev/mapper/soulstone_crypt" ]; then
        cryptsetup close soulstone_crypt 2>/dev/null || true
    fi
    ensure_local_directories
    log "Soul Stone safely unmounted and closed."
    if command -v notify-send >/dev/null 2>&1; then
        su - "$USER_NAME" -c 'notify-send -i media-flash-sd "Soul Stone" "Safe to remove SD card." 2>/dev/null || true'
    fi
}

cmd_link() {
    local target_folder="$1"
    if [ -z "$target_folder" ]; then
        echo "Usage: soulstone link <folder_name>"
        exit 1
    fi
    load_mappings
    mkdir -p "$CONFIG_DIR"
    local clean_name="$(basename "$target_folder")"
    local sd_target="$SD_MOUNT/$clean_name"
    local local_target="$USER_HOME/$clean_name"

    log "Linking '$clean_name' to Soul Stone companion storage..."
    mkdir -p "$sd_target"
    chown -R "$USER_UID:$USER_GID" "$sd_target"
    mkdir -p "$local_target"
    chown -R "$USER_UID:$USER_GID" "$local_target"

    if [ "$(ls -A "$local_target" 2>/dev/null)" ] && ! is_mounted "$local_target"; then
        log "Migrating local files from $local_target -> $sd_target..."
        rsync -avbu --remove-source-files "$local_target/" "$sd_target/" 2>/dev/null || true
    fi

    if ! is_mounted "$local_target"; then
        mount --bind -o x-gvfs-hide "$sd_target" "$local_target"
        mount --make-private "$local_target"
    fi

    if ! grep -q "^${clean_name}\b" "$CONFIG_FILE" 2>/dev/null; then
        echo "$clean_name" >> "$CONFIG_FILE"
        chown "$USER_UID:$USER_GID" "$CONFIG_FILE"
    fi
    log "Successfully linked ~/$clean_name! It will auto-bind whenever Soul Stone is connected."
}

cmd_unlink() {
    local target_folder="$1"
    if [ -z "$target_folder" ]; then
        echo "Usage: soulstone unlink <folder_name>"
        exit 1
    fi
    local clean_name="$(basename "$target_folder")"
    local local_target="$USER_HOME/$clean_name"

    log "Unlinking '$clean_name' from PC..."
    if is_mounted "$local_target"; then
        umount -l "$local_target" 2>/dev/null || true
    fi

    if [ -f "$CONFIG_FILE" ]; then
        sed -i "/^${clean_name}\b/d" "$CONFIG_FILE"
    fi
    log "Unlinked ~/$clean_name from PC! Files remain safely on Soul Stone at ~/Soul Stone/$clean_name as standalone extra storage."
}

status() {
    load_mappings
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
            echo " [ACTIVE NATIVE]  $local_path -> $SD_MOUNT/$sd_sub"
        else
            echo " [OFFLINE LOCAL]  $local_path (internal drive)"
        fi
    done

    for ide_dir in "${IDE_DIRS[@]}"; do
        if [ -L "$USER_HOME/$ide_dir" ]; then
            echo " [ACTIVE SYMLINK] $USER_HOME/$ide_dir -> $USER_HOME/Projects/$ide_dir"
        fi
    done

    if is_mount_healthy "$USER_HOME/Soul Stone"; then
        echo " [ACTIVE PORTAL]  $USER_HOME/Soul Stone -> $SD_MOUNT"
    else
        echo " [OFFLINE PORTAL] $USER_HOME/Soul Stone"
    fi
}

cmd_list() {
    load_mappings
    echo "=== Soul Stone Directory Telemetry & Extra Storage ==="
    if ! is_mounted "$SD_MOUNT"; then
        echo "Soul Stone is currently OFFLINE / DISCONNECTED."
        echo ""
        echo "Configured Overlays (will auto-bind when attached):"
        for mapping in "${MAPPINGS[@]}"; do
            IFS="|" read -r sd_sub local_path <<< "$mapping"
            echo "  [CONFIGURED] ~/${local_path#$USER_HOME/} -> Soul Stone/$sd_sub"
        done
        return 0
    fi

    echo "--- 🔗 Bound Overlays (Seamlessly Active on PC) ---"
    local bound_subs=()
    for mapping in "${MAPPINGS[@]}"; do
        IFS="|" read -r sd_sub local_path <<< "$mapping"
        bound_subs+=("$sd_sub")
        if is_mounted "$local_path"; then
            echo "  [ACTIVE OVERLAY] ~/${local_path#$USER_HOME/} -> Soul Stone/$sd_sub"
        else
            echo "  [CONFIGURED]     ~/${local_path#$USER_HOME/} -> Soul Stone/$sd_sub (unmounted)"
        fi
    done

    echo ""
    echo "--- 🚀 IDE Project Symlinks (Zero-Mount Compatibility) ---"
    for ide_dir in "${IDE_DIRS[@]}"; do
        if [ -L "$USER_HOME/$ide_dir" ]; then
            echo "  [ACTIVE SYMLINK] ~/$ide_dir -> ~/Projects/$ide_dir"
        fi
    done

    echo ""
    echo "--- 🗄️ Standalone Extra Storage (Exclusively on Soul Stone / Off PC) ---"
    local found_extra=0
    for d in "$SD_MOUNT"/*; do
        [ -d "$d" ] || continue
        local bname="$(basename "$d")"
        [[ "$bname" == .* ]] && continue
        local is_bound=0
        for b in "${bound_subs[@]}"; do
            if [ "$b" == "$bname" ]; then
                is_bound=1
                break
            fi
        done
        if [ "$is_bound" -eq 0 ]; then
            local sz="$(du -sh "$d" 2>/dev/null | awk '{print $1}')"
            echo "  [EXTRA STORAGE]  ~/Soul Stone/$bname ($sz) — Private to Soul Stone, not bound to PC"
            found_extra=1
        fi
    done
    if [ "$found_extra" -eq 0 ]; then
        echo "  (No standalone extra storage folders yet. Any folder in ~/Soul Stone not in overlays.conf stays off your PC!)"
    fi
    echo ""
    echo "💡 Run 'soulstone link <Folder>' to bind a folder to PC, or 'soulstone unlink <Folder>' to keep it as extra storage only."
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
    link|bind)
        cmd_link "$2"
        ;;
    unlink|unbind)
        cmd_unlink "$2"
        ;;
    list)
        cmd_list
        ;;
    *)
        echo "Usage: $0 {attach|detach|eject|status|link <dir>|unlink <dir>|list}"
        exit 1
        ;;
esac
