#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
output="/Volumes/Expand/Codex Media/Voxley"
[[ -d /Volumes/Expand ]] || { echo 'Mount Expand before testing Voxley.' >&2; exit 1; }
mkdir -p "$output/Build/tmp" "$output/Build/modules" "$output/Build/cache"
export TMPDIR="$output/Build/tmp/"
export CLANG_MODULE_CACHE_PATH="$output/Build/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$output/Build/modules"
if [[ "${1:-}" == --with-models ]]; then
    export VOXLEY_TEST_AUDIO="$output/Build/tmp/apple-model-test.aiff"
    /usr/bin/say -v Samantha -o "$VOXLEY_TEST_AUDIO" 'Please bring the purple elephant sketch to the meeting.'
fi
xcrun swift test --no-parallel --package-path "$root" --scratch-path "$output/Build/swiftpm" --cache-path "$output/Build/cache"
