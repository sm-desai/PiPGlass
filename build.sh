#!/bin/zsh
# Builds PiPGlass.app, signs it with a stable local identity and installs it to /Applications.
#
# Screen Recording / Accessibility grants are tied to the app's code-signing identity.
# Ad-hoc signatures change on every build (and the grants with them), so the first run
# creates a self-signed "PiPGlass Local Code Signing" certificate in a private keychain
# (~/Library/Application Support/PiPGlass-Signing) and every build reuses it.
# That keychain is locked with a random password generated on your Mac and stored in your
# login keychain; nothing secret lives in this repository.
#
# Options (environment variables):
#   PIPGLASS_DEBUG=1   compile in the signal-driven self-test hooks (see Sources/Debug.swift)
#   NO_INSTALL=1       build and sign only; don't copy to /Applications
set -euo pipefail

ROOT="${0:A:h}"
BUILD="$ROOT/build"
APP="$BUILD/PiPGlass.app"
INSTALL_DIR="/Applications"
IDENTITY="PiPGlass Local Code Signing"
SIGN_DIR="$HOME/Library/Application Support/PiPGlass-Signing"
KEYCHAIN="$SIGN_DIR/pipglass-signing.keychain-db"
KC_PASS_SERVICE="PiPGlass signing keychain"
DEPLOYMENT_TARGET="$(sw_vers -productVersion | cut -d. -f1).0"

keychain_password() {
  security find-generic-password -a "$USER" -s "$KC_PASS_SERVICE" -w 2>/dev/null
}

ensure_identity() {
  if [[ -f "$KEYCHAIN" ]]; then
    local pass
    if ! pass="$(keychain_password)"; then
      echo "error: $KEYCHAIN exists but its password isn't in your login keychain." >&2
      echo "       Delete \"$SIGN_DIR\" and run this again (you'll have to re-grant permissions)." >&2
      exit 1
    fi
    security unlock-keychain -p "$pass" "$KEYCHAIN"
    return
  fi
  echo "==> Creating local code-signing identity ($IDENTITY)"
  local pass tmp
  pass="$(openssl rand -hex 32)"
  ( umask 077; mkdir -p "$SIGN_DIR" )
  tmp="$(mktemp -d)"
  trap "rm -rf '$tmp'" EXIT   # the unencrypted private key only ever lives here
  cat > "$tmp/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$tmp/cert.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
  openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -out "$tmp/id.p12" -passout "pass:$pass" -name "$IDENTITY"
  security add-generic-password -U -a "$USER" -s "$KC_PASS_SERVICE" -w "$pass" \
    -j "Random password for PiPGlass's local code-signing keychain (created by build.sh)"
  security create-keychain -p "$pass" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"   # no auto-lock
  security unlock-keychain -p "$pass" "$KEYCHAIN"
  security import "$tmp/id.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pass" "$KEYCHAIN" >/dev/null
  rm -rf "$tmp"
  trap - EXIT
}

SWIFT_FLAGS=()
if [[ "${PIPGLASS_DEBUG:-0}" == 1 ]]; then
  echo "==> Debug hooks enabled (development only)"
  SWIFT_FLAGS+=(-D PIPGLASS_DEBUG)
fi

echo "==> Compiling (target macOS $DEPLOYMENT_TARGET, $(uname -m))"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 "${SWIFT_FLAGS[@]}" \
  -target "$(uname -m)-apple-macos$DEPLOYMENT_TARGET" \
  -framework AppKit -framework ScreenCaptureKit -framework CoreMedia \
  -framework Carbon -framework ApplicationServices -framework QuartzCore \
  "$ROOT"/Sources/*.swift \
  -o "$APP/Contents/MacOS/PiPGlass"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $DEPLOYMENT_TARGET" "$APP/Contents/Info.plist"

echo "==> Signing"
ensure_identity
# codesign only looks in the user keychain search list, so add the private keychain
# for the duration of the signing step and always put the original list back.
ORIG_KEYCHAINS=("${(@f)$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')}")
restore_keychains() { security list-keychains -d user -s "${ORIG_KEYCHAINS[@]}"; }
trap restore_keychains EXIT
security list-keychains -d user -s "${ORIG_KEYCHAINS[@]}" "$KEYCHAIN"
codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
restore_keychains
trap - EXIT
codesign --verify --strict "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated || true

if [[ "${NO_INSTALL:-0}" == 1 ]]; then
  echo "==> Done: $APP"
  exit 0
fi

echo "==> Installing to $INSTALL_DIR"
if pgrep -x PiPGlass >/dev/null; then
  pkill -TERM -x PiPGlass || true   # SIGTERM restores a parked Firefox PiP window
  sleep 1
fi
rm -rf "$INSTALL_DIR/PiPGlass.app"
ditto "$APP" "$INSTALL_DIR/PiPGlass.app"
echo "==> Done: $INSTALL_DIR/PiPGlass.app  (launch: open -a PiPGlass)"
