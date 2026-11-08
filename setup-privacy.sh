#!/usr/bin/env bash
# Turn on Privacy in BlueZ, so that during pairing it sends the Echo its IRK and
# identity address like a phone does. Only needed once.
#
# Usage: sudo ./setup-privacy.sh          enable it
#        sudo ./setup-privacy.sh --undo   put main.conf back as it was
#
# Restarting bluetoothd drops every connected Bluetooth device for a few seconds.
set -euo pipefail

CONF=/etc/bluetooth/main.conf
BACKUP="$CONF.before-echo-privacy"

if [ "$(id -u)" -ne 0 ]; then
    echo "run it with sudo" >&2
    exit 1
fi

if [ "${1:-}" = "--undo" ]; then
    if [ ! -f "$BACKUP" ]; then
        echo "no backup at $BACKUP, nothing to undo" >&2
        exit 1
    fi
    mv "$BACKUP" "$CONF"
    systemctl restart bluetooth
    echo "main.conf restored, bluetooth restarted"
    exit 0
fi

if [ -f "$CONF" ] && grep -Eq '^[[:space:]]*Privacy[[:space:]]*=[[:space:]]*device[[:space:]]*$' "$CONF"; then
    echo "Privacy = device is already set"
    exit 0
fi

if [ ! -f "$CONF" ]; then
    printf '[General]\nPrivacy = device\n' > "$CONF"
    : > "$BACKUP"   # empty backup, so --undo leaves an empty file
else
    [ -f "$BACKUP" ] || cp -a "$CONF" "$BACKUP"
    if grep -Eq '^[[:space:]]*#?[[:space:]]*Privacy[[:space:]]*=' "$CONF"; then
        # The stock file has "#Privacy = off" under [General]; replace the first one.
        sed -i -E '0,/^[[:space:]]*#?[[:space:]]*Privacy[[:space:]]*=.*/s//Privacy = device/' "$CONF"
    else
        sed -i '/^\[General\]/a Privacy = device' "$CONF"
    fi
fi

systemctl restart bluetooth
sleep 2
if bluetoothctl mgmt.info 2>/dev/null | grep 'current settings:' | grep -qw privacy; then
    echo "Privacy is on. Backup of the old file: $BACKUP"
else
    echo "main.conf changed, but the controller doesn't report privacy yet; check 'bluetoothctl mgmt.info'" >&2
    exit 1
fi
