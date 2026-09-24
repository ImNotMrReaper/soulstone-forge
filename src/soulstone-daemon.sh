#!/usr/bin/env bash
# Soul Stone Hardware Watchdog Daemon
# Automatically detects insertion and removal of the Soul Stone SD card
# Production Hardened with Boot I/O Self-Healing Rescan
set -u

LUKS_UUID="8636c4f3-09c8-42ce-bf9b-fe273be32b3f"
BTRFS_UUID="18ceeb84-5abf-4456-88a2-d2f2fb2255f0"
SD_MOUNT="/mnt/sdcard"

log() {
    echo "[SoulStone Watchdog] $*" | logger -t soulstone-daemon || true
}

log "Soul Stone watchdog started. Monitoring for card UUID $LUKS_UUID..."

LAST_RESCAN=0

while true; do
    is_mounted=false
    if mountpoint -q "$SD_MOUNT" 2>/dev/null; then
        is_mounted=true
    fi

    if [ "$is_mounted" = true ]; then
        media_lost=false

        # Check 1: Check block device size of the underlying drive holding the crypto mapping
        if [ -b "/dev/mapper/soulstone_crypt" ]; then
            dm_node="$(readlink -f /dev/mapper/soulstone_crypt)"
            dm_name="$(basename "$dm_node")"
            if [ -d "/sys/block/$dm_name/slaves" ]; then
                for slave in /sys/block/$dm_name/slaves/*; do
                    if [ -e "$slave" ]; then
                        disk_base="$(basename "$slave" | sed 's/[0-9]*$//')"
                        if [ -f "/sys/block/$disk_base/size" ]; then
                            size=$(cat "/sys/block/$disk_base/size" 2>/dev/null || echo 0)
                            if [ "$size" -eq 0 ]; then
                                media_lost=true
                            fi
                        fi
                    fi
                done
            fi
        else
            media_lost=true
        fi

        # Check 2: Check if /mnt/sdcard is responding or throwing I/O error
        if [ "$media_lost" = false ]; then
            if ! timeout 0.5 ls -A "$SD_MOUNT" >/dev/null 2>&1; then
                media_lost=true
            fi
        fi

        if [ "$media_lost" = true ]; then
            log "Soul Stone SD card removed! Triggering immediate clean detach..."
            /usr/local/bin/soulstone-storage detach || true
            sleep 1
        fi

    else
        # If not mounted, ensure any lingering stale soulstone_crypt device is closed if card is gone
        if [ -b "/dev/mapper/soulstone_crypt" ]; then
            cryptsetup close soulstone_crypt 2>/dev/null || true
        fi

        # Not currently mounted. Check if the Soul Stone SD card is inserted
        luks_dev="$(blkid -t UUID="$LUKS_UUID" -o device 2>/dev/null | head -n1 || true)"

        # Auto-recover from transient boot I/O errors (e.g. Alcor card reader "Sense Key: Not Ready")
        if [ -z "$luks_dev" ]; then
            NOW=$(date +%s)
            if [ $((NOW - LAST_RESCAN)) -ge 5 ]; then
                for candidate in /sys/block/sd* /sys/block/mmcblk*; do
                    [ -e "$candidate" ] || continue
                    c_dev="$(basename "$candidate")"
                    [ -f "/sys/block/$c_dev/removable" ] || continue
                    is_remov=$(cat "/sys/block/$c_dev/removable" 2>/dev/null || echo 0)
                    c_size=$(cat "/sys/block/$c_dev/size" 2>/dev/null || echo 0)
                    # If removable device with capacity > 1GB has 0 partitions or no LUKS partition detected
                    if [ "$is_remov" = "1" ] && [ "$c_size" -gt 2000000 ]; then
                        part_count=$(lsblk -no TYPE "/dev/$c_dev" 2>/dev/null | grep -c "part" || true)
                        if [ "$part_count" -eq 0 ]; then
                            log "Detected unpartitioned removable drive /dev/$c_dev (size: $c_size). Probing for partition table..."
                            [ -w "/sys/block/$c_dev/device/rescan" ] && echo 1 > "/sys/block/$c_dev/device/rescan" 2>/dev/null || true
                            partx -u "/dev/$c_dev" 2>/dev/null || true
                            blockdev --rereadpt "/dev/$c_dev" 2>/dev/null || true
                        fi
                    fi
                done
                LAST_RESCAN=$NOW
                luks_dev="$(blkid -t UUID="$LUKS_UUID" -o device 2>/dev/null | head -n1 || true)"
            fi
        fi

        if [ -n "$luks_dev" ] && [ -b "$luks_dev" ]; then
            dev_base="$(lsblk -no PKNAME "$luks_dev" 2>/dev/null || true)"
            [ -z "$dev_base" ] && dev_base="sdb"
            size=$(cat "/sys/block/$dev_base/size" 2>/dev/null || echo 0)
            if [ "$size" -gt 0 ]; then
                log "Soul Stone SD card ($LUKS_UUID) detected on $luks_dev ($dev_base)! Triggering auto-attach..."
                /usr/local/bin/soulstone-storage attach || true
                sleep 2
            fi
        fi
    fi

    sleep 1
done
