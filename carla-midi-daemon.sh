#!/usr/bin/env bash
# Linux-Carla-MIDI-Daemon
# Auto-wires MIDI controllers AND audio outputs for Carla plugins ("samplers")
# on Linux/PipeWire, with per-plugin MIDI priority/failover and toggleable audio
# routes. Optionally manages a virtual microphone that exists only while a Carla
# plugin is loaded (created on open, removed on close) and mixes plugin audio
# with your real mic.
#
# Event-driven via PipeWire's pw-mon (no polling). Requires: pw-link, pw-mon, jq.
# Virtual-mic feature additionally needs: pactl.

set -uo pipefail

CONFIG="${CARLA_MIDI_DAEMON_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/carla-midi-daemon/config.json}"

log() { printf '%s carla-midi-daemon: %s\n' "$(date '+%H:%M:%S')" "$*"; }

for c in pw-link pw-mon jq; do
  command -v "$c" >/dev/null || { log "required command not found: $c"; exit 1; }
done
[ -r "$CONFIG" ] || { log "config not readable: $CONFIG"; exit 1; }
jq -e . "$CONFIG" >/dev/null 2>&1 || { log "config is not valid JSON: $CONFIG"; exit 1; }

cfg() { jq -r "$1" "$CONFIG" 2>/dev/null; }   # read a value from the config

declare -A AL_SEEN          # trigger devices seen on the previous pass
AL_LAST_LAUNCH=-1000        # SECONDS at last launch (debounce)

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
# true (exit 0) if any port belongs to a node named exactly $1
node_exists() { { _ports o; _ports i; } | awk -F'\t' -v n="$1:" 'index($2,n)==1 { f=1 } END { exit f?0:1 }'; }

mklink() { [ -n "${1:-}" ] && [ -n "${2:-}" ] && pw-link    "$1" "$2" 2>/dev/null; return 0; }
rmlink() { [ -n "${1:-}" ] && [ -n "${2:-}" ] && pw-link -d "$1" "$2" 2>/dev/null; return 0; }

# module id of our null-sink for the virtual source named $1 (empty if none)
mic_module_id() { pactl list short modules 2>/dev/null | awk -v n="sink_name=$1 " 'index($0,n){print $1; exit}'; }

# ── virtual microphone: present only while a gating Carla plugin is loaded ──
manage_virtual_mic() {
  [ "$(cfg '.virtual_mic.enabled // false')" = true ] || return 0
  command -v pactl >/dev/null || { log "virtual_mic needs pactl (pipewire-pulse) — skipping"; return 0; }

  local name desc gate setdef gate_present mic_present mid s src
  name=$(cfg '.virtual_mic.name'); [ -z "$name" ] || [ "$name" = null ] && return 0
  desc=$(cfg ".virtual_mic.description // \"$name\"")
  gate=$(cfg '.virtual_mic.present_with // ""')
  setdef=$(cfg '.virtual_mic.set_default // false')

  if [ -n "$gate" ]; then node_exists "$gate"; gate_present=$?; else gate_present=0; fi
  node_exists "$name"; mic_present=$?

  if [ "$gate_present" -eq 0 ]; then
    # Carla is open -> make sure the virtual mic exists
    if [ "$mic_present" -ne 0 ]; then
      log "Carla open -> creating virtual mic '$name'"
      pactl load-module module-null-sink \
        media.class=Audio/Source/Virtual \
        sink_name="$name" channel_map=front-left,front-right \
        sink_properties="device.description=$desc" >/dev/null 2>&1
      [ "$setdef" = true ] && pactl set-default-source "$name" 2>/dev/null
      # ports may not be ready this tick; the resulting node-add re-triggers reconcile
    fi
    if node_exists "$name"; then
      # mix configured sampler outputs into the mic (stereo, by position)
      while IFS= read -r s; do
        [ -z "$s" ] && continue
        mklink "$(src_exact "$s:output_1")" "$(sink_match "$name" input_FL)"
        mklink "$(src_exact "$s:output_2")" "$(sink_match "$name" input_FR)"
      done < <(cfg '.virtual_mic.mix_samplers[]?')
      # mix configured capture sources (e.g. your mic) into the virtual mic.
      # Auto-detects the source's ports: mono -> both channels, stereo -> L/R.
      local fl fr; fl=$(sink_match "$name" input_FL); fr=$(sink_match "$name" input_FR)
      local -a vp
      while IFS= read -r src; do
        [ -z "$src" ] && continue
        mapfile -t vp < <(_ports o | awk -F'\t' -v t="$src" 'index($2,t){print $1}')
        if   [ "${#vp[@]}" -ge 2 ]; then mklink "${vp[0]}" "$fl"; mklink "${vp[1]}" "$fr"
        elif [ "${#vp[@]}" -eq 1 ]; then mklink "${vp[0]}" "$fl"; mklink "${vp[0]}" "$fr"
        fi
      done < <(cfg '.virtual_mic.mix_sources[]?')
    fi
  else
    # Carla is closed -> remove the virtual mic so it vanishes from the system.
    # (An external audio manager is expected to restore the previous default.)
    if [ "$mic_present" -eq 0 ]; then
      mid=$(mic_module_id "$name")
      [ -n "$mid" ] && { log "Carla closed -> removing virtual mic '$name'"; pactl unload-module "$mid" 2>/dev/null; }
    fi
  fi
}

