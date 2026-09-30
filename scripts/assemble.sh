#!/bin/sh
# Bundle assembly, used by BOTH `mise install` and `mise release` so the app you
# run and the app you ship can never diverge.
#   scripts/assemble.sh <destination.app>     (VERSION in the environment)
# The .app bundle exists for ONE reason: UNUserNotificationCenter refuses
# unbundled processes. Assembled by hand (no Xcode). The notifier is a second,
# nested .app (Contents/Helpers/awake-notifier.app): the notification hop needs
# an LS-launched user-context app, and the daemon is a launchd agent by design.
# Same icon, own bundle id, its own Info.plist.
set -e
dest="$1"
[ -n "$dest" ] || { echo "usage: scripts/assemble.sh <destination.app>"; exit 1; }
[ -n "$VERSION" ] || { echo "VERSION is not set"; exit 1; }
helper="$dest/Contents/Helpers/awake-notifier.app"
mkdir -p "$dest/Contents/MacOS" "$dest/Contents/Resources"
ditto .build/release/awake "$dest/Contents/MacOS/awake"
ditto Resources/awake.icns "$dest/Contents/Resources/awake.icns"
# The agent skill ships in the bundle; `awake skill install` links it into the
# agents on the Mac, so an upgrade of the app is an upgrade of the skill.
ditto skill "$dest/Contents/Resources/skill"
sed "s|__VERSION__|$VERSION|g" launchd/Info.plist.in > "$dest/Contents/Info.plist"
# The agent's plist lives IN the bundle, registered by SMAppService (Agent.swift):
# launchd runs whatever image sits at the bundle's path, so it follows upgrades.
# Per-user paths cannot appear in it; the daemon points its own output at its log.
mkdir -p "$dest/Contents/Library/LaunchAgents"
ditto launchd/garden.untitled.awake.plist "$dest/Contents/Library/LaunchAgents/garden.untitled.awake.plist"
mkdir -p "$helper/Contents/MacOS" "$helper/Contents/Resources"
ditto .build/release/awake-notifier "$helper/Contents/MacOS/awake-notifier"
ditto Resources/awake.icns "$helper/Contents/Resources/awake.icns"
sed "s|__VERSION__|$VERSION|g" launchd/Notifier-Info.plist.in > "$helper/Contents/Info.plist"
