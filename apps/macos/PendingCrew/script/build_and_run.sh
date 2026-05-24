#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="PendingCrew"
BUNDLE_ID="com.pendingname.pendingcrew"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
XCODE_PROJECT="$ROOT_DIR/PendingCrew.xcodeproj"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

stop_running_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

run_tests() {
  cd "$ROOT_DIR"
  if [[ -d "$XCODE_PROJECT" ]]; then
    xcodebuild \
      -quiet \
      -project "$XCODE_PROJECT" \
      -scheme "$APP_NAME" \
      -configuration Debug \
      -destination "platform=macOS,arch=arm64" \
      -derivedDataPath "$DIST_DIR/DerivedDataTests" \
      SYMROOT="$DIST_DIR/XcodeBuildTests" \
      test
  else
    swift test
  fi
}

run_ui_smoke_test() {
  cd "$ROOT_DIR"
  if [[ ! -d "$XCODE_PROJECT" ]]; then
    echo "UI smoke test requires $XCODE_PROJECT" >&2
    exit 2
  fi

  xcodebuild \
    -quiet \
    -project "$XCODE_PROJECT" \
    -scheme "$APP_NAME" \
    -configuration Debug \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$DIST_DIR/DerivedDataUITests" \
    SYMROOT="$DIST_DIR/XcodeBuildUITests" \
    -only-testing:PendingCrewUITests/PendingCrewUITests/testLaunchShowsDisconnectedCrewWorkspace \
    test
}

stage_xcode_app_bundle() {
  cd "$ROOT_DIR"
  xcodebuild \
    -quiet \
    -project "$XCODE_PROJECT" \
    -scheme "$APP_NAME" \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$DIST_DIR/DerivedData" \
    SYMROOT="$DIST_DIR/XcodeBuild" \
    CODE_SIGNING_ALLOWED=NO \
    build

  APP_BUNDLE="$DIST_DIR/XcodeBuild/Debug/$APP_NAME.app"
  APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
}

stage_swiftpm_app_bundle() {
  cd "$ROOT_DIR"
  swift build

  BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"
  APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
  APP_CONTENTS="$APP_BUNDLE/Contents"
  APP_MACOS="$APP_CONTENTS/MacOS"
  APP_BINARY="$APP_MACOS/$APP_NAME"
  INFO_PLIST="$APP_CONTENTS/Info.plist"

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS"
  cp "$BUILD_BINARY" "$APP_BINARY"
  chmod +x "$APP_BINARY"

  cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>$(defaults read -g AppleLocale 2>/dev/null | cut -d _ -f 1 || echo en)</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>MacOSX</string>
  </array>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <false/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
PLIST
}

stage_app_bundle() {
  if [[ -d "$XCODE_PROJECT" ]]; then
    stage_xcode_app_bundle
  else
    stage_swiftpm_app_bundle
  fi
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  --test|test)
    run_tests
    exit 0
    ;;
  --ui-test|ui-test)
    run_ui_smoke_test
    exit 0
    ;;
esac

stop_running_app
stage_app_bundle

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--test|--ui-test]" >&2
    exit 2
    ;;
esac
