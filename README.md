# Media Alarm

A small, dependency-light macOS tool that wakes you (or anything else) on a daily
schedule: at a chosen local time it opens a URL in the browser/app you pick,
optionally connects Bluetooth speaker(s) and routes audio, then slowly **ramps the
volume up from silence** so you don't get jolted awake.

Two modes: a **single-speaker** ramp of the system volume (the default), and a
**multi-speaker** mode that plays to several speakers at once (via a Multi-Output
Device) and ramps each one independently.

It's built from shell scripts plus a generated `launchd` LaunchAgent (and, for
multi-speaker mode, a tiny CoreAudio helper compiled at install). The original use
case is a 6 AM YouTube live stream as a gentle alarm — just the default config.

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
  - `--audio-output` / `--multi-output` → [`switchaudio-osx`](https://github.com/deweller/switchaudio-osx)
- **Xcode Command Line Tools** (`swiftc`) — only for **multi-speaker mode**, to
  compile the bundled `device-volume.swift` helper at install. `install.sh` errors
  with `xcode-select --install` if it's missing. Single-speaker mode needs no build
  tools.
- **`mpv` + `yt-dlp`** — only for the **`--player mpv`** backend (plays the stream
  locally at the live edge). `install.sh` auto-installs both via Homebrew when you
  pass `--player mpv`. The default browser backend needs neither.
- With just built-in speakers (no `--bt-device`/`--audio-output`/`--multi-output`),
  **no Homebrew or Xcode tools are required at all.**

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
| `--browser <app>` | `Arc` | App name passed to `open -a` (browser backend). |
| `--player <browser\|mpv>` | `browser` | Playback backend. `mpv` plays the stream locally at the **live edge** (needs `mpv`+`yt-dlp`); `browser` opens `--url` in `--browser`. |
| `--bt-device <id>` | *(none)* | Bluetooth name or MAC to connect. **Repeatable.** Requires `blueutil`. |
| `--audio-output <name>` | *(none)* | Single-speaker: output device to route to. Requires `SwitchAudioSource`. |
| `--multi-output <name>` | *(none)* | Multi-speaker: Multi-Output Device to select. Enables multi mode. Mutually exclusive with `--audio-output`. |
| `--ramp-speaker <id>` | *(none)* | Multi-speaker: CoreAudio device **name or UID** to ramp. **Repeatable.** Requires `--multi-output`. |
| `--start-volume <0-100>` | `0` | Volume before the ramp. |
| `--target-volume <0-100>` | `60` | Volume the ramp climbs to. |
| `--ramp-seconds <n>` | `180` | Ramp duration in seconds. |
| `--connect-timeout <n>` | `20` | Seconds to wait per Bluetooth connection. |
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

## Always-live playback (`--player mpv`)

By default the alarm opens the URL in a browser — but a YouTube **live** stream can
resume *in the past* there, because YouTube's DVR remembers where you left off. The
`mpv` backend avoids that entirely:

```sh
bash install.sh --hour 6 --minute 0 \
  --url "https://www.youtube.com/@markets/live" \
  --player mpv \
  --bt-device a8-e6-e8-8d-19-92 --audio-output "SRS-XB100" \
  --target-volume 60 --ramp-seconds 180
```

- `mpv` plays the stream locally via `yt-dlp`, which starts at the **live edge** —
  no browser, no DVR resume, no extension.
- It opens an `mpv` **video window** at full mpv volume; the usual volume **ramp
  still governs loudness** (system volume in single-speaker mode, per-speaker in
  multi-speaker mode). `--browser` is ignored in this mode.
- mpv keeps playing after the ramp finishes — the agent's plist sets
  `AbandonProcessGroup` so launchd doesn't kill it. Stop it with `pkill mpv` or by
  closing its window.
- Needs `mpv` + `yt-dlp`, auto-installed by `install.sh` when you pass `--player mpv`.

## Multiple speakers (per-device ramp)

macOS can only play to one Bluetooth speaker at a time *unless* you combine them
into a **Multi-Output Device**, and a Multi-Output Device has no master volume — so
the system-volume ramp can't drive it. Multi-speaker mode works around this by
ramping each member speaker individually through a small CoreAudio helper.

One-time setup, in **Audio MIDI Setup** (Applications → Utilities):

1. Click **+** → **Create Multi-Output Device**.
2. Tick the speakers you want to play to together.
3. Leave **drift correction** off for the clock/master device and on for the
   others.
4. Give it a name (e.g. `BedroomMulti`).

Then install with `--multi-output` (the Multi-Output Device) and one
`--ramp-speaker` per speaker you want ramped (using the speakers' **CoreAudio**
names — see below):

```sh
bash install.sh --hour 6 --minute 0 \
  --url "https://www.youtube.com/@markets/live" --browser Arc \
  --bt-device "Speaker A" --bt-device "Speaker B" \
  --multi-output "BedroomMulti" \
  --ramp-speaker "Speaker A" --ramp-speaker "Speaker B" \
  --target-volume 60 --ramp-seconds 180
```

This compiles the `device-volume.swift` helper (needs Xcode Command Line Tools),
connects each `--bt-device`, selects the Multi-Output Device, and ramps each
`--ramp-speaker` from start to target.

**Two speakers of the same model?** They share both a Bluetooth name and a
CoreAudio name, so names can't tell them apart. Connect them by **MAC address** and
ramp them by **UID**:

```sh
bash install.sh --hour 6 --minute 0 \
  --url "https://www.youtube.com/@markets/live" --browser Arc \
  --bt-device a8-e6-e8-8d-19-92 --bt-device a8-e6-e8-b5-8d-0c \
  --multi-output "SonySpeakerPair" \
  --ramp-speaker "A8-E6-E8-8D-19-92:output" --ramp-speaker "A8-E6-E8-B5-8D-0C:output" \
  --target-volume 60 --ramp-seconds 180
```

Get the MACs with `blueutil --paired` and the UIDs with `device-volume list`.

> **Will your speaker actually ramp?** Per-device ramp only works on speakers that
> honor macOS volume changes (AVRCP). Some Bluetooth speakers ignore them. The tool
> **probes each `--ramp-speaker` and warns** if it doesn't take. The definitive
> check: connect the speaker, play audio, press the volume keys — if loudness
> changes, it'll ramp.

## Finding device names

```sh
blueutil --paired                  # Bluetooth names / MAC addresses (for --bt-device)
SwitchAudioSource -a -t output     # audio output names (for --audio-output / --multi-output)
./device-volume list               # "<name>\t<uid>" per output (for --ramp-speaker; after building)
```

The Bluetooth identifier (`--bt-device`) and the audio output / ramp-speaker name
(`--audio-output`, `--multi-output`, `--ramp-speaker`) are often the same string
but not always — `blueutil` matches the Bluetooth name/MAC, while
`SwitchAudioSource`/`device-volume` match the CoreAudio output name. `--ramp-speaker`
also accepts a **UID** (from `device-volume list`), which is the only way to tell
apart two speakers that share a name.

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
- **System volume vs. player volume.** In single-speaker mode the ramp controls
  macOS *system* output volume; in multi-speaker mode it sets each speaker's own
  CoreAudio volume. Either way, leave the site's own player at 100% so the ramp is
  the only thing governing loudness.
- **Multi-speaker mode** needs a Multi-Output Device created once in Audio MIDI
  Setup and the Xcode Command Line Tools (`swiftc`) at install time, and per-speaker
  ramp depends on each speaker honoring macOS volume changes (see
  [Multiple speakers](#multiple-speakers-per-device-ramp)).

## License

[MIT](LICENSE).
