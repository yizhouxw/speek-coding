#!/bin/bash
set -euo pipefail

PACKAGE_PATH="${1:-}"
if [ -z "$PACKAGE_PATH" ] || [ ! -f "$PACKAGE_PATH" ]; then
	printf 'usage: %s <SpeekCoding.pkg>\n' "$0" >&2
	exit 64
fi

TMP_DIR="$(/usr/bin/mktemp -d -t speek-coding-package-smoke)"
trap '/bin/rm -rf "$TMP_DIR"' EXIT
/usr/sbin/pkgutil --expand-full "$PACKAGE_PATH" "$TMP_DIR/expanded"
PAYLOAD_ROOT="$(/usr/bin/find "$TMP_DIR/expanded" -type d -name Payload -print -quit)"
APP="$PAYLOAD_ROOT/Applications/SpeekCoding.app"
RESOURCES="$APP/Contents/Resources"
LAUNCHER="$PAYLOAD_ROOT/usr/local/bin/speek"
TEST_HOME="$TMP_DIR/home"

/bin/mkdir -p "$TEST_HOME/.config/karabiner"
/usr/bin/printf '%s\n' '{"profiles":[{"name":"Default profile","selected":true,"complex_modifications":{"rules":[]}}]}' \
	>"$TEST_HOME/.config/karabiner/karabiner.json"

export PATH=/usr/bin:/bin
export SPEEK_APP_RESOURCES="$RESOURCES"
export DJI_INSTALLER_HOME="$TEST_HOME"
export DJI_KARABINER_CLI=/usr/bin/true
export SPEEK_LAUNCHCTL=/usr/bin/true
export SPEEK_STATE_DIR="$TEST_HOME/tmp/speek-coding"
export SPEEK_LEGACY_STATE_DIR="$TEST_HOME/tmp/speek-coding-legacy"
export SPEEK_SKIP_AGENT_HEALTHCHECK=1
export SPEEK_SKIP_LAUNCHSERVICES_REGISTER=1
export PYTHON3_BIN="$TMP_DIR/missing-python3"
export SWIFTC_BIN="$TMP_DIR/missing-swiftc"
export DJI_PERMISSION_CHECK_JSON='{"status":"ok","microphone":"granted","accessibility":"granted","postEvent":"granted"}'

"$LAUNCHER" setup --yes --json --trigger-mode keyboard --fake-transcript 'package smoke' >/dev/null
"$LAUNCHER" status --json >/dev/null

CONFIG_FILE="$TEST_HOME/.config/speek-coding/config.env"
/usr/bin/grep -F "/Applications/SpeekCoding.app/Contents/Resources/runtime/python/bin/python3'" "$CONFIG_FILE" >/dev/null
[ ! -e "$TEST_HOME/.config/speek-coding/venv" ]

"$LAUNCHER" uninstall --yes --json >/dev/null
[ -d "$APP" ]
[ ! -e "$TEST_HOME/.config/speek-coding/install-state.json" ]
/usr/bin/codesign --verify --deep --strict "$APP"

printf 'Speek packaged lifecycle smoke test passed without system Node.js, Python, or swiftc.\n'
