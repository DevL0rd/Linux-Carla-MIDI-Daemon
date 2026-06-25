#!/usr/bin/env bash
# Linux-Carla-MIDI-DAEMON
# Auto-wires MIDI controllers AND audio outputs for Carla plugins ("samplers")
# on Linux/PipeWire, with per-plugin MIDI priority/failover and toggleable audio
# routes (e.g. headphones + a "Discord mic" injection).
#
# Event-driven via PipeWire's pw-mon (no polling). Requires: pw-link, pw-mon, jq.

set -uo pipefail

CONFIG="${CARLA_MIDI_DAEMON_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/carla-midi-daemon/config.json}"

log() { printf '%s carla-midi-daemon: %s\n' "$(date '+%H:%M:%S')" "$*"; }

for c in pw-link pw-mon jq; do
  command -v "$c" >/dev/null || { log "required command not found: $c"; exit 1; }
done
[ -r "$CONFIG" ] || { log "config not readable: $CONFIG"; exit 1; }
jq -e . "$CONFIG" >/dev/null 2>&1 || { log "config is not valid JSON: $CONFIG"; exit 1; }

# ── PipeWire helpers ───────────────────────────────────────────────────────
# Emit "ID<TAB>NAME" lines, stripping the trailing (capture)/(playback) tag.
# $1 = o (source/output ports) | i (sink/input ports)
_ports() {
  pw-link -I "-$1" 2>/dev/null \
    | sed -E 's/^[[:space:]]*([0-9]+)[[:space:]]+/\1\t/; s/ \((capture|playback)\)$//'
}
src_exact()  { _ports o | awk -F'\t' -v n="$1" '$2==n      { print $1; exit }'; }   # exact source
src_sub()    { _ports o | awk -F'\t' -v n="$1" 'index($2,n){ print $1; exit }'; }   # substring source
sink_exact() { _ports i | awk -F'\t' -v n="$1" '$2==n      { print $1; exit }'; }   # exact sink
# sink port whose node-name contains substring $1 and whose port is exactly $2
sink_match() { _ports i | awk -F'\t' -v t="$1" -v p="$2" 'index($2,t) && $2 ~ ("[:]" p "$") { print $1; exit }'; }

mklink() { [ -n "${1:-}" ] && [ -n "${2:-}" ] && pw-link    "$1" "$2" 2>/dev/null; return 0; }
rmlink() { [ -n "${1:-}" ] && [ -n "${2:-}" ] && pw-link -d "$1" "$2" 2>/dev/null; return 0; }

cfg() { jq -r "$1" "$CONFIG" 2>/dev/null; }   # read a value from the config

# ── core: bring the live graph in line with the config ─────────────────────
reconcile() {
  local n i plugin port target chosen dev sid
  n=$(cfg '(.samplers // []) | length'); [ -z "$n" ] && n=0
  for ((i = 0; i < n; i++)); do
    plugin=$(cfg ".samplers[$i].plugin")
    [ -z "$plugin" ] || [ "$plugin" = null ] && continue

    # ── MIDI: priority failover (exclusive) ──────────────────────────────
    port=$(cfg ".samplers[$i].midi.port // \"events-in\"")
    target=$(sink_exact "$plugin:$port")
    if [ -n "$target" ]; then
      chosen=""
      while IFS= read -r dev; do
        [ -z "$dev" ] && continue
        sid=$(src_sub "$dev")
        [ -z "$sid" ] && continue
        if [ -z "$chosen" ]; then chosen="$sid"; mklink "$sid" "$target"
        else rmlink "$sid" "$target"; fi
      done < <(cfg ".samplers[$i].midi.priority[]?")
      # auto_add: nothing listed is present -> grab any connected MIDI source
      if [ -z "$chosen" ] && [ "$(cfg ".samplers[$i].midi.auto_add // false")" = true ]; then
        local id name
        while IFS=$'\t' read -r id name; do
          case "$name" in *"Midi Through"*|"$plugin:"*) continue ;; esac
          mklink "$id" "$target"; break
        done < <(_ports o | awk -F'\t' 'tolower($2) ~ /midi/')
      fi
    fi

    # ── AUDIO: route sampler outputs to each destination (toggleable) ─────
    local -a sp dp
    mapfile -t sp < <(cfg ".samplers[$i].audio.source_ports[]?")
    [ "${#sp[@]}" -eq 0 ] && continue
    local rn j enabled rtarget k soid doid
    rn=$(cfg "(.samplers[$i].audio.routes // []) | length"); [ -z "$rn" ] && rn=0
    for ((j = 0; j < rn; j++)); do
      enabled=$(cfg ".samplers[$i].audio.routes[$j].enabled != false")   # default true; only explicit false disables
      rtarget=$(cfg ".samplers[$i].audio.routes[$j].target")
      [ -z "$rtarget" ] || [ "$rtarget" = null ] && continue
      mapfile -t dp < <(cfg ".samplers[$i].audio.routes[$j].ports[]?")
      for ((k = 0; k < ${#sp[@]} && k < ${#dp[@]}; k++)); do
        soid=$(src_exact "$plugin:${sp[$k]}")
        doid=$(sink_match "$rtarget" "${dp[$k]}")
        if [ "$enabled" = true ]; then mklink "$soid" "$doid"   # connect enabled route
        else rmlink "$soid" "$doid"; fi                          # disconnect disabled route
      done
    done
  done
}

# ── run: initial pass, then react to every graph change (debounced) ────────
log "starting; config=$CONFIG"
reconcile
pw-mon 2>/dev/null | while IFS= read -r _; do
  while IFS= read -r -t 0.4 _; do :; done       # coalesce hotplug event bursts
  reconcile
done
