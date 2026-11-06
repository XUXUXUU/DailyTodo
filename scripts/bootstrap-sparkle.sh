#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=2.10.1
checksum=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
destination="$PWD/Vendor/Sparkle"
if [[ -f "$destination/.archive-sha256" && -f "$destination/Sparkle.framework/Sparkle" && "$(cat "$destination/.archive-sha256")" == "$checksum" ]]; then
    exit 0
fi
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
curl --fail --location --silent --show-error --retry 3 --connect-timeout 20 --max-time 600 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" \
    -o "$temporary/sparkle.tar.xz"
printf '%s  %s\n' "$checksum" "$temporary/sparkle.tar.xz" | shasum -a 256 -c -
tar -xJf "$temporary/sparkle.tar.xz" -C "$temporary"
mkdir -p "$destination"
ditto "$temporary/Sparkle.framework" "$destination/Sparkle.framework"
ditto "$temporary/bin" "$destination/bin"
cp "$temporary/LICENSE" "$destination/LICENSE"
printf '%s' "$checksum" > "$destination/.archive-sha256"
