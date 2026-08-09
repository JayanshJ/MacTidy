#!/bin/bash
# Creates a self-signed code-signing certificate ("MacTidy Signing") in the
# login keychain. Why: ad-hoc signatures (`codesign -s -`) change identity on
# every build, so macOS drops the app's Full Disk Access grant each rebuild.
# A stable certificate keeps the TCC grant across rebuilds.
#
# Run once: ./Support/make-signing-cert.sh
# macOS may show up to two prompts (trust settings; first codesign key use).
set -euo pipefail

NAME="MacTidy Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "Signing identity '$NAME' already exists — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Generating self-signed code-signing certificate '$NAME' (10-year validity)…"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:FALSE"

# Legacy PBE/MAC algorithms: OpenSSL 3's modern PKCS#12 defaults can't be
# read by the macOS Security framework ("MAC verification failed").
openssl pkcs12 -export -out "$TMP/bundle.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:mactidy \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

echo "Importing into the login keychain…"
security import "$TMP/bundle.p12" -k "$KEYCHAIN" -P mactidy \
    -T /usr/bin/codesign -T /usr/bin/security

echo "Marking the certificate trusted for code signing (may prompt)…"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "Done. 'make app' will now sign with '$NAME'."
    echo "Re-add dist/MacTidy.app to Full Disk Access once; the grant then survives rebuilds."
else
    echo "Certificate imported but the identity isn't valid for code signing yet." >&2
    echo "Open Keychain Access → login → '$NAME' → Trust → Code Signing: Always Trust." >&2
    exit 1
fi
