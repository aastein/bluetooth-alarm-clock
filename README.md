# Media Alarm

A small, dependency-light macOS tool that wakes you (or anything else) on a daily
schedule: at a chosen local time it opens a URL in the browser/app you pick,
optionally connects a Bluetooth audio device and routes system output to it, then
slowly **ramps the volume up from silence** so you don't get jolted awake.

It's built from two shell scripts and a generated `launchd` LaunchAgent — no
daemons, no frameworks, no special permissions. The original use case is a 6 AM
YouTube live stream as a gentle alarm, which is just the default configuration.

## How it works

- **`alarm.sh`** performs one alarm run: connect Bluetooth → route audio → mute →
  open the URL → ramp the volume. It's driven entirely by flags.
- **`install.sh`** generates `~/Library/LaunchAgents/<label>.plist` from the flags
  you pass and loads it with `launchctl`, so the OS runs `alarm.sh` every day at
  the scheduled local time.

## Requirements

- **macOS.** Uses the built-in `open` and `osascript`.
- **[Homebrew](https://brew.sh)** — only if you use the optional Bluetooth/audio
  features. `install.sh` will auto-install the specific tools you need:
  - `--bt-device` → [`blueutil`](https://github.com/toy/blueutil)
  - `--audio-output` → [`switchaudio-osx`](https://github.com/deweller/switchaudio-osx)
- With just built-in speakers (no `--bt-device`/`--audio-output`), **no Homebrew
  is required at all.**

> **Dependency errors are explicit.** `alarm.sh` never installs anything at run
> time — if a tool you configured is missing it exits with the exact
> `brew install …` command to run. `install.sh` is the only place that installs,
> and only the dependencies your flags actually use.

## Quick start

Pair your Bluetooth device once in **System Settings → Bluetooth** first (the tool
connects an already-paired device; it does not pair). Then:

```sh
bash install.sh --hour 6 --minute 0 \
  --url "https://www.youtube.com/@markets/live" --browser Arc \
  --bt-device "Bedroom Speaker" --audio-output "Bedroom Speaker" \
  --target-volume 60 --ramp-seconds 180
```

If you passed `--bt-device`, `install.sh` probes Bluetooth once so macOS shows
its one-time *"blueutil would like to use Bluetooth"* prompt now — click
**Allow** (see [Notes & caveats](#notes--caveats)). It then prints a
copy-pasteable command to **test the alarm immediately** without waiting for the
schedule. You can also just run `alarm.sh` directly with the same flags (see
below).

## `alarm.sh` flags

| Flag | Default | Description |
|---|---|---|
| `--url <url>` | `https://www.youtube.com/@markets/live` | URL to open. |
| `--browser <app>` | `Arc` | App name passed to `open -a`. |
| `--bt-device <id>` | *(none)* | Bluetooth name or MAC to connect. Empty = skip Bluetooth. Requires `blueutil`. |
| `--audio-output <name>` | *(none)* | Output device to route to. Empty = skip. Requires `SwitchAudioSource`. |
| `--start-volume <0-100>` | `0` | System volume before the ramp. |
| `--target-volume <0-100>` | `60` | Volume the ramp climbs to. |
| `--ramp-seconds <n>` | `180` | Ramp duration in seconds. |
| `--connect-timeout <n>` | `20` | Seconds to wait for the Bluetooth connection. |
| `-h`, `--help` | | Show help. |

Bluetooth and audio routing are **best-effort**: if the device can't connect in
time, the alarm logs a warning and still plays (through whatever output is
current) rather than aborting.

## `install.sh` flags

All `alarm.sh` flags above are accepted and forwarded into the LaunchAgent, plus:

| Flag | Default | Description |
|---|---|---|
| `--hour <0-23>` | `6` | Hour to fire (local time). |
| `--minute <0-59>` | `0` | Minute to fire. |
| `--label <reverse-dns>` | `local.media-alarm` | LaunchAgent label and plist filename. |
| `--log-file <path>` | `$HOME/Library/Logs/<label>.log` | Where stdout/stderr go. |
| `--uninstall` | | Unload and remove the agent for `--label`, then exit. |
| `-h`, `--help` | | Show help. |

## Finding device names

```sh
blueutil --paired           # Bluetooth device names / MAC addresses
SwitchAudioSource -a -t output   # exact audio output device names
```

The Bluetooth identifier (`--bt-device`) and the audio output name
(`--audio-output`) are usually the same string, but not always — `blueutil`
matches the Bluetooth name/MAC, while `SwitchAudioSource` matches the name shown
in **System Settings → Sound**.

## Testing without waiting

```sh
bash alarm.sh --url "https://www.youtube.com/@markets/live" --browser Arc \
  --bt-device "Bedroom Speaker" --audio-output "Bedroom Speaker" \
  --target-volume 60 --ramp-seconds 180
```

When the LaunchAgent runs it, output is captured to the log file shown by
`install.sh` (default `$HOME/Library/Logs/<label>.log`).

## Uninstall

```sh
bash install.sh --uninstall --label local.media-alarm
```

## Notes & caveats

- **Local time only.** The schedule fires at the given hour/minute in the Mac's
  local timezone. There is no timezone anchoring — if you change the system
  timezone, the fire time follows it.
- **The Mac must be awake at the scheduled time.** This tool does not wake the
  machine from sleep. Keep it awake (e.g. disable sleep, or lid open on power) if
  you depend on the alarm.
- **One alarm per `--label`.** To run several alarms, install again with a
  different `--label` (and `--log-file`).
- **No keyboard/screen permissions.** It does not script keystrokes or clicks,
  so no Accessibility/Automation permission is needed. Playback relies on the
  page autoplaying when opened.
- **One-time Bluetooth permission** (only with `--bt-device`). The first time
  `blueutil` touches Bluetooth, macOS shows a *"blueutil would like to use
  Bluetooth"* prompt. `install.sh` triggers this during install (a harmless
  read-only probe) so you can click **Allow** while you're there — otherwise it
  would appear at the first scheduled run, with nobody around to approve it, and
  the connect would silently fall back to the built-in speakers. The grant is
  tied to `blueutil`, so it persists for the scheduled run. If it ever
  re-prompts or the connect silently fails, enable `blueutil` manually under
  **System Settings → Privacy & Security → Bluetooth**.
- **System volume vs. player volume.** The ramp controls macOS *system* output
  volume. Leave the site's own player at 100% so the ramp is the only thing
  governing loudness.

## License

[MIT](LICENSE).
