#!/usr/bin/env bash
# Deploy hardened Soul Stone scripts and restart daemon (run as root)
set -e
SRC="$(cd "$(dirname "$0")" && pwd)/src"
bash -n "$SRC/soulstone-storage.sh" "$SRC/soulstone-daemon.sh" "$SRC/soulstone-link.sh"
install -m 755 "$SRC/soulstone-storage.sh" /usr/local/bin/soulstone-storage
install -m 755 "$SRC/soulstone-daemon.sh"  /usr/local/bin/soulstone-daemon
install -m 755 "$SRC/soulstone-link.sh"    /usr/local/bin/soulstone-link
systemctl restart soulstone-daemon.service
echo "Soul Stone system binaries updated and daemon restarted successfully."
