#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/CodexRunway.app}"
EXPECTED_ARCH="${2:-$(uname -m)}"
EXPECTED_STORAGE_MODE="${3:-local}"
WIDGET="$APP/Contents/PlugIns/CodexRunwayWidget.appex"

[[ -d "$APP" ]] || { printf 'Missing app: %s\n' "$APP" >&2; exit 1; }
[[ -d "$WIDGET" ]] || { printf 'Missing widget extension: %s\n' "$WIDGET" >&2; exit 1; }

plutil -lint "$APP/Contents/Info.plist" "$WIDGET/Contents/Info.plist"

HOST_ID="$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")"
WIDGET_ID="$(plutil -extract CFBundleIdentifier raw "$WIDGET/Contents/Info.plist")"
WIDGET_DISPLAY_NAME="$(plutil -extract CFBundleDisplayName raw "$WIDGET/Contents/Info.plist")"
HOST_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
WIDGET_VERSION="$(plutil -extract CFBundleShortVersionString raw "$WIDGET/Contents/Info.plist")"
HOST_BUILD="$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")"
WIDGET_BUILD="$(plutil -extract CFBundleVersion raw "$WIDGET/Contents/Info.plist")"
STORAGE_MODE="$(plutil -extract RunwayWidgetStorageMode raw "$WIDGET/Contents/Info.plist")"
WIDGET_ARCHS="$(lipo -archs "$WIDGET/Contents/MacOS/CodexRunwayWidget")"

[[ "$WIDGET_ID" == "$HOST_ID.widget" ]] || {
  printf 'Unexpected widget identifier: %s (host: %s)\n' "$WIDGET_ID" "$HOST_ID" >&2
  exit 1
}
[[ "$WIDGET_DISPLAY_NAME" == "CodexRunway" ]] || {
  printf 'Unexpected widget display name: %s\n' "$WIDGET_DISPLAY_NAME" >&2
  exit 1
}
[[ "$WIDGET_VERSION" == "$HOST_VERSION" && "$WIDGET_BUILD" == "$HOST_BUILD" ]] || {
  printf 'Widget version %s (%s) does not match host %s (%s)\n' \
    "$WIDGET_VERSION" "$WIDGET_BUILD" "$HOST_VERSION" "$HOST_BUILD" >&2
  exit 1
}
[[ "$STORAGE_MODE" == "$EXPECTED_STORAGE_MODE" ]] || {
  printf 'Unexpected widget storage mode: %s\n' "$STORAGE_MODE" >&2
  exit 1
}
[[ " $WIDGET_ARCHS " == *" $EXPECTED_ARCH "* ]] || {
  printf 'Widget architectures %s do not include %s\n' "$WIDGET_ARCHS" "$EXPECTED_ARCH" >&2
  exit 1
}

codesign --verify --deep --strict "$APP"

HOST_REQUIREMENT="$(codesign -d -r- "$APP" 2>&1)"
WIDGET_REQUIREMENT="$(codesign -d -r- "$WIDGET" 2>&1)"
printf '%s\n' "$HOST_REQUIREMENT" | grep -Fq "designated => identifier \"$HOST_ID\"" || {
  printf 'Host designated requirement is not identifier-stable:\n%s\n' "$HOST_REQUIREMENT" >&2
  exit 1
}
printf '%s\n' "$WIDGET_REQUIREMENT" | grep -Fq "designated => identifier \"$WIDGET_ID\"" || {
  printf 'Widget designated requirement is not identifier-stable:\n%s\n' "$WIDGET_REQUIREMENT" >&2
  exit 1
}
if printf '%s\n' "$HOST_REQUIREMENT" "$WIDGET_REQUIREMENT" | grep -Eq '^# designated => cdhash'; then
  printf 'Packaged signature still uses a per-build cdhash requirement.\n' >&2
  exit 1
fi

USAGE="$(plutil -extract NSAppDataUsageDescription raw "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ -n "$USAGE" ]] || {
  printf 'Missing NSAppDataUsageDescription in %s\n' "$APP" >&2
  exit 1
}

printf 'Verified widget %s v%s (%s, %s) in %s\n' \
  "$WIDGET_ID" "$WIDGET_VERSION" "$EXPECTED_ARCH" "$STORAGE_MODE" "$APP"
