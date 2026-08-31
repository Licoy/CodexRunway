#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=codesign-helpers.sh
source "$ROOT/Scripts/codesign-helpers.sh"
ARCH="${ARCH:-$(uname -m)}"
if [[ "${1:-}" == "--arch" ]]; then
  ARCH="${2:-}"
fi

case "$ARCH" in
  arm64|x86_64) ;;
  *)
    printf 'Unsupported ARCH: %s\n' "$ARCH" >&2
    printf 'Usage: ARCH=arm64|x86_64 %s or %s --arch arm64|x86_64\n' "$0" "$0" >&2
    exit 2
    ;;
esac

TRIPLE="${ARCH}-apple-macosx12.0"
INCLUDE_WIDGET="${INCLUDE_WIDGET:-1}"
RUNWAY_BUNDLE_ID="${RUNWAY_BUNDLE_ID:-com.github.codex-runway}"
RUNWAY_APP_GROUP_ID="${RUNWAY_APP_GROUP_ID:-group.com.github.codex-runway}"
RUNWAY_WIDGET_BUNDLE_ID="${RUNWAY_WIDGET_BUNDLE_ID:-${RUNWAY_BUNDLE_ID}.widget}"
RUNWAY_WIDGET_STORAGE_MODE="${RUNWAY_WIDGET_STORAGE_MODE:-local}"
DIST="$ROOT/dist"
APP="$DIST/CodexRunway.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"
PLUGINS="$CONTENTS/PlugIns"
WIDGET_DERIVED="$DIST/widget-derived-${ARCH}"
ZIP="$DIST/CodexRunway-macos-${ARCH}.zip"
TAR_GZ="$DIST/CodexRunway-macos-${ARCH}.app.tar.gz"
DMG="$DIST/CodexRunway-macos-${ARCH}.dmg"
DMG_ROOT="$DIST/dmg-${ARCH}"

case "$RUNWAY_WIDGET_STORAGE_MODE" in
  local|app-group) ;;
  *)
    printf 'Unsupported RUNWAY_WIDGET_STORAGE_MODE: %s\n' "$RUNWAY_WIDGET_STORAGE_MODE" >&2
    exit 2
    ;;
esac

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"

swift build -c release --package-path "$ROOT" --triple "$TRIPLE"
BIN_DIR="$(swift build -c release --package-path "$ROOT" --triple "$TRIPLE" --show-bin-path)"
cp "$BIN_DIR/CodexRunway" "$MACOS/CodexRunway"
if [[ -n "${EXPECTED_MACOS_SDK_MAJOR:-}" ]]; then
  SDK="$(otool -l "$MACOS/CodexRunway" | awk '$1 == "sdk" { print $2; exit }')"
  case "$SDK" in
    "${EXPECTED_MACOS_SDK_MAJOR}".*) ;;
    *)
      printf 'Expected macOS SDK %s.x, got %s\n' "$EXPECTED_MACOS_SDK_MAJOR" "${SDK:-unknown}" >&2
      exit 1
      ;;
  esac
