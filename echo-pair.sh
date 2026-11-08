#!/usr/bin/env bash
# Pair a Linux PC with an Amazon Echo so the Echo keeps the pairing.
#
# The Echo treats a new pairing as temporary and deletes it when its pairing mode
# ends. A phone gets kept because, during that window, it hands the Echo its LE
# identity over the classic link and the Echo then finds it over LE. To get the
# same from BlueZ, three things have to be true while pairing:
#
#   1. the PC advertises over LE                    (this script)
#   2. Privacy is on, so BlueZ sends its IRK        (setup-privacy.sh, once)
#   3. the PC is central on the classic link, since Linux only starts SMP over
#      BR/EDR from the central side                 (this script, needs sudo)
#
# The script stays in the foreground until the Echo's pairing window is over,
# then turns everything back off. Ctrl+C also cleans up.
#
# Usage: ./echo-pair.sh AA:BB:CC:DD:EE:FF
# Put the Echo in pairing mode first ("Alexa, pair Bluetooth").
set -euo pipefail

MAC="${1:-}"
HCI="${HCI:-hci0}"
WINDOW="${WINDOW:-420}"            # the pairing window is ~5 min; stay up a bit longer
SCAN_SECONDS="${SCAN_SECONDS:-60}"
SUDO="${SUDO:-sudo}"

if [[ ! "$MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
    echo "usage: $0 <echo-bluetooth-address>" >&2
    echo "find it with: bluetoothctl --timeout 20 scan on | grep -i echo" >&2
    exit 1
fi
MAC="${MAC^^}"

for cmd in bluetoothctl hciconfig; do
    if ! command -v "$cmd" >/dev/null; then
        echo "$cmd not found." >&2
        [ "$cmd" = hciconfig ] && echo "It comes with bluez (Debian/Ubuntu) or bluez-deprecated-tools (Arch, Fedora)." >&2
        exit 1
    fi
done

if ! bluetoothctl mgmt.info 2>/dev/null | grep 'current settings:' | grep -qw privacy; then
    echo "Privacy is off in BlueZ. Run 'sudo ./setup-privacy.sh' once, then try again." >&2
    exit 1
fi

bluetoothctl show | grep -q 'Powered: yes' || bluetoothctl power on >/dev/null

old_lm=$(hciconfig "$HCI" lm | sed -n 's/.*Link mode: *//p')
pids=()
cleanup() {
    for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
    if [[ "$old_lm" == *MASTER* || "$old_lm" == *CENTRAL* ]]; then
        $SUDO hciconfig "$HCI" lm accept,master || true
    else
        $SUDO hciconfig "$HCI" lm accept || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Ask to stay central on incoming connections too, so the Echo can't switch roles.
$SUDO hciconfig "$HCI" lm accept,master

# Start fresh: an old bond on the PC side makes the Echo reject the new one.
bluetoothctl remove "$MAC" >/dev/null 2>&1 || true

# bluetoothctl keeps the advertisement registered only while it runs.
bluetoothctl --timeout "$WINDOW" advertise on </dev/null >/dev/null 2>&1 &
pids+=($!)
sleep 2
if ! bluetoothctl show | grep -qE 'ActiveInstances: 0x0*[1-9]'; then
    echo "warning: LE advertising did not start; the Echo will probably drop the pairing" >&2
fi

# Discovery stays on for the whole window too. Every kept pairing in testing had it,
# so it stays until someone shows it isn't needed.
bluetoothctl --timeout "$WINDOW" scan on </dev/null >/dev/null 2>&1 &
pids+=($!)
start=$SECONDS

echo "looking for $MAC (is the Echo in pairing mode?)"
found=0
for _ in $(seq 1 "$SCAN_SECONDS"); do
    if bluetoothctl devices | grep -q "$MAC"; then found=1; break; fi
    sleep 1
done
if [ "$found" -eq 0 ]; then
    echo "not found. Say \"Alexa, pair Bluetooth\" and run this again." >&2
    exit 1
fi

bluetoothctl trust "$MAC" >/dev/null
# Read the whole output first: grep -q would close the pipe early and,
# with pipefail, report a successful pairing as a failure.
pair_out=$(bluetoothctl --timeout 25 pair "$MAC" 2>&1 || true)
if ! grep -q 'Pairing successful' <<<"$pair_out" && ! bluetoothctl info "$MAC" | grep -q 'Paired: yes'; then
    echo "pairing failed:" >&2
    grep -E 'Failed|Error' <<<"$pair_out" >&2 || true
    exit 1
fi
sleep 3
conn_out=$(bluetoothctl --timeout 15 connect "$MAC" 2>&1 || true)
grep -E 'Connection successful|Failed' <<<"$conn_out" || true

echo "paired. Keep this running until the Echo's pairing window is over (about $((WINDOW / 60)) min)."
while (( SECONDS - start < WINDOW )); do
    sleep 20
    if ! bluetoothctl info "$MAC" | grep -q 'Connected: yes'; then
        bluetoothctl --timeout 15 connect "$MAC" >/dev/null 2>&1 || true
    fi
done

# The PC side keeps its bond either way. Whether the Echo kept it shows up as
# whether it still accepts the connection.
bluetoothctl info "$MAC" | grep -q 'Connected: yes' || bluetoothctl --timeout 15 connect "$MAC" >/dev/null 2>&1 || true
if bluetoothctl info "$MAC" | grep -q 'Connected: yes'; then
    echo "done. The Echo is still connected after its pairing window, so it kept the PC."
else
    echo "not connected after the window. If 'bluetoothctl connect $MAC' keeps failing," >&2
    echo "the Echo dropped the pairing; see the README." >&2
    exit 1
fi
