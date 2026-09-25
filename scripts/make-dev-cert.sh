#!/bin/zsh
# Creates a self-signed code-signing certificate "VoiceParty Dev" in your login keychain.
# macOS ties Accessibility/Microphone grants to the signing certificate, so signing every build
# with the same certificate keeps permissions across rebuilds. Only needed without an Apple
# Development certificate (Xcode → Settings → Accounts).
set -euo pipefail
NAME="VoiceParty Dev"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "'$NAME' already exists."
  exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout pass:voiceparty 2>/dev/null
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P voiceparty -T /usr/bin/codesign
echo "Created '$NAME'. The first codesign may ask to use the key — choose Always Allow."
