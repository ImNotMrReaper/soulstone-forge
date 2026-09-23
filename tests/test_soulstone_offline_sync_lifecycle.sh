#!/usr/bin/env bash
# =============================================================================
# Soul Stone: Offline Sync & Directory Usability Comprehensive Test Suite
# Tests:
#   1. Clean Mount & Attachment on SD Card Plug
#   2. Clean Unmount & Ghost-Mount Elimination on SD Card Unplug
#   3. Zero SD Card Files lingering on Computer when Unmounted
#   4. Directory Tree Usability & Persistence on Computer while Offline
#   5. Writing/Moving Files to Computer Directories while Unmounted
#   6. Automatic Reconciliation & Sync of Computer Files to SD Card on Re-Mount
#   7. Verified Content Checksums & Zero-Pollution Teardown
# =============================================================================
set -e

# ── ANSI Colors ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

PASS=0; FAIL=0; WARN=0
FAIL_DETAILS=()

pass() { echo -e "  ${GREEN}✔ PASS${RESET}  $1"; ((PASS++)) || true; }
fail() { echo -e "  ${RED}✘ FAIL${RESET}  $1"; ((FAIL++)) || true; FAIL_DETAILS+=("$1"); }
warn() { echo -e "  ${YELLOW}⚠ WARN${RESET}  $1"; ((WARN++)) || true; }
info() { echo -e "  ${CYAN}ℹ${RESET}      $1"; }
header() {
    echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}  $1${RESET}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════════════${RESET}"
}

# ── User Context Resolution ──────────────────────────────────────────────────
USER_NAME="mr-reaper"
USER_HOME="/home/$USER_NAME"
USER_UID="$(id -u "$USER_NAME" 2>/dev/null || echo 1000)"

user_exec() {
    sudo -u "$USER_NAME" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" "$@"
}

# ── Constants ────────────────────────────────────────────────────────────────
LUKS_UUID="8636c4f3-09c8-42ce-bf9b-fe273be32b3f"
BTRFS_UUID="18ceeb84-5abf-4456-88a2-d2f2fb2255f0"
SD_MOUNT="/mnt/sdcard"
HOME_PORTAL="$USER_HOME/Soul Stone"
TEST_TIMESTAMP="$(date +%s)"
TEST_SKETCH_NAME="test_offline_sketch_${TEST_TIMESTAMP}.ino"
TEST_DOC_NAME="test_offline_document_${TEST_TIMESTAMP}.txt"
TEST_DL_NAME="test_offline_download_${TEST_TIMESTAMP}.dat"

TEST_DIRS=(
    "$USER_HOME/Projects"
    "$USER_HOME/Projects/Arduino Projects"
    "$USER_HOME/Projects/Godot Projects"
    "$USER_HOME/Projects/Pycharm Projects"
    "$USER_HOME/Documents"
    "$USER_HOME/Downloads"
    "$USER_HOME/Pictures"
    "$USER_HOME/Music"
    "$USER_HOME/Videos"
    "$USER_HOME/Movies"
    "$USER_HOME/Archives"
    "$USER_HOME/Games"
)

OVERLAYS=(
    "$USER_HOME/Archives"
    "$USER_HOME/Documents"
    "$USER_HOME/Downloads"
    "$USER_HOME/Pictures"
    "$USER_HOME/Music"
    "$USER_HOME/Videos"
    "$USER_HOME/Movies"
    "$USER_HOME/Projects"
    "$USER_HOME/Games"
)

IDE_SYMLINKS=(
    "$USER_HOME/Arduino Projects"
    "$USER_HOME/Godot Projects"
    "$USER_HOME/Pycharm Projects"
)

# ═════════════════════════════════════════════════════════════════════════════
header "PHASE 1 · Watchdog Daemon & System Service Integrity"
# ═════════════════════════════════════════════════════════════════════════════

if systemctl is-active --quiet soulstone-daemon.service; then
    pass "soulstone-daemon.service is active and running"
else
    fail "soulstone-daemon.service is not running"
fi

