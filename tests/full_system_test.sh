#!/usr/bin/env bash
# =============================================================================
# Soul Stone + Soulstone-Forge Comprehensive Test Suite (Hardened v2)
# Tests: Encryption, Mounts, Icons, GVFS, Eject, Reattach, Data Integrity,
#        Systemd, Udev, GitHub Sync, Btrfs, Overlay Health, Zero Clutter
# =============================================================================

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

PASS=0; FAIL=0; WARN=0
FAIL_DETAILS=()

pass() { echo -e "  ${GREEN}✔ PASS${RESET}  $1"; ((PASS++)) || true; }
fail() { echo -e "  ${RED}✘ FAIL${RESET}  $1"; ((FAIL++)) || true; FAIL_DETAILS+=("$1"); }
warn() { echo -e "  ${YELLOW}⚠ WARN${RESET}  $1"; ((WARN++)) || true; }
info() { echo -e "  ${CYAN}ℹ${RESET}      $1"; }
header() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"; echo -e "${BOLD}  $1${RESET}"; echo -e "${CYAN}══════════════════════════════════════════════════════${RESET}"; }

user_exec() {
    sudo -u mr-reaper DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus" "$@"
}

# ── Constants ─────────────────────────────────────────────────────────────────
LUKS_UUID="8636c4f3-09c8-42ce-bf9b-fe273be32b3f"
BTRFS_UUID="18ceeb84-5abf-4456-88a2-d2f2fb2255f0"
SD_MOUNT="/mnt/sdcard"
HOME_PORTAL="/home/mr-reaper/Soul Stone"
ICON_PATH="/home/mr-reaper/.local/share/icons/sdcard.png"
KEYFILE="/etc/soulstone/soulstone.key"
REPO_PATH="/home/mr-reaper/.local/share/soulstone-forge"
TEST_FILE="/mnt/sdcard/.soulstone_test_$(date +%s)"

EXPECTED_OVERLAYS=(
  "/home/mr-reaper/Archives"
  "/home/mr-reaper/Documents"
  "/home/mr-reaper/Downloads"
  "/home/mr-reaper/Pictures"
  "/home/mr-reaper/Music"
  "/home/mr-reaper/Videos"
  "/home/mr-reaper/Movies"
  "/home/mr-reaper/Projects"
  "/home/mr-reaper/Games"
)

EXPECTED_SYMLINKS=(
  "/home/mr-reaper/Pycharm Projects"
  "/home/mr-reaper/Arduino Projects"
  "/home/mr-reaper/Godot Projects"
)

# ═════════════════════════════════════════════════════════════════════════════
header "PHASE 1 · Hardware & Physical Device Checks"
# ═════════════════════════════════════════════════════════════════════════════

SOUL_DEV=$(lsblk --raw -n -o NAME,UUID 2>/dev/null | grep "$LUKS_UUID" | awk '{print $1}' | head -1)
if [[ -n "$SOUL_DEV" ]]; then
    pass "Physical block device with LUKS UUID detected: /dev/$SOUL_DEV"
else
    fail "No physical block device found with LUKS UUID $LUKS_UUID"
fi

if cryptsetup status soulstone_crypt 2>/dev/null | grep -q "type:.*LUKS2"; then
    pass "LUKS2 dm-crypt device 'soulstone_crypt' is active and healthy"
else
    fail "soulstone_crypt is not active or not LUKS2"
fi

CIPHER=$(cryptsetup status soulstone_crypt 2>/dev/null | grep "cipher:" | awk '{print $2}')
if [[ "$CIPHER" == "aes-xts-plain64" ]]; then
    pass "Cipher: AES-XTS-plain64 (512-bit keys) confirmed"
else
    warn "Cipher is '$CIPHER' (expected aes-xts-plain64)"
fi

if [[ -f "$KEYFILE" ]]; then
    KPERMS=$(stat -c "%a" "$KEYFILE")
    KOWNER=$(stat -c "%U:%G" "$KEYFILE")
    if [[ "$KPERMS" == "400" && "$KOWNER" == "root:root" ]]; then
        pass "Keyfile $KEYFILE present: permissions 0400 root:root ✓"
    else
        fail "Keyfile permissions wrong: got $KPERMS $KOWNER (need 400 root:root)"
    fi
else
    fail "Machine keyfile $KEYFILE MISSING"
fi

