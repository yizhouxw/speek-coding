#!/bin/bash
set -euo pipefail
# Shared by source installs, package builds and validation. Statically link NativeInput.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:?Usage: build-native-app.sh OUTPUT [swiftc options]}"
shift
# Source installs and checks must not silently inherit the build host's OS minimum.
if [[ $# -eq 0 ]]; then set -- -target "$(uname -m)-apple-macosx13.0"; fi
SWIFTC="${SWIFTC_BIN:-/usr/bin/swiftc}"
TMP_DIR="$(/usr/bin/mktemp -d -t speek-native-build)"
trap '/bin/rm -rf "$TMP_DIR"' EXIT
"$SWIFTC" "$REPO_ROOT"/NativeInput/Sources/NativeInput/*.swift -O "$@" \
    -emit-library -static -emit-module -module-name NativeInput \
    -emit-module-path "$TMP_DIR/NativeInput.swiftmodule" -o "$TMP_DIR/libNativeInput.a"
"$SWIFTC" "$REPO_ROOT/scripts/speek-coding-app.swift" -O "$@" \
    -I "$TMP_DIR" -L "$TMP_DIR" -lNativeInput -o "$OUTPUT" \
    -framework AppKit -framework AVFoundation -framework ApplicationServices \
    -framework CoreAudio -framework CoreGraphics -framework IOKit
