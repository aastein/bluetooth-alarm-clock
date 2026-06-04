#!/bin/bash
#
# install.sh — generate a launchd LaunchAgent that runs alarm.sh on a daily
# schedule (local time) and load it via launchctl. Re-runnable (it reloads
# cleanly). Use --uninstall to remove.
#
# Run as:  bash install.sh [options]
# (invoked via 'bash' so a missing execute bit on this file is never a blocker.)

set -euo pipefail

PROG="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALARM="$SCRIPT_DIR/alarm.sh"

# --- defaults ---------------------------------------------------------------
HOUR=6
MINUTE=0
LABEL="local.media-alarm"
LOG_FILE=""            # derived from LABEL after parsing if left empty
UNINSTALL=0
NEED_BLUEUTIL=0
NEED_SWITCHAUDIO=0
MULTI_OUTPUT=""              # --multi-output value (enables multi-speaker mode)
AUDIO_OUTPUT_PRESENT=0       # whether --audio-output was given (mutual-exclusion check)
RAMP_SPEAKER_COUNT=0         # number of --ramp-speaker flags supplied
BT_DEVICE_VALUES=()          # captured --bt-device values, for the permission probe
FWD_ARGS=()                  # alarm.sh flags to forward into the plist (flag value ...)

die() { echo "$PROG: error: $*" >&2; exit 1; }
log() { echo "[$PROG] $*"; }

usage() {
  cat <<EOF
Usage: $PROG [options]
       $PROG --uninstall [--label <label>]

Generate \$HOME/Library/LaunchAgents/<label>.plist that runs alarm.sh daily at
the given local time, and load it via launchctl.

Schedule / agent options:
  --hour <0-23>           Hour to fire, local time (default: $HOUR)
  --minute <0-59>         Minute to fire (default: $MINUTE)
  --label <reverse-dns>   Agent label & plist filename (default: $LABEL)
  --log-file <path>       Log file (default: \$HOME/Library/Logs/<label>.log)
  --uninstall             Unload and remove the agent for --label, then exit
  -h, --help              Show this help and exit

Alarm options (forwarded to alarm.sh — see 'alarm.sh --help'):
  --url <url>             URL to open
  --browser <app>         App for 'open -a'
  --bt-device <id>        Bluetooth device to connect; repeatable (installs blueutil)
  --audio-output <name>   Single-speaker: output to route to (installs switchaudio-osx)
  --multi-output <name>   Multi-speaker: Multi-Output Device to select (installs
                          switchaudio-osx; compiles the volume helper, needs swiftc).
                          Mutually exclusive with --audio-output.
  --ramp-speaker <id>     Multi-speaker: CoreAudio device name or UID to ramp;
                          repeatable. Use a UID for same-named speakers.
                          Requires --multi-output.
  --start-volume <0-100>  Volume before the ramp
  --target-volume <0-100> Volume to ramp up to
  --ramp-seconds <n>      Ramp duration in seconds
  --connect-timeout <n>   Bluetooth connect timeout in seconds

Examples:
  # 6 AM YouTube-live wake-up through a paired Bluetooth speaker:
  bash $PROG --hour 6 --minute 0 \\
    --url "https://www.youtube.com/@markets/live" --browser Arc \\
    --bt-device "Bedroom Speaker" --audio-output "Bedroom Speaker" \\
    --target-volume 60 --ramp-seconds 180

  # Remove it again:
  bash $PROG --uninstall
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

# xml_escape STRING — escape XML metacharacters for safe insertion into the plist.
xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"      # must be first
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&apos;}"
  printf '%s' "$s"
}

