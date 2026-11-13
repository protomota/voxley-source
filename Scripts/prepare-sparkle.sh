#!/bin/bash
set -euo pipefail

version=2.10.1
checksum=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
folder="${1:?Pass the absolute Sparkle cache directory on Expand}/sparkle-$version"
[[ "$folder" == /Volumes/Expand/* ]] || { echo 'Choose a Sparkle cache on Expand.' >&2; exit 1; }
mkdir -p "$folder"
archive="Sparkle-$version.tar.xz"
(
    cd "$folder"
    if [[ ! -f "$archive" ]]; then
        curl --fail --silent --show-error --location --retry 2 \
            "https://github.com/sparkle-project/Sparkle/releases/download/$version/$archive" -o "$archive.part"
        mv "$archive.part" "$archive"
    fi
    printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c >&2
    tar -xf "$archive"
)
printf '%s\n' "$folder"