fi
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $RUNWAY_BUNDLE_ID" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/AppIcon.svg" "$RESOURCES/AppIcon.svg"
cp "$ROOT/Resources/AppIcon.png" "$RESOURCES/AppIcon.png"
cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
for lproj in "$ROOT/Resources"/*.lproj; do
  [[ -d "$lproj" ]] || continue
  /usr/bin/ditto "$lproj" "$RESOURCES/$(basename "$lproj")"
done
if [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey ${SPARKLE_PUBLIC_KEY}" "$CONTENTS/Info.plist"
fi
if [[ -d "$BIN_DIR/Sparkle.framework" ]]; then
  /usr/bin/ditto "$BIN_DIR/Sparkle.framework" "$FRAMEWORKS/Sparkle.framework"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/CodexRunway" 2>/dev/null || true
fi

if [[ "$INCLUDE_WIDGET" == "1" ]]; then
  rm -rf "$WIDGET_DERIVED"
  APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$CONTENTS/Info.plist")"
  APP_BUILD="$(plutil -extract CFBundleVersion raw "$CONTENTS/Info.plist")"
  WIDGET_BUILD_SETTINGS=(
    RUNWAY_WIDGET_BUNDLE_ID="$RUNWAY_WIDGET_BUNDLE_ID"
    RUNWAY_APP_GROUP_ID="$RUNWAY_APP_GROUP_ID"
    RUNWAY_WIDGET_DISPLAY_NAME="CodexRunway"
    RUNWAY_WIDGET_STORAGE_MODE="$RUNWAY_WIDGET_STORAGE_MODE"
    MARKETING_VERSION="$APP_VERSION"
    CURRENT_PROJECT_VERSION="$APP_BUILD"
    CODE_SIGNING_ALLOWED=NO
    ARCHS="$ARCH"
    ONLY_ACTIVE_ARCH=YES
  )
  if [[ "$RUNWAY_WIDGET_STORAGE_MODE" == "local" ]]; then
    WIDGET_BUILD_SETTINGS+=(ENABLE_APP_SANDBOX=NO CODE_SIGN_ENTITLEMENTS=)
  fi
  xcodebuild \
    -project "$ROOT/WidgetExtension/CodexRunwayWidget.xcodeproj" \
    -scheme CodexRunwayWidget \
    -configuration Release \
    -derivedDataPath "$WIDGET_DERIVED" \
    "${WIDGET_BUILD_SETTINGS[@]}" \
    build
  mkdir -p "$PLUGINS"
  /usr/bin/ditto \
    "$WIDGET_DERIVED/Build/Products/Release/CodexRunwayWidget.appex" \
    "$PLUGINS/CodexRunwayWidget.appex"
  /usr/libexec/PlistBuddy \
    -c "Add :RunwayWidgetStorageMode string $RUNWAY_WIDGET_STORAGE_MODE" \
    "$CONTENTS/Info.plist"
  if [[ "$RUNWAY_WIDGET_STORAGE_MODE" == "app-group" ]]; then
    /usr/libexec/PlistBuddy -c "Add :RunwayAppGroupID string $RUNWAY_APP_GROUP_ID" "$CONTENTS/Info.plist"
  fi
fi

if command -v codesign >/dev/null 2>&1; then
  APP_ENTITLEMENTS="$(mktemp)"
  WIDGET_ENTITLEMENTS="$(mktemp)"
  trap 'rm -f "$APP_ENTITLEMENTS" "$WIDGET_ENTITLEMENTS"' EXIT
  plutil -create xml1 "$APP_ENTITLEMENTS"
  /usr/libexec/PlistBuddy \
    -c "Add :com.apple.security.cs.disable-library-validation bool true" \
    "$APP_ENTITLEMENTS"
  if [[ "$INCLUDE_WIDGET" == "1" ]]; then
    plutil -create xml1 "$WIDGET_ENTITLEMENTS"
    /usr/libexec/PlistBuddy \
      -c "Add :com.apple.security.app-sandbox bool true" \
      "$WIDGET_ENTITLEMENTS"
    if [[ "$RUNWAY_WIDGET_STORAGE_MODE" == "app-group" ]]; then
      /usr/libexec/PlistBuddy \
        -c "Add :com.apple.security.application-groups array" \
        -c "Add :com.apple.security.application-groups:0 string $RUNWAY_APP_GROUP_ID" \
        "$APP_ENTITLEMENTS"
      /usr/libexec/PlistBuddy \
        -c "Add :com.apple.security.application-groups array" \
        -c "Add :com.apple.security.application-groups:0 string $RUNWAY_APP_GROUP_ID" \
        "$WIDGET_ENTITLEMENTS"
    else
      /usr/libexec/PlistBuddy \
        -c "Add :com.apple.security.temporary-exception.files.home-relative-path.read-only array" \
        -c "Add :com.apple.security.temporary-exception.files.home-relative-path.read-only:0 string /.codex-runway/widget-snapshot.json" \
        "$WIDGET_ENTITLEMENTS"
    fi
  fi
  if [[ -d "$FRAMEWORKS/Sparkle.framework" ]]; then
    codesign --force --options runtime --sign - "$FRAMEWORKS/Sparkle.framework" >/dev/null
  fi
  if [[ "$INCLUDE_WIDGET" == "1" ]]; then
    runway_codesign \
      "$PLUGINS/CodexRunwayWidget.appex" \
      "$RUNWAY_WIDGET_BUNDLE_ID" \
      "$WIDGET_ENTITLEMENTS" >/dev/null
  fi
  runway_codesign \
    "$APP" \
    "$RUNWAY_BUNDLE_ID" \
    "$APP_ENTITLEMENTS" >/dev/null
fi

mkdir -p "$DIST"
rm -rf "$DMG_ROOT"
rm -f "$ZIP" "$TAR_GZ" "$DMG"
(cd "$DIST" && /usr/bin/ditto -c -k --keepParent "CodexRunway.app" "$(basename "$ZIP")")
(cd "$DIST" && /usr/bin/tar -czf "$(basename "$TAR_GZ")" "CodexRunway.app")
mkdir -p "$DMG_ROOT"
/usr/bin/ditto "$APP" "$DMG_ROOT/CodexRunway.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "CodexRunway" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DMG_ROOT"
printf '%s\n%s\n%s\n' "$ZIP" "$TAR_GZ" "$DMG"
