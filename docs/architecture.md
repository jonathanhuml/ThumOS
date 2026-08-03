# ThumOS Architecture

## Current Scope

The first implementation records Creator Micro 2 Pro commands as local events.

The daemon reads macOS HID events through IOKit and filters to the physical Work Louder Creator device. This lets ThumOS distinguish a Creator key mapped to `Return` from the regular keyboard `Return`.

The shortcut/event-tap path remains available as a fallback for experiments, but it should not be the default because global keyboard events do not reliably identify the physical device.

## Components

- `thumosd`: headless recorder process.
- `creator-micro-2.json`: command mapping config.
- `events.sqlite3`: append-only local event log.
- Future menu-bar app: status, data display, config editing, export, and Bluetooth headset controls.

## Event Flow

1. User presses a Creator key.
2. macOS emits an IOKit HID input value for the Work Louder device.
3. `thumosd` filters the event by physical device metadata.
4. A `press`, `release`, or `value` row is inserted into SQLite.

## SQLite Schema

```sql
CREATE TABLE input_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  source TEXT NOT NULL,
  device_name TEXT,
  command_id TEXT NOT NULL,
  command_label TEXT NOT NULL,
  event_type TEXT NOT NULL,
  key_code INTEGER NOT NULL,
  modifiers INTEGER NOT NULL,
  occurred_at_utc TEXT NOT NULL,
  monotonic_ns INTEGER NOT NULL,
  active_app_bundle_id TEXT,
  raw_payload TEXT
);
```

## Future Bluetooth Headset Layer

Bluetooth headset support should be a separate service module. It can write headset connection events to a sibling table, but it should not be coupled to Creator command capture.
