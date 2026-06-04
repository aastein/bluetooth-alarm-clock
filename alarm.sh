#!/bin/bash
#
# alarm.sh — scheduled media alarm action.
#
# Opens a URL in a chosen app, optionally connects Bluetooth audio device(s) and
# routes output, mutes, then gradually ramps the volume from a start level up to
# a target level.
#
# Two modes:
#   * Single-speaker (default): ramps the macOS system output volume via osascript.
#   * Multi-speaker (--multi-output): plays to several speakers via a Multi-Output
#     Device and ramps EACH listed speaker independently via the bundled
#     'device-volume' CoreAudio helper (system volume can't drive a Multi-Output
#     Device, which has no master volume).
#
# Configured entirely via CLI flags. Run with --help. The schedule is handled by
# a launchd LaunchAgent (see install.sh); this script performs one alarm run.

set -euo pipefail

# ----------------------------------------------------------------------------
# Defaults — the single source of truth. Every variable is initialised here,
# before the argument parser, so `set -u` never trips on an omitted flag.
# ----------------------------------------------------------------------------
URL="https://www.youtube.com/@markets/live"
BROWSER_APP="Arc"
BT_DEVICES=()              # repeatable --bt-device; connect each
AUDIO_OUTPUT_NAME=""       # single-mode output routing
MULTI_OUTPUT=""            # multi-mode Multi-Output Device (presence enables multi mode)
RAMP_SPEAKERS=()           # repeatable --ramp-speaker; CoreAudio names to ramp (multi mode)
START_VOLUME=0
TARGET_VOLUME=60
RAMP_SECONDS=180
CONNECT_TIMEOUT=20

# launchd runs jobs with a minimal PATH. Make Homebrew (Apple Silicon + Intel)
# and the system bins reachable so blueutil / SwitchAudioSource resolve.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

PROG="$(basename "$0")"
ALARM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$ALARM_DIR/device-volume"

die() { echo "$PROG: error: $*" >&2; exit 1; }
log() { echo "[$PROG] $*"; }

usage() {
  cat <<EOF
Usage: $PROG [options]

Open a URL in an app, optionally connect Bluetooth speaker(s) and route output,
mute, then slowly ramp volume from start to target.

Common options:
  --url <url>             URL to open (default: $URL)
  --browser <app>         App for 'open -a' (default: $BROWSER_APP)
  --bt-device <id>        Bluetooth name/MAC to connect; repeatable. Requires blueutil.
  --start-volume <0-100>  Volume before the ramp (default: $START_VOLUME)
  --target-volume <0-100> Volume to ramp up to (default: $TARGET_VOLUME)
  --ramp-seconds <n>      Ramp duration in seconds (default: $RAMP_SECONDS)
  --connect-timeout <n>   Seconds to wait per Bluetooth connect (default: $CONNECT_TIMEOUT)
  -h, --help              Show this help and exit

Single-speaker mode (default) — ramps the system output volume:
  --audio-output <name>   Output device to route to. Requires SwitchAudioSource.

Multi-speaker mode — ramps each speaker independently:
  --multi-output <name>   Multi-Output Device (created once in Audio MIDI Setup)
                          to select as output. Presence enables multi-speaker mode.
                          Mutually exclusive with --audio-output.
  --ramp-speaker <name>   CoreAudio output device name to ramp; repeatable.
                          Requires --multi-output. (List names: device-volume list)

Volumes are 0-100. Times are local.
EOF
}

# vnum NAME VALUE MIN [MAX] — validate that a flag is an integer in range.
vnum() {
  local name="$1" value="$2" min="$3" max="${4:-}"
  [[ "$value" =~ ^[0-9]+$ ]] || die "--$name must be a non-negative integer (got '$value')"
  [ "$value" -ge "$min" ] || die "--$name must be >= $min (got '$value')"
  if [ -n "$max" ]; then
    [ "$value" -le "$max" ] || die "--$name must be <= $max (got '$value')"
  fi
}

# need_cmd CMD HINT — fail clearly if a required command is missing.
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found. $2"
}

