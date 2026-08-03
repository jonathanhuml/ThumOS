#!/bin/sh
set -eu

database_path="${1:-$HOME/Library/Application Support/ThumOS/events.sqlite3}"

if [ ! -f "$database_path" ]; then
  echo "No event database found at $database_path"
  exit 0
fi

sqlite3 "$database_path" <<'SQL'
.timeout 5000
DELETE FROM input_events;
.output /dev/null
PRAGMA wal_checkpoint(TRUNCATE);
SQL

echo "Cleared events from $database_path"
