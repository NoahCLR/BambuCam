#!/bin/zsh
set -euo pipefail

# Adapted from NoahCLR/homebrew-tap templates/install-local.sh (see the
# backport rule in that repo's templates/README.md).
#
# Builds Release, signs with the stable local identity, installs to
# /Applications, and relaunches if the app was running. Works without a
# paid Apple Developer account. Signing with the same identity as
# scripts/release.sh means permission grants survive switching between a
# local install and the brew-installed copy.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d /tmp/bambucam-install.XXXXXX)"
DERIVED_DATA="$BUILD_DIR/DerivedData"
APP_NAME="BambuCam.app"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME"
INSTALL_APP="/Applications/$APP_NAME"

source "$ROOT_DIR/scripts/signing-common.sh"

command -v xcodegen >/dev/null || {
  echo "error: xcodegen is required (brew install xcodegen)" >&2
  exit 1
}
xcodegen generate --quiet

echo "Building BambuCam..."
trap 'rm -rf "$BUILD_DIR"' EXIT
xcodebuild \
  -project "$ROOT_DIR/BambuCam.xcodeproj" \
  -scheme BambuCam \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -quiet \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "$BUILT_APP" ]]; then
  echo "Build did not produce $BUILT_APP" >&2
  exit 1
fi

ensure_signing_identity
sign_app_bundle "$BUILT_APP"

WAS_RUNNING=0
if pgrep -x "BambuCam" >/dev/null; then
  WAS_RUNNING=1
  osascript -e 'tell application "BambuCam" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    pgrep -x "BambuCam" >/dev/null || break
    sleep 0.25
  done
  pkill -x "BambuCam" 2>/dev/null || true
fi

echo "Installing to /Applications..."
rm -rf "$INSTALL_APP"
ditto "$BUILT_APP" "$INSTALL_APP"
codesign --verify --deep --strict "$INSTALL_APP"
echo "installed $INSTALL_APP"

if [[ $WAS_RUNNING -eq 1 || "${1:-}" == "--open" ]]; then
  open "$INSTALL_APP"
fi
