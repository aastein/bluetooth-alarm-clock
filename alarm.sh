#!/bin/bash
#
# alarm.sh — scheduled media alarm action.
#
# Opens a URL in a chosen app, optionally connects a Bluetooth audio device and
# routes system output to it, mutes, then gradually ramps system volume from a
# start level up to a target level.
#
# Configured entirely via CLI flags. Run with --help for the full list. The
# schedule itself is handled by a launchd LaunchAgent (see install.sh); this
# script performs one alarm run.

set -euo pipefail

# ----------------------------------------------------------------------------
# Defaults — the single source of truth. Every variable is initialised here,
# before the argument parser, so that `set -u` never trips on a flag the user
# omits (notably the optional, empty-by-default BT_DEVICE / AUDIO_OUTPUT_NAME).
# ----------------------------------------------------------------------------
URL="https://www.youtube.com/@markets/live"
BROWSER_APP="Arc"
BT_DEVICE=""
AUDIO_OUTPUT_NAME=""
START_VOLUME=0
TARGET_VOLUME=60
RAMP_SECONDS=180
CONNECT_TIMEOUT=20

# launchd runs jobs with a minimal PATH. Make Homebrew (Apple Silicon and Intel
# prefixes) and the system bins reachable so blueutil / SwitchAudioSource resolve.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

PROG="$(basename "$0")"

die() {
  echo "$PROG: error: $*" >&2
  exit 1
}

log() {
  echo "[$PROG] $*"
}

