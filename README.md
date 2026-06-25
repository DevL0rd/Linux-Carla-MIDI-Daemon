# Linux-Carla-MIDI-DAEMON

A tiny background daemon that automatically wires your MIDI controllers to
[Carla](https://github.com/falkTX/Carla) plugins on Linux/PipeWire — with
**per-plugin priority and automatic failover**.

Manual patchbay connections in Carla are fragile: any time a device connects or
disconnects, PipeWire rebuilds its node graph and your hand-made links vanish.
This daemon watches the graph and re-asserts the right connections instantly, so
your keyboard "just works" no matter what gets plugged in or unplugged.

## What it does

- Maps one or more MIDI controllers to a Carla plugin (a **sampler**).
- Each sampler has its **own independent priority list**. The highest-priority
  controller that is currently connected drives that plugin; the rest are left
  disconnected so only one keyboard plays it at a time.
- **Automatic failover:** unplug the primary controller and it falls back to the
  next one; plug it back in and it switches back — within a fraction of a second.
- Optional **auto-add**: if none of the listed devices are present, grab whatever
  MIDI controller is connected.
- **Event-driven** (via PipeWire's `pw-mon`) — it sleeps until the graph changes,
  so it uses no CPU while idle. No polling.

## Requirements

- PipeWire with `pw-link` and `pw-mon` (standard on modern PipeWire installs)
- [Carla](https://github.com/falkTX/Carla) with at least one plugin loaded
- A user systemd session (the daemon runs as a `--user` service)

## Install

```bash
git clone https://github.com/DevL0rd/Linux-Carla-MIDI-DAEMON
cd Linux-Carla-MIDI-DAEMON
./install.sh
```

The installer is **idempotent** — run it as many times as you like. It:

- installs the daemon to `~/.local/bin/carla-midi-daemon`
- installs a user service to `~/.config/systemd/user/carla-midi-daemon.service`
- creates `~/.config/carla-midi-daemon/devices.conf` from the example **only if it
  doesn't already exist** (your edits are never overwritten)
- enables and (re)starts the service

## Configure

Edit `~/.config/carla-midi-daemon/devices.conf`:

```ini
[sampler:BitsonicSampler]
port      = events-in
priority1 = USB func for MIDI
priority2 = CN29: Bluetooth
auto_add  = no
```

| Key         | Meaning                                                                   |
|-------------|---------------------------------------------------------------------------|
| `port`      | The plugin's MIDI input port. Default: `events-in`.                       |
| `priorityN` | A device, `N = 1` highest. Lower-priority entries are fallbacks.          |
| `auto_add`  | `yes` to grab any connected MIDI device when no listed device is present. |

- `[sampler:NAME]` — `NAME` is the plugin's PipeWire node name as shown in Carla
  (e.g. `BitsonicSampler`). Add more `[sampler:…]` blocks for more plugins; each
  keeps its own priorities.
- **Device names** are matched as a **substring** of the PipeWire source-port
  name, so you only need a recognizable fragment. List what's available with:

  ```bash
  pw-link -o | grep -i midi
  ```

Apply changes after editing:

```bash
systemctl --user restart carla-midi-daemon
```

## Manage

```bash
systemctl --user status  carla-midi-daemon     # state
journalctl --user -u carla-midi-daemon -f      # live logs
systemctl --user restart carla-midi-daemon     # reload config
```

## Uninstall

```bash
./uninstall.sh            # remove daemon + service, keep your config
./uninstall.sh --purge    # also delete ~/.config/carla-midi-daemon
```

## How it works

The daemon resolves each `[sampler:NAME]` to that plugin's MIDI input port
(`NAME:port`). On startup, and on every PipeWire graph change, it walks the
priority list, connects the first device that exists, and disconnects any others
pointing at the same plugin. If nothing matches and `auto_add` is on, it links
the first available MIDI source (ignoring `Midi Through` and the plugin's own
ports). Event bursts from a single hotplug are coalesced so it reconciles once.

## License

Released into the public domain — do whatever you like with it.
