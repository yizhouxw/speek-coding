#!/bin/sh
set -eu

APP_RESOURCES="${SPEEK_APP_RESOURCES:-/Applications/SpeekCoding.app/Contents/Resources}"
NODE="$APP_RESOURCES/runtime/node/bin/node"
CLI="$APP_RESOURCES/cli/index.mjs"

if [ ! -x "$NODE" ] || [ ! -f "$CLI" ]; then
	printf 'SpeekCoding runtime is incomplete. Reinstall SpeekCoding.pkg.\n' >&2
	exit 69
fi

exec "$NODE" "$CLI" "$@"