usage() {
  cat <<EOF
Usage: $PROG [options]

Open a URL in an app, optionally connect a Bluetooth audio device and route
output to it, mute, then slowly ramp system volume from start to target.

Options:
  --url <url>             URL to open (default: $URL)
  --browser <app>         App for 'open -a' (default: $BROWSER_APP)
  --bt-device <id>        Bluetooth name or MAC to connect; empty = skip.
                          Requires 'blueutil'.
  --audio-output <name>   Output device to route to; empty = skip.
                          Requires 'SwitchAudioSource' (switchaudio-osx).
  --start-volume <0-100>  Volume before the ramp (default: $START_VOLUME)
  --target-volume <0-100> Volume to ramp up to (default: $TARGET_VOLUME)
  --ramp-seconds <n>      Ramp duration in seconds (default: $RAMP_SECONDS)
  --connect-timeout <n>   Seconds to wait for Bluetooth connect (default: $CONNECT_TIMEOUT)
  -h, --help              Show this help and exit

Volumes are macOS system output volume (0-100). Times are local.
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
# Parse arguments. The loop overwrites only the flags the user supplies.
# ----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --url)             [ $# -ge 2 ] || die "--url requires a value";             URL="$2";               shift 2 ;;
    --browser)         [ $# -ge 2 ] || die "--browser requires a value";         BROWSER_APP="$2";       shift 2 ;;
    --bt-device)       [ $# -ge 2 ] || die "--bt-device requires a value";       BT_DEVICE="$2";         shift 2 ;;
    --audio-output)    [ $# -ge 2 ] || die "--audio-output requires a value";    AUDIO_OUTPUT_NAME="$2"; shift 2 ;;
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

# ----------------------------------------------------------------------------
# Pre-flight dependency checks (fail fast, before any side effects). Only the
# tools the chosen flags actually need are required.
# ----------------------------------------------------------------------------
need_cmd open "This tool requires macOS (the 'open' command was not found)."
need_cmd osascript "This tool requires macOS (AppleScript 'osascript' was not found)."
if [ -n "$BT_DEVICE" ]; then
  need_cmd blueutil "--bt-device was given but 'blueutil' is missing. Install it: brew install blueutil"
fi
if [ -n "$AUDIO_OUTPUT_NAME" ]; then
  need_cmd SwitchAudioSource "--audio-output was given but 'SwitchAudioSource' is missing. Install it: brew install switchaudio-osx"
fi

# ----------------------------------------------------------------------------
# 1. Bluetooth connect (best-effort: an alarm that plays beats one that aborts).
# ----------------------------------------------------------------------------
bt_is_connected() {
  # blueutil --is-connected prints "1"/"0" and exits 0; guard the output anyway
  # so a non-zero exit (e.g. device not paired) reads as "not connected".
  blueutil --is-connected "$BT_DEVICE" 2>/dev/null || echo 0
}

connected=0
if [ -n "$BT_DEVICE" ]; then
  if [ "$(bt_is_connected)" = "1" ]; then
    log "Bluetooth '$BT_DEVICE' already connected"
    connected=1
  else
    log "connecting Bluetooth '$BT_DEVICE' (timeout ${CONNECT_TIMEOUT}s)..."
    # --connect exits non-zero on failure; '|| true' keeps set -e from aborting.
    blueutil --connect "$BT_DEVICE" || true
    waited=0
    while [ "$waited" -lt "$CONNECT_TIMEOUT" ]; do
      if [ "$(bt_is_connected)" = "1" ]; then
        connected=1
        break
      fi
      sleep 1
      waited=$((waited + 1))
    done
    if [ "$connected" = "1" ]; then
      log "Bluetooth connected after ${waited}s"
    else
      echo "[$PROG] WARNING: could not connect to '$BT_DEVICE' within ${CONNECT_TIMEOUT}s; continuing" >&2
    fi
  fi
fi

# ----------------------------------------------------------------------------
# 2. Route audio output. If a Bluetooth device was requested, only route once it
#    is actually connected (the final state after the poll above).
# ----------------------------------------------------------------------------
if [ -n "$AUDIO_OUTPUT_NAME" ]; then
  if [ -n "$BT_DEVICE" ] && [ "$connected" != "1" ]; then
    echo "[$PROG] WARNING: not routing to '$AUDIO_OUTPUT_NAME' (Bluetooth not connected)" >&2
  else
    log "routing system output to '$AUDIO_OUTPUT_NAME'"
    SwitchAudioSource -t output -s "$AUDIO_OUTPUT_NAME" \
      || echo "[$PROG] WARNING: could not set output to '$AUDIO_OUTPUT_NAME'; continuing" >&2
  fi
fi

# ----------------------------------------------------------------------------
# 3. Mute baseline. Clearing the mute flag and setting the volume are
#    independent states on macOS, so do both.
# ----------------------------------------------------------------------------
log "setting start volume to $START_VOLUME (unmuted)"
osascript -e 'set volume without output muted'
osascript -e "set volume output volume $START_VOLUME"

# ----------------------------------------------------------------------------
# 4. Open the URL, then give the page a moment to load and begin playback.
# ----------------------------------------------------------------------------
log "opening '$URL' in '$BROWSER_APP'"
open -a "$BROWSER_APP" "$URL" \
  || die "could not open '$URL' in '$BROWSER_APP' (is the app installed?)"
sleep 5

# ----------------------------------------------------------------------------
# 5. Ramp the volume. Guard STEPS == 0 *before* dividing to avoid a div-by-zero.
# ----------------------------------------------------------------------------
steps=$((TARGET_VOLUME - START_VOLUME))
if [ "$steps" -eq 0 ]; then
  log "start and target volume are equal ($TARGET_VOLUME); nothing to ramp"
else
  interval=$((RAMP_SECONDS / steps))
  log "ramping volume $START_VOLUME -> $TARGET_VOLUME over ${RAMP_SECONDS}s ($steps steps, ${interval}s each)"
  v="$START_VOLUME"
  # Assignment form 'v=$((v+1))' is set -e safe; the bare '((v++))' form is not
  # (it returns non-zero when the pre-increment value is 0).
  while [ "$v" -lt "$TARGET_VOLUME" ]; do
    v=$((v + 1))
    osascript -e "set volume output volume $v"
    sleep "$interval"
  done
  log "reached target volume $TARGET_VOLUME"
fi

log "done"
