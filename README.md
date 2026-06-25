# Linux-Carla-MIDI-DAEMON

A tiny background daemon that automatically wires your MIDI controllers **and
audio** for [Carla](https://github.com/falkTX/Carla) plugins on Linux/PipeWire.

Manual patchbay connections in Carla are fragile: any time a device connects or
disconnects, PipeWire rebuilds its node graph and your hand-made links vanish.
This daemon watches the graph and re-asserts the right connections instantly, so
your rig "just works" no matter what gets plugged in or unplugged.

## Features

- **MIDI priority/failover** — map several controllers to a Carla plugin (a
  *sampler*) in priority order. The highest-priority connected controller drives
  it; unplug it and it falls back to the next, plug it back and it switches back.
- **Audio routing** — route each plugin's outputs to one or more destinations,
  each with an `enabled` toggle.
- **Virtual microphone** — create a mic (e.g. `Carla-Mic`) that mixes plugin
  audio with your real mic, set it as the active input, and tie it to Carla's
  lifecycle: it appears when a plugin loads and **vanishes when Carla closes**.
- **Auto-launch Carla** — open Carla automatically when a controller is plugged
  in.
- **auto_add** (optional) — grab any connected MIDI device when none of the
  listed ones are present.
- **Event-driven** — wakes only on real Node/Port/Device changes (filtered from
  PipeWire's firehose in C); ~0% CPU at idle. No polling.

## Requirements

- PipeWire with `pw-link` and `pw-mon`
- `jq`
- `pactl` (only for the virtual-microphone feature; from `pipewire-pulse`)
- [Carla](https://github.com/falkTX/Carla)
- A user systemd session (runs as a `--user` service)

## Install

```bash
git clone https://github.com/DevL0rd/Linux-Carla-MIDI-DAEMON
cd Linux-Carla-MIDI-DAEMON
./install.sh
```

The installer is **idempotent**. It installs the daemon to
`~/.local/bin/carla-midi-daemon`, a user service to
`~/.config/systemd/user/carla-midi-daemon.service`, creates
`~/.config/carla-midi-daemon/config.json` from the example **only if absent**
(your edits are never overwritten), and enables + (re)starts the service.

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
          { "name": "headphones", "enabled": true, "target": "ROG_DELTA_II", "ports": ["playback_FL", "playback_FR"] }
        ]
      }
    }
  ],
  "virtual_mic": {
    "enabled": true,
    "name": "Carla-Mic",
    "description": "Carla Piano + Voice",
    "set_default": true,
    "present_with": "BitsonicSampler",
    "mix_samplers": ["BitsonicSampler"],
    "mix_sources": ["mono-fallback"]
  },
  "auto_launch": {
    "enabled": true,
    "command": "carla",
    "process": "carla",
    "when_connected": ["USB func for MIDI", "CN29: Bluetooth"]
  }
}
```

**Name matching:** MIDI devices, audio `target`s and `mix_sources` are matched as
a **substring** of the PipeWire port/node name, so a recognizable fragment is
enough. List names with:

```bash
pw-link -o | grep -i midi     # MIDI controllers
pw-link -i                    # audio sinks / route targets
pactl list short sources      # capture sources (your mic)
```

### `samplers[]`

| Field | Meaning |
|-------|---------|
| `plugin` | Plugin's PipeWire node name as shown in Carla (e.g. `BitsonicSampler`). |
| `midi.port` | Plugin's MIDI input port. Default `events-in`. |
| `midi.priority[]` | MIDI devices, ordered — first = highest priority. |
| `midi.auto_add` | `true` to grab any MIDI device when none listed are present. |
| `audio.source_ports[]` | Plugin output ports, e.g. `["output_1","output_2"]` (L, R). |
| `audio.routes[]` | Destinations; connected when `enabled` (default true), disconnected when `false`. |
| `route.target` / `route.ports[]` | Destination node (substring) and its input ports, paired with `source_ports` by position. |

### `virtual_mic`

Creates a virtual input device that exists **only while Carla has the plugin
loaded** — created when it appears, removed when Carla closes (an external audio
manager is expected to restore your previous default mic).

| Field | Meaning |
|-------|---------|
| `enabled` | Turn the feature on/off. |
| `name` / `description` | Node name and friendly description of the virtual mic. |
| `set_default` | `true` to make it the active (default) input while present. |
| `present_with` | Node whose presence gates it (your plugin) — its appearance/disappearance = Carla open/close. |
| `mix_samplers[]` | Plugins whose stereo outputs are mixed in. |
| `mix_sources[]` | Capture sources mixed in (your mic). Mono sources fan to both channels; stereo map L/R. |

### `auto_launch`

Opens Carla when a controller is plugged in. **Edge-triggered**: fires only on an
absent→present transition, so closing Carla while the controller stays plugged
won't relaunch it. Skipped if `process` is already running.

| Field | Meaning |
|-------|---------|
| `enabled` | On by default. |
| `command` | What to run (e.g. `carla`, or `carla /path/to/project.carxp`). |
| `process` | Process name checked with `pgrep -x` to avoid double launches. |
| `when_connected[]` | MIDI device substrings that trigger the launch. |

Apply config changes with:

```bash
systemctl --user restart carla-midi-daemon
```

## Manage

```bash
systemctl --user status  carla-midi-daemon
journalctl --user -u carla-midi-daemon -f
systemctl --user restart carla-midi-daemon
```

## Uninstall

```bash
./uninstall.sh            # remove daemon + service, keep config
./uninstall.sh --purge    # also delete ~/.config/carla-midi-daemon
```

The daemon removes its virtual mic on shutdown, so nothing is left dangling.

## License

Released into the public domain — do whatever you like with it.
