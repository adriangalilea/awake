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
sed "s|__VERSION__|$VERSION|g" launchd/Info.plist.in > "$dest/Contents/Info.plist"
mkdir -p "$helper/Contents/MacOS" "$helper/Contents/Resources"
ditto .build/release/awake-notifier "$helper/Contents/MacOS/awake-notifier"
ditto Resources/awake.icns "$helper/Contents/Resources/awake.icns"
sed "s|__VERSION__|$VERSION|g" launchd/Notifier-Info.plist.in > "$helper/Contents/Info.plist"