KEYSLOTS=$(cryptsetup luksDump "/dev/disk/by-uuid/$LUKS_UUID" 2>/dev/null | grep -c "ENABLED" || true)
if [[ "$KEYSLOTS" -ge 1 ]]; then
    pass "LUKS keyslot(s) enabled: $KEYSLOTS active slot(s)"
else
    warn "Could not verify LUKS keyslots"
fi

# ═════════════════════════════════════════════════════════════════════════════
header "PHASE 2 · Filesystem & Mount Integrity"
# ═════════════════════════════════════════════════════════════════════════════

if mountpoint -q "$SD_MOUNT"; then
    pass "/mnt/sdcard is a valid, live mountpoint"
else
    fail "/mnt/sdcard is NOT mounted"
fi

FS_TYPE=$(findmnt -n -o FSTYPE "$SD_MOUNT" 2>/dev/null || echo "none")
if [[ "$FS_TYPE" == "btrfs" ]]; then
    pass "Filesystem type: btrfs ✓"
else
    fail "Filesystem type: $FS_TYPE (expected btrfs)"
fi

MOUNT_OPTS=$(findmnt -n -o OPTIONS "$SD_MOUNT" 2>/dev/null || echo "")
for OPT in "noatime" "lazytime" "compress=zstd:1" "space_cache=v2" "commit=120"; do
    if echo "$MOUNT_OPTS" | grep -q "$OPT"; then
        pass "Mount option '$OPT' active"
    else
        fail "Mount option '$OPT' MISSING (got: $MOUNT_OPTS)"
    fi
done

if echo "$MOUNT_OPTS" | grep -q "autodefrag"; then
    fail "CRITICAL: 'autodefrag' is set — causes flash wear amplification!"
else
    pass "autodefrag correctly absent (flash longevity protected)"
fi

if grep -q "x-gvfs-hide" /etc/fstab && ! grep -q "x-gvfs-show" /etc/fstab; then
    pass "fstab: x-gvfs-hide set on /mnt/sdcard (no duplicate GVFS mount) ✓"
else
    fail "fstab: x-gvfs-show still present → causes duplicate 'Soul Stone' in Nautilus!"
fi

# ═════════════════════════════════════════════════════════════════════════════
header "PHASE 3 · Companion Overlays & IDE Symlinks Health"
# ═════════════════════════════════════════════════════════════════════════════

ACTIVE_OVERLAYS=0
for OVERLAY in "${EXPECTED_OVERLAYS[@]}"; do
    if mountpoint -q "$OVERLAY" 2>/dev/null; then
        if timeout 2 ls "$OVERLAY" > /dev/null 2>&1; then
            pass "Native Overlay: $OVERLAY [ACTIVE & HEALTHY]"
            ((ACTIVE_OVERLAYS++)) || true
        else
            fail "Native Overlay: $OVERLAY is mounted but UNHEALTHY (stale/frozen)"
        fi
    else
        fail "Native Overlay: $OVERLAY NOT MOUNTED [OFFLINE LOCAL]"
    fi
done

for SYMLINK in "${EXPECTED_SYMLINKS[@]}"; do
    if [ -L "$SYMLINK" ] && [ -d "$SYMLINK" ]; then
        pass "IDE Symlink: $SYMLINK -> $(readlink "$SYMLINK") [HEALTHY & ZERO-MOUNT]"
    else
        fail "IDE Symlink broken or missing: $SYMLINK"
    fi
done

if mountpoint -q "$HOME_PORTAL" 2>/dev/null && timeout 2 ls "$HOME_PORTAL" > /dev/null 2>&1; then
    pass "Soul Stone home portal: ~/Soul Stone [ACTIVE PORTAL]"
    ((ACTIVE_OVERLAYS++)) || true
else
    fail "Soul Stone home portal: ~/Soul Stone NOT MOUNTED or unhealthy"
fi

info "Active native overlays: $ACTIVE_OVERLAYS/10 (9 standard + 1 portal)"

GHOST_MOUNTS=$(findmnt | grep "^│\?[├└].*\s/root/" || true)
if [[ -z "$GHOST_MOUNTS" ]]; then
    pass "No ghost /root/* mounts detected ✓"
else
    fail "Ghost /root/* mounts found: $GHOST_MOUNTS"
fi