# ----------------------------------------------------------------------------
# Parse arguments. --bt-device and --ramp-speaker are repeatable (arrays).
# ----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --url)             [ $# -ge 2 ] || die "--url requires a value";             URL="$2";               shift 2 ;;
    --browser)         [ $# -ge 2 ] || die "--browser requires a value";         BROWSER_APP="$2";       shift 2 ;;
    --bt-device)       [ $# -ge 2 ] || die "--bt-device requires a value";       BT_DEVICES+=("$2");     shift 2 ;;
    --audio-output)    [ $# -ge 2 ] || die "--audio-output requires a value";    AUDIO_OUTPUT_NAME="$2"; shift 2 ;;
    --multi-output)    [ $# -ge 2 ] || die "--multi-output requires a value";    MULTI_OUTPUT="$2";      shift 2 ;;
    --ramp-speaker)    [ $# -ge 2 ] || die "--ramp-speaker requires a value";    RAMP_SPEAKERS+=("$2");  shift 2 ;;
    --start-volume)    [ $# -ge 2 ] || die "--start-volume requires a value";    START_VOLUME="$2";      shift 2 ;;
    --target-volume)   [ $# -ge 2 ] || die "--target-volume requires a value";   TARGET_VOLUME="$2";     shift 2 ;;
    --ramp-seconds)    [ $# -ge 2 ] || die "--ramp-seconds requires a value";    RAMP_SECONDS="$2";      shift 2 ;;
    --connect-timeout) [ $# -ge 2 ] || die "--connect-timeout requires a value"; CONNECT_TIMEOUT="$2";   shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    --)                shift; break ;;
    -*)                die "unknown flag: $1 (see --help)" ;;
    *)                 die "unexpected argument: $1 (see --help)" ;;
  esac
done

# ----------------------------------------------------------------------------
# Validate.
# ----------------------------------------------------------------------------
[ -n "$URL" ]         || die "--url must not be empty"
[ -n "$BROWSER_APP" ] || die "--browser must not be empty"
vnum start-volume    "$START_VOLUME"    0 100
vnum target-volume   "$TARGET_VOLUME"   0 100
vnum ramp-seconds    "$RAMP_SECONDS"    1
vnum connect-timeout "$CONNECT_TIMEOUT" 0
[ "$TARGET_VOLUME" -ge "$START_VOLUME" ] \
  || die "--target-volume ($TARGET_VOLUME) must be >= --start-volume ($START_VOLUME)"

# Mode validation.
if [ -n "$MULTI_OUTPUT" ]; then
  [ -z "$AUDIO_OUTPUT_NAME" ] || die "--multi-output and --audio-output are mutually exclusive"
  [ "${#RAMP_SPEAKERS[@]}" -gt 0 ] || die "--multi-output requires at least one --ramp-speaker"
  [ -x "$HELPER" ] || die "volume helper not found/executable at $HELPER — run install.sh in multi-speaker mode to build it"
else
  [ "${#RAMP_SPEAKERS[@]}" -eq 0 ] || die "--ramp-speaker requires --multi-output"
fi

# ----------------------------------------------------------------------------
# Pre-flight dependency checks (fail fast, before any side effects). Only the
# tools the chosen flags actually need are required.
# ----------------------------------------------------------------------------
need_cmd open "This tool requires macOS (the 'open' command was not found)."
need_cmd osascript "This tool requires macOS (AppleScript 'osascript' was not found)."
if [ "${#BT_DEVICES[@]}" -gt 0 ]; then
  need_cmd blueutil "--bt-device was given but 'blueutil' is missing. Install it: brew install blueutil"
fi
if [ -n "$MULTI_OUTPUT" ] || [ -n "$AUDIO_OUTPUT_NAME" ]; then
  need_cmd SwitchAudioSource "audio routing was requested but 'SwitchAudioSource' is missing. Install it: brew install switchaudio-osx"
fi

# ----------------------------------------------------------------------------
# 1. Bluetooth connect (best-effort: an alarm that plays beats one that aborts).
# ----------------------------------------------------------------------------
bt_is_connected() {  # $1 = device id; echoes "1"/"0"
  blueutil --is-connected "$1" 2>/dev/null || echo 0
}

CONNECTED_RESULT=0
connect_bt() {  # $1 = device id; best-effort; sets CONNECTED_RESULT
  local dev="$1" waited=0
  CONNECTED_RESULT=0
  if [ "$(bt_is_connected "$dev")" = "1" ]; then
    log "Bluetooth '$dev' already connected"
    CONNECTED_RESULT=1
    return 0
  fi
  log "connecting Bluetooth '$dev' (timeout ${CONNECT_TIMEOUT}s)..."
  blueutil --connect "$dev" || true   # --connect exits non-zero on failure
  while [ "$waited" -lt "$CONNECT_TIMEOUT" ]; do
    if [ "$(bt_is_connected "$dev")" = "1" ]; then
      CONNECTED_RESULT=1
      log "Bluetooth '$dev' connected after ${waited}s"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo "[$PROG] WARNING: could not connect to '$dev' within ${CONNECT_TIMEOUT}s; continuing" >&2
  return 0
}

single_connected=0   # tracks the (single-mode) device's connection for routing
for dev in ${BT_DEVICES[@]+"${BT_DEVICES[@]}"}; do
  connect_bt "$dev"
  single_connected="$CONNECTED_RESULT"
done

