#!/usr/bin/env python3
"""
SoulStone Forge - Master Engine for Encrypted Modular Removable Storage Management
Automates creation, LUKS2/AES-256 encryption, formatting, cloning, migration, and system bindings for Soul Stone SD cards.
"""

import os
import sys
import json
import time
import shutil
import base64
import argparse
import subprocess
from pathlib import Path
from PIL import Image

VERSION = "2.0.0"
USER_NAME = "mr-reaper"
USER_HOME = f"/home/{USER_NAME}"
PROJECT_ROOT = Path(__file__).resolve().parent.parent
ASSETS_DIR = PROJECT_ROOT / "assets"
MASTER_ICON = ASSETS_DIR / "sdcard.png"

DEFAULT_MAPPINGS = [
    "Archives",
    "Documents",
    "Downloads",
    "Pictures",
    "Music",
    "Videos",
    "Movies",
    "Projects",
    "Projects/Pycharm Projects",
    "Projects/Arduino Projects",
    "Projects/Godot Projects",
]

PURPLE_SYMBOLIC_SVG = '''<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
  <path fill="#7764D8" fill-rule="evenodd" d="M 2 0.5 C 1.17 0.5 0.5 1.17 0.5 2 L 0.5 14 C 0.5 14.83 1.17 15.5 2 15.5 L 14 15.5 C 14.83 15.5 15.5 14.83 15.5 14 L 15.5 4.8 C 15.5 4.4 15.34 4.02 15.06 3.74 L 12.26 0.94 C 11.98 0.66 11.6 0.5 11.2 0.5 L 2 0.5 z M 2 1.8 L 10.7 1.8 L 14.2 5.3 L 14.2 14.2 L 2 14.2 L 2 1.8 z M 3.2 2.8 L 3.2 6.2 L 4.6 6.2 L 4.6 2.8 L 3.2 2.8 z M 5.6 2.8 L 5.6 6.2 L 7 6.2 L 7 2.8 L 5.6 2.8 z M 8 2.8 L 8 6.2 L 9.4 6.2 L 9.4 2.8 L 8 2.8 z M 10.4 2.8 L 10.4 5.2 L 11.8 5.2 L 11.8 2.8 L 10.4 2.8 z M 4.5 8 C 3.7 8 3 8.7 3 9.5 L 3 12.5 C 3 13.3 3.7 14 4.5 14 L 11.5 14 C 12.3 14 13 13.3 13 12.5 L 13 9.5 C 13 8.7 12.3 8 11.5 8 L 4.5 8 z M 4.5 9.2 L 11.5 9.2 L 11.5 12.8 L 4.5 12.8 L 4.5 9.2 z"/>
</svg>'''

BANNER = r"""
  ____             _ ____  _                      _____                 
 / ___|  ___  _   _| / ___|| |_ ___  _ __   ___  |  ___|__  _ __ __ _  ___ 
 \___ \ / _ \| | | | \___ \| __/ _ \| '_ \ / _ \ | |_ / _ \| '__/ _` |/ _ \
  ___) | (_) | |_| | |___) | || (_) | | | |  __/ |  _| (_) | | | (_| |  __/
 |____/ \___/ \__,_|_|____/ \__\___/|_| |_|\___| |_|  \___/|_|  \__, |\___|
                                                                |___/      
          🔒 Encrypted Modular Companion Removable Storage Generator v""" + VERSION + "\n"

def log(msg, tag="INFO"):
    colors = {
        "INFO": "\033[94m[INFO]\033[0m",
        "OK": "\033[92m[OK]\033[0m",
        "WARN": "\033[93m[WARN]\033[0m",
        "ERR": "\033[91m[ERROR]\033[0m",
        "STAR": "\033[95m[★]\033[0m",
        "LOCK": "\033[96m[🔒]\033[0m"
    }
    prefix = colors.get(tag, f"[{tag}]")
    print(f"{prefix} {msg}", flush=True)

