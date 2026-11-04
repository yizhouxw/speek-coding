#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

TARGET_ARCH="${SPEEK_PACKAGE_ARCH:-$(/usr/bin/uname -m)}"
OUTPUT_DIR="${SPEEK_PACKAGE_OUTPUT_DIR:-$REPO_ROOT/dist}"
NODE_VERSION="22.23.1"
PYTHON_VERSION="3.12.12"
PYTHON_BUILD="20260211"
PYTHON_SOURCE="${SPEEK_PYTHON_SOURCE:-archive}"
MACOS_TARGET="${SPEEK_MACOS_TARGET:-13.0}"
APP_SIGNING_IDENTITY="${SPEEK_APP_SIGNING_IDENTITY:--}"
APP_SIGNING_TIMESTAMP="${SPEEK_APP_SIGNING_TIMESTAMP:-1}"
if [ "${SPEEK_RELEASE:-0}" != "1" ] && [ -z "${SPEEK_APP_SIGNING_IDENTITY+x}" ]; then
	LOCAL_SIGNING_IDENTITY="$( { /usr/bin/security find-identity -v -p codesigning 2>/dev/null || true; } | /usr/bin/awk 'index($0, "\"SpeekCoding Local Code Signing\"") && !found { print $2; found = 1 }')"
	if [ -n "$LOCAL_SIGNING_IDENTITY" ]; then
		APP_SIGNING_IDENTITY="$LOCAL_SIGNING_IDENTITY"
		APP_SIGNING_TIMESTAMP="${SPEEK_APP_SIGNING_TIMESTAMP:-0}"
	fi
fi
INSTALLER_SIGNING_IDENTITY="${SPEEK_INSTALLER_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${SPEEK_NOTARY_PROFILE:-}"
VERSION="$(/usr/bin/awk -F '"' '/"version"/ { print $4; exit }' package.json)"

case "$TARGET_ARCH" in
arm64)
	NODE_ARCH="arm64"
	NODE_SHA256="ef28d8fab2c0e4314522d4bb1b7173270aa3937e93b92cb7de79c112ac1fa953"
	PYTHON_ARCH="aarch64"
	PYTHON_SHA256="22625deaf5757e7c266cf1a096c9151a06b598b1e14632a2ec9993d58ec5fe84"
	;;
x86_64)
	NODE_ARCH="x64"
	NODE_SHA256="b8da981b8a0b1241b70249204916da76c63573ddf5814dbd2d1e41069105cb81"
	PYTHON_ARCH="x86_64"
	PYTHON_SHA256="a84ac7a36d465bc6eb68db84540fdb5da04333900e2c3cb34b5d454f2022048c"
	;;
*)
	printf 'unsupported package architecture: %s\n' "$TARGET_ARCH" >&2
	exit 64
	;;
esac

if [ "$TARGET_ARCH" != "$(/usr/bin/uname -m)" ]; then
	printf 'cross-architecture packaging is not supported; run this script on a %s Mac\n' "$TARGET_ARCH" >&2
	exit 64
fi

for command in curl npm pkgbuild shasum swiftc; do
	command -v "$command" >/dev/null 2>&1 || {
		printf 'build dependency not found: %s\n' "$command" >&2
		exit 69
	}
done

if [ "${SPEEK_RELEASE:-0}" = "1" ] && [ "$APP_SIGNING_IDENTITY" = "-" ]; then
	printf 'release builds require SPEEK_APP_SIGNING_IDENTITY with a Developer ID Application identity\n' >&2
	exit 64
fi
if [ "${SPEEK_RELEASE:-0}" = "1" ] && [ -z "$INSTALLER_SIGNING_IDENTITY" ]; then
	printf 'release builds require SPEEK_INSTALLER_SIGNING_IDENTITY with a Developer ID Installer identity\n' >&2
	exit 64
fi
if [ "${SPEEK_RELEASE:-0}" = "1" ] && [ -z "$NOTARY_PROFILE" ]; then
	printf 'release builds require SPEEK_NOTARY_PROFILE for notarization\n' >&2
	exit 64
fi

BUILD_DIR="$REPO_ROOT/build/package-$TARGET_ARCH"
CACHE_DIR="$REPO_ROOT/build/cache"
ROOT_DIR="$BUILD_DIR/root"
APP="$ROOT_DIR/Applications/SpeekCoding.app"
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"
RUNTIME="$RESOURCES/runtime"
PACKAGE_PATH="$OUTPUT_DIR/SpeekCoding-$VERSION-$TARGET_ARCH.pkg"