if [[ -x "/usr/local/bin/soulstone-storage" ]]; then
    pass "/usr/local/bin/soulstone-storage is installed and executable"
else
    fail "/usr/local/bin/soulstone-storage missing or not executable"
fi

if [[ -x "/usr/local/bin/soulstone-daemon" ]]; then
    pass "/usr/local/bin/soulstone-daemon is installed and executable"
else
    fail "/usr/local/bin/soulstone-daemon missing or not executable"
fi

# Assert no conflicting static entries in fstab or crypttab
if grep -q "^/dev/mapper/soulstone_crypt" /etc/fstab 2>/dev/null; then
    fail "Conflicting active /mnt/sdcard entry found in /etc/fstab"
else
    pass "No conflicting active /mnt/sdcard autofs entry in /etc/fstab"
fi

if grep -q "^soulstone_crypt\b" /etc/crypttab 2>/dev/null; then
    fail "Conflicting active soulstone_crypt entry found in /etc/crypttab"
else
    pass "No conflicting static soulstone_crypt entry in /etc/crypttab"
fi

# ═════════════════════════════════════════════════════════════════════════════
header "PHASE 2 · Baseline State & Clean Detach (Unmount Test)"
# ═════════════════════════════════════════════════════════════════════════════

info "Stopping soulstone-daemon temporarily to simulate physical SD card removal..."
sudo systemctl stop soulstone-daemon.service
info "Executing clean detach to simulate unmounted/unplugged state..."
sudo /usr/local/bin/soulstone-storage detach

# Verify everything is unmounted
all_unmounted=true
for dir in "${OVERLAYS[@]}"; do
    if mountpoint -q "$dir" 2>/dev/null; then
        fail "Directory still mounted: $dir"
        all_unmounted=false
    fi
done
if [[ "$all_unmounted" == true ]]; then
    pass "All 9 home directory overlays cleanly unmounted"
fi

if mountpoint -q "$SD_MOUNT" 2>/dev/null; then
    fail "$SD_MOUNT is still mounted"
else
    pass "$SD_MOUNT is completely unmounted"
fi

if mountpoint -q "$HOME_PORTAL" 2>/dev/null; then
    fail "$HOME_PORTAL is still mounted"
else
    pass "Home portal $HOME_PORTAL is completely unmounted"
fi

if [[ -b "/dev/mapper/soulstone_crypt" ]]; then
    fail "/dev/mapper/soulstone_crypt device mapper is still open"
else
    pass "/dev/mapper/soulstone_crypt is cleanly closed"
fi

# Verify GNOME Files / gio shows NO mounted Soul Stone volume
gio_output="$(user_exec gio mount -l 2>/dev/null || true)"
if echo "$gio_output" | grep -q "Soul Stone -> file://"; then
    fail "Soul Stone volume still shows as mounted in GNOME Files (Nautilus)"
else
    pass "Soul Stone volume does NOT show as mounted in GNOME Files / Nautilus"
fi

# ═════════════════════════════════════════════════════════════════════════════
header "PHASE 3 · Local Computer Directory Usability & Persistence Test"
# ═════════════════════════════════════════════════════════════════════════════

info "Verifying that computer directories are intact, writable, and usable while offline..."

all_dirs_exist=true
for dir in "${TEST_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        # Check permissions
        if sudo -u "$USER_NAME" test -w "$dir"; then
            pass "Directory exists & is writable: $dir"
        else
            fail "Directory exists but is not writable: $dir"
            all_dirs_exist=false
        fi
    else
        fail "Directory missing on computer: $dir"
        all_dirs_exist=false
    fi
done

# Verify IDE symlinks are valid and point to existing local directories
for symlink in "${IDE_SYMLINKS[@]}"; do
    if [[ -L "$symlink" ]] && [[ -d "$symlink" ]]; then
        target="$(readlink "$symlink")"
        pass "IDE symlink valid: $symlink -> $target"
    else
        fail "IDE symlink broken or missing: $symlink"
    fi
done

# ═════════════════════════════════════════════════════════════════════════════
header "PHASE 4 · Offline File Creation Test (Simulating Work without SD Card)"
# ═════════════════════════════════════════════════════════════════════════════

