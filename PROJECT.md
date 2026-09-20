# Project: System Automation Suite (Soul Stone, Biometrics, Joy-Con)

## Architecture
This project implements and hardens a 3-pillar system automation suite on Ubuntu 24.04 LTS (GNOME 46 Wayland on Dell Inspiron 16 5640):
1. **Removable Companion Storage Subsystem (`soulstone-storage`)**:
   - Manages an encrypted LUKS2/Btrfs micro-SD card (`Soul Stone`, UUID `18ceeb84-5abf-4456-88a2-d2f2fb2255f0`).
   - Dynamic mount detection handles both UDisks2 desktop automounts (`/media/mr-reaper/Soul Stone`) and headless systemd mount points (`/mnt/sdcard`).
   - Binds companion directories (`Downloads`, `Documents`, `Pictures`, `Projects`, `Games`, `Soul Stone`) into `~` with `-o x-gvfs-hide` for Ubuntu Dock & Nautilus sidebar clutter suppression.
   - Arms udev rule (`/etc/udev/rules.d/99-sdcard-icons.rules`) and systemd service (`soulstone-storage.service`) to trigger automated attachment upon unlocking.
   - Enforces `mr-reaper:mr-reaper` ownership across all directories including `Games/{SteamLibrary, Emulators, RetroArch, ROMs}`.
   - Sets GIO metadata custom icon (`~/.local/share/icons/sdcard.png`) on `~/Soul Stone`.

2. **Biometric Multi-User Dual-Slot Parity Subsystem (`reaper-biometrics`)**:
   - Dual physical sensors: Goodix MOC capacitive sensor (`27c6:631c`) on power button and Digital Persona U.are.U 4500 optical USB reader (`05ba:000a`).
   - Multi-user slot allocation: Mr-Reaper (Owner, 4 finger slots) and Rinnythepooh (Partner, 4 finger slots) concurrently active across both sensors (8 hardware templates per device, 16 total).
   - AES-256-GCM AEAD encrypted template vault (`/etc/reaper-biometrics/fingerprints_vault.enc`).
   - NIST Bozorth3 sensitivity tuning: set `FP_BZ3_IDENTIFY_THRESHOLD=14` alongside `FP_BZ3_THRESHOLD=14` in `/etc/systemd/system/fprintd.service.d/override.conf` for 1-to-N identify accuracy on optical sensor.
   - PAM pipeline: `/lib/security/reaper_fprint_pam.py` and `reaper_concurrent_biometric_pam.py` forward `--service` and `--command` context, stream live sensor and user identification visual feedback, and provide non-blocking authentication. Direct symlink `/var/lib/fprint/rinnythepooh -> mr-reaper`.

3. **Joy-Con Controller Mouse Remote Subsystem (`joycon-mouse`)**:
   - Unified repository path between `/home/mr-reaper/.local/share/joycon-mouse/` and `/home/mr-reaper/PycharmProjects/joycon-mouse/`.
   - Active window focus detection on GNOME 46 Wayland via active host GNOME Shell extension `display-window-restorer@mr-reaper` exporting focused window state to `/run/user/1000/active_window.json`.
   - Automatic gaming pause: on focus of Xbox Cloud Gaming PWA (`chrome-www.xbox.com__play-Default`) or full-screen games, release virtual keys and drop `EVIOCGRAB` to let native gamepad events pass cleanly.
   - Automatic desktop resume: on window defocus, drain event descriptors, re-arm `EVIOCGRAB`, and resume desktop air-mouse emulation.
   - CLI status command `joycon-mouse --status` providing structured state transition reporting.

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | Dynamic Mount Detection | Detect both `/media/mr-reaper/Soul Stone` and `/mnt/sdcard` | M1 | ORIGINAL_REQUEST §R1 |
| 2 | GVFS Dock Suppression | Bind-mount companion folders with `-o x-gvfs-hide` | M1 | ORIGINAL_REQUEST §R1 |
| 3 | SD Card Permissions | Recursive `mr-reaper:mr-reaper` on SD card & Games subfolders | M1 | ORIGINAL_REQUEST §R1 |
| 4 | Home Portal & GIO Icon | Configure `~/Soul Stone` directory overlay with purple SD icon | M1 | ORIGINAL_REQUEST §R1 |
| 5 | Systemd & Udev Automation | Fix udev rule matching (`Soul_Stone`) and enable service | M1 | ORIGINAL_REQUEST §R1 |
| 6 | Storage Status Reporting | `soulstone-storage status` reports all overlays as `[ACTIVE NATIVE]` | M1 | ORIGINAL_REQUEST §AC |
| 7 | Multi-User Template Parity | 8 enrolled prints per sensor partitioned for Mr-Reaper & Rinnythepooh | M2 | ORIGINAL_REQUEST §R2 |
| 8 | Bozorth3 Identify Threshold | Set `FP_BZ3_IDENTIFY_THRESHOLD=14` in fprintd override | M2 | Survey Discovery |
| 9 | Direct User Listing | Symlink `/var/lib/fprint/rinnythepooh -> mr-reaper` | M2 | ORIGINAL_REQUEST §R2 |
| 10 | PAM Context & Live Feedback | Pass `--service` in PAM wrapper and stream live visual feedback | M2 | ORIGINAL_REQUEST §R2 |
| 11 | Joy-Con Repo Unification | Symlink PycharmProjects to `.local/share/joycon-mouse` | M3 | Survey Discovery |
| 12 | Wayland Focus Telemetry | GNOME Shell extension focus bridge via `/run/user/1000/active_window.json` | M3 | ORIGINAL_REQUEST §R3 |
| 13 | Gaming Focus Auto-Pause | Release `EVIOCGRAB` and virtual keys when Xbox PWA/game focused | M3 | ORIGINAL_REQUEST §R3 |
| 14 | Desktop Focus Auto-Resume | Drain descriptors and re-arm `EVIOCGRAB` when returning to desktop | M3 | ORIGINAL_REQUEST §R3 |
| 15 | Driver Status Reporting | `joycon-mouse --status` displays mode and transition telemetry | M3 | ORIGINAL_REQUEST §AC |
| 16 | E2E System Verification | Full verification across R1, R2, R3 against acceptance criteria | M4 | ORIGINAL_REQUEST §AC |
| 17 | Task Ledger Logging | Record full changes in `~/.agents/tasks/TASKS.md` | M4 | Directives & persistent-task-tracking |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Soul Stone SD Card Engine & Dynamic Overlays | Features 1–6 | none | IN_PROGRESS |
| M2 | Biometric Multi-User Dual-Slot Parity | Features 7–10 | none | PLANNED |
| M3 | Joy-Con Mouse Driver Gaming Focus Auto-Pause | Features 11–15 | none | PLANNED |
| M4 | E2E Acceptance Verification & Hardening | Features 16–17 | M1, M2, M3 | PLANNED |

