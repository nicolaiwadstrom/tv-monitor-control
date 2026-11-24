#!/bin/zsh
# Builds TVMonitorControl.app (menu-bar app, no Dock icon) next to this script.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/TVMonitorControl"

APP="TVMonitorControl.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TVMonitorControl"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.local.TVMonitorControl</string>
    <key>CFBundleName</key><string>TV Monitor Control</string>
    <key>CFBundleExecutable</key><string>TVMonitorControl</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.5</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Controls your TVs on the local network when the Mac's displays sleep or wake.</string>
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST

# LaunchAgent registered at runtime through SMAppService (menu: "Run as background service").
mkdir -p "$APP/Contents/Library/LaunchAgents"
cat > "$APP/Contents/Library/LaunchAgents/dev.local.TVMonitorControl.agent.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>dev.local.TVMonitorControl.agent</string>
    <key>BundleProgram</key><string>Contents/MacOS/TVMonitorControl</string>
    <key>AssociatedBundleIdentifiers</key>
    <array><string>dev.local.TVMonitorControl</string></array>
    <key>RunAtLoad</key><true/>
    <!-- Restart after a crash or kill; a normal Quit (exit 0) stays quit. -->
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>5</integer>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Library/LaunchAgents/dev.local.TVMonitorControl.agent.plist" "$APP/Contents/Info.plist"

codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
