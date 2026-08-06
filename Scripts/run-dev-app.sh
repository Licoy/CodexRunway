#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_EXECUTABLE="${1:?usage: run-dev-app.sh <swift-run-executable> [arguments ...]}"
shift
ARCH="$(uname -m)"
DEV_ROOT="$ROOT/.build/codex-runway-widget-dev"
APP="$DEV_ROOT/CodexRunway-dev.app"
STAGING="$DEV_ROOT/CodexRunway-dev.app.staging"
DERIVED="$ROOT/.build/widget-derived-dev-$ARCH"
CONTENTS="$STAGING/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"
PLUGINS="$CONTENTS/PlugIns"
BUNDLE_ID="com.github.codex-runway.swift-dev"
WIDGET_ID="com.github.codex-runway.widget.swift-dev"
PREVIOUS_DEV_WIDGET_ID="com.github.codex-runway.widget.dev"
BUILD_NUMBER="40.$(date +%H%M).$(date +%S)"
MARKETING_VERSION="$(plutil -extract CFBundleShortVersionString raw "$ROOT/Resources/Info.plist")"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

terminate_dev_processes() {
  local process_name="$1"
  local expected_id="$2"
  local pid executable identifier
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    executable="$(ps -p "$pid" -o comm= | sed 's/^[[:space:]]*//')"
    [[ -n "$executable" ]] || continue
    identifier="$(codesign -dvv "$executable" 2>&1 | awk -F= '/^Identifier=/{print $2; exit}')"
    if [[ "$identifier" == "$expected_id" ]]; then
      kill "$pid" 2>/dev/null || true
    fi
  done < <(pgrep -x "$process_name" || true)
}

terminate_dev_host_at_fixed_path() {
  local pid executable
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    executable="$(ps -p "$pid" -o comm= | sed 's/^[[:space:]]*//')"
    if [[ "$executable" == "$APP/Contents/MacOS/CodexRunway" ]]; then
      kill "$pid" 2>/dev/null || true
    fi
  done < <(pgrep -x CodexRunway || true)
}

terminate_dev_host_at_fixed_path
terminate_dev_processes CodexRunway "$BUNDLE_ID"
terminate_dev_processes CodexRunwayWidget "$WIDGET_ID"
terminate_dev_processes CodexRunwayWidget "$PREVIOUS_DEV_WIDGET_ID"
sleep 0.2

LOCK="$HOME/Library/Application Support/Codex Runway/codex-runway.lock"
if [[ -e "$LOCK" ]] && lsof -t "$LOCK" >/dev/null 2>&1; then
  printf 'Codex Runway is already running. Quit the installed app before swift run.\n' >&2
  exit 1
fi

xcodebuild \
  -project "$ROOT/WidgetExtension/CodexRunwayWidget.xcodeproj" \
  -scheme CodexRunwayWidget \
  -configuration Debug \
  -derivedDataPath "$DERIVED" \
  RUNWAY_WIDGET_BUNDLE_ID="$WIDGET_ID" \
  RUNWAY_APP_GROUP_ID="group.com.github.codex-runway.swift-dev" \
  RUNWAY_WIDGET_DISPLAY_NAME="Codex Runway Dev" \
  RUNWAY_WIDGET_STORAGE_MODE=local \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  ENABLE_APP_SANDBOX=NO \
  CODE_SIGN_ENTITLEMENTS= \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS="$ARCH" \
  ONLY_ACTIVE_ARCH=YES \
  build

mkdir -p "$DEV_ROOT"
rm -rf "$STAGING"
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS" "$PLUGINS"
/usr/bin/ditto "$SOURCE_EXECUTABLE" "$MACOS/CodexRunway"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleIdentifier $BUNDLE_ID" \
  -c "Set :CFBundleName Codex Runway Dev" \
  -c "Add :CFBundleDisplayName string Codex Runway Dev" \
  -c "Set :CFBundleVersion $BUILD_NUMBER" \
  -c "Add :RunwayWidgetStorageMode string local" \
  "$CONTENTS/Info.plist"
