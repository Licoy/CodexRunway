#!/usr/bin/env bash
# Ad-hoc sign with a stable designated requirement.
#
# Default `codesign --sign -` records only a per-build cdhash. TCC keys
# kTCCServiceSystemPolicyAppData grants by that requirement, so "Allow"
# does not survive rebuilds (and often not even a relaunch of the same
# ad-hoc app). An identifier requirement stays stable across builds.

runway_designated_requirement() {
  local identifier="${1:?identifier required}"
  printf '=designated => identifier "%s"' "$identifier"
}

runway_codesign() {
  local target="${1:?target required}"
  local identifier="${2:?identifier required}"
  local entitlements="${3:-}"
  local requirement
  requirement="$(runway_designated_requirement "$identifier")"
  local args=(
    --force
    --options runtime
    --identifier "$identifier"
    --requirements "$requirement"
    --sign -
  )
  if [[ -n "$entitlements" ]]; then
    args+=(--entitlements "$entitlements")
  fi
  codesign "${args[@]}" "$target"
}

runway_codesign_self_test() {
  local scratch identifier app requirement observed
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/runway-codesign.XXXXXX")"
  identifier="com.github.codex-runway.codesign-self-test"
  app="$scratch/Dummy.app"
  mkdir -p "$app/Contents/MacOS"
  cp /bin/echo "$app/Contents/MacOS/Dummy"
  cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Dummy</string>
  <key>CFBundleIdentifier</key>
  <string>com.github.codex-runway.codesign-self-test</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
</dict>
</plist>
PLIST
  runway_codesign "$app" "$identifier"
  codesign --verify --deep --strict "$app"
  requirement="$(runway_designated_requirement "$identifier")"
  observed="$(codesign -d -r- "$app" 2>&1)"
  printf '%s\n' "$observed" | grep -Fq "designated => identifier \"$identifier\""
  if printf '%s\n' "$observed" | grep -Eq '^# designated => cdhash'; then
    printf 'codesign helper left an implicit cdhash requirement:\n%s\n' "$observed" >&2
    rm -rf "$scratch"
    return 1
  fi
  [[ "$requirement" == "=designated => identifier \"$identifier\"" ]]
  rm -rf "$scratch"
}

if [[ -n "${BASH_VERSION:-}" && "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  case "${1:-}" in
    --self-test)
      runway_codesign_self_test
      ;;
    *)
      printf 'Usage: %s --self-test\n' "$0" >&2
      exit 2
      ;;
  esac
fi
