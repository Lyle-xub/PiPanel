#!/bin/bash

set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
dist_dir="$root_dir/dist"
derived_data="${PIPANEL_DERIVED_DATA:-/tmp/PiPanelReleaseDerivedData}"
identity="${1:-${PIPANEL_SIGN_IDENTITY:-}}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$root_dir/PiPanel/App/Info.plist")"
archive_name="PiPanel-${version}-macOS-universal"
work_dir="$(mktemp -d /tmp/pipanel-release.XXXXXX)"
stage_dir="$work_dir/dmg-root"
mount_dir="$work_dir/mount"
rw_dmg="$work_dir/PiPanel-rw.dmg"
final_dmg="$dist_dir/$archive_name.dmg"
final_zip="$dist_dir/$archive_name.zip"
app_path="$dist_dir/PiPanel.app"
app_icon="$app_path/Contents/Resources/AppIcon.icns"

# A release signed ad hoc gets a designated requirement made only of its current CDHashes. The
# next build therefore looks like a different application to macOS and causes every existing
# Keychain item and privacy permission to ask for authorization again. Never silently produce a
# distributable package with that identity. `--adhoc` remains available for explicit local-only
# smoke testing, while production packaging requires an installed Developer ID certificate.
if [[ "$identity" == "--adhoc" ]]; then
    identity="-"
elif [[ -z "$identity" ]]; then
    identity="$(
        security find-identity -v -p codesigning \
            | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' \
            | head -n 1
    )"
fi

if [[ -z "$identity" ]]; then
    echo "No Developer ID Application signing identity is installed." >&2
    echo "Install a Developer ID Application certificate with its private key in Keychain." >&2
    echo "For a local-only build, explicitly pass --adhoc." >&2
    exit 78
fi

if [[ "$identity" != "-" && "$identity" != Developer\ ID\ Application:* ]]; then
    echo "Release packaging requires a Developer ID Application identity." >&2
    echo "For a local-only build, explicitly pass --adhoc." >&2
    exit 78
fi

cleanup() {
    # /tmp is a symlink to /private/tmp, so matching `mount` output against mount_dir is brittle.
    # hdiutil detach is safe to try unconditionally and makes failed Finder scripting recoverable.
    hdiutil detach "$mount_dir" -force >/dev/null 2>&1 || true
    rm -rf "$work_dir"
}
trap cleanup EXIT

mkdir -p "$dist_dir" "$stage_dir/.background" "$mount_dir"
rm -rf "$app_path"
rm -f "$final_dmg" "$final_zip" "$dist_dir/SHA256SUMS"

echo "Building PiPanel $version (Release, arm64 + x86_64)…"
xcodebuild \
    -project "$root_dir/PiPanel.xcodeproj" \
    -scheme PiPanel \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    build

ditto "$derived_data/Build/Products/Release/PiPanel.app" "$app_path"
xattr -cr "$app_path"

# SwiftUI's VideoPlayer compiles against the private _AVKit_SwiftUI overlay, but optimized release
# builds can omit the parent AVKit framework unless it is an explicit target dependency. Such an
# app passes compilation and signing, then aborts in getSuperclassMetadata when onboarding first
# constructs VideoPlayer. Refuse to package that broken binary again.
if ! otool -L "$app_path/Contents/MacOS/PiPanel" | rg -q '/AVKit\.framework/'; then
    echo "Release executable is missing its explicit AVKit.framework dependency" >&2
    exit 1
fi

"$root_dir/scripts/sign_release_app.sh" "$app_path" "$identity"

if [[ "$(lipo -archs "$app_path/Contents/MacOS/PiPanel")" != *arm64* ]] \
    || [[ "$(lipo -archs "$app_path/Contents/MacOS/PiPanel")" != *x86_64* ]]; then
    echo "Release executable is not universal" >&2
    exit 1
fi

if rg --files "$app_path" | rg -q '(\.debug\.dylib$|\.swiftmodule/)'; then
    echo "Debug-only build artifacts found in release app" >&2
    exit 1
fi

echo "Rendering Arc-inspired DMG background…"
swift -module-cache-path "$work_dir/swift-module-cache" \
    "$root_dir/scripts/render_dmg_background.swift" \
    "$stage_dir/.background/background.png"
ditto "$app_path" "$stage_dir/PiPanel.app"
ln -s /Applications "$stage_dir/Applications"
cp "$app_icon" "$stage_dir/.VolumeIcon.icns"

hdiutil create \
    -volname PiPanel \
    -fs HFS+ \
    -format UDRW \
    -srcfolder "$stage_dir" \
    -ov \
    "$rw_dmg" >/dev/null

hdiutil attach "$rw_dmg" \
    -mountpoint "$mount_dir" \
    -readwrite \
    -noverify \
    -noautoopen >/dev/null

set_file="$(xcrun --find SetFile)"
de_rez="$(xcrun --find DeRez)"
rez="$(xcrun --find Rez)"
"$set_file" -a V "$mount_dir/.background" "$mount_dir/.VolumeIcon.icns"
"$set_file" -a C "$mount_dir"

osascript <<APPLESCRIPT
tell application "Finder"
    set dmgFolder to POSIX file "$mount_dir" as alias
    open dmgFolder
    delay 1
    set dmgWindow to container window of dmgFolder
    set current view of dmgWindow to icon view
    -- Finder occasionally reports these cosmetic properties as temporarily read-only while a
    -- newly-mounted image is still settling. They must never abort an otherwise valid release.
    try
        set toolbar visible of dmgWindow to false
    end try
    try
        set statusbar visible of dmgWindow to false
    end try
    try
        set pathbar visible of dmgWindow to false
    end try
    -- Finder's bounds include its 32 pt title bar; keep a full 660 × 420 content area visible.
    set bounds of dmgWindow to {120, 120, 780, 572}
    set viewOptions to icon view options of dmgWindow
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set text size of viewOptions to 12
    set background picture of viewOptions to file ".background:background.png" of dmgFolder
    set position of item "PiPanel.app" of dmgFolder to {172, 226}
    set position of item "Applications" of dmgFolder to {488, 226}
    update dmgFolder without registering applications
    delay 2
    try
        close dmgWindow
    end try
end tell
APPLESCRIPT

sync
hdiutil detach "$mount_dir" >/dev/null
hdiutil convert "$rw_dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$final_dmg" >/dev/null
hdiutil verify "$final_dmg" >/dev/null

# `.VolumeIcon.icns` controls the icon of the mounted volume. Finder stores the icon of the DMG
# file itself in a custom `icns` resource, so attach the same AppIcon there as well. This makes
# locally distributed/copied release artifacts visually match PiPanel before they are mounted.
cp "$app_icon" "$work_dir/AppIcon.icns"
sips -i "$work_dir/AppIcon.icns" >/dev/null
"$de_rez" -only icns "$work_dir/AppIcon.icns" > "$work_dir/AppIcon.r"
(
    cd "$work_dir"
    "$rez" AppIcon.r -append -o "$final_dmg"
)
"$set_file" -a C "$final_dmg"
hdiutil verify "$final_dmg" >/dev/null

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$final_zip"

(
    cd "$dist_dir"
    shasum -a 256 "$(basename "$final_dmg")" "$(basename "$final_zip")" > SHA256SUMS
)

codesign --verify --deep --strict --verbose=2 "$app_path"

echo "Release artifacts ready:"
echo "  $final_dmg"
echo "  $final_zip"
echo "  $dist_dir/SHA256SUMS"