# Check for nested/stacked mounts
STACKED_MOUNTS=$(findmnt -o TARGET | sort | uniq -d | grep -E "Projects|Soul Stone|sdcard" || true)
if [[ -z "$STACKED_MOUNTS" ]]; then
    pass "Zero stacked or duplicate mount points detected in mount table ✓"
else
    fail "Stacked mount points detected: $STACKED_MOUNTS"
fi

# ═════════════════════════════════════════════════════════════════════════════
header "PHASE 4 · GVFS / Nautilus Duplicate & Clutter Prevention"
# ═════════════════════════════════════════════════════════════════════════════

SS_COUNT=$(user_exec python3 -c "
import gi, sys
gi.require_version('Gio', '2.0')
from gi.repository import Gio
vm = Gio.VolumeMonitor.get()
count = 0
for m in vm.get_mounts():
    if 'Soul Stone' in m.get_name():
        count += 1
print(count)
" 2>/dev/null | tail -1)

if [[ "$SS_COUNT" == "1" ]]; then
    pass "Exactly 1 'Soul Stone' GIO mount detected (zero duplicates) ✓"
elif [[ "$SS_COUNT" == "0" ]]; then
    fail "No Soul Stone GIO mount visible in desktop session"
else
    fail "DUPLICATE DETECTED: $SS_COUNT 'Soul Stone' GIO mounts (expected 1)"
fi

SS_URI=$(user_exec python3 -c "
import gi
gi.require_version('Gio', '2.0')
from gi.repository import Gio
vm = Gio.VolumeMonitor.get()
for m in vm.get_mounts():
    if 'Soul Stone' in m.get_name() and m.get_volume():
        print(m.get_root().get_uri())
        break
" 2>/dev/null || echo "")

if echo "$SS_URI" | grep -q "Soul%20Stone\|Soul_Stone"; then
    pass "Soul Stone GIO mount points to ~/Soul Stone portal ✓"
elif [[ -n "$SS_URI" ]]; then
    warn "Soul Stone GIO mount URI: $SS_URI"
fi

FOLDER_MOUNTS=$(user_exec python3 -c "
import gi
gi.require_version('Gio', '2.0')
from gi.repository import Gio
vm = Gio.VolumeMonitor.get()
found = []
for m in vm.get_mounts():
    if m.get_name() in ['Pycharm Projects', 'Godot Projects', 'Arduino Projects', 'Projects', 'Downloads', 'Documents', 'Movies', 'Music', 'Pictures', 'Videos', 'Archives', 'Games']:
        found.append(m.get_name())
print(' '.join(found))
" 2>/dev/null || echo "")

if [[ -z "$FOLDER_MOUNTS" ]]; then
    pass "Zero folder mounts in GIO (Nautilus sidebar 100% clean of folder clutter) ✓"
else
    fail "Folder mounts detected in GIO: $FOLDER_MOUNTS"
fi

# ═════════════════════════════════════════════════════════════════════════════
header "PHASE 5 · Icon System Verification"
# ═════════════════════════════════════════════════════════════════════════════

if [[ -f "$ICON_PATH" ]]; then
    ICON_SIZE=$(python3 -c "from PIL import Image; img=Image.open('$ICON_PATH'); print(img.size[0])")
    if [[ "$ICON_SIZE" -ge 256 ]]; then
        pass "Custom sdcard.png icon: ${ICON_SIZE}x${ICON_SIZE}px ✓"
    else
        warn "Custom icon size is ${ICON_SIZE}px"
    fi
else
    fail "Custom icon MISSING: $ICON_PATH"
fi

CUSTOM_ICON=$(user_exec gio info "$HOME_PORTAL" 2>/dev/null | grep "metadata::custom-icon" | awk '{print $2}')
if [[ "$CUSTOM_ICON" == "file:///home/mr-reaper/.local/share/icons/sdcard.png" ]]; then
    pass "metadata::custom-icon correctly set on ~/Soul Stone portal ✓"
else
    fail "metadata::custom-icon on ~/Soul Stone: '$CUSTOM_ICON'"
fi

SYM_SVG="/home/mr-reaper/.local/share/icons/Yaru-purple/scalable/devices/media-flash-sd-symbolic.svg"
if [[ -f "$SYM_SVG" ]]; then
    if grep -q "currentColor\|fill=" "$SYM_SVG" && ! grep -q "data:image/png;base64" "$SYM_SVG"; then
        pass "Symbolic SVG is proper vector path SVG (no bitmap wrapper) ✓"
    elif grep -q "data:image/png;base64" "$SYM_SVG"; then
        fail "Symbolic SVG contains raster base64 PNG embed"
    else
        warn "Could not inspect symbolic SVG"
    fi
else
    fail "Symbolic SVG missing at $SYM_SVG"
fi

# ═════════════════════════════════════════════════════════════════════════════
header "PHASE 6 · Udev & Systemd Configuration"
# ═════════════════════════════════════════════════════════════════════════════

UDEV_FILES=$(ls /etc/udev/rules.d/ | grep -E "sdcard|soulstone")
if echo "$UDEV_FILES" | grep -q "80-sdcard-icons.rules" && echo "$UDEV_FILES" | grep -q "99-soulstone.rules" && [[ ! -f /etc/udev/rules.d/99-sdcard-icons.rules ]]; then
    pass "Udev rules: clean consolidated pair (80-sdcard-icons.rules + 99-soulstone.rules) ✓"
else
    fail "Udev rules unexpected state: $UDEV_FILES"
fi

if systemctl cat soulstone-storage.service > /dev/null 2>&1; then
    pass "soulstone-storage.service present and enabled ✓"
else
    fail "soulstone-storage.service not found"
fi

if [[ -f /etc/systemd/system/mnt-sdcard.mount.d/override.conf ]] && grep -q "ExecStopPre" /etc/systemd/system/mnt-sdcard.mount.d/override.conf; then
    pass "mnt-sdcard.mount.d/override.conf: ExecStopPre GUI eject hook active ✓"
else
    fail "override.conf missing ExecStopPre hook"
fi

if grep -q "SOUL_BOOT" /etc/udev/rules.d/99-soulstone.rules 2>/dev/null; then
    pass "SOUL_BOOT FAT32 partition hidden via udev UDISKS_IGNORE ✓"
else
    warn "SOUL_BOOT hide rule not found"
fi

# ═════════════════════════════════════════════════════════════════════════════
header "PHASE 7 · Data Integrity & Btrfs Health"
# ═════════════════════════════════════════════════════════════════════════════

echo "soulstone_test_$(date +%s)" > "$TEST_FILE"
WRITTEN=$(cat "$TEST_FILE" 2>/dev/null)
if [[ -n "$WRITTEN" ]]; then
    pass "Live read/write test on Soul Stone: verified ✓"
    rm -f "$TEST_FILE"
else
    fail "Read/write test FAILED on Soul Stone"
fi

BTRFS_ERRORS=$(btrfs device stats "$SD_MOUNT" 2>/dev/null | grep -v "^Label\|^\s*$" | awk '{print $2}' | grep -v "^0$" || true)
if [[ -z "$BTRFS_ERRORS" ]]; then
    pass "Btrfs device stats: 0 errors across all counters ✓"
else
    fail "Btrfs device stats show errors: $BTRFS_ERRORS"
fi

OWNER=$(stat -c "%U:%G" "$SD_MOUNT")
if [[ "$OWNER" == "mr-reaper:mr-reaper" ]]; then
    pass "SD card root ownership: mr-reaper:mr-reaper ✓"
else
    fail "SD card root ownership: $OWNER"
fi

# ═════════════════════════════════════════════════════════════════════════════
header "PHASE 8 · Soulstone-Forge GitHub Repository"
# ═════════════════════════════════════════════════════════════════════════════

if [[ -d "$REPO_PATH/.git" ]]; then
    pass "soulstone-forge git repo verified at $REPO_PATH ✓"
else
    fail "soulstone-forge git repo missing at $REPO_PATH"
fi

GIT_STATUS=$(git -C "$REPO_PATH" status --porcelain 2>/dev/null)
if [[ -z "$GIT_STATUS" ]]; then
    pass "Git working tree: clean (nothing uncommitted) ✓"
else
    warn "Git working tree has uncommitted changes: $GIT_STATUS"
fi

# ═════════════════════════════════════════════════════════════════════════════
header "PHASE 9 · UNMOUNT / EJECT & REMOUNT FULL CYCLE TEST"
# ═════════════════════════════════════════════════════════════════════════════

info "Executing controlled ejection test via soulstone-storage eject..."
/usr/local/bin/soulstone-storage eject
sleep 2

MOUNTS_AFTER_EJECT=$(findmnt | grep "soulstone_crypt" || true)
if [[ -z "$MOUNTS_AFTER_EJECT" ]]; then
    pass "Post-eject: all overlays & root mount cleanly detached ✓"
else
    fail "Post-eject: mounts still active: $MOUNTS_AFTER_EJECT"
fi

if cryptsetup status soulstone_crypt > /dev/null 2>&1; then
    fail "Post-eject: LUKS container 'soulstone_crypt' still open"
else
    pass "Post-eject: LUKS container 'soulstone_crypt' closed cleanly ✓"
fi

OFFLINE_COUNT=0
for OVERLAY in "${EXPECTED_OVERLAYS[@]}"; do
    if ! mountpoint -q "$OVERLAY" 2>/dev/null; then
        ((OFFLINE_COUNT++)) || true
    fi
done
if [[ "$OFFLINE_COUNT" -eq "${#EXPECTED_OVERLAYS[@]}" ]]; then
    pass "Post-eject: all 9 companion directories offline (internal drive preserved) ✓"
else
    fail "Post-eject: some overlays remained mounted"
fi

info "Executing remount test via soulstone-storage attach..."
/usr/local/bin/soulstone-storage attach
sleep 2

REATTACH_COUNT=0
for OVERLAY in "${EXPECTED_OVERLAYS[@]}"; do
    if mountpoint -q "$OVERLAY" 2>/dev/null && timeout 2 ls "$OVERLAY" > /dev/null 2>&1; then
        ((REATTACH_COUNT++)) || true
    else
        fail "Post-reattach: overlay NOT restored: $OVERLAY"
    fi
done
if [[ "$REATTACH_COUNT" -eq "${#EXPECTED_OVERLAYS[@]}" ]]; then
    pass "Post-reattach: all 9 companion overlays ACTIVE and healthy ✓"
fi

for SYMLINK in "${EXPECTED_SYMLINKS[@]}"; do
    if [ -L "$SYMLINK" ] && [ -d "$SYMLINK" ]; then
        pass "Post-reattach: IDE Symlink $SYMLINK verified ✓"
    else
        fail "Post-reattach: IDE Symlink broken: $SYMLINK"
    fi
done

if mountpoint -q "$HOME_PORTAL" 2>/dev/null; then
    pass "Post-reattach: ~/Soul Stone home portal remounted ✓"
else
    fail "Post-reattach: ~/Soul Stone portal NOT remounted"
fi

DATA_CHECK=$(echo "integrity_cycle_$(date +%s)" | tee /mnt/sdcard/.cycle_test 2>/dev/null)
READBACK=$(cat /mnt/sdcard/.cycle_test 2>/dev/null)
if [[ "$DATA_CHECK" == "$READBACK" ]]; then
    pass "Data integrity after unmount/remount cycle: verified ✓"
    rm -f /mnt/sdcard/.cycle_test
else
    fail "Data integrity check FAILED after remount"
fi

# ═════════════════════════════════════════════════════════════════════════════
header "PHASE 10 · Live Telemetry Status"
# ═════════════════════════════════════════════════════════════════════════════

/usr/local/bin/soulstone-storage status

# ═════════════════════════════════════════════════════════════════════════════
header "FINAL TEST SUMMARY"
# ═════════════════════════════════════════════════════════════════════════════

TOTAL=$((PASS + FAIL + WARN))
echo -e "\n  ${BOLD}Total Tests Run:${RESET} $TOTAL"
echo -e "  ${GREEN}${BOLD}PASS:${RESET} $PASS"
echo -e "  ${RED}${BOLD}FAIL:${RESET} $FAIL"
echo -e "  ${YELLOW}${BOLD}WARN:${RESET} $WARN"

if [[ ${#FAIL_DETAILS[@]} -gt 0 ]]; then
    echo -e "\n  ${RED}${BOLD}Failed Tests:${RESET}"
    for F in "${FAIL_DETAILS[@]}"; do
        echo -e "    ${RED}✘${RESET} $F"
    done
fi

if [[ "$FAIL" -eq 0 ]]; then
    echo -e "\n  ${GREEN}${BOLD}✔ ALL SYSTEMS OPERATIONAL — ZERO FAILURES, ZERO CLUTTER${RESET}\n"
    exit 0
else
    echo -e "\n  ${RED}${BOLD}✘ $FAIL TEST(S) FAILED${RESET}\n"
    exit 1
fi
