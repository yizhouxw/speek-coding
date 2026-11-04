#!/bin/bash
set -euo pipefail

# Run only on an ephemeral CI runner. All credentials are supplied through Actions secrets.
for name in APP_CERTIFICATE_P12_BASE64 APP_CERTIFICATE_PASSWORD INSTALLER_CERTIFICATE_P12_BASE64 INSTALLER_CERTIFICATE_PASSWORD APPLE_API_KEY_P8_BASE64 APPLE_API_KEY_ID APPLE_API_ISSUER_ID SPEEK_APP_SIGNING_IDENTITY SPEEK_INSTALLER_SIGNING_IDENTITY; do
	if [ -z "${!name:-}" ]; then
		printf 'Missing required release credential or identity: %s\n' "$name" >&2
		exit 64
	fi
done

work_dir="$(/usr/bin/mktemp -d "${RUNNER_TEMP:-/tmp}/speek-release.XXXXXX")"
keychain="$work_dir/signing.keychain-db"
keychain_password="$(/usr/bin/openssl rand -hex 32)"
cleanup() {
	/usr/bin/security delete-keychain "$keychain" >/dev/null 2>&1 || true
	/bin/rm -rf "$work_dir"
}
trap cleanup EXIT
umask 077
printf '%s' "$APP_CERTIFICATE_P12_BASE64" | /usr/bin/base64 -D > "$work_dir/app.p12"
printf '%s' "$INSTALLER_CERTIFICATE_P12_BASE64" | /usr/bin/base64 -D > "$work_dir/installer.p12"
printf '%s' "$APPLE_API_KEY_P8_BASE64" | /usr/bin/base64 -D > "$work_dir/AuthKey.p8"
/usr/bin/security create-keychain -p "$keychain_password" "$keychain"
/usr/bin/security set-keychain-settings -lut 21600 "$keychain"
/usr/bin/security unlock-keychain -p "$keychain_password" "$keychain"
/usr/bin/security list-keychains -d user -s "$keychain"
/usr/bin/security default-keychain -d user -s "$keychain"
/usr/bin/security import "$work_dir/app.p12" -k "$keychain" -P "$APP_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
/usr/bin/security import "$work_dir/installer.p12" -k "$keychain" -P "$INSTALLER_CERTIFICATE_PASSWORD" -T /usr/bin/productbuild -T /usr/bin/pkgbuild
/usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
/usr/bin/xcrun notarytool store-credentials speek-ci --key "$work_dir/AuthKey.p8" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" --keychain "$keychain"
export SPEEK_RELEASE=1 SPEEK_NOTARY_PROFILE=speek-ci
npm run package:mac
