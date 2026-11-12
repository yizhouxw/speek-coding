#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

TMP_DIR="$(/usr/bin/mktemp -d -t speek-coding-validate)"
trap '/bin/rm -rf "$TMP_DIR"' EXIT

bash -n scripts/speek-command.sh
bash -n scripts/ensure-signing-identity.sh
bash -n scripts/build-package.sh
bash -n scripts/verify-package.sh
bash -n scripts/package-smoke-test.sh
bash -n scripts/speek-package-launcher.sh
/usr/bin/plutil -lint app/Info.plist app/SpeekCoding.entitlements packaging/components.plist >/dev/null
PYTHONPYCACHEPREFIX="$TMP_DIR/pycache" python3 -m py_compile scripts/local-asr-server.py scripts/generate-license-notices.py
swiftc scripts/speek-hud.swift -O -o "$TMP_DIR/speek-hud-validate"
"$TMP_DIR/speek-hud-validate" --layout-self-test
bash -n scripts/build-native-app.sh
scripts/build-native-app.sh "$TMP_DIR/speek-coding-app-validate"
# Explicitly sign the temporary executable before macOS validates it on launch.
/usr/bin/codesign --force --sign "${SPEEK_VALIDATION_CODESIGN_IDENTITY:--}" "$TMP_DIR/speek-coding-app-validate"
/usr/bin/codesign --verify --strict "$TMP_DIR/speek-coding-app-validate"
"$TMP_DIR/speek-coding-app-validate" --localization-self-test
"$TMP_DIR/speek-coding-app-validate" --license-self-test licenses/LICENSES.txt
python3 -B test/qwen-streaming.py --native-client "$TMP_DIR/speek-coding-app-validate"
node --check cli/index.mjs
for file in cli/lib/*.mjs; do
	node --check "$file"
done
node -e "JSON.parse(require('fs').readFileSync('karabiner/dji-mic-mini.json', 'utf8'))"
swift test --package-path NativeInput --scratch-path "$TMP_DIR/native-input-build"
npm run lint --silent
git diff --check