def run_cmd(cmd, check=True, capture=True):
    if isinstance(cmd, str):
        res = subprocess.run(cmd, shell=True, capture_output=capture, text=True)
    else:
        res = subprocess.run(cmd, capture_output=capture, text=True)
    if check and res.returncode != 0:
        err = res.stderr.strip() if res.stderr else "Unknown error"
        raise RuntimeError(f"Command failed ({res.returncode}): {cmd}\nError: {err}")
    return res

def check_root():
    if os.geteuid() != 0:
        log("Root privileges required for hardware disk operations.", "WARN")
        args = ["pkexec", sys.executable] + sys.argv
        os.execvp("pkexec", args)

def list_safe_devices():
    res = run_cmd(["lsblk", "-J", "-o", "NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,RM,RO,TRAN"])
    data = json.loads(res.stdout)
    devices = []

    def inspect_dev(dev):
        path = dev.get("path") or f"/dev/{dev.get('NAME')}"
        mounts = []
        if dev.get("mountpoint"):
            mounts.append(dev.get("mountpoint"))
        for child in dev.get("children", []):
            if child.get("mountpoint"):
                mounts.append(child.get("mountpoint"))
        
        is_os = any(m in ["/", "/boot", "/boot/efi", "[SWAP]"] for m in mounts)
        is_loop = dev.get("type") == "loop"
        is_zram = "zram" in path

        if not is_os and not is_loop and not is_zram:
            devices.append({
                "name": dev.get("name"),
                "path": path,
                "size": dev.get("size"),
                "type": dev.get("type"),
                "tran": dev.get("tran", "unknown"),
                "label": dev.get("label") or "",
                "fstype": dev.get("fstype") or "",
                "mounts": mounts,
                "children": dev.get("children", [])
            })

    for d in data.get("blockdevices", []):
        if d.get("type") == "disk":
            inspect_dev(d)

    return devices

def install_icons():
    log("Installing custom purple SD card icon across all GTK themes...", "STAR")
    if not MASTER_ICON.exists():
        log(f"Master icon asset missing at {MASTER_ICON}", "ERR")
        return False

    raw_img = Image.open(MASTER_ICON).convert("RGBA")
    user_icon_dir = Path(f"{USER_HOME}/.local/share/icons")
    user_icon_dir.mkdir(parents=True, exist_ok=True)
    raw_img.save(user_icon_dir / "sdcard.png", "PNG")

    with open(MASTER_ICON, "rb") as f:
        b64 = base64.b64encode(f.read()).decode('utf-8')

    embedded_svg = f'''<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="512" height="512" viewBox="0 0 512 512">
  <image width="512" height="512" xlink:href="data:image/png;base64,{b64}"/>
</svg>'''

    themes = ["hicolor", "Yaru", "Yaru-purple", "Yaru-purple-dark", "Yaru-dark", "Adwaita"]
    sizes = [16, 22, 24, 32, 48, 64, 128, 256, 512]
    icon_names = [
        "media-flash-sd",
        "drive-removable-media-sd",
        "drive-sdcard",
        "sd-card",
        "media-memory-sd",
        "gnome-dev-media-sdmmc",
        "sdcard"
    ]

    for theme in themes:
        theme_path = user_icon_dir / theme
        for size in sizes:
            for context in ["places", "devices"]:
                d = theme_path / f"{size}x{size}" / context
                d.mkdir(parents=True, exist_ok=True)
                resized = raw_img.resize((size, size), Image.Resampling.LANCZOS)
                for name in icon_names:
                    resized.save(d / f"{name}.png", "PNG")
                    resized.save(d / f"{name}-symbolic.symbolic.png", "PNG")

            for context in ["places", "devices"]:
                d2 = theme_path / f"{size}x{size}@2x" / context
                d2.mkdir(parents=True, exist_ok=True)
                resized2 = raw_img.resize((size * 2, size * 2), Image.Resampling.LANCZOS)
                for name in icon_names:
                    resized2.save(d2 / f"{name}.png", "PNG")

        for context in ["places", "devices"]:
            sd = theme_path / "scalable" / context
            sd.mkdir(parents=True, exist_ok=True)
            for name in icon_names:
                (sd / f"{name}.svg").write_text(embedded_svg)
                (sd / f"{name}-symbolic.svg").write_text(PURPLE_SYMBOLIC_SVG)

        index_theme = theme_path / "index.theme"
        if not index_theme.exists():
            sys_index = Path(f"/usr/share/icons/{theme}/index.theme")
            if sys_index.exists():
                shutil.copyfile(sys_index, index_theme)
        run_cmd(f"gtk-update-icon-cache -f -t '{theme_path}'", check=False)

    log("Custom SD Card icons installed successfully across all resolutions.", "OK")
    return True