# ── auto-launch: open Carla when a trigger MIDI controller connects ────────
# Edge-triggered: fires only when a device goes absent -> present (so closing
# Carla while the controller stays plugged won't relaunch it), and only if the
# target process isn't already running.
auto_launch() {
  [ "$(cfg '.auto_launch.enabled // false')" = true ] || return 0
  local dev proc cmd newly=0
  while IFS= read -r dev; do
    [ -z "$dev" ] && continue
    if [ -n "$(src_sub "$dev")" ]; then
      [ "${AL_SEEN[$dev]:-0}" = 1 ] || newly=1
      AL_SEEN[$dev]=1
    else
      AL_SEEN[$dev]=0
    fi
  done < <(cfg '.auto_launch.when_connected[]?')
  [ "$newly" -eq 1 ] || return 0

  proc=$(cfg '.auto_launch.process // "carla"')
  pgrep -x "$proc" >/dev/null 2>&1 && return 0           # already running
  [ $((SECONDS - AL_LAST_LAUNCH)) -lt 15 ] && return 0   # debounce relaunch
  AL_LAST_LAUNCH=$SECONDS
  cmd=$(cfg '.auto_launch.command // "carla"')
  log "MIDI controller connected and '$proc' not running -> launching: $cmd"
  setsid sh -c "$cmd" >/dev/null 2>&1 </dev/null &
}

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

  auto_launch
  manage_virtual_mic
}

# ── lifecycle: tidy up the virtual mic when the daemon stops ───────────────
cleanup() {
  if [ "$(cfg '.virtual_mic.enabled // false')" = true ] && command -v pactl >/dev/null; then
    local name mid
    name=$(cfg '.virtual_mic.name')
    [ -n "$name" ] && [ "$name" != null ] && { mid=$(mic_module_id "$name"); [ -n "$mid" ] && pactl unload-module "$mid" 2>/dev/null; }
  fi
}
trap cleanup EXIT INT TERM

# ── run: initial pass, then react to graph changes (debounced) ─────────────
# pw-mon emits thousands of param-update lines per second, and every pw-link the
# daemon runs registers a short-lived Client — reacting to those would spin the
# CPU and self-trigger forever. So in C (awk) we wake the shell ONLY when a
# Node/Port/Device is added or removed (a real controller/plugin/mic appearing
# or leaving), ignoring Client/Link churn and param updates. Bursts are
# coalesced into one reconcile.
log "starting; config=$CONFIG"
reconcile
pw-mon 2>/dev/null | awk '
  /^(added|removed):/                                  { hot = 1; next }
  /^[a-z]+:/                                           { hot = 0 }
  hot && /type: PipeWire:Interface:(Node|Port|Device)/ { print; fflush(); hot = 0 }
' | while IFS= read -r _; do
  while IFS= read -r -t 0.4 _; do :; done
  reconcile
done
