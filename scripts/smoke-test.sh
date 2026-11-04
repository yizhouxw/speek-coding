#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT

mkdir -p "$TMP_HOME/.config/karabiner"
printf '%s\n' '{"profiles":[{"name":"Default profile","selected":true,"complex_modifications":{"rules":[]}}]}' \
	>"$TMP_HOME/.config/karabiner/karabiner.json"

export DJI_INSTALLER_HOME="$TMP_HOME"
export DJI_KARABINER_CLI=/usr/bin/true
export SPEEK_LAUNCHCTL=/usr/bin/true
export SPEEK_STATE_DIR="$TMP_HOME/tmp/speek-coding"
export SPEEK_LEGACY_STATE_DIR="$TMP_HOME/tmp/speek-coding-legacy"
export SPEEK_CODESIGN_IDENTITY=-
export SPEEK_ALLOW_ADHOC_SIGNING=1
export SPEEK_SKIP_AGENT_HEALTHCHECK=1
export SPEEK_SKIP_LAUNCHSERVICES_REGISTER=1
export DJI_PERMISSION_CHECK_JSON='{"status":"ok","microphone":"granted","accessibility":"granted","postEvent":"granted"}'

cd "$REPO_ROOT"
node ./cli/index.mjs setup --skip-asr --yes --json \
	--trigger-mode keyboard --fake-transcript "smoke test" >/dev/null
node ./cli/index.mjs status --json >/dev/null
node ./cli/index.mjs uninstall --yes --json >/dev/null

test ! -e "$TMP_HOME/.config/speek-coding/install-state.json"
test ! -e "$TMP_HOME/.config/speek-coding/venv"
test ! -e "$TMP_HOME/Library/LaunchAgents/com.speek.coding.asr.plist"

printf 'Speek lifecycle smoke test passed.\n'