## Interface Contracts
### Storage ↔ System & Desktop
- Mount paths: `/media/mr-reaper/Soul Stone` or `/mnt/sdcard`
- Overlays: `~/Downloads`, `~/Documents`, `~/Pictures`, `~/Projects`, `~/Games`, `~/Soul Stone`
- Mount flags: `-o bind,x-gvfs-hide`
- Service: `soulstone-storage.service` triggered by `ENV{SYSTEMD_WANTS}` via udev
- Status CLI: `/usr/local/bin/soulstone-storage status` (outputs `[ACTIVE NATIVE]` for all companion overlays)

### Biometrics ↔ PAM & fprintd
- Sensors: Device 0 (`goodixmoc`), Device 1 (`uru4000/0`)
- Enrolled slots: 8 per sensor (`left-thumb`, `left-index-finger`, `left-middle-finger`, `left-ring-finger`, `right-thumb`, `right-index-finger`, `right-middle-finger`, `right-ring-finger`)
- User allocation: Mr-Reaper (slots 1, 2, 5, 6), Rinnythepooh (slots 3, 4, 7, 8)
- Thresholds: `FP_BZ3_THRESHOLD=14`, `FP_BZ3_IDENTIFY_THRESHOLD=14`
- PAM wrappers: `/lib/security/reaper_fprint_pam.py`, `/lib/security/reaper_concurrent_biometric_pam.py`

### Joy-Con ↔ GNOME Shell Wayland
- Focus bridge: `/run/user/1000/active_window.json` containing `{"active": bool, "wm_class": str, "title": str, "is_fullscreen": bool}`
- PWA class: `chrome-www.xbox.com__play-Default`
- Controller Grab: `ioctl(fd, EVIOCGRAB, 1)` (active mouse) / `ioctl(fd, EVIOCGRAB, 0)` (paused gaming)
- CLI command: `joycon-mouse --status`

## Code Layout
- `/usr/local/bin/soulstone-storage`: Primary storage CLI and automation script
- `/home/mr-reaper/.local/share/soulstone-forge/src/engine.py`: Python storage engine
- `/etc/udev/rules.d/99-sdcard-icons.rules`: Storage automount udev rule
- `/etc/systemd/system/soulstone-storage.service`: Storage systemd unit
- `/etc/systemd/system/fprintd.service.d/override.conf`: fprintd thresholds override
- `/lib/security/reaper_concurrent_biometric_pam.py`: PAM concurrent biometrics module
- `/lib/security/reaper_fprint_pam.py`: PAM fprint module
- `/var/lib/fprint/rinnythepooh`: Symlink to `/var/lib/fprint/mr-reaper`
- `/home/mr-reaper/.local/share/gnome-shell/extensions/display-window-restorer@mr-reaper/extension.js`: Window focus export hook
- `/home/mr-reaper/.local/share/joycon-mouse/joycon-mouse.py`: Joy-Con daemon
- `/home/mr-reaper/PycharmProjects/joycon-mouse`: Symlink to `/home/mr-reaper/.local/share/joycon-mouse`
- `~/.agents/tasks/TASKS.md`: System task ledger