def generate_system_files(luks_uuid, btrfs_uuid):
    log(f"Binding Encrypted Soul Stone (LUKS: {luks_uuid}, Btrfs: {btrfs_uuid})...", "INFO")
    script_path = Path("/usr/local/bin/soulstone-storage")
    mappings_str = "\n".join([f'    "{m}|$USER_HOME/{m}"' for m in DEFAULT_MAPPINGS])
    
    script_content = f'''#!/usr/bin/env bash
# Soul Stone Dynamic Seamless Modular Storage Engine (Encrypted Edition)
set -e

USER_NAME="{USER_NAME}"
USER_HOME="/home/$USER_NAME"
SD_MOUNT="/mnt/sdcard"
LUKS_UUID="{luks_uuid}"
BTRFS_UUID="{btrfs_uuid}"
MAPPER_NAME="soulstone_crypt"
MAPPER_DEV="/dev/mapper/$MAPPER_NAME"
LUKS_DEV="/dev/disk/by-uuid/$LUKS_UUID"

MAPPINGS=(
{mappings_str}
)

log() {{
    echo "[SoulStone $(date '+%Y-%m-%d %H:%M:%S')] $*" | logger -t soulstone-storage || true
    echo "[SoulStone] $*"
}}

is_mounted() {{
    mountpoint -q "$1" 2>/dev/null
}}

is_mount_healthy() {{
    local target="$1"
    if mountpoint -q "$target" 2>/dev/null; then
        if ls -A "$target" >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}}

clean_stale_mounts() {{
    log "Flushing any dead/stale mounts..."
    for mapping in "${{MAPPINGS[@]}}"; do
        IFS="|" read -r sd_sub local_path <<< "$mapping"
        if is_mounted "$local_path"; then
            if ! is_mount_healthy "$local_path"; then
                umount -l "$local_path" 2>/dev/null || true
            fi
        fi
    done

    if is_mounted "$USER_HOME/SD Card"; then
        if ! is_mount_healthy "$USER_HOME/SD Card"; then
            umount -l "$USER_HOME/SD Card" 2>/dev/null || true
        fi
    fi

    if is_mounted "$SD_MOUNT"; then
        if ! is_mount_healthy "$SD_MOUNT"; then
            umount -l "$SD_MOUNT" 2>/dev/null || true
        fi
    fi
}}

force_detach_all() {{
    log "Force detaching all overlays..."
    for mapping in "${{MAPPINGS[@]}}"; do
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

    if [ -e "$MAPPER_DEV" ]; then
        cryptsetup luksClose "$MAPPER_NAME" 2>/dev/null || true
    fi
}}

attach() {{
    log "Attaching Soul Stone encrypted companion storage..."
    mkdir -p "$SD_MOUNT"

    clean_stale_mounts

    # If mapper not open, attempt open or check if opened by desktop
    if [ ! -e "$MAPPER_DEV" ]; then
        # Check if opened under another mapper name or by UUID
        local found_mapper
        found_mapper=$(lsblk -rn -o NAME,TYPE,UUID | grep "crypt.*$BTRFS_UUID" | awk '{{print "/dev/mapper/" $1}}' || true)
        if [ -n "$found_mapper" ] && [ -e "$found_mapper" ]; then
            MAPPER_DEV="$found_mapper"
        elif [ -b "$LUKS_DEV" ]; then
            log "LUKS device detected. Waiting for user passphrase unlock in desktop..."
        fi
    fi

    # Mount Btrfs filesystem once decrypted
    if ! is_mount_healthy "$SD_MOUNT"; then
        if [ -e "$MAPPER_DEV" ]; then
            while is_mounted "$SD_MOUNT"; do
                umount -l "$SD_MOUNT" 2>/dev/null || break
            done
            mount -t btrfs -o compress-force=zstd:3,noatime,autodefrag,space_cache=v2 "$MAPPER_DEV" "$SD_MOUNT"
            log "Mounted $MAPPER_DEV to $SD_MOUNT"
        else
            log "Soul Stone decrypted volume not yet unlocked."
            exit 0
        fi
    fi

    for mapping in "${{MAPPINGS[@]}}"; do
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

        if ! is_mount_healthy "$local_path"; then
            umount -l "$local_path" 2>/dev/null || true

            if [ -d "$local_path" ] && [ "$(ls -A "$local_path" 2>/dev/null)" ]; then
                log "Migrating offline files: $local_path -> $sd_path..."
                rsync -av --remove-source-files "$local_path/" "$sd_path/" 2>/dev/null || true
                find "$local_path" -mindepth 1 -type d -empty -delete 2>/dev/null || true
            fi

            mount --bind "$sd_path" "$local_path"
            mount -o remount,bind,x-gvfs-hide "$local_path"
            log "Bind-mounted (hidden from dock): $sd_path -> $local_path"
        fi
    done

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

    log "Soul Stone encrypted companion storage attached cleanly."
}}

detach() {{
    log "Detaching Soul Stone modular storage..."
    force_detach_all
    log "Soul Stone detached and encrypted."
}}

status() {{
    echo "=== Soul Stone Status ==="
    if is_mount_healthy "$SD_MOUNT"; then
        echo "Root: MOUNTED & DECRYPTED on $SD_MOUNT ($(findmnt -n -o SOURCE "$SD_MOUNT"))"
    elif [ -e "$MAPPER_DEV" ]; then
        echo "Root: UNLOCKED (Mapper Active) but not mounted"
    else
        echo "Root: LOCKED / ENCRYPTED / UNMOUNTED"
    fi
    echo "--- Active Directory Overlays ---"
    for mapping in "${{MAPPINGS[@]}}"; do
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
}}

case "$1" in
    attach) attach ;;
    detach) detach ;;
    clean) clean_stale_mounts ;;
    force-detach) force_detach_all ;;
    status) status ;;
    *) echo "Usage: $0 {{attach|detach|clean|force-detach|status}}"; exit 1 ;;
esac
'''
    script_path.write_text(script_content)
    script_path.chmod(0o755)

    udev_path = Path("/etc/udev/rules.d/99-sdcard-icons.rules")
    udev_content = f'''# Soul Stone Encrypted Storage UDev Rule (LUKS: {luks_uuid}, Btrfs: {btrfs_uuid})
SUBSYSTEM=="block", ENV{{ID_FS_UUID}}=="{luks_uuid}", ACTION=="add", ENV{{ID_DRIVE_FLASH_SD}}="1", ENV{{UDISKS_ICON_NAME}}="media-flash-sd", ENV{{UDISKS_NAME}}="Soul Stone (Locked)", TAG+="systemd"
SUBSYSTEM=="block", ENV{{ID_FS_UUID}}=="{btrfs_uuid}", ACTION=="add", ENV{{ID_DRIVE_FLASH_SD}}="1", ENV{{UDISKS_ICON_NAME}}="media-flash-sd", ENV{{UDISKS_NAME}}="Soul Stone", TAG+="systemd", ENV{{SYSTEMD_WANTS}}="soulstone-storage.service"
SUBSYSTEM=="block", ENV{{ID_FS_UUID}}=="{luks_uuid}", ACTION=="remove", RUN+="/usr/local/bin/soulstone-storage detach"
'''
    udev_path.write_text(udev_content)
    run_cmd("udevadm control --reload-rules && udevadm trigger", check=False)

    fstab_path = Path("/etc/fstab")
    lines = [l for l in fstab_path.read_text().splitlines() if "soulstone" not in l.lower() and "/mnt/sdcard" not in l]
    lines.append(f"UUID={btrfs_uuid} /mnt/sdcard btrfs users,nofail,noauto,compress-force=zstd:3,noatime,autodefrag,x-gvfs-show,x-gvfs-name=Soul\\040Stone,x-gvfs-icon=media-flash-sd,x-gvfs-symbolic-icon=media-flash-sd 0 0")
    fstab_path.write_text("\n".join(lines) + "\n")

    log("Encrypted system bindings updated successfully.", "OK")

