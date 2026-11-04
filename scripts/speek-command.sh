#!/bin/bash
set -euo pipefail
umask 077

STATE_DIR="${SPEEK_STATE_DIR:-/tmp/speek-coding-$(/usr/bin/id -u)}"
SOCKET_PATH="${SPEEK_AGENT_SOCKET:-$STATE_DIR/agent.sock}"
if [ -n "${SPEEK_CODING_APP:-}" ]; then
	APP_PATH="$SPEEK_CODING_APP"
elif [ -d "/Applications/SpeekCoding.app" ]; then
	APP_PATH="/Applications/SpeekCoding.app"
else
	APP_PATH="$HOME/Applications/SpeekCoding.app"
fi
TOKEN_PATH="${SPEEK_IPC_TOKEN:-$HOME/.config/speek-coding/ipc-token}"
LOG="$STATE_DIR/command.log"

/bin/mkdir -p "$STATE_DIR"

command_name="${1:-toggle}"
command_source="${2:-karabiner}"
if [ "$command_name" = "route" ]; then
	command_name="${3:-toggle}"
fi

case "$command_name" in
save | start)
	command_name="save"
	;;
watch | stop)
	command_name="watch"
	;;
toggle | cancel | status | permissions)
	;;
confirm | preconfirm | open-window)
	# Compatibility with 0.1 Karabiner rules while an update is being applied.
	command_name="toggle"
	;;
*)
	printf 'unsupported SpeekCoding command: %s\n' "$command_name" >>"$LOG"
	exit 64
	;;
esac

case "$command_source" in
fn | dji | karabiner | compatibility)
	;;
*)
	command_source="karabiner"
	;;
esac

if [ ! -S "$SOCKET_PATH" ]; then
	if [ ! -d "$APP_PATH" ]; then
		printf 'SpeekCoding.app not found: %s\n' "$APP_PATH" >>"$LOG"
		exit 127
	fi
	/usr/bin/open -gj "$APP_PATH"
	for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
		[ -S "$SOCKET_PATH" ] && break
		/bin/sleep 0.1
	done
fi

if [ ! -S "$SOCKET_PATH" ]; then
	printf 'SpeekCoding IPC socket not ready: %s\n' "$SOCKET_PATH" >>"$LOG"
	exit 69
fi

current_uid="$(/usr/bin/id -u)"
directory_uid="$(/usr/bin/stat -f '%u' "$STATE_DIR" 2>/dev/null || true)"
directory_mode="$(/usr/bin/stat -f '%Lp' "$STATE_DIR" 2>/dev/null || true)"
socket_uid="$(/usr/bin/stat -f '%u' "$SOCKET_PATH" 2>/dev/null || true)"
socket_mode="$(/usr/bin/stat -f '%Lp' "$SOCKET_PATH" 2>/dev/null || true)"
socket_type="$(/usr/bin/stat -f '%HT' "$SOCKET_PATH" 2>/dev/null || true)"
if [ -L "$STATE_DIR" ] || [ "$directory_uid" != "$current_uid" ] || [ "$directory_mode" != "700" ] ||
	[ -L "$SOCKET_PATH" ] || [ "$socket_uid" != "$current_uid" ] || [ "$socket_mode" != "600" ] ||
	[ "$socket_type" != "Socket" ]; then
	printf 'unsafe SpeekCoding IPC endpoint: %s\n' "$SOCKET_PATH" >>"$LOG"
	exit 77
fi

if [ ! -r "$TOKEN_PATH" ]; then
	printf 'SpeekCoding IPC credential not found: %s\n' "$TOKEN_PATH" >>"$LOG"
	exit 77
fi
token="$(/usr/bin/tr -d '[:space:]' <"$TOKEN_PATH")"
printf '{"command":"%s","source":"%s","token":"%s"}\n' "$command_name" "$command_source" "$token" |
	/usr/bin/nc -U "$SOCKET_PATH" >/dev/null 2>>"$LOG"
