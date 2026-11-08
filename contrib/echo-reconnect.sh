#!/usr/bin/env bash
# Reconnect to a paired Echo whenever the link drops (Echo reboot, power cut,
# end of its pairing window). BlueZ gives up after a few attempts; this does not.
#
# Usage: echo-reconnect.sh AA:BB:CC:DD:EE:FF [interval-seconds]
set -u

MAC="${1:?usage: $0 <echo-bluetooth-address> [interval]}"
MAC="${MAC^^}"
INTERVAL="${2:-30}"

while true; do
    info=$(bluetoothctl info "$MAC" 2>/dev/null)
    if echo "$info" | grep -q 'Paired: yes' && ! echo "$info" | grep -q 'Connected: yes'; then
        bluetoothctl --timeout 15 connect "$MAC" >/dev/null 2>&1 || true
    fi
    sleep "$INTERVAL"
done
