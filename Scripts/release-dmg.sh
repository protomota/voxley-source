#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:?Usage: Scripts/release-dmg.sh RELEASE_DIRECTORY NOTARYTOOL_OPTIONS...}"
shift
[[ "$output" == /Volumes/Expand/* && -d "$output/Voxley.app" && $# -gt 0 ]] || {
    echo 'Supply a signed release directory on Expand and notarytool authentication options.' >&2
    exit 1
}
base='/Volumes/Expand/Codex Media/Voxley/Build'
mkdir -p "$base/tmp"
export TMPDIR="$base/tmp/"
python="${VOXLEY_DMG_PYTHON:-$base/dmg-tools/bin/python}"
app="$output/Voxley.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
identity="$(codesign -d --verbose=2 "$app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p')"
[[ -n "$identity" ]] || { echo 'A Developer ID signed Voxley.app is required.' >&2; exit 1; }
image="$output/Voxley-$version.dmg"
packager=("$python" "$root/Scripts/package-mac-dmg.py" --app "$app" --output "$image")
if [[ -f "$image" ]]; then
    "${packager[@]}" --verify-only
else
    "${packager[@]}"
fi
if ! xcrun stapler validate "$image" >/dev/null 2>&1; then
    codesign --force --timestamp --sign "$identity" "$image"
    xcrun notarytool submit "$image" "$@" --wait --output-format json > "${image%.dmg}.notarization.json"
    /usr/bin/plutil -extract status raw -expect string "${image%.dmg}.notarization.json" | /usr/bin/grep -Fx Accepted
    xcrun stapler staple "$image"
fi
codesign --verify --strict "$image"
xcrun stapler validate "$image"
spctl --assess --type open --context context:primary-signature --verbose=2 "$image"
"${packager[@]}" --verify-only

sparkle="$(bash "$root/Scripts/prepare-sparkle.sh" "$base")"
account=voxley-direct
public_key=$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$app/Contents/Info.plist")
[[ "$("$sparkle/bin/generate_keys" --account "$account" -p)" == "$public_key" ]] || {
    echo 'The Sparkle signing key does not match this app.' >&2
    exit 1
}
"$sparkle/bin/generate_appcast" --account "$account" --maximum-deltas 0 \
    --download-url-prefix https://voxley.si/downloads/ "$output"
signature="$(xmllint --xpath 'string(//enclosure/@*[local-name()="edSignature"])' "$output/appcast.xml")"
"$sparkle/bin/sign_update" --account "$account" --verify "$image" "$signature"
"$sparkle/bin/sign_update" --account "$account" --verify "$output/appcast.xml"
(cd "$output" && shasum -a 256 "$(basename "$image")" > SHA256SUMS)
printf '%s\n' "$image"
