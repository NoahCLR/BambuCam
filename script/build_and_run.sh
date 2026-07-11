#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="BambuCam"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/debug"
APP_PATH="$BUILD_DIR/Build/Products/Debug/$APP_NAME.app"

cd "$ROOT_DIR"
command -v xcodegen >/dev/null || {
  echo "error: xcodegen is required (brew install xcodegen)" >&2
  exit 1
}

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
xcodegen generate --quiet
xcodebuild \
  -project BambuCam.xcodeproj \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -derivedDataPath "$BUILD_DIR" \
  -quiet build

open_app() {
  /usr/bin/open -n "$APP_PATH"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_PATH/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--verify]" >&2
    exit 2
    ;;
esac
