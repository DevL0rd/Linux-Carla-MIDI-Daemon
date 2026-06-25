#!/usr/bin/env bash
# Linux-Carla-MIDI-DAEMON
# Auto-wires MIDI controllers to Carla plugins ("samplers") with priority
# failover. Each sampler keeps its own independent priority list; the highest
# priority controller that is currently connected drives the plugin, and the
# daemon switches automatically when devices connect or disconnect.
#
# Event-driven via PipeWire's pw-mon (no polling). Requires: pw-link, pw-mon.

set -uo pipefail

CONFIG="${CARLA_MIDI_DAEMON_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/carla-midi-daemon/devices.conf}"

log() { printf '%s carla-midi-daemon: %s\n' "$(date '+%H:%M:%S')" "$*"; }

command -v pw-link >/dev/null || { log "pw-link not found (install pipewire)"; exit 1; }
command -v pw-mon  >/dev/null || { log "pw-mon not found (install pipewire)";  exit 1; }
[ -r "$CONFIG" ] || { log "config not readable: $CONFIG"; exit 1; }

# ── config parsing ─────────────────────────────────────────────────────────
list_samplers() {
  awk -F']' '/^\[sampler:/ { s=$1; sub(/^\[sampler:/,"",s); gsub(/^[ \t]+|[ \t]+$/,"",s); if (s!="") print s }' "$CONFIG"
}
_section_val() {  # $1=sampler  $2=key  -> value (first match within the block)
  awk -v want="$1" -v key="$2" '
    /^\[sampler:/ { cur=$0; sub(/^\[sampler:/,"",cur); sub(/\].*/,"",cur); gsub(/^[ \t]+|[ \t]+$/,"",cur); next }
    cur==want && $0 ~ "^[ \t]*" key "[ \t]*=" {
      sub(/^[^=]*=[ \t]*/,""); sub(/[ \t]+$/,""); print; exit
    }
  ' "$CONFIG"
}
sampler_port()    { local p; p=$(_section_val "$1" port); printf '%s' "${p:-events-in}"; }
sampler_autoadd() { case "$(_section_val "$1" auto_add | tr '[:upper:]' '[:lower:]')" in yes|true|1) echo 1;; *) echo 0;; esac; }
sampler_devices() {  # priority-ordered device patterns for sampler $1
  awk -v want="$1" '
    /^\[sampler:/ { cur=$0; sub(/^\[sampler:/,"",cur); sub(/\].*/,"",cur); gsub(/^[ \t]+|[ \t]+$/,"",cur); next }
    cur==want && $0 ~ /^[ \t]*priority[0-9]+[ \t]*=/ {
      n=$0; sub(/^[ \t]*priority/,"",n); sub(/[ \t]*=.*/,"",n)
      v=$0; sub(/^[^=]*=[ \t]*/,"",v); sub(/[ \t]+$/,"",v)
      printf "%05d\t%s\n", n+0, v
    }
  ' "$CONFIG" | sort -n | cut -f2-
}

# ── PipeWire helpers ───────────────────────────────────────────────────────
# Emit "ID<TAB>NAME" lines, stripping the trailing (capture)/(playback) tag.
# $1 = o (source ports) | i (sink ports)
_ports() {
  pw-link -I "-$1" 2>/dev/null \
    | sed -E 's/^[[:space:]]*([0-9]+)[[:space:]]+/\1\t/; s/ \((capture|playback)\)$//'
}
sink_id() { _ports i | awk -F'\t' -v n="$1" '$2==n     { print $1; exit }'; }  # exact
src_id()  { _ports o | awk -F'\t' -v n="$1" 'index($2,n){ print $1; exit }'; }  # substring

mklink() { [ -n "${1:-}" ] && [ -n "${2:-}" ] && pw-link    "$1" "$2" 2>/dev/null; return 0; }
rmlink() { [ -n "${1:-}" ] && [ -n "${2:-}" ] && pw-link -d "$1" "$2" 2>/dev/null; return 0; }

# ── core: bring the live graph in line with the config ─────────────────────
reconcile() {
  local s port target chosen dev sid id name
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    port=$(sampler_port "$s")
    target=$(sink_id "$s:$port")
    [ -z "$target" ] && continue                 # plugin not loaded yet — skip

    chosen=""
    # configured devices, priority order: keep the top available, drop the rest
    while IFS= read -r dev; do
      [ -z "$dev" ] && continue
      sid=$(src_id "$dev")
      [ -z "$sid" ] && continue
      if [ -z "$chosen" ]; then chosen="$sid"; mklink "$sid" "$target"
      else rmlink "$sid" "$target"; fi
    done < <(sampler_devices "$s")

    # auto_add: nothing configured is present -> grab any connected MIDI source
    if [ -z "$chosen" ] && [ "$(sampler_autoadd "$s")" = 1 ]; then
      while IFS=$'\t' read -r id name; do
        case "$name" in
          *"Midi Through"*|"$s:"*) continue ;;   # skip loopback and own ports
        esac
        mklink "$id" "$target"; chosen="$name"; break
      done < <(_ports o | grep -iE 'midi')
    fi
  done < <(list_samplers)
}

# ── run: initial pass, then react to every graph change (debounced) ────────
log "starting; config=$CONFIG"
reconcile
pw-mon 2>/dev/null | while IFS= read -r _; do
  while IFS= read -r -t 0.4 _; do :; done       # coalesce hotplug event bursts
  reconcile
done
