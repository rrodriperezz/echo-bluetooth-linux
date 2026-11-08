# Amazon Echo drops a Linux PC about 5 minutes after pairing

If you use an Amazon Echo as a Bluetooth speaker for a Linux machine, you may have seen this:

- Pairing works, audio plays, Alexa says "Connected to <your PC>".
- About five minutes later the audio stops.
- After that the Echo refuses the PC. `bluetoothctl connect` fails, btmon shows
  `Connection Rejected due to Unacceptable BD_ADDR (0x0f)`, and the PC is gone from
  the Echo's device list in the Alexa app.
- Pairing again only buys you another five minutes.

Phones paired with the same Echo stay paired. Changing the BlueZ version doesn't help.

## Cause

The Echo treats every new pairing as temporary and deletes it when its pairing mode
ends, roughly 5 minutes after "Alexa, pair Bluetooth". The pairing time doesn't matter:
pair at 25 s or at 200 s and it's gone at about 290 s either way.

A phone survives because of what happens right after the classic pairing:

1. The phone is advertising over Bluetooth LE (Android and iOS do this on their own).
2. The phone runs cross-transport key derivation (CTKD) over the classic link and sends
   the Echo its IRK and identity address.
3. A few seconds later the Echo connects to the phone over LE, as central, resolving the
   phone's private address with that IRK, and reads its GATT database.

After that the Echo keeps the phone. A stock BlueZ setup does none of this:

- It doesn't advertise unless an application asks for it.
- It only sends its IRK and identity address when `Privacy` is enabled in `main.conf`.
  Without it, the key distribution is `EncKey Sign`, without `IdKey`.
- The Linux kernel only starts SMP over BR/EDR (the CTKD step) when it is central on the
  classic link. The Echo usually asks for a role switch and BlueZ accepts, so the PC
  ends up peripheral and CTKD never runs.

So the Echo never learns who the PC is on LE, never finds it, and drops it when the
window closes. The audio link itself is plain classic Bluetooth (A2DP). The LE side only
matters during pairing.

## Fix

You need all three: LE advertising, `Privacy = device`, and the PC staying central while
it pairs.

Once:

```bash
sudo ./setup-privacy.sh        # adds "Privacy = device" to /etc/bluetooth/main.conf
```

It keeps a backup and `sudo ./setup-privacy.sh --undo` puts the file back. It restarts
bluetoothd, so your other Bluetooth devices drop for a few seconds.

Then, every time you pair an Echo:

```bash
# say "Alexa, pair Bluetooth" first
./echo-pair.sh AA:BB:CC:DD:EE:FF
```

The script:

- asks for sudo once, to run `hciconfig hci0 lm accept,master`;
- removes any old bond with the Echo;
- starts an LE advertisement and discovery;
- trusts, pairs and connects;
- stays in the foreground for 7 minutes, until the Echo's pairing window has closed;
- puts the link mode back and stops advertising.

`hciconfig` ships with `bluez` on Debian and Ubuntu. On Arch and Fedora it is in
`bluez-deprecated-tools`.

If you'd rather do it by hand:

```bash
sudo hciconfig hci0 lm accept,master
bluetoothctl --timeout 420 advertise on &
bluetoothctl --timeout 420 scan on &
# wait until the Echo shows up in "bluetoothctl devices"
bluetoothctl trust   AA:BB:CC:DD:EE:FF
bluetoothctl pair    AA:BB:CC:DD:EE:FF
bluetoothctl connect AA:BB:CC:DD:EE:FF
# wait until the Echo's pairing mode is over (~5 min), then
sudo hciconfig hci0 lm accept
```

After that you don't need the advertisement or the link mode. The pairing then behaves like
a phone's: it stays.

If the Echo reboots or loses power, BlueZ tries to reconnect a few times and gives up.
`contrib/` has a small loop and a systemd user unit that keep retrying.

