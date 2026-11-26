#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product TORCSMac
bin_dir="$(swift build -c release --show-bin-path)"
app_dir="$PWD/build/TORCSMac.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/TORCSMac" "$app_dir/Contents/MacOS/TORCSMac"
# Every package resource bundle the app links, and none of the test ones.
# The render path's shaders live in TORCSMac_TORCSRender.bundle; without it
# beside the executable the app only finds them through the build
# directory baked into the binary, which a shipped copy does not have.
render_bundle="$bin_dir/TORCSMac_TORCSRender.bundle"
[[ -d "$render_bundle" ]] || { echo "missing $render_bundle" >&2; exit 1; }
rm -rf "$app_dir/Contents/Resources"/TORCSMac_*.bundle
for bundle in "$bin_dir"/TORCSMac_*.bundle; do
    name="$(basename "$bundle" .bundle)"
    # Only packages that still exist: a stale bundle from a deleted package
    # lingers in the build directory and must not ship.
    [[ -d "Packages/${name#TORCSMac_}" ]] || continue
    cp -R "$bundle" "$app_dir/Contents/Resources/"
done
# Prebuilt shader library: no compilation at launch, no stalls in a race.
Scripts/build-shaders.sh "$app_dir/Contents/Resources/TORCSMac_TORCSRender.bundle/Shaders/TORCSRender.metallib"
cp LICENSE THIRD_PARTY_NOTICES.md "$app_dir/Contents/Resources/"
# The icon, drawn by the app itself so it matches the screens.
iconset="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset"
"$bin_dir/TORCSMac" --render-icon "$iconset/icon_512x512@2x.png"
for size in 16 32 128 256 512; do
    sips -z $size $size "$iconset/icon_512x512@2x.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size*2))
    [[ $size -eq 512 ]] || sips -z $double $double "$iconset/icon_512x512@2x.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$iconset")"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TORCSMac</string>
<key>CFBundleIdentifier</key><string>org.torcs.mac</string>
<key>CFBundleName</key><string>TORCS</string>
<key>CFBundleDisplayName</key><string>TORCS</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSApplicationCategoryType</key><string>public.app-category.racing-games</string>
<key>LSSupportsGameMode</key><true/>
<key>GCSupportsGameMode</key><true/>
</dict></plist>
PLIST
if [[ -n "${TORCS_SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$TORCS_SIGN_IDENTITY" "$app_dir"
else
    codesign --force --sign - "$app_dir"
fi
codesign --verify --strict "$app_dir"
echo "Built $app_dir"
