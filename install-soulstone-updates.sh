#!/usr/bin/env bash
# Deploy hardened Soul Stone scripts and restart daemon (run as root)
set -e
SRC="$(cd "$(dirname "$0")" && pwd)/src"
bash -n "$SRC/soulstone-storage.sh" "$SRC/soulstone-daemon.sh" "$SRC/soulstone-link.sh"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$SRC/nautilus/soulstone_extension.py"
install -m 755 "$SRC/soulstone-storage.sh" /usr/local/bin/soulstone-storage
install -m 755 "$SRC/soulstone-daemon.sh"  /usr/local/bin/soulstone-daemon
install -m 755 "$SRC/soulstone-link.sh"    /usr/local/bin/soulstone-link
systemctl restart soulstone-daemon.service

# Nautilus right-click menu: the extension is the ONLY provider of Link/Unlink.
# Legacy Nautilus scripts are removed, or every entry would appear twice.
U="${SUDO_USER:-$(id -un "${PKEXEC_UID:-1000}" 2>/dev/null)}"
H="$(getent passwd "$U" | cut -d: -f6)"
if [ -n "$U" ] && [ "$U" != root ] && [ -d "$H" ]; then
    EXT_DIR="$H/.local/share/nautilus-python/extensions"
    runuser -u "$U" -- mkdir -p "$EXT_DIR"
    runuser -u "$U" -- install -m 644 "$SRC/nautilus/soulstone_extension.py" "$EXT_DIR/soulstone_extension.py"
    rm -rf "$EXT_DIR/__pycache__"
    rm -f "$H/.local/share/nautilus/scripts/Link to Soul Stone" "$H/.local/share/nautilus/scripts/Unlink from Soul Stone"
    runuser -u "$U" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$U")/bus" nautilus -q 2>/dev/null || true
fi
echo "Soul Stone system binaries updated and daemon restarted successfully."
