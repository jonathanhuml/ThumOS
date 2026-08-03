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

## Run In The Background

```sh
make install-launch-agent
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.thumos.daemon.plist
launchctl enable gui/$(id -u)/io.thumos.daemon
launchctl kickstart gui/$(id -u)/io.thumos.daemon
```

Logs are written to:

- `~/Library/Logs/ThumOS/thumosd.out.log`
- `~/Library/Logs/ThumOS/thumosd.err.log`

## Inspect Events

```sh
sqlite3 "$HOME/Library/Application Support/ThumOS/events.sqlite3" \
  "select occurred_at_utc, source, device_name, command_id, event_type from input_events order by id desc limit 20;"
```

## Later UI

The future config UI should be a small menu-bar app that reads this SQLite database and edits the JSON command map. Bluetooth headset connection can be added as a separate capability without changing the event log schema.
