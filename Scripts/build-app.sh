#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-/Volumes/Expand/Codex Media/Voxley}"
[[ -d /Volumes/Expand ]] || { echo 'Mount Expand before building Voxley.' >&2; exit 1; }
[[ "$output" == /Volumes/Expand/* ]] || { echo 'Choose an output directory on Expand.' >&2; exit 1; }
mkdir -p "$output/Build/tmp" "$output/Build/modules" "$output/Build/cache"
export TMPDIR="$output/Build/tmp/"
export CLANG_MODULE_CACHE_PATH="$output/Build/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$output/Build/modules"
args=(--package-path "$root" --scratch-path "$output/Build/swiftpm" --cache-path "$output/Build/cache")
app="$output/Voxley.app"
identity="${VOXLEY_SIGNING_IDENTITY:-}"
if [[ -z "$identity" && -d "$app" ]]; then
    signing_info="$(/usr/bin/codesign -d --verbose=2 "$app" 2>&1)"
    identity="$(sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' <<< "$signing_info")"
    if [[ -z "$identity" && "$signing_info" != *"Signature=adhoc"* ]]; then
        echo "Couldn’t read Voxley’s existing signing identity. Set VOXLEY_SIGNING_IDENTITY and try again." >&2
        exit 1
    fi
fi
if [[ -n "$identity" && "$identity" != "-" ]] &&
   ! /usr/bin/security find-identity -v -p codesigning "$HOME/Library/Keychains/login.keychain-db" | /usr/bin/grep -Fq "\"$identity\""; then
    echo "Voxley’s signing identity is not available in the login keychain. The installed app was left intact." >&2
    exit 1
fi
signing_flags=(--timestamp=none)
sparkle=''
if [[ "${VOXLEY_RELEASE:-0}" == 1 ]]; then
    [[ "$identity" == "Developer ID Application: "* ]] || { echo 'A Developer ID Application identity is required for distribution.' >&2; exit 1; }
    signing_flags=(--timestamp --options runtime)
    sparkle="$(bash "$root/Scripts/prepare-sparkle.sh" '/Volumes/Expand/Codex Media/Voxley/Build')"
    args+=(-Xswiftc -DVOXLEY_SPARKLE -Xswiftc -F -Xswiftc "$sparkle"
           -Xlinker -F -Xlinker "$sparkle" -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
fi
xcrun swift build "${args[@]}" -c release
bin="$(xcrun swift build "${args[@]}" -c release --show-bin-path)"
mkdir -p "$app/Contents/MacOS"
install -m 755 "$bin/Voxley" "$app/Contents/MacOS/Voxley"
install -m 644 "$root/Scripts/Info.plist" "$app/Contents/Info.plist"
iconset="$output/Build/tmp/AppIcon.iconset"
mkdir -p "$iconset" "$app/Contents/Resources"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$root/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    twice=$((size * 2))
    /usr/bin/sips -z "$twice" "$twice" "$root/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
if [[ -n "$sparkle" ]]; then
    /usr/libexec/PlistBuddy -c "Merge '$root/Scripts/Sparkle.plist'" "$app/Contents/Info.plist"
    install -m 644 "$sparkle/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"
    install -m 644 "$root/Packaging/macOS/background.tiff" "$app/Contents/Resources/VoxleyInstallerBackground.tiff"
    framework="$app/Contents/Frameworks/Sparkle.framework"
    ditto "$sparkle/Sparkle.framework" "$framework"
    for component in "$framework/Versions/Current/XPCServices/"*.xpc \
        "$framework/Versions/Current/Autoupdate" "$framework/Versions/Current/Updater.app" "$framework"; do
        /usr/bin/codesign --force --sign "$identity" --keychain "$HOME/Library/Keychains/login.keychain-db" "${signing_flags[@]}" "$component"
    done
    signing_flags+=(--entitlements "$root/Scripts/VoxleyRelease.entitlements")
fi
if [[ -n "$identity" && "$identity" != "-" ]]; then
    /usr/bin/codesign --force --sign "$identity" --keychain "$HOME/Library/Keychains/login.keychain-db" "${signing_flags[@]}" "$app"
else
    /usr/bin/codesign --force --sign - "$app"
fi
/usr/bin/codesign --verify --deep --strict "$app"
echo "$app"