info "Writing test files to computer directories while SD card is unmounted..."

TEST_SKETCH="$USER_HOME/Projects/Arduino Projects/$TEST_SKETCH_NAME"
TEST_DOC="$USER_HOME/Documents/$TEST_DOC_NAME"
TEST_DL="$USER_HOME/Downloads/$TEST_DL_NAME"

PAYLOAD_SKETCH="// Soul Stone Offline Test Sketch - Generated at $TEST_TIMESTAMP\nvoid setup() { Serial.begin(115200); }\nvoid loop() { delay(1000); }"
PAYLOAD_DOC="Soul Stone Offline Document Payload - Timestamp $TEST_TIMESTAMP - Integrity Verified."
PAYLOAD_DL="BINARY_DATA_DUMMY_PAYLOAD_TEST_${TEST_TIMESTAMP}_FORGE"

sudo -u "$USER_NAME" bash -c "echo -e '$PAYLOAD_SKETCH' > '$TEST_SKETCH'"
sudo -u "$USER_NAME" bash -c "echo -e '$PAYLOAD_DOC' > '$TEST_DOC'"
sudo -u "$USER_NAME" bash -c "echo -e '$PAYLOAD_DL' > '$TEST_DL'"

if [[ -f "$TEST_SKETCH" ]] && [[ -f "$TEST_DOC" ]] && [[ -f "$TEST_DL" ]]; then
    pass "Test files successfully created in computer directories while offline"
else
    fail "Failed to write test files to computer directories while offline"
fi

# Calculate local sha256 checksums
HASH_SKETCH="$(sha256sum "$TEST_SKETCH" | awk '{print $1}')"
HASH_DOC="$(sha256sum "$TEST_DOC" | awk '{print $1}')"
HASH_DL="$(sha256sum "$TEST_DL" | awk '{print $1}')"
info "Computed local SHA256 hashes:"
info "  Sketch: $HASH_SKETCH"
info "  Doc:    $HASH_DOC"
info "  DL:     $HASH_DL"

# ═════════════════════════════════════════════════════════════════════════════
header "PHASE 5 · Re-Attachment & Automatic Sync Test (Simulating SD Card Plugged In)"
# ═════════════════════════════════════════════════════════════════════════════

info "Attaching Soul Stone to test automatic reconciliation & sync..."
sudo /usr/local/bin/soulstone-storage attach
sudo systemctl start soulstone-daemon.service

# Verify attachment
if mountpoint -q "$SD_MOUNT"; then
    pass "Soul Stone decrypted mount active at $SD_MOUNT"
else
    fail "$SD_MOUNT failed to mount"
fi

if mountpoint -q "$HOME_PORTAL"; then
    pass "Unified home portal active at $HOME_PORTAL"
else
    fail "$HOME_PORTAL failed to mount"
fi

# Check GNOME Files custom icon metadata
icon_meta="$(user_exec gio info "$HOME_PORTAL" 2>/dev/null | grep "metadata::custom-icon" || true)"
if [[ -n "$icon_meta" ]]; then
    pass "GNOME custom icon metadata verified on $HOME_PORTAL"
else
    warn "Custom icon metadata not reported by gio info (session bus variance)"
fi

# Verify offline files were transferred/synced to the physical SD card
SD_SKETCH="$SD_MOUNT/Projects/Arduino Projects/$TEST_SKETCH_NAME"
SD_DOC="$SD_MOUNT/Documents/$TEST_DOC_NAME"
SD_DL="$SD_MOUNT/Downloads/$TEST_DL_NAME"

if [[ -f "$SD_SKETCH" ]]; then
    pass "Offline sketch successfully synced to SD card: $SD_SKETCH"
    SD_HASH_SKETCH="$(sha256sum "$SD_SKETCH" | awk '{print $1}')"
    if [[ "$HASH_SKETCH" == "$SD_HASH_SKETCH" ]]; then
        pass "Sketch SHA256 checksum matches 100%!"
    else
        fail "Sketch SHA256 mismatch! Local: $HASH_SKETCH, SD: $SD_HASH_SKETCH"
    fi