`Privacy = device` makes the PC use a random resolvable address on LE. My Bluetooth mouse
paired and worked fine with it on. If one of your devices doesn't, you can undo it after
pairing the Echo; the Echo keeps the pairing.

## How I found it

The setup was a desktop with a Realtek RTL8922AU (USB, BT 5.4), kernel 7.0, BlueZ 5.85
and PipeWire 1.6.2. I tested against two Echo Dots and an Echo Spot, which all behaved the
same way.

What I measured first:

- The deletion follows the pairing window, not the pairing time.
- It happened with audio streaming, with an idle link, and with no link at all (pair,
  disconnect after 2 s, never reconnect).
- There was no Bluetooth traffic at deletion time. The Echo just stopped knowing the PC.
- The Echo stayed discoverable after the PC paired. With a phone, it doesn't.
- If the PC asks for General Bonding (connecting A2DP without `pair`), the Echo answers
  "No Bonding". With Dedicated Bonding it accepts, but only until the window closes.

None of these changed anything; the PC was deleted at the end of the window every time:

| Change | Result |
|---|---|
| BlueZ 5.64 + PulseAudio, BlueZ 5.66, BlueZ 5.85 + PipeWire | deleted |
| Loading the Windows firmware for the same chip | deleted |
| Class of device set to phone (0x08020c) | deleted |
| DeviceID set to Microsoft, then to Apple | deleted |
| An AVRCP player that always reports PLAYING | deleted |
| Exposing a PBAP server and a MAP server like a phone | deleted (the Echo never connected to them) |
| PC discoverable during the whole window | deleted |
| Pairing without disconnecting afterwards | deleted |
| "Alexa, connect <PC name>" after pairing | deleted |

Then I borrowed an Android phone (Galaxy A23), turned on its HCI snoop log, paired it with
the same Echo and compared its capture with the PC's. The classic pairing was the same:
Echo `NoInputNoOutput` with Dedicated Bonding, Just Works, P-256 key. The differences are
the three steps in [Cause](#cause). In the phone's capture the CTKD initiator key
distribution is `EncKey IdKey Sign (0x07)`, and the Echo opens the LE connection about 7 s
after it.

Then I tried to make the PC do the same, one piece at a time. Every run started with the PC
removed from the Echo's list:

| Advertising + discovery | Privacy | PC central | Kept |
|---|---|---|---|
| no | no | no | 0 (every test before the phone capture, plus a control run) |
| yes | no | by chance | 2 of 6 |
| yes | no | forced | 0 of 1 (the Echo connected over LE, then the classic link dropped after 5 s) |
| yes | yes | no | 0 of 1 (no CTKD in the capture) |
| yes | yes | forced | **4 of 4** (the last one with `echo-pair.sh`) |

In the good runs the capture looks like the phone's: CTKD with `IdKey` both ways, and
the Echo connecting to the PC over LE as central. The Echo didn't even cut the audio when its
pairing mode ended.

The 2 of 6 is why advertising alone looked like the fix at first. In one of those two runs
the role switch failed, so the PC stayed central and CTKD ran anyway.

A pairing that the Echo kept played audio for half an hour without a drop. It also survived
the Echo rebooting and reconnected with the same link key.

## What I don't know

- What exactly the Echo checks. It could be the LE connection itself, resolving the IRK, or
  something it reads over GATT. Its firmware isn't public.
- Whether discovery has to stay on. Every kept pairing had it, so the script keeps it.
- The sample is small: 4 of 4 with the full recipe, all on one Echo Dot. The partial
  variants were tried once or a few times each.
- Since when the Echo behaves this way. Pairings made from Linux a year or two ago on the
  same Echos were never removed, which suggests a firmware change on Amazon's side.
- After about eight pairings in a row, the Echo sometimes stops entering pairing mode or
  empties its whole list. Unplugging it for a few seconds fixes that.

## Related reports

- [bluez/bluez#2671](https://github.com/bluez/bluez/issues/2671): Echo Dot "will self
  terminate the connection after a few moments and refuse to reconnect".

## License

MIT
