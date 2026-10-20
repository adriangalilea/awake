#!/bin/sh
# Bundle assembly, used by `mise install`, `mise dev` and the release so the
# app you run and the app you ship can never diverge.
#   scripts/assemble.sh <destination.app>     (VERSION in the environment)
# BUNDLE_ID names the app, its notifier (`<id>.notifier`) and its agent: the
# release's by default, the development build's (`garden.untitled.awake.dev`,
# "awake Dev") for local installs (Sources/AwakeKit/Claim.swift, Identity).
# CONFIG picks the SwiftPM build to bundle (release, or debug for the loop).
# The .app bundle exists for ONE reason: UNUserNotificationCenter refuses
# unbundled processes. Assembled by hand (no Xcode). The notifier is a second,
# nested .app (Contents/Helpers/awake-notifier.app): the notification hop needs
# an LS-launched user-context app, and the daemon is a launchd agent by design.
# Same icon, own bundle id, its own Info.plist.
set -e
dest="$1"
[ -n "$dest" ] || { echo "usage: scripts/assemble.sh <destination.app>"; exit 1; }
[ -n "$VERSION" ] || { echo "VERSION is not set"; exit 1; }
id="${BUNDLE_ID:-garden.untitled.awake}"
name="${BUNDLE_NAME:-awake}"
config="${CONFIG:-release}"
helper="$dest/Contents/Helpers/awake-notifier.app"
mkdir -p "$dest/Contents/MacOS" "$dest/Contents/Resources"
ditto ".build/$config/awake" "$dest/Contents/MacOS/awake"
ditto Resources/awake.icns "$dest/Contents/Resources/awake.icns"
# The glass icon (CFBundleIconName); the icns above is its flat fallback.
ditto Resources/Assets.car "$dest/Contents/Resources/Assets.car"
# The agent skill ships in the bundle; `awake skill install` links it into the
# agents on the Mac, so an upgrade of the app is an upgrade of the skill.
ditto skill "$dest/Contents/Resources/skill"
stamp() { sed -e "s|__VERSION__|$VERSION|g" -e "s|__BUNDLE_ID__|$id|g" -e "s|__NAME__|$name|g" "$1"; }
stamp launchd/Info.plist.in > "$dest/Contents/Info.plist"
# The agent's plist lives IN the bundle, registered by SMAppService (Agent.swift):
# launchd runs whatever image sits at the bundle's path, so it follows upgrades.
# Per-user paths cannot appear in it; the daemon points its own output at its log.
mkdir -p "$dest/Contents/Library/LaunchAgents"
stamp launchd/agent.plist.in > "$dest/Contents/Library/LaunchAgents/$id.plist"
mkdir -p "$helper/Contents/MacOS" "$helper/Contents/Resources"
ditto ".build/$config/awake-notifier" "$helper/Contents/MacOS/awake-notifier"
ditto Resources/awake.icns "$helper/Contents/Resources/awake.icns"
stamp launchd/Notifier-Info.plist.in > "$helper/Contents/Info.plist"