cp "$ROOT/Resources/AppIcon.svg" "$RESOURCES/AppIcon.svg"
cp "$ROOT/Resources/AppIcon.png" "$RESOURCES/AppIcon.png"
cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"

BIN_DIR="$(cd "$(dirname "$SOURCE_EXECUTABLE")" && pwd)"
if [[ -d "$BIN_DIR/Sparkle.framework" ]]; then
  /usr/bin/ditto "$BIN_DIR/Sparkle.framework" "$FRAMEWORKS/Sparkle.framework"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/CodexRunway" 2>/dev/null || true
  codesign --force --options runtime --sign - "$FRAMEWORKS/Sparkle.framework" >/dev/null
fi

/usr/bin/ditto \
  "$DERIVED/Build/Products/Debug/CodexRunwayWidget.appex" \
  "$PLUGINS/CodexRunwayWidget.appex"

APP_ENTITLEMENTS="$(mktemp)"
WIDGET_ENTITLEMENTS="$(mktemp)"
trap 'rm -f "$APP_ENTITLEMENTS" "$WIDGET_ENTITLEMENTS"' EXIT
plutil -create xml1 "$APP_ENTITLEMENTS"
/usr/libexec/PlistBuddy \
  -c "Add :com.apple.security.cs.disable-library-validation bool true" \
  "$APP_ENTITLEMENTS"
plutil -create xml1 "$WIDGET_ENTITLEMENTS"
/usr/libexec/PlistBuddy \
  -c "Add :com.apple.security.app-sandbox bool true" \
  -c "Add :com.apple.security.temporary-exception.files.home-relative-path.read-only array" \
  -c "Add :com.apple.security.temporary-exception.files.home-relative-path.read-only:0 string /.codex-runway/widget-snapshot.json" \
  "$WIDGET_ENTITLEMENTS"
codesign \
  --force \
  --options runtime \
  --entitlements "$WIDGET_ENTITLEMENTS" \
  --sign - \
  "$PLUGINS/CodexRunwayWidget.appex" >/dev/null
codesign \
  --force \
  --options runtime \
  --entitlements "$APP_ENTITLEMENTS" \
  --sign - \
  "$STAGING" >/dev/null
codesign --verify --deep --strict "$STAGING"

while IFS= read -r stale_app; do
  [[ -n "$stale_app" && "$stale_app" != "$APP" ]] || continue
  "$LSREGISTER" -u "$stale_app" >/dev/null 2>&1 || true
done < <(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null || true)
while IFS= read -r stale_app; do
  [[ "$stale_app" != "$APP" ]] || continue
  stale_id="$(plutil -extract CFBundleIdentifier raw "$stale_app/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$stale_id" == "$BUNDLE_ID" ]]; then
    "$LSREGISTER" -u "$stale_app" >/dev/null 2>&1 || true
  fi
done < <(find /private/tmp -maxdepth 2 -type d -name '*.app' -print 2>/dev/null)
while IFS= read -r registered; do
  [[ -n "$registered" ]] && pluginkit -r "$registered" >/dev/null 2>&1 || true
done < <(pluginkit -m -A -D -v -i "$WIDGET_ID" 2>/dev/null | awk 'NF {print $NF}')
previous_dev_extension="$APP/Contents/PlugIns/CodexRunwayWidget.appex"
if [[ -d "$previous_dev_extension" ]]; then
  pluginkit -r "$previous_dev_extension" >/dev/null 2>&1 || true
fi
[[ -d "$APP" ]] && "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
rm -rf "$APP"
mv "$STAGING" "$APP"
"$LSREGISTER" -f "$APP"
pluginkit -a "$APP/Contents/PlugIns/CodexRunwayWidget.appex"

printf 'Codex Runway Dev: %s\n' "$APP"
if [[ "$#" -gt 0 ]]; then
  open -n "$APP" --args "$@"
else
  open -n "$APP"
fi
