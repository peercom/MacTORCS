#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product TORCSMac
bin_dir="$(swift build -c release --show-bin-path)"
app_dir="$PWD/build/TORCSMac.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/TORCSMac" "$app_dir/Contents/MacOS/TORCSMac"
cp -R "$bin_dir/TORCSMac_TORCSMetal.bundle" "$app_dir/Contents/Resources/"
cp LICENSE THIRD_PARTY_NOTICES.md "$app_dir/Contents/Resources/"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TORCSMac</string>
<key>CFBundleIdentifier</key><string>org.torcs.mac</string>
<key>CFBundleName</key><string>TORCS Mac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSApplicationCategoryType</key><string>public.app-category.racing-games</string>
</dict></plist>
PLIST
if [[ -n "${TORCS_SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$TORCS_SIGN_IDENTITY" "$app_dir"
else
    codesign --force --sign - "$app_dir"
fi
codesign --verify --strict "$app_dir"
echo "Built $app_dir"
