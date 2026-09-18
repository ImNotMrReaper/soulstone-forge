# ⚡ SoulStone Forge

> **Master Template & Automation Engine for Soul Stone Modular Removable Storage on Linux**

`SoulStone Forge` turns any MicroSD card, SD card, or external SSD into a transparent **modular companion storage device** for your Linux laptop.

It mirrors the exact architecture currently running on your system:
- **100% Native SD Residence:** Selected user directories (`Downloads`, `Documents`, `Pictures`, `Music`, `Videos`, `Movies`, `Archives`, `Projects`) live purely on the SD card with zero duplicate storage on the internal NVMe drive.
- **Offline Fallback & Auto-Sync:** When the SD card is disconnected, folders remain clean placeholders for offline use. When plugged back in, any new offline files are automatically migrated (`rsync -av --remove-source-files`) and transparently re-mounted.
- **Single Drive Presentation:** Sub-directory bind-mounts are tagged with `x-gvfs-hide` so individual folders never clutter the Ubuntu Dock or file manager sidebar. Only the single **Soul Stone** drive appears.
- **1-Click User Eject:** Polkit authorization rules grant 1-click unmount/eject without password prompts.
- **Themed Custom SD Icon:** Custom transparent purple SD card icon (`#7764D8`) with true GTK4 vector symbolic SVGs across all resolutions (`16x16` through `512x512`).

---

## 🛠️ Quick Commands

```bash
# Launch Interactive TUI (Format, Clone, Diagnose, Mount)
soulstone

# Forge a brand new SD Card (Example: on /dev/sda)
sudo soulstone --forge /dev/sda

# Clone/Migrate an existing Soul Stone to a new SD card
sudo soulstone --clone /mnt/sdcard /dev/sdb

# Check live mount and directory health status
soulstone --status

# Reinstall and refresh all custom GTK purple SD card icons
soulstone --install-icons
```

---

## 📦 Project Architecture

```text
soulstone-forge/
├── assets/
│   └── sdcard.png                   # Master 1024x1024 transparent purple RGBA icon (#7764D8)
├── bin/
│   └── soulstone                    # Global CLI executable launcher
├── src/
│   └── engine.py                    # Master Python provisioning & migration engine
├── templates/
│   ├── soulstone-storage.sh         # Live mount, auto-sync & health probe engine
│   ├── 99-sdcard-icons.rules        # UDev hotplug auto-mount & icon rule
│   ├── soulstone-storage.service    # Systemd hotplug background service
│   └── 50-udisks2-soulstone.rules   # Polkit user unmount authorization
└── README.md                        # Documentation & recovery runbook
```

---

## 🔄 Disaster Recovery: Forging a Replacement Card

If you ever lose or upgrade your SD card:
1. Insert your new MicroSD card into your laptop.
2. Run:
   ```bash
   soulstone
   ```
3. Select **`[1] Forge a NEW Soul Stone`** and pick your device.
4. The engine will:
   - Partition with GPT and format with Btrfs (`zstd:3` transparent compression).
   - Generate all folder skeletons (`Downloads`, `Documents`, `Pictures`, `Projects`, etc.).
   - Embed `.VolumeIcon.png` and update your system's UUID bindings.
   - Bind-mount all folders and establish your [`~/SD Card`](file:///home/mr-reaper/SD%20Card) portal.
