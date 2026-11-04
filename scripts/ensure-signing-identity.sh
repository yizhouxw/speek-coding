#!/bin/bash
set -euo pipefail

IDENTITY_NAME="${SPEEK_CODESIGN_IDENTITY_NAME:-SpeekCoding Local Code Signing}"
KEYCHAIN="${SPEEK_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if [ -n "${SPEEK_CODESIGN_IDENTITY:-}" ]; then
	if [ "$SPEEK_CODESIGN_IDENTITY" = "-" ] && [ "${SPEEK_ALLOW_ADHOC_SIGNING:-0}" != "1" ]; then
		printf 'ad-hoc signing is not stable; set a persistent identity or let SpeekCoding create one\n' >&2
		exit 64
	fi
	printf '%s\n' "$SPEEK_CODESIGN_IDENTITY"
	exit 0
fi

find_identity() {
	{ /usr/bin/security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null || true; } |
		/usr/bin/awk -v name="$IDENTITY_NAME" 'index($0, "\"" name "\"") { print $2; exit }'
}

identity="$(find_identity)"
if [ -n "$identity" ]; then
	printf '%s\n' "$identity"
	exit 0
fi

for command in /usr/bin/security /usr/bin/openssl /usr/bin/codesign; do
	[ -x "$command" ] || {
		printf 'required signing tool not found: %s\n' "$command" >&2
		exit 69
	}
done

tmp_dir="$(/usr/bin/mktemp -d -t speek-coding-signing)"
trap '/bin/rm -rf "$tmp_dir"' EXIT
password="$(/usr/bin/uuidgen)"

if /usr/bin/security find-certificate -c "$IDENTITY_NAME" -p "$KEYCHAIN" >"$tmp_dir/existing.pem" 2>/dev/null &&
	[ -s "$tmp_dir/existing.pem" ]; then
	/usr/bin/security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$tmp_dir/existing.pem" >/dev/null
	identity="$(find_identity)"
	if [ -n "$identity" ]; then
		printf '%s\n' "$identity"
		exit 0
	fi
fi

/bin/cat >"$tmp_dir/openssl.cnf" <<EOF
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no

[subject]
CN = $IDENTITY_NAME
O = SpeekCoding

[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

/usr/bin/openssl req -new -newkey rsa:2048 -nodes -x509 -sha256 -days 3650 \
	-config "$tmp_dir/openssl.cnf" \
	-keyout "$tmp_dir/key.pem" \
	-out "$tmp_dir/certificate.pem" >/dev/null 2>&1

/usr/bin/openssl pkcs12 -export \
	-inkey "$tmp_dir/key.pem" \
	-in "$tmp_dir/certificate.pem" \
	-name "$IDENTITY_NAME" \
	-out "$tmp_dir/identity.p12" \
	-passout "pass:$password" >/dev/null 2>&1

/usr/bin/security import "$tmp_dir/identity.p12" \
	-k "$KEYCHAIN" \
	-P "$password" \
	-T /usr/bin/codesign >/dev/null
/usr/bin/security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$tmp_dir/certificate.pem" >/dev/null

identity="$(find_identity)"
if [ -z "$identity" ]; then
	printf 'created %s but macOS did not expose it as a valid code-signing identity\n' "$IDENTITY_NAME" >&2
	exit 70
fi

printf '%s\n' "$identity"
