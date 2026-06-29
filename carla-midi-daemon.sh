#!/usr/bin/env bash
# Linux-Carla-MIDI-Daemon
# Auto-wires MIDI controllers AND audio outputs for Carla plugins ("samplers")
# on Linux/PipeWire, with per-plugin MIDI priority/failover and toggleable audio
# routes. Optionally mixes plugin audio into your microphone WITHOUT a virtual
# device: while a gating Carla plugin is loaded, it links the plugin's output
# into whatever app is capturing the current default source. The default mic is
# never changed and no device appears/disappears, so apps that own the default
# (e.g. WiVRn) are left untouched.
#
# Event-driven via PipeWire's pw-mon (no polling). Requires: pw-link, pw-mon, jq.
# Mic-mix feature additionally needs: pactl (to read the default source).

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

# ── mic mix: feed Carla audio into the current default mic's consumers ──────
# No virtual device and no default change. While the gating plugin is loaded we
# link each sampler's stereo output INTO whatever apps are currently capturing
# the default source, so those apps hear mic + Carla. Reconciled to the desired
# set every pass: links to consumers that went away (or that belonged to a
# previous default after it changes), and all links once the plugin closes, are
# torn down; new consumers are wired up. Idempotent — safe to call each tick.
mix_into_default_mic() {
  [ "$(cfg '.mic_mix.enabled // false')" = true ] || return 0
  command -v pactl >/dev/null || { log "mic_mix needs pactl (pipewire-pulse) — skipping"; return 0; }

  local -a samplers
  mapfile -t samplers < <(cfg '.mic_mix.mix_samplers[]?')
  [ "${#samplers[@]}" -eq 0 ] && return 0

  local gate gate_present
  gate=$(cfg '.mic_mix.present_with // ""')
  if [ -n "$gate" ]; then node_exists "$gate"; gate_present=$?; else gate_present=0; fi

  # ── desired links: "sampler_out<TAB>consumer_in" (empty while plugin closed) ─
  local desired="" def consumers cport s
  if [ "$gate_present" -eq 0 ]; then
    def=$(pactl get-default-source 2>/dev/null)
    if [ -n "$def" ] && [ "$def" != "@DEFAULT_SOURCE@" ]; then
      # input ports currently fed by the default source's capture ports
      consumers=$(pw-link -o -l 2>/dev/null | awk -v def="$def:" '
        /^[[:space:]]*\|->/ { if (cur) { l=$0; sub(/^[[:space:]]*\|-> /,"",l); sub(/ \((capture|playback)\)$/,"",l); print l } ; next }
        /^[[:space:]]/      { next }
        { cur = (index($0, def) == 1) }
      ')
      while IFS= read -r cport; do
        [ -z "$cport" ] && continue
        for s in "${samplers[@]}"; do
          [ -z "$s" ] && continue
          case "$cport" in
            *FR|*_R|*-R|*[Rr]ight*) desired+="$s:output_2	$cport"$'\n' ;;
            *FL|*_L|*-L|*[Ll]eft*)  desired+="$s:output_1	$cport"$'\n' ;;
            *) desired+="$s:output_1	$cport"$'\n'"$s:output_2	$cport"$'\n' ;;  # mono/unknown -> sum both
          esac
        done
      done <<< "$consumers"
    fi
  fi

  # ── existing links from our sampler outputs: "sampler_out<TAB>consumer_in" ──
  local existing="" cur="" line dst port
  while IFS= read -r line; do
    case "$line" in
      *"|-> "*) [ -n "$cur" ] && { dst=${line##*|-> }; dst=${dst% (capture)}; dst=${dst% (playback)}; existing+="$cur	$dst"$'\n'; } ;;
      [[:space:]]*) : ;;                                    # other indented (e.g. |<-) lines
      *) port=${line% (capture)}; port=${port% (playback)}; cur=""
         for s in "${samplers[@]}"; do case "$port" in "$s:output_1"|"$s:output_2") cur="$port" ;; esac; done ;;
    esac
  done < <(pw-link -o -l 2>/dev/null)

  # ── reconcile: drop stale, add missing ─────────────────────────────────────
  local link
  while IFS= read -r link; do
    [ -z "$link" ] && continue
    printf '%s' "$desired" | grep -qxF "$link" || rmlink "${link%%	*}" "${link##*	}"
  done <<< "$existing"
  while IFS= read -r link; do
    [ -z "$link" ] && continue
    printf '%s' "$existing" | grep -qxF "$link" || mklink "${link%%	*}" "${link##*	}"
  done <<< "$desired"
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
  # GUI apps need the graphical-session env (DISPLAY/WAYLAND_DISPLAY/etc). The
  # daemon may have started before the compositor imported those into the user
  # manager, so its own environment can lack them. Pull the current values from
  # the user systemd manager so Carla can actually reach the display.
  local -a genv=()
  while IFS= read -r _e; do genv+=("$_e"); done < <(
    systemctl --user show-environment 2>/dev/null \
      | grep -E '^(DISPLAY|WAYLAND_DISPLAY|XAUTHORITY|XDG_RUNTIME_DIR|XDG_SESSION_TYPE|XDG_CURRENT_DESKTOP)=')
  setsid env "${genv[@]}" sh -c "$cmd" >/dev/null 2>&1 </dev/null &
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
  mix_into_default_mic
}

# ── lifecycle: drop our mic-mix links when the daemon stops ─────────────────
cleanup() {
  [ "$(cfg '.mic_mix.enabled // false')" = true ] || return 0
  local -a samplers; mapfile -t samplers < <(cfg '.mic_mix.mix_samplers[]?')
  [ "${#samplers[@]}" -eq 0 ] && return 0
  local cur="" line dst s
  while IFS= read -r line; do
    case "$line" in
      *"|-> "*) [ -n "$cur" ] && { dst=${line##*|-> }; dst=${dst% (capture)}; dst=${dst% (playback)}; rmlink "$cur" "$dst"; } ;;
      [[:space:]]*) : ;;
      *) cur=""; line=${line% (capture)}; line=${line% (playback)}
         for s in "${samplers[@]}"; do case "$line" in "$s:output_1"|"$s:output_2") cur="$line" ;; esac; done ;;
    esac
  done < <(pw-link -o -l 2>/dev/null)
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
