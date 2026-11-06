#!/bin/bash
set -euo pipefail

PACKAGE_PATH="${1:-}"
EXPECTED_ARCH="${2:-$(/usr/bin/uname -m)}"

if [ -z "$PACKAGE_PATH" ] || [ ! -f "$PACKAGE_PATH" ]; then
	printf 'usage: %s <SpeekCoding.pkg> [arm64|x86_64]\n' "$0" >&2
	exit 64
fi

TMP_DIR="$(/usr/bin/mktemp -d -t speek-coding-package-verify)"
trap '/bin/rm -rf "$TMP_DIR"' EXIT

/usr/sbin/pkgutil --expand-full "$PACKAGE_PATH" "$TMP_DIR/expanded"
PAYLOAD_ROOT="$(/usr/bin/find "$TMP_DIR/expanded" -type d -name Payload -print -quit)"
PACKAGE_INFO="$(/usr/bin/find "$TMP_DIR/expanded" -type f -name PackageInfo -print -quit)"
APP="$PAYLOAD_ROOT/Applications/SpeekCoding.app"
RESOURCES="$APP/Contents/Resources"
NODE="$RESOURCES/runtime/node/bin/node"
PYTHON="$RESOURCES/runtime/python/bin/python3"
HUD="$RESOURCES/bin/speek-hud"
CLI="$RESOURCES/cli/index.mjs"
LAUNCHER="$PAYLOAD_ROOT/usr/local/bin/speek"
NODE_LICENSE="$RESOURCES/licenses/Node.js-LICENSE"
THIRD_PARTY_NOTICES="$RESOURCES/THIRD_PARTY_NOTICES.md"

for path in "$APP" "$RESOURCES/SpeekCoding.icns" "$NODE" "$PYTHON" "$HUD" "$CLI" "$LAUNCHER" "$NODE_LICENSE" "$THIRD_PARTY_NOTICES"; do
	[ -e "$path" ] || {
		printf 'missing package payload: %s\n' "$path" >&2
		exit 1
	}
done

/usr/bin/grep -q 'relocatable="false"' "$PACKAGE_INFO"

/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/file "$APP/Contents/MacOS/SpeekCoding" "$NODE" "$PYTHON" "$HUD" |
	/usr/bin/grep -q "$EXPECTED_ARCH"

PATH=/usr/bin:/bin "$NODE" --version >/dev/null
PATH=/usr/bin:/bin "$PYTHON" -B -c 'import faster_whisper; print(faster_whisper.__version__)' >/dev/null
if [ "$EXPECTED_ARCH" = "arm64" ]; then
	PATH=/usr/bin:/bin "$PYTHON" -B -c 'import mlx.core, mlx_qwen3_asr' >/dev/null
fi
PATH=/usr/bin:/bin "$NODE" "$CLI" --version >/dev/null
/usr/bin/codesign --verify --deep --strict "$APP"

/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" |
	/usr/bin/grep -qx 'com.speek.coding'
/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" |
	/usr/bin/grep -qx 'SpeekCoding'
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist" |
	/usr/bin/grep -qx 'SpeekCoding'

printf 'Verified self-contained SpeekCoding package for %s: %s\n' "$EXPECTED_ARCH" "$PACKAGE_PATH"