else
    fail "Offline sketch was NOT synced to SD card: $SD_SKETCH"
fi

if [[ -f "$SD_DOC" ]]; then
    pass "Offline document successfully synced to SD card: $SD_DOC"
    SD_HASH_DOC="$(sha256sum "$SD_DOC" | awk '{print $1}')"
    if [[ "$HASH_DOC" == "$SD_HASH_DOC" ]]; then
        pass "Document SHA256 checksum matches 100%!"
    else
        fail "Document SHA256 mismatch! Local: $HASH_DOC, SD: $SD_HASH_DOC"
    fi
else
    fail "Offline document was NOT synced to SD card: $SD_DOC"
fi

if [[ -f "$SD_DL" ]]; then
    pass "Offline download file successfully synced to SD card: $SD_DL"
    SD_HASH_DL="$(sha256sum "$SD_DL" | awk '{print $1}')"
    if [[ "$HASH_DL" == "$SD_HASH_DL" ]]; then
        pass "Download file SHA256 checksum matches 100%!"
    else
        fail "Download file SHA256 mismatch! Local: $HASH_DL, SD: $SD_HASH_DL"
    fi
else
    fail "Offline download file was NOT synced to SD card: $SD_DL"
fi

# Verify the files are also visible through the mounted computer directories
if [[ -f "$TEST_SKETCH" ]] && [[ -f "$TEST_DOC" ]] && [[ -f "$TEST_DL" ]]; then
    pass "Synced files are immediately visible in computer directories (~/Projects, ~/Documents, ~/Downloads)"
else
    fail "Synced files are not visible in computer directories"
fi

# ═════════════════════════════════════════════════════════════════════════════
header "PHASE 6 · Clean Detach & Host Isolation Verification"
# ═════════════════════════════════════════════════════════════════════════════

info "Cleaning test files from SD card..."
rm -f "$SD_SKETCH" "$SD_DOC" "$SD_DL"
sync

info "Executing final detach to verify host directory isolation..."
sudo systemctl stop soulstone-daemon.service
sudo /usr/local/bin/soulstone-storage detach

# Verify that test files are GONE from the computer (because they lived on the SD card)
if [[ ! -f "$TEST_SKETCH" ]] && [[ ! -f "$TEST_DOC" ]] && [[ ! -f "$TEST_DL" ]]; then
    pass "Verified: No SD card files linger on the computer when unmounted"
else
    fail "Some test files still linger on the computer after unmount"
fi

# Verify that the directories STILL EXIST and are ready for new work
for dir in "${TEST_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        pass "Directory remains intact and usable: $dir"
    else
        fail "Directory disappeared after detach: $dir"
    fi
done

# Re-attach so the user's system returns to mounted active state
info "Re-attaching Soul Stone to leave system in active operational state..."
sudo /usr/local/bin/soulstone-storage attach
sudo systemctl start soulstone-daemon.service

# ═════════════════════════════════════════════════════════════════════════════
header "FINAL VERDICT & TEST METRICS"
# ═════════════════════════════════════════════════════════════════════════════

TOTAL=$((PASS + FAIL + WARN))
echo -e "\n  ${BOLD}Total Assertions Checked:${RESET} $TOTAL"
echo -e "  ${GREEN}${BOLD}Assertions Passed:${RESET}        $PASS"
echo -e "  ${RED}${BOLD}Assertions Failed:${RESET}        $FAIL"
echo -e "  ${YELLOW}${BOLD}Warnings:${RESET}                 $WARN\n"

if [[ "$FAIL" -gt 0 ]]; then
    echo -e "${RED}${BOLD}❌ Test Suite FAILED with $FAIL errors:${RESET}"
    for err in "${FAIL_DETAILS[@]}"; do
        echo -e "  - $err"
    done
    exit 1
else
    echo -e "${GREEN}${BOLD}✔ ALL ASSERTIONS PASSED! Soul Stone operates with 100% compliance.${RESET}\n"
    exit 0
fi
