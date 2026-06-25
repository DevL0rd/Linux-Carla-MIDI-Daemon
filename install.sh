#!/usr/bin/env bash
# Idempotent installer for Linux-Carla-MIDI-DAEMON.
# Safe to re-run: it refreshes the binary/service and never clobbers your config.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN="$HOME/.local/bin/carla-midi-daemon"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/carla-midi-daemon"
CFG="$CFG_DIR/devices.conf"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="$UNIT_DIR/carla-midi-daemon.service"

echo ">> Installing Linux-Carla-MIDI-DAEMON"

command -v pw-link >/dev/null || { echo "!! pw-link not found — install pipewire"; exit 1; }
command -v pw-mon  >/dev/null || { echo "!! pw-mon not found — install pipewire";  exit 1; }

install -Dm755 "$SRC/carla-midi-daemon.sh" "$BIN"
echo "   daemon   -> $BIN"

if [ -e "$CFG" ]; then
  echo "   config   -> $CFG (kept existing)"
else
  install -Dm644 "$SRC/devices.conf.example" "$CFG"
  echo "   config   -> $CFG (new — created from example)"
fi

install -Dm644 "$SRC/carla-midi-daemon.service" "$UNIT"
echo "   service  -> $UNIT"

systemctl --user daemon-reload
systemctl --user enable carla-midi-daemon.service >/dev/null
systemctl --user restart carla-midi-daemon.service   # (re)start, picking up changes

echo ">> Done."
echo "   Edit devices:  $CFG"
echo "   Apply edits:   systemctl --user restart carla-midi-daemon"
echo "   Live logs:     journalctl --user -u carla-midi-daemon -f"
