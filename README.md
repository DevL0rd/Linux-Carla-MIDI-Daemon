# Linux-Carla-MIDI-DAEMON

A tiny background daemon that automatically wires your MIDI controllers **and
audio outputs** for [Carla](https://github.com/falkTX/Carla) plugins on
Linux/PipeWire — with **per-plugin MIDI priority/failover** and **toggleable
audio routes** (e.g. headphones + a "Discord mic" injection).

Manual patchbay connections in Carla are fragile: any time a device connects or
disconnects, PipeWire rebuilds its node graph and your hand-made links vanish.
This daemon watches the graph and re-asserts the right connections instantly, so
your rig "just works" no matter what gets plugged in or unplugged.

## What it does

- **MIDI priority/failover** — map several controllers to a Carla plugin (a
  *sampler*) in priority order. The highest-priority controller that is
  currently connected drives the plugin; the rest are disconnected so only one
  plays it. Unplug it and it falls back to the next; plug it back and it switches
  back — within a fraction of a second.
- **Audio routing** — route each plugin's audio outputs to one or more
  destinations. Each route has an `enabled` flag, so you can toggle, for example,
  a **Discord-mic** injection on and off.
- **auto_add** (optional) — if none of the listed MIDI devices are present, grab
  whatever controller is connected.
- **Event-driven** (PipeWire `pw-mon`) — sleeps until the graph changes, so it
  uses no CPU while idle. No polling.

## Requirements

- PipeWire with `pw-link` and `pw-mon`
- `jq`
- [Carla](https://github.com/falkTX/Carla) with at least one plugin loaded
- A user systemd session (runs as a `--user` service)

## Install

```bash
git clone https://github.com/DevL0rd/Linux-Carla-MIDI-DAEMON
cd Linux-Carla-MIDI-DAEMON
./install.sh
```

The installer is **idempotent** — re-run it any time. It:

- installs the daemon to `~/.local/bin/carla-midi-daemon`
- installs a user service to `~/.config/systemd/user/carla-midi-daemon.service`
- creates `~/.config/carla-midi-daemon/config.json` from the example **only if it
  doesn't already exist** (your edits are never overwritten)
- enables and (re)starts the service

## Configure

All configuration is **JSON**, at `~/.config/carla-midi-daemon/config.json`:

```json
{
  "samplers": [
    {
      "plugin": "BitsonicSampler",
      "midi": {
        "port": "events-in",
        "auto_add": false,
        "priority": ["USB func for MIDI", "CN29: Bluetooth"]
      },
      "audio": {
        "source_ports": ["output_1", "output_2"],
        "routes": [
          { "name": "headphones",  "enabled": true, "target": "ROG_DELTA_II",      "ports": ["playback_FL", "playback_FR"] },
          { "name": "discord_mic", "enabled": true, "target": "easyeffects_source", "ports": ["input_FL", "input_FR"] }
        ]
      }
    }
  ]
}
```

### Schema

| Field | Meaning |
|-------|---------|
| `samplers[]` | One entry per Carla plugin to manage. Each has its own independent settings. |
| `plugin` | The plugin's PipeWire node name as shown in Carla, e.g. `BitsonicSampler`. |
| `midi.port` | The plugin's MIDI input port. Default: `events-in`. |
| `midi.priority[]` | MIDI devices, **ordered** — first = highest priority, rest are fallbacks. |
| `midi.auto_add` | `true` to grab any connected MIDI device when none of the listed ones are present. |
| `audio.source_ports[]` | The plugin's audio output ports, e.g. `["output_1","output_2"]` (L, R). |
| `audio.routes[]` | Audio destinations. Each is connected when `enabled`, disconnected when not. |
| `route.name` | Free label (for your reference). |
| `route.enabled` | `true`/`false` — flip a route on or off (e.g. the Discord-mic send). |
| `route.target` | Destination node name (substring match). |
| `route.ports[]` | Destination input ports, paired with `source_ports` by position (L, R). |

**Name matching:** MIDI devices and audio `target`s are matched as a **substring**
of the PipeWire port/node name, so a recognizable fragment is enough. List names with:

```bash
pw-link -o | grep -i midi    # MIDI sources (controllers)
pw-link -i                   # audio sinks / capture inputs (route targets)
```

### The "Discord mic" route

`target: "easyeffects_source"` injects the plugin's audio into the microphone
source apps record from, so it's transmitted over a call. Flip `enabled` to
`false` (then restart) to stop sending it. Targets vary by setup — yours may be a
loopback/null sink or a different processed source; use `pw-link -i` to find it.

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

For each sampler, the daemon resolves the plugin's MIDI input port and walks the
priority list — connecting the first device that exists and disconnecting the
others. For audio, it links each enabled route's destination and unlinks disabled
ones. It does this on startup and on every PipeWire graph change; event bursts
from a single hotplug are coalesced so it reconciles once.

## License

Released into the public domain — do whatever you like with it.
