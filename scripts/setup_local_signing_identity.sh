#!/bin/bash

set -euo pipefail

identity="${PIPANEL_LOCAL_SIGNING_IDENTITY:-PiPanel Local Code Signing}"
login_keychain="${PIPANEL_LOGIN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if security find-identity -v -p codesigning "$login_keychain" | grep -F "\"$identity\"" >/dev/null; then
    echo "Reusing existing signing identity: $identity"
    exit 0
fi

if security find-certificate -c "$identity" "$login_keychain" >/dev/null 2>&1; then
    echo "A certificate named '$identity' exists but has no usable private key." >&2
    echo "Remove or repair that certificate in Keychain Access before retrying." >&2
    exit 78
fi

work_dir="$(mktemp -d /tmp/pipanel-local-signing.XXXXXX)"
chmod 700 "$work_dir"
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

openssl req \
    -new \
    -newkey rsa:3072 \
    -x509 \
    -sha256 \
    -days 3650 \
    -nodes \
    -subj "/CN=$identity/O=PiPanel" \
    -addext "basicConstraints=critical,CA:true" \
    -addext "keyUsage=critical,digitalSignature,keyCertSign" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "subjectKeyIdentifier=hash" \
    -addext "authorityKeyIdentifier=keyid:always,issuer" \
    -keyout "$work_dir/private-key.pem" \
    -out "$work_dir/certificate.pem" >/dev/null 2>&1

p12_password="$(openssl rand -hex 24)"
openssl pkcs12 \
    -export \
    -legacy \
    -name "$identity" \
    -inkey "$work_dir/private-key.pem" \
    -in "$work_dir/certificate.pem" \
    -passout "pass:$p12_password" \
    -out "$work_dir/identity.p12"

# Limit private-key access to Apple's signing tools. Do not use security import -A: that would
# let every local application use the release key without user approval.
security import "$work_dir/identity.p12" \
    -k "$login_keychain" \
    -f pkcs12 \
    -P "$p12_password" \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null

# A self-signed identity has no public CA above it. Trust only its code-signing policy in the
# current user's trust domain so codesign can validate the identity without weakening TLS trust.
security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$login_keychain" \
    "$work_dir/certificate.pem"

if ! security find-identity -v -p codesigning "$login_keychain" \
    | grep -F "\"$identity\"" >/dev/null; then
    echo "The local signing identity was imported but is not valid for code signing." >&2
    exit 1
fi

echo "Created local signing identity: $identity"
echo "Keep its private key in Login Keychain; every future PiPanel build must reuse it."
