#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 /absolute/path/to/thumosd" >&2
  exit 64
fi

binary_path="$1"
plist_path="$HOME/Library/LaunchAgents/io.thumos.daemon.plist"
log_dir="$HOME/Library/Logs/ThumOS"

mkdir -p "$HOME/Library/LaunchAgents" "$log_dir"

cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>io.thumos.daemon</string>

  <key>ProgramArguments</key>
  <array>
    <string>${binary_path}</string>
    <string>--hid-record</string>
    <string>--hid-product</string>
    <string>Creator</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <true/>

  <key>StandardOutPath</key>
  <string>${log_dir}/thumosd.out.log</string>

  <key>StandardErrorPath</key>
  <string>${log_dir}/thumosd.err.log</string>
</dict>
</plist>
PLIST

echo "Wrote $plist_path"
echo "Load it with:"
echo "  launchctl bootstrap gui/$(id -u) $plist_path"
echo "  launchctl enable gui/$(id -u)/io.thumos.daemon"
echo "  launchctl kickstart gui/$(id -u)/io.thumos.daemon"
