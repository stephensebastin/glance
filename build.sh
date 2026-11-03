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

# --install: copy to ~/Applications and register a LaunchAgent that starts it at login and restarts
# it within seconds whenever it stops, however it stopped. To stop it until the next login, use
# "Quit until next login" in its right-click menu, or: launchctl bootout gui/$(id -u)/local.claudepeek
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
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
AGENTPLIST
  launchctl bootstrap "$DOMAIN" "$AGENT"
  echo "Installed $DEST; it now starts at login and restarts whenever it stops."
elif [[ "${1:-}" == "--run" ]]; then
  # Pause the installed copy so the two don't fight; ./build.sh --install (or the next login) brings it back.
  launchctl bootout "gui/$(id -u)/local.claudepeek" 2>/dev/null && echo "Paused the installed copy until --install or next login." || true
  pkill -x ClaudePeek 2>/dev/null && sleep 1 || true
  open "$APP"
fi
