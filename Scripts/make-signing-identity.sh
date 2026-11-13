#!/bin/bash
# Creates a local, self-signed code-signing identity ("KlaD Local Signing") in a
# dedicated keychain (~/Library/Keychains/klad-signing.keychain-db) so every
# build of KlaD carries the same signature. macOS privacy permissions are tied
# to the signature: with ad-hoc signing every rebuild looks like a new app and
# macOS asks for folder access again.
#
# The keychain password lives in ~/.config/klad/signing-keychain-password so
# builds can unlock it without prompts. Remove everything with:
#   security delete-keychain ~/Library/Keychains/klad-signing.keychain-db
#   rm -rf ~/.config/klad
set -euo pipefail
NAME="KlaD Local Signing"
KEYCHAIN="$HOME/Library/Keychains/klad-signing.keychain-db"
PASSFILE="$HOME/.config/klad/signing-keychain-password"

if [[ -f "$KEYCHAIN" && -f "$PASSFILE" ]] && security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists."
  exit 0
fi

mkdir -p "$(dirname "$PASSFILE")"
chmod 700 "$(dirname "$PASSFILE")"
[[ -f "$PASSFILE" ]] || { openssl rand -hex 24 > "$PASSFILE"; chmod 600 "$PASSFILE"; }
KPASS=$(cat "$PASSFILE")

[[ -f "$KEYCHAIN" ]] || security create-keychain -p "$KPASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"          # no auto-lock
security unlock-keychain -p "$KPASS" "$KEYCHAIN"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1
PPASS=$(openssl rand -hex 12)
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/id.p12" -passout "pass:$PPASS" -legacy >/dev/null 2>&1 \
  || openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
       -out "$WORK/id.p12" -passout "pass:$PPASS" >/dev/null 2>&1
security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$PPASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KPASS" "$KEYCHAIN" >/dev/null

# Make the keychain searchable (keeps existing search list).
EXISTING=$(security list-keychains -d user | tr -d '"' | xargs)
case " $EXISTING " in
  *" $KEYCHAIN "*) ;;
  *) security list-keychains -d user -s $EXISTING "$KEYCHAIN" ;;
esac
echo "Created \"$NAME\" in $KEYCHAIN"
