#!/usr/bin/env bash
# Soul Stone Universal Linux Companion Installer
# Installs storage engine, udev rules, systemd services, and desktop icons on any Linux machine
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "[!] Please run as root (e.g. sudo bash install_linux.sh)"
    exit 1
fi

echo "=================================================================="
echo "          SOUL STONE LINUX COMPANION DRIVE INSTALLER"
echo "=================================================================="

# Detect primary user
if [ -n "$SUDO_USER" ]; then
    TARGET_USER="$SUDO_USER"
else
    TARGET_USER="$(logname 2>/dev/null || id -un 1000 2>/dev/null || echo "$USER")"
fi

USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -z "$USER_HOME" ] && USER_HOME="/home/$TARGET_USER"

echo "[*] Configuring for user: $TARGET_USER (Home: $USER_HOME)"

# Copy storage engine
if [ -f "/usr/local/bin/soulstone-storage" ]; then
    echo "[+] /usr/local/bin/soulstone-storage is already installed."
else
    echo "[*] Fetching latest soulstone-storage engine from GitHub..."
    curl -fsSL https://raw.githubusercontent.com/ImNotMrReaper/soulstone-forge/main/templates/soulstone-storage.sh -o /usr/local/bin/soulstone-storage
    chmod 755 /usr/local/bin/soulstone-storage
fi

# Install udev rules
cat << 'EOF' > /etc/udev/rules.d/99-soulstone.rules
# Soul Stone Dynamic Udev Rules
SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="SOUL_BOOT", ENV{UDISKS_IGNORE}="1"
ACTION=="add|change", SUBSYSTEM=="block", ENV{DM_NAME}=="soulstone_crypt", TAG+="systemd", ENV{SYSTEMD_WANTS}+="soulstone-storage.service"
ACTION=="add|change", SUBSYSTEM=="block", ENV{ID_FS_UUID}=="18ceeb84-5abf-4456-88a2-d2f2fb2255f0", TAG+="systemd", ENV{SYSTEMD_WANTS}+="soulstone-storage.service"
ACTION=="remove", SUBSYSTEM=="block", ENV{DM_NAME}=="soulstone_crypt", RUN+="/usr/local/bin/soulstone-storage detach"
EOF

# Install systemd service
cat << 'EOF' > /etc/systemd/system/soulstone-storage.service
[Unit]
Description=Soul Stone Seamless Storage & Directory Mount Engine
After=local-fs.target
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/soulstone-storage attach
ExecStop=/usr/local/bin/soulstone-storage detach
TimeoutSec=120

[Install]
WantedBy=multi-user.target
EOF

udevadm control --reload-rules
systemctl daemon-reload
systemctl enable soulstone-storage.service

echo "[+] Successfully configured! Attaching live overlays now..."
/usr/local/bin/soulstone-storage attach

echo "=================================================================="
echo " [✓] Soul Stone is now fully operational on this Linux machine!"
echo "=================================================================="
