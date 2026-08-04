# ThumOS

ThumOS is a lightweight local recorder for Creator Micro 2 Pro commands.

The first version is a headless macOS daemon. It reads the Creator as a physical HID device and writes Creator-origin press/release events to SQLite.

## Build

```sh
make
```

## Initialize

```sh
make init
```

This creates:

- `~/.config/thumos/creator-micro-2.json`
- `~/Library/Application Support/ThumOS/events.sqlite3`

## Identify The Creator

```sh
make list-hid
```

The Creator should appear similar to:

```text
manufacturer="Work Louder" product="Creator Micro 2"
```

## Run HID Discovery

```sh
make discover-hid
```

Press a Creator key and a regular keyboard key. Only Creator events should print because the command filters to devices whose product/manufacturer contains `Creator`.

## Run In The Foreground

```sh
make run
```

This runs:

```sh
build/thumosd --hid-record --hid-product Creator
```

## macOS App

Build the macOS app:

```sh
make app
```

Open it:

```sh
make open-ui
```

ThumOS opens as a normal macOS app and also appears in the menu bar.

- The main window has a `Session Recording` switch, Muse controls, output-folder selection, a session dropdown, and waveform viewing.
- The menu-bar item opens a compact popover with the same recording controls.
- Closing the window hides it; the app keeps running.
- Quitting ThumOS from the app menu exits the UI, so the menu-bar item disappears.
- Recording is controlled by the app. Turning it on creates one session folder and starts an in-process Creator HID monitor plus Muse EEG when Muse is connected.
- macOS must allow ThumOS in `System Settings > Privacy & Security > Input Monitoring` for Creator Recording.
- `Show Data` opens a read-only view of the selected session's Creator events.
- `Export CSV` saves the selected session's Creator events to a CSV file.
- `Connect Muse` uses native CoreBluetooth to find and prepare a Muse headset.
- `View Waveform` draws the selected session's Muse EEG with Creator annotations.

The app bundle includes its own copy of `thumosd` for command-line diagnostics at:

```text
build/ThumOS.app/Contents/MacOS/thumosd
```

Session folders are saved under the selected output folder. The default is:

```text
~/Documents/ThumOS Sessions/
```

Each session folder contains:

- `creator-events.csv`
- `muse-eeg.csv`
- `annotations.csv`
- `session.json`

The Muse connector uses the ZUNA WebBluetooth Muse constants:

- BLE service `0000fe8d-0000-1000-8000-00805f9b34fb`
- Control channel `273e0001-4c4d-454d-96be-f03bac821358`
- EEG channels `TP9`, `AF7`, `AF8`, `TP10`
- ZUNA's Muse packet decoder, saved as one CSV row per decoded channel sample

## Creator Annotations

During a session, ThumOS annotates Creator HID sequences:

- `keyboard.return` -> `yes`
- `keyboard.down-arrow`, `keyboard.down-arrow`, `keyboard.return` -> `no`
- `keyboard.down-arrow`, `keyboard.return` -> `allow permission`
- `command` + `keyboard.right-arrow` alternates `talk start` and `talk end`

## Shortcut Fallback

In Work Louder Input, map the Creator buttons to the shortcuts in `config/creator-micro-2.json`.

The default config uses rare macOS function-key combinations:

- `Control + Option + Command + F13` through `F20`
- `Control + Option + Command + Shift + F13` through `F17`

Those thirteen mappings represent Creator keys `K01` through `K13`.

```sh
build/thumosd --request-permission
build/thumosd --print-events
```

macOS must grant Accessibility permission before global shortcut monitoring works. HID recording does not use this shortcut fallback.

## Optional LaunchAgent

```sh
make install-launch-agent
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.thumos.daemon.plist
launchctl enable gui/$(id -u)/io.thumos.daemon
launchctl kickstart gui/$(id -u)/io.thumos.daemon
```

Logs are written to:

- `~/Library/Logs/ThumOS/thumosd.out.log`
- `~/Library/Logs/ThumOS/thumosd.err.log`

The LaunchAgent path is optional. The macOS app does not need it for normal recording.

## Inspect Events

```sh
sqlite3 "$HOME/Library/Application Support/ThumOS/events.sqlite3" \
  "select occurred_at_utc, source, device_name, command_id, event_type from input_events order by id desc limit 20;"
```

The event database lives at:

```text
~/Library/Application Support/ThumOS/events.sqlite3
```

Clear recorded events:

```sh
make clear-events
```

## Later UI

The future config UI should be a small menu-bar app that reads this SQLite database and edits the JSON command map. Bluetooth headset connection can be added as a separate capability without changing the event log schema.
