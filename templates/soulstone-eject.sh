#!/usr/bin/env bash
# Soul Stone Graceful Eject Helper
set -e
if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "$@"
fi
/usr/local/bin/soulstone-storage eject
