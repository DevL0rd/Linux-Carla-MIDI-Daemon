# Linux-Carla-MIDI-Daemon

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
- **Mic mix (no virtual device)** — while a Carla plugin is loaded, mix its
  audio into your microphone by linking the plugin output into whatever app is
  capturing the **current default source**. The default mic is never changed and
  no device appears/disappears, so apps that own the default (e.g. WiVRn) keep
  working. Links are removed when the plugin closes or the daemon stops.
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
git clone https://github.com/DevL0rd/Linux-Carla-MIDI-Daemon
cd Linux-Carla-MIDI-Daemon
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
  "mic_mix": {
    "enabled": true,
    "present_with": "BitsonicSampler",
    "mix_samplers": ["BitsonicSampler"]
  },
  "auto_launch": {
    "enabled": true,
    "command": "carla $HOME/.config/carla-midi-daemon/BitsonicSampler.carxp",
    "process": "carla",
    "when_connected": ["USB func for MIDI", "CN29: Bluetooth"]
  }
}
```

**Name matching:** MIDI devices and audio `target`s are matched as a **substring**
of the PipeWire port/node name, so a recognizable fragment is enough. List names
with:

```bash
pw-link -o | grep -i midi     # MIDI controllers
pw-link -i                    # audio sinks / route targets
pactl get-default-source      # the mic the mix follows
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

### `mic_mix`

Mixes plugin audio into your microphone **without a virtual device**. While the
gating plugin is loaded, the daemon links each sampler's stereo output into
whatever apps are currently capturing the **default source** (`pactl
get-default-source`), so those apps hear mic + Carla. The default mic is never
changed and nothing appears/disappears, so apps that own the default (e.g.
WiVRn) are unaffected. Links are reconciled each pass and removed when the
plugin closes, the default changes, or the daemon stops.

Because it follows the *default* source, a mono mic fans both Carla channels
into a mono consumer; a stereo consumer gets L/R by position. An app capturing a
specific non-default device only receives the mix if that device is downstream
of the default (e.g. via EasyEffects pointed at the default mic).

| Field | Meaning |
|-------|---------|
| `enabled` | Turn the feature on/off. |
| `present_with` | Node whose presence gates the mix (your plugin) — its appearance/disappearance = Carla open/close. |
| `mix_samplers[]` | Plugins whose stereo outputs (`output_1`/`output_2`) are mixed in. |

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

A starter Carla project, **`BitsonicSampler.carxp`**, is bundled and installed to
`~/.config/carla-midi-daemon/`; the default `command` opens it. It contains only
the plugin (and its preset) — no patchbay connections, because the daemon makes
all the connections itself once the plugin loads. Save over that file from Carla
to customize what auto-launch opens (the installer won't overwrite it).

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

The daemon removes its mic-mix links on shutdown, so nothing is left dangling.

## License

Released into the public domain — do whatever you like with it.