# ----------------------------------------------------------------------------
# Parse arguments. Schedule/agent flags are consumed here; alarm flags are
# validated where numeric and forwarded verbatim into the plist.
# ----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --hour)      [ $# -ge 2 ] || die "--hour requires a value";     HOUR="$2";     shift 2 ;;
    --minute)    [ $# -ge 2 ] || die "--minute requires a value";   MINUTE="$2";   shift 2 ;;
    --label)     [ $# -ge 2 ] || die "--label requires a value";    LABEL="$2";    shift 2 ;;
    --log-file)  [ $# -ge 2 ] || die "--log-file requires a value"; LOG_FILE="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;

    --url|--browser)
      [ $# -ge 2 ] || die "$1 requires a value"
      FWD_ARGS+=("$1" "$2"); shift 2 ;;
    --bt-device)
      [ $# -ge 2 ] || die "--bt-device requires a value"
      if [ -n "$2" ]; then NEED_BLUEUTIL=1; BT_DEVICE_VALUES+=("$2"); fi
      FWD_ARGS+=("$1" "$2"); shift 2 ;;
    --audio-output)
      [ $# -ge 2 ] || die "--audio-output requires a value"
      if [ -n "$2" ]; then NEED_SWITCHAUDIO=1; AUDIO_OUTPUT_PRESENT=1; fi
      FWD_ARGS+=("$1" "$2"); shift 2 ;;
    --multi-output)
      [ $# -ge 2 ] || die "--multi-output requires a value"
      if [ -n "$2" ]; then NEED_SWITCHAUDIO=1; MULTI_OUTPUT="$2"; fi
      FWD_ARGS+=("$1" "$2"); shift 2 ;;
    --ramp-speaker)
      [ $# -ge 2 ] || die "--ramp-speaker requires a value"
      RAMP_SPEAKER_COUNT=$((RAMP_SPEAKER_COUNT + 1))
      FWD_ARGS+=("$1" "$2"); shift 2 ;;
    --start-volume|--target-volume)
      [ $# -ge 2 ] || die "$1 requires a value"
      vnum "${1#--}" "$2" 0 100
      FWD_ARGS+=("$1" "$2"); shift 2 ;;
    --ramp-seconds)
      [ $# -ge 2 ] || die "--ramp-seconds requires a value"
      vnum ramp-seconds "$2" 1
      FWD_ARGS+=("$1" "$2"); shift 2 ;;
    --connect-timeout)
      [ $# -ge 2 ] || die "--connect-timeout requires a value"
      vnum connect-timeout "$2" 0
      FWD_ARGS+=("$1" "$2"); shift 2 ;;

    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag: $1 (see --help)" ;;
    *)  die "unexpected argument: $1 (see --help)" ;;
  esac
done

PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# ----------------------------------------------------------------------------
# Uninstall path: unload and remove only this label's generated plist.
# ----------------------------------------------------------------------------
if [ "$UNINSTALL" = "1" ]; then
  log "uninstalling agent '$LABEL'"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  if [ -f "$PLIST" ]; then
    log "removing $PLIST"
    rm -f "$PLIST"
  else
    log "no plist at $PLIST (nothing to remove)"
  fi
  log "uninstalled"
  exit 0
fi