def forge_encrypted_card(device_path, passphrase="soulkeeper"):
    check_root()
    log(f"Forging Encrypted Soul Stone on {device_path} (Passphrase: {passphrase})...", "LOCK")
    
    run_cmd(f"umount -l {device_path}* 2>/dev/null || true", check=False)
    run_cmd(f"wipefs -af {device_path}")

    # Dual partition: 500MB FAT32 (Windows unlock info) + Rest LUKS2
    run_cmd(f"parted -s {device_path} mklabel gpt")
    run_cmd(f"parted -s {device_path} mkpart SOUL_BOOT fat32 2048s 500MB")
    run_cmd(f"parted -s {device_path} mkpart SoulStone_Encrypted 500MB 100%")
    time.sleep(2)

    part1 = f"{device_path}p1" if "nvme" in device_path or "mmcblk" in device_path else f"{device_path}1"
    part2 = f"{device_path}p2" if "nvme" in device_path or "mmcblk" in device_path else f"{device_path}2"

    run_cmd(f"mkfs.vfat -F 32 -n SOUL_BOOT {part1}")

    p = subprocess.Popen(
        ["cryptsetup", "luksFormat", "--type", "luks2", "--cipher", "aes-xts-plain64", "--key-size", "512", "--hash", "sha512", "--pbkdf", "argon2id", "--batch-mode", part2],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )
    stdout, stderr = p.communicate(input=f"{passphrase}\n")
    if p.returncode != 0:
        raise RuntimeError(f"luksFormat failed: {stderr}")

    mapper_name = "soulstone_crypt"
    p_open = subprocess.Popen(
        ["cryptsetup", "luksOpen", part2, mapper_name],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )
    p_open.communicate(input=f"{passphrase}\n")

    mapper_dev = f"/dev/mapper/{mapper_name}"
    run_cmd(f"mkfs.btrfs -f -L 'Soul Stone' {mapper_dev}")

    luks_uuid = run_cmd(f"blkid -s UUID -o value {part2}").stdout.strip()
    btrfs_uuid = run_cmd(f"blkid -s UUID -o value {mapper_dev}").stdout.strip()

    temp_mount = "/tmp/soulstone_init"
    Path(temp_mount).mkdir(parents=True, exist_ok=True)
    run_cmd(f"mount -t btrfs -o compress-force=zstd:3 {mapper_dev} {temp_mount}")

    for d in DEFAULT_MAPPINGS:
        target_dir = Path(temp_mount) / d
        target_dir.mkdir(parents=True, exist_ok=True)
        run_cmd(f"chown -R {USER_NAME}:{USER_NAME} '{target_dir}'")

    if MASTER_ICON.exists():
        shutil.copyfile(MASTER_ICON, Path(temp_mount) / ".VolumeIcon.png")
        run_cmd(f"chown {USER_NAME}:{USER_NAME} '{temp_mount}/.VolumeIcon.png'")

    run_cmd(f"umount {temp_mount}")
    shutil.rmtree(temp_mount, ignore_errors=True)

    generate_system_files(luks_uuid, btrfs_uuid)
    install_icons()
    run_cmd("/usr/local/bin/soulstone-storage attach")
    log("🎉 Encrypted Soul Stone forged, attached, and protected with AES-256!", "OK")

