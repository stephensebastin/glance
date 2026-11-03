#!/bin/zsh
# Builds ClaudePeek.app next to this script. Usage: ./build.sh [--run | --install]
set -euo pipefail
cd "${0:A:h}"

APP=ClaudePeek.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" -o "$APP/Contents/MacOS/ClaudePeek" Sources/main.swift 2>&1 \
  | grep -v "warning:" || true
[[ -x "$APP/Contents/MacOS/ClaudePeek" ]] || { echo "build failed"; exit 1; }

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Peek</string>
  <key>CFBundleIdentifier</key><string>local.claudepeek</string>
  <key>CFBundleExecutable</key><string>ClaudePeek</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $PWD/$APP"

# --install: copy to ~/Applications and register a LaunchAgent so it starts at login and is
# restarted if it crashes or is killed. Quitting with × (a clean exit) keeps it closed until the
# next login, or until you run: launchctl kickstart gui/$(id -u)/local.claudepeek
if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/ClaudePeek.app"
  AGENT="$HOME/Library/LaunchAgents/local.claudepeek.plist"
  DOMAIN="gui/$(id -u)"
  launchctl bootout "$DOMAIN/local.claudepeek" 2>/dev/null || true
  pkill -x ClaudePeek 2>/dev/null && sleep 1 || true
  mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  cat > "$AGENT" <<AGENTPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.claudepeek</string>
  <key>Program</key><string>$DEST/Contents/MacOS/ClaudePeek</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
AGENTPLIST
  launchctl bootstrap "$DOMAIN" "$AGENT"
  echo "Installed $DEST; it now starts at login and restarts if it stops unexpectedly."
elif [[ "${1:-}" == "--run" ]]; then
  pkill -x ClaudePeek 2>/dev/null && sleep 1 || true
  open "$APP"
fi