/bin/rm -rf "$BUILD_DIR"
/bin/mkdir -p "$CACHE_DIR" "$CONTENTS/MacOS" "$RESOURCES/bin" "$RUNTIME" "$ROOT_DIR/usr/local/bin" "$OUTPUT_DIR"

download() {
	local url="$1"
	local destination="$2"
	if [ ! -f "$destination" ]; then
		printf 'Downloading %s\n' "$url"
		/usr/bin/curl --fail --location --retry 5 --retry-all-errors --output "$destination.part" "$url"
		/bin/mv "$destination.part" "$destination"
	fi
}

verify_sha256() {
	local expected="$1"
	local file="$2"
	local actual
	actual="$(/usr/bin/shasum -a 256 "$file" | /usr/bin/awk '{ print $1 }')"
	if [ "$actual" != "$expected" ]; then
		printf 'checksum mismatch for %s\nexpected: %s\nactual:   %s\n' "$file" "$expected" "$actual" >&2
		exit 65
	fi
}

NODE_ASSET="node-v$NODE_VERSION-darwin-$NODE_ARCH.tar.gz"
NODE_ARCHIVE="$CACHE_DIR/$NODE_ASSET"
download "https://nodejs.org/download/release/v$NODE_VERSION/$NODE_ASSET" "$NODE_ARCHIVE"
verify_sha256 "$NODE_SHA256" "$NODE_ARCHIVE"
/usr/bin/tar -xzf "$NODE_ARCHIVE" -C "$BUILD_DIR"
/bin/mkdir -p "$RUNTIME/node/bin"
/bin/cp "$BUILD_DIR/node-v$NODE_VERSION-darwin-$NODE_ARCH/bin/node" "$RUNTIME/node/bin/node"
/bin/mkdir -p "$RESOURCES/licenses"
/bin/cp "$BUILD_DIR/node-v$NODE_VERSION-darwin-$NODE_ARCH/LICENSE" "$RESOURCES/licenses/Node.js-LICENSE"
/bin/chmod 755 "$RUNTIME/node/bin/node"

PYTHON_ASSET="cpython-$PYTHON_VERSION+$PYTHON_BUILD-$PYTHON_ARCH-apple-darwin-install_only_stripped.tar.gz"
PYTHON_ARCHIVE="$CACHE_DIR/$PYTHON_ASSET"
PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/$PYTHON_BUILD/cpython-$PYTHON_VERSION%2B$PYTHON_BUILD-$PYTHON_ARCH-apple-darwin-install_only_stripped.tar.gz"
if [ "$PYTHON_SOURCE" = "uv" ]; then
	command -v uv >/dev/null 2>&1 || {
		printf 'SPEEK_PYTHON_SOURCE=uv requires uv on the build machine\n' >&2
		exit 69
	}
	UV_PYTHON_DIR="$CACHE_DIR/uv-python-$TARGET_ARCH"
	uv python install "$PYTHON_VERSION" --install-dir "$UV_PYTHON_DIR" --no-bin --native-tls --no-progress
	/usr/bin/ditto \
		"$UV_PYTHON_DIR/cpython-$PYTHON_VERSION-macos-$PYTHON_ARCH-none" \
		"$RUNTIME/python"
elif [ "$PYTHON_SOURCE" = "archive" ]; then
	download "$PYTHON_URL" "$PYTHON_ARCHIVE"
	verify_sha256 "$PYTHON_SHA256" "$PYTHON_ARCHIVE"
	/usr/bin/tar -xzf "$PYTHON_ARCHIVE" -C "$RUNTIME"
else
	printf 'unsupported SPEEK_PYTHON_SOURCE: %s (expected archive or uv)\n' "$PYTHON_SOURCE" >&2
	exit 64
fi
BUNDLED_PYTHON="$RUNTIME/python/bin/python3"
PYTHON_SITE_PACKAGES="$(PATH=/usr/bin:/bin "$BUNDLED_PYTHON" -c 'import sysconfig; print(sysconfig.get_path("purelib"))')"
PIP_PLATFORM="macosx_${MACOS_TARGET/./_}_$TARGET_ARCH"
PATH=/usr/bin:/bin "$BUNDLED_PYTHON" -m pip install \
	--disable-pip-version-check \
	--break-system-packages \
	--no-compile \
	--no-cache-dir \
	--require-hashes \
	--only-binary=:all: \
	--platform "$PIP_PLATFORM" \
	--target "$PYTHON_SITE_PACKAGES" \
	--upgrade \
	--requirement packaging/requirements-asr.txt