# ----------------------------------------------------------------------------
# apply_volume LEVEL — set the current loudness for the active mode.
#   multi mode  -> each --ramp-speaker via the CoreAudio helper (guarded so one
#                  speaker's failure can't abort the ramp under set -e)
#   single mode -> the system output volume via osascript
# ----------------------------------------------------------------------------
apply_volume() {  # $1 = 0-100
  local level="$1" spk
  if [ -n "$MULTI_OUTPUT" ]; then
    for spk in ${RAMP_SPEAKERS[@]+"${RAMP_SPEAKERS[@]}"}; do
      "$HELPER" set "$spk" "$level" || true
    done
  else
    osascript -e "set volume output volume $level"
  fi
}

# ----------------------------------------------------------------------------
# 2. Mode-specific routing / setup.
# ----------------------------------------------------------------------------
if [ -n "$MULTI_OUTPUT" ]; then
  log "selecting Multi-Output Device '$MULTI_OUTPUT'"
  SwitchAudioSource -t output -s "$MULTI_OUTPUT" \
    || echo "[$PROG] WARNING: could not select '$MULTI_OUTPUT'; continuing" >&2

  # Probe each ramp speaker for working volume control. Runs before any audio
  # plays, so the test value is inaudible. Uses a distinctive non-zero value +
  # tolerance to avoid both a false pass at the default start of 0 and false
  # warnings from devices that quantize the volume. Every helper call guarded.
  for spk in ${RAMP_SPEAKERS[@]+"${RAMP_SPEAKERS[@]}"}; do
    if ! "$HELPER" set "$spk" 50 >/dev/null 2>&1; then
      echo "[$PROG] WARNING: '$spk' not found or has no settable volume; its ramp may be a no-op" >&2
      continue
    fi
    rb="$("$HELPER" get "$spk" 2>/dev/null || echo "")"
    if [[ "$rb" =~ ^[0-9]+$ ]]; then
      if [ "$rb" -lt 48 ] || [ "$rb" -gt 52 ]; then
        echo "[$PROG] WARNING: '$spk' did not honor a volume change (set 50, read $rb); its ramp may be a no-op" >&2
      fi
    else
      echo "[$PROG] WARNING: could not read volume of '$spk'; its ramp may be a no-op" >&2
    fi
  done
else
  if [ -n "$AUDIO_OUTPUT_NAME" ]; then
    if [ "${#BT_DEVICES[@]}" -gt 0 ] && [ "$single_connected" != "1" ]; then
      echo "[$PROG] WARNING: not routing to '$AUDIO_OUTPUT_NAME' (Bluetooth not connected)" >&2
    else
      log "routing system output to '$AUDIO_OUTPUT_NAME'"
      SwitchAudioSource -t output -s "$AUDIO_OUTPUT_NAME" \
        || echo "[$PROG] WARNING: could not set output to '$AUDIO_OUTPUT_NAME'; continuing" >&2
    fi
  fi
fi

# ----------------------------------------------------------------------------
# 3. Mute baseline + start level (both modes). Clearing the mute flag and
#    setting the volume are independent states on macOS, so do both.
# ----------------------------------------------------------------------------
log "setting start volume to $START_VOLUME (unmuted)"
osascript -e 'set volume without output muted'
apply_volume "$START_VOLUME"

# ----------------------------------------------------------------------------
# 4. Open the URL, then give the page a moment to load and begin playback.
# ----------------------------------------------------------------------------
log "opening '$URL' in '$BROWSER_APP'"
open -a "$BROWSER_APP" "$URL" \
  || die "could not open '$URL' in '$BROWSER_APP' (is the app installed?)"
sleep 5

# ----------------------------------------------------------------------------
# 5. Ramp. Guard steps == 0 before dividing to avoid a div-by-zero.
# ----------------------------------------------------------------------------
steps=$((TARGET_VOLUME - START_VOLUME))
if [ "$steps" -eq 0 ]; then
  log "start and target volume are equal ($TARGET_VOLUME); nothing to ramp"
else
  interval=$((RAMP_SECONDS / steps))
  if [ -n "$MULTI_OUTPUT" ]; then
    log "ramping ${#RAMP_SPEAKERS[@]} speaker(s) $START_VOLUME -> $TARGET_VOLUME over ${RAMP_SECONDS}s ($steps steps, ${interval}s each)"
  else
    log "ramping volume $START_VOLUME -> $TARGET_VOLUME over ${RAMP_SECONDS}s ($steps steps, ${interval}s each)"
  fi
  # Assignment-form increment is set -e safe; the bare '((v++))' form is not.
  v="$START_VOLUME"
  while [ "$v" -lt "$TARGET_VOLUME" ]; do
    v=$((v + 1))
    apply_volume "$v"
    sleep "$interval"
  done
  log "reached target volume $TARGET_VOLUME"
fi

log "done"
