#!/usr/bin/env bash
# Deploy hardened Soul Stone scripts and restart daemon
set -e
cp -f /home/mr-reaper/.local/share/soulstone-forge/src/soulstone-storage.sh /usr/local/bin/soulstone-storage
chmod 755 /usr/local/bin/soulstone-storage
cp -f /home/mr-reaper/.local/share/soulstone-forge/src/soulstone-daemon.sh /usr/local/bin/soulstone-daemon
chmod 755 /usr/local/bin/soulstone-daemon
systemctl restart soulstone-daemon.service
echo "Soul Stone system binaries updated and daemon restarted successfully."