def interactive_cli():
    print(BANNER)
    print("Select an operation:")
    print(" [1] 🔒 Forge an ENCRYPTED Soul Stone (LUKS2 / AES-256, Password Protected)")
    print(" [2] 🔄 Clone / Move an Encrypted Soul Stone to a new card")
    print(" [3] 🎨 Reinstall & Refresh Custom Purple SD Card Icons")
    print(" [4] 📊 View Current Soul Stone Status & Health")
    print(" [5] 🔌 Attach / Detach Soul Stone manually")
    print(" [0] Exit")
    print("-" * 65)

    choice = input("Enter choice (0-5): ").strip()
    if choice == "1":
        devices = list_safe_devices()
        if not devices:
            log("No external removable storage devices detected.", "ERR")
            return
        print("\nAvailable Storage Devices (Safe to Format):")
        for i, d in enumerate(devices, 1):
            print(f" [{i}] {d['path']:<12} Size: {d['size']:<8} Transport: {d['tran']:<8} [{d['label']}]")
        dev_idx = input(f"\nSelect target device number (1-{len(devices)}): ").strip()
        try:
            sel = devices[int(dev_idx) - 1]
            pw = input("\nEnter encryption passphrase (press Enter for 'soulkeeper'): ").strip()
            if not pw:
                pw = "soulkeeper"
            confirm = input(f"\n⚠️  WARNING: ALL DATA ON {sel['path']} WILL BE ENCRYPTED & FORMATTED!\nType 'YES' to proceed: ").strip()
            if confirm == "YES":
                forge_encrypted_card(sel['path'], pw)
        except (ValueError, IndexError):
            log("Invalid selection.", "ERR")

    elif choice == "2":
        devices = list_safe_devices()
        if len(devices) < 1:
            log("Destination storage device required.", "ERR")
            return
        for i, d in enumerate(devices, 1):
            print(f" [{i}] {d['path']:<12} Size: {d['size']:<8} [{d['label']}]")
        dev_idx = input(f"Select destination device (1-{len(devices)}): ").strip()
        try:
            sel = devices[int(dev_idx) - 1]
            pw = input("\nEnter encryption passphrase for new card: ").strip()
            forge_encrypted_card(sel['path'], pw)
        except Exception as e:
            log(f"Cloning failed: {e}", "ERR")

    elif choice == "3":
        install_icons()
        run_cmd("nautilus -q || true", check=False)
        log("Icons re-installed and Nautilus reloaded.", "OK")

    elif choice == "4":
        run_cmd("/usr/local/bin/soulstone-storage status", check=False, capture=False)

    elif choice == "5":
        act = input("Enter 'attach' or 'detach': ").strip().lower()
        if act in ["attach", "detach"]:
            run_cmd(f"/usr/local/bin/soulstone-storage {act}", capture=False)

def main():
    parser = argparse.ArgumentParser(description="SoulStone Forge - Encrypted Removable Modular Storage Engine")
    parser.add_argument("--forge", metavar="DEVICE", help="Format and forge an encrypted Soul Stone on target device")
    parser.add_argument("--passphrase", default="soulkeeper", help="Encryption passphrase (default: soulkeeper)")
    parser.add_argument("--install-icons", action="store_true", help="Reinstall custom purple SD card icons")
    parser.add_argument("--status", action="store_true", help="Check live Soul Stone status")
    
    args = parser.parse_args()

    if args.forge:
        forge_encrypted_card(args.forge, args.passphrase)
    elif args.install_icons:
        install_icons()
    elif args.status:
        run_cmd("/usr/local/bin/soulstone-storage status", check=False, capture=False)
    else:
        interactive_cli()

if __name__ == "__main__":
    main()
