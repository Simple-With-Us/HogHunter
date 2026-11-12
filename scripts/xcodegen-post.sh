#!/bin/bash
# Run by XcodeGen after it writes the project (options.postGenCommand).
#
# Points this checkout's default DerivedData at the internal disk.  This Mac's
# global Xcode setting keeps DerivedData on an external volume.  A Debug build is
# signed ad hoc, so every build is a new app to macOS, and a Debug app or test
# host run from a removable volume asks "HogHunter would like to access files on
# a removable volume" as it launches; Allow never lasts past the next build.  An
# explicit -derivedDataPath still wins, which is what Release and CI use.
# Record: docs/rollouts/2026-11-04-tcc-prompts-and-code-identity.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# One folder per checkout, so lanes do not share products.
KEY="$(printf '%s' "$ROOT" | /usr/bin/shasum -a 256 | /usr/bin/cut -c1-12)"
LOCATION="$HOME/Library/Caches/HogHunterDerivedData/$(basename "$ROOT")-$KEY"
# The per-user file, not xcshareddata: xcodebuild ignores this setting in the
# shared one.  It is generated and git-ignored along with the rest of the project.
SETTINGS_DIR="$ROOT/HogHunter.xcodeproj/project.xcworkspace/xcuserdata/$(/usr/bin/id -un).xcuserdatad"

# XML-escaped: a path with &, < or > would otherwise break the plist.
LOCATION_XML="$(printf '%s' "$LOCATION" | /usr/bin/sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"

/bin/mkdir -p "$SETTINGS_DIR"
/bin/cat > "$SETTINGS_DIR/WorkspaceSettings.xcsettings" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>BuildLocationStyle</key>
	<string>UseAppPreferences</string>
	<key>DerivedDataCustomLocation</key>
	<string>$LOCATION_XML</string>
	<key>DerivedDataLocationStyle</key>
	<string>AbsolutePath</string>
</dict>
</plist>
PLIST