# ----------------------------------------------------------------------------
# Validate install inputs. (Cross-field checks like target >= start live in
# alarm.sh, which knows the defaults; here we only range-check what we're given.)
# ----------------------------------------------------------------------------
vnum hour   "$HOUR"   0 23
vnum minute "$MINUTE" 0 59
# Normalise to base-10 so values like "08" don't get misread as octal later.
HOUR=$((10#$HOUR))
MINUTE=$((10#$MINUTE))
[ -n "$LABEL" ] || die "--label must not be empty"
[ -f "$ALARM" ] || die "alarm.sh not found next to this installer (expected $ALARM)"

if [ -z "$LOG_FILE" ]; then
  LOG_FILE="$HOME/Library/Logs/$LABEL.log"
fi

# Mode validation (mirrors alarm.sh, so a misconfig fails at install, not at alarm time).
if [ -n "$MULTI_OUTPUT" ]; then
  [ "$AUDIO_OUTPUT_PRESENT" = "0" ] || die "--multi-output and --audio-output are mutually exclusive"
  [ "$RAMP_SPEAKER_COUNT" -gt 0 ] || die "--multi-output requires at least one --ramp-speaker"
else
  [ "$RAMP_SPEAKER_COUNT" -eq 0 ] || die "--ramp-speaker requires --multi-output"
fi

# ----------------------------------------------------------------------------
# Ensure the optional dependencies the chosen flags actually need. We install
# only what is used; if Homebrew is absent we error with guidance.
# ----------------------------------------------------------------------------
ensure_dep() {
  # ensure_dep CMD BREW_FORMULA
  if command -v "$1" >/dev/null 2>&1; then
    log "dependency '$1' present"
    return 0
  fi
  command -v brew >/dev/null 2>&1 \
    || die "'$1' is required (you configured the matching feature) but Homebrew is not installed. Install Homebrew from https://brew.sh or install '$1' manually, then re-run."
  log "installing '$1' via Homebrew ($2)..."
  brew install "$2"
}

if [ "$NEED_BLUEUTIL" = "1" ];    then ensure_dep blueutil blueutil; fi
if [ "$NEED_SWITCHAUDIO" = "1" ]; then ensure_dep SwitchAudioSource switchaudio-osx; fi

# Multi-speaker mode needs the CoreAudio volume helper compiled from source.
if [ -n "$MULTI_OUTPUT" ]; then
  command -v swiftc >/dev/null 2>&1 \
    || die "multi-speaker mode needs the Swift compiler (swiftc). Install the Xcode Command Line Tools: xcode-select --install, then re-run."
  [ -f "$SCRIPT_DIR/device-volume.swift" ] \
    || die "device-volume.swift not found next to this installer (expected $SCRIPT_DIR/device-volume.swift)"
  log "compiling volume helper (device-volume.swift)..."
  swiftc -O "$SCRIPT_DIR/device-volume.swift" -o "$SCRIPT_DIR/device-volume" \
    || die "failed to compile device-volume.swift"
  log "built $SCRIPT_DIR/device-volume"
fi

# ----------------------------------------------------------------------------
# Surface the one-time macOS Bluetooth permission prompt now, while you're at
# the keyboard to click "Allow", so the scheduled run can connect without a
# prompt at alarm time. This is a read-only probe (the same call alarm.sh makes
# first) — it does not connect the device or change anything. The grant is tied
# to blueutil itself, so it persists for the launchd-scheduled run.
# ----------------------------------------------------------------------------
if [ "$NEED_BLUEUTIL" = "1" ]; then
  log "checking Bluetooth access — click 'Allow' if a 'blueutil would like to use Bluetooth' prompt appears..."
  for dev in ${BT_DEVICE_VALUES[@]+"${BT_DEVICE_VALUES[@]}"}; do
    if blueutil --is-connected "$dev" >/dev/null 2>&1; then
      log "Bluetooth access OK; blueutil can see '$dev'"
    else
      echo "[$PROG] NOTE: blueutil could not query '$dev'." >&2
      echo "[$PROG]   - If you denied the Bluetooth prompt: enable blueutil under" >&2
      echo "[$PROG]     System Settings > Privacy & Security > Bluetooth, then re-run." >&2
      echo "[$PROG]   - Otherwise confirm the device is paired (System Settings > Bluetooth)" >&2
      echo "[$PROG]     and that the name/MAC matches exactly." >&2
    fi
  done
fi

# alarm.sh runs via '/bin/bash <path>' in the plist, so the execute bit is not
# strictly required — but set it so 'bash alarm.sh' / './alarm.sh' both work.
chmod +x "$ALARM"

# ----------------------------------------------------------------------------
# Build ProgramArguments: each argv element is its own <string> (no shell
# splitting), every value XML-escaped (matters for URLs containing '&').
# ----------------------------------------------------------------------------
PROGRAM_ARGS="    <string>/bin/bash</string>
    <string>$(xml_escape "$ALARM")</string>"
for arg in ${FWD_ARGS[@]+"${FWD_ARGS[@]}"}; do
  PROGRAM_ARGS="$PROGRAM_ARGS
    <string>$(xml_escape "$arg")</string>"
done

# ----------------------------------------------------------------------------
# Write the plist. $HOME is expanded into absolute paths because '~' does NOT
# expand inside a plist.
# ----------------------------------------------------------------------------
mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$(dirname "$LOG_FILE")"

LABEL_XML="$(xml_escape "$LABEL")"
LOG_XML="$(xml_escape "$LOG_FILE")"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL_XML}</string>
    <key>ProgramArguments</key>
    <array>
${PROGRAM_ARGS}
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>${HOUR}</integer>
        <key>Minute</key>
        <integer>${MINUTE}</integer>
    </dict>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${LOG_XML}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_XML}</string>
</dict>
</plist>
EOF

log "wrote $PLIST"

# ----------------------------------------------------------------------------
# (Re)load the agent. bootout first (ignore "not loaded") so re-runs are clean.
# ----------------------------------------------------------------------------
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" \
  || die "launchctl bootstrap failed for $PLIST (check the plist and $LOG_FILE)"

log "loaded '$LABEL' — runs daily at $(printf '%02d:%02d' "$HOUR" "$MINUTE") local time"
log "logs: $LOG_FILE"

# ----------------------------------------------------------------------------
# Print a copy-pasteable command to test the alarm now, without waiting.
# ----------------------------------------------------------------------------
TEST_CMD="bash $(printf '%q' "$ALARM")"
for arg in ${FWD_ARGS[@]+"${FWD_ARGS[@]}"}; do
  TEST_CMD="$TEST_CMD $(printf '%q' "$arg")"
done
log "test it now (without waiting for the schedule):"
echo "    $TEST_CMD"