/usr/bin/find "$RUNTIME/python" -type d -name __pycache__ -prune -exec /bin/rm -rf {} +

/bin/cp app/Info.plist "$CONTENTS/Info.plist"
/bin/cp app/SpeekCoding.icns "$RESOURCES/SpeekCoding.icns"
/bin/cp app/SpeekCoding.entitlements "$CONTENTS/SpeekCoding.entitlements"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MACOS_TARGET" "$CONTENTS/Info.plist"

/usr/bin/swiftc scripts/speek-coding-app.swift \
	-O \
	-target "$TARGET_ARCH-apple-macosx$MACOS_TARGET" \
	-o "$CONTENTS/MacOS/SpeekCoding" \
	-framework AppKit \
	-framework AVFoundation \
	-framework ApplicationServices \
	-framework CoreAudio \
	-framework CoreGraphics
/usr/bin/swiftc scripts/speek-hud.swift \
	-O \
	-target "$TARGET_ARCH-apple-macosx$MACOS_TARGET" \
	-o "$RESOURCES/bin/speek-hud"

/usr/bin/ditto cli "$RESOURCES/cli"
/usr/bin/ditto karabiner "$RESOURCES/karabiner"
/usr/bin/ditto docs "$RESOURCES/docs"
/bin/mkdir -p "$RESOURCES/scripts"
/bin/cp scripts/local-asr-server.py scripts/speek-command.sh "$RESOURCES/scripts/"
/bin/cp package.json package-lock.json README.md CHANGELOG.md LICENSE SECURITY.md "$RESOURCES/"
/bin/cp packaging/THIRD_PARTY_NOTICES.md "$RESOURCES/"

(
	cd "$RESOURCES"
	/usr/bin/env npm ci --omit=dev --ignore-scripts --no-audit --no-fund
)

/bin/cp scripts/speek-package-launcher.sh "$ROOT_DIR/usr/local/bin/speek"
/bin/cp scripts/speek-package-launcher.sh "$ROOT_DIR/usr/local/bin/speek-coding"
/bin/chmod 755 \
	"$CONTENTS/MacOS/SpeekCoding" \
	"$RESOURCES/bin/speek-hud" \
	"$RESOURCES/scripts/speek-command.sh" \
	"$ROOT_DIR/usr/local/bin/speek" \
	"$ROOT_DIR/usr/local/bin/speek-coding"

SIGN_ARGS=(--force --deep --options runtime --entitlements "$CONTENTS/SpeekCoding.entitlements" --sign "$APP_SIGNING_IDENTITY")
if [ "$APP_SIGNING_IDENTITY" != "-" ] && { [ "${SPEEK_RELEASE:-0}" = "1" ] || [ "$APP_SIGNING_TIMESTAMP" = "1" ]; }; then
	SIGN_ARGS+=(--timestamp)
elif [ "$APP_SIGNING_IDENTITY" != "-" ]; then
	SIGN_ARGS+=(--timestamp=none)
fi
/usr/bin/codesign "${SIGN_ARGS[@]}" "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"

PKG_ARGS=(
	--root "$ROOT_DIR"
	--identifier com.speek.coding.pkg
	--version "$VERSION"
	--install-location /
	--component-plist packaging/components.plist
)
if [ -n "$INSTALLER_SIGNING_IDENTITY" ]; then
	PKG_ARGS+=(--sign "$INSTALLER_SIGNING_IDENTITY")
fi
/bin/rm -f "$PACKAGE_PATH"
/usr/bin/pkgbuild "${PKG_ARGS[@]}" "$PACKAGE_PATH"

if [ -n "$NOTARY_PROFILE" ]; then
	/usr/bin/xcrun notarytool submit "$PACKAGE_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
	/usr/bin/xcrun stapler staple "$PACKAGE_PATH"
fi

if [ "${SPEEK_RELEASE:-0}" = "1" ]; then
	/usr/sbin/pkgutil --check-signature "$PACKAGE_PATH"
	/usr/sbin/spctl --assess --type install --verbose=2 "$PACKAGE_PATH"
fi

scripts/verify-package.sh "$PACKAGE_PATH" "$TARGET_ARCH"
scripts/package-smoke-test.sh "$PACKAGE_PATH"
printf 'Built %s\n' "$PACKAGE_PATH"
