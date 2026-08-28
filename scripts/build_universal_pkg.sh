#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/v2s.xcodeproj"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/.build/universal-pkg}"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Release/Easy2say.app"
PACKAGE_SCRIPTS_DIR="$ROOT_DIR/packaging/macos/scripts"
STABLE_OUTPUT_PATH="${STABLE_OUTPUT_PATH:-$BUILD_ROOT/Easy2say-universal.pkg}"
OUTPUT_PATH="${OUTPUT_PATH:-}"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-}"
APPLICATION_IDENTITY="${APPLICATION_IDENTITY:-}"
APPLICATION_ENTITLEMENTS="${APPLICATION_ENTITLEMENTS:-$ROOT_DIR/Config/DeveloperID.entitlements}"
REUSE_SIGNED_APP="${REUSE_SIGNED_APP:-0}"
SIGNING_KEYCHAIN="${SIGNING_KEYCHAIN:-}"

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

assert_no_optional_models() {
  local root="$1"
  local forbidden

  forbidden="$(find "$root" \
    \( -iname '*TranslateGemma*' \
       -o -iname '*MonlamWhisperTibetan*' \
       -o -iname '*Melong*.aimodel*' \
       -o -iname '*Melong*.gguf' \) \
    -print -quit)"

  [[ -z "$forbidden" ]] || fail "Forbidden model asset present: $forbidden"
}

assert_universal_machos() {
  local root="$1"
  local candidate
  local description
  local architectures
  local macho_count=0

  while IFS= read -r -d '' candidate; do
    description="$(file -b "$candidate")"
    case "$description" in
      Mach-O*) ;;
      *) continue ;;
    esac

    macho_count=$((macho_count + 1))
    architectures="$(lipo -archs "$candidate")"
    case " $architectures " in
      *' arm64 '*) ;;
      *) fail "Missing arm64 slice: $candidate ($architectures)" ;;
    esac
    case " $architectures " in
      *' x86_64 '*) ;;
      *) fail "Missing x86_64 slice: $candidate ($architectures)" ;;
    esac
  done < <(find "$root" -type f -print0)

  [[ $macho_count -gt 0 ]] || fail "No Mach-O files found under $root"
  printf 'Verified %d Universal 2 Mach-O files.\n' "$macho_count"
}

require_cmd codesign
require_cmd file
require_cmd find
require_cmd lipo
require_cmd pkgbuild
require_cmd pkgutil
require_cmd plutil
require_cmd shasum
if [[ "$REUSE_SIGNED_APP" == "0" ]]; then
  require_cmd xcodebuild
fi

[[ -d "$PROJECT_PATH" ]] || fail "Xcode project not found: $PROJECT_PATH"
[[ -x "$PACKAGE_SCRIPTS_DIR/preinstall" ]] || fail "Executable preinstall migration script not found: $PACKAGE_SCRIPTS_DIR/preinstall"
case "$REUSE_SIGNED_APP" in
  0|1) ;;
  *) fail "REUSE_SIGNED_APP must be 0 or 1" ;;
esac
codesign_keychain_args=()
if [[ -n "$SIGNING_KEYCHAIN" ]]; then
  [[ -f "$SIGNING_KEYCHAIN" ]] || fail "Signing keychain not found: $SIGNING_KEYCHAIN"
  codesign_keychain_args+=(--keychain "$SIGNING_KEYCHAIN")
fi

mkdir -p "$BUILD_ROOT"
if [[ "$REUSE_SIGNED_APP" == "0" ]]; then
  rm -rf "$DERIVED_DATA/Build"

  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme v2s \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    MACOSX_DEPLOYMENT_TARGET=26.0 \
    CODE_SIGNING_ALLOWED=NO \
    clean build
fi

[[ -d "$APP_PATH" ]] || fail "Built app not found: $APP_PATH"
assert_no_optional_models "$APP_PATH"
assert_universal_machos "$APP_PATH"

if [[ "$REUSE_SIGNED_APP" == "0" ]]; then
  if [[ -n "$APPLICATION_IDENTITY" ]]; then
    [[ -f "$APPLICATION_ENTITLEMENTS" ]] || fail "Application entitlements not found: $APPLICATION_ENTITLEMENTS"
    codesign --force --deep --options runtime --timestamp "${codesign_keychain_args[@]}" --sign "$APPLICATION_IDENTITY" "$APP_PATH"
    codesign --force --options runtime --timestamp --entitlements "$APPLICATION_ENTITLEMENTS" "${codesign_keychain_args[@]}" --sign "$APPLICATION_IDENTITY" "$APP_PATH"
  else
    codesign --force --deep --sign - --timestamp=none "$APP_PATH"
  fi
fi
codesign --verify --deep --strict "$APP_PATH"

version="$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")"
[[ -n "$version" ]] || fail "Could not read CFBundleShortVersionString"
bundle_name="$(plutil -extract CFBundleName raw "$APP_PATH/Contents/Info.plist")"
bundle_executable="$(plutil -extract CFBundleExecutable raw "$APP_PATH/Contents/Info.plist")"
bundle_identifier="$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Contents/Info.plist")"
[[ "$bundle_name" == "Easy2say" ]] || fail "Unexpected CFBundleName: $bundle_name"
[[ "$bundle_executable" == "Easy2say" ]] || fail "Unexpected CFBundleExecutable: $bundle_executable"
[[ "$bundle_identifier" == "com.franklioxygen.v2s" ]] || fail "Unexpected bundle identifier: $bundle_identifier"

if [[ -z "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="$BUILD_ROOT/Easy2say-${version}-universal.pkg"
fi
mkdir -p "$(dirname "$OUTPUT_PATH")"
rm -f "$OUTPUT_PATH"

pkg_args=(
  --component "$APP_PATH"
  --install-location /Applications
  --identifier com.franklioxygen.v2s.pkg
  --version "$version"
  --scripts "$PACKAGE_SCRIPTS_DIR"
)
if [[ -n "$SIGNING_KEYCHAIN" ]]; then
  pkg_args+=(--keychain "$SIGNING_KEYCHAIN")
fi
if [[ -n "$INSTALLER_IDENTITY" ]]; then
  pkg_args+=(--sign "$INSTALLER_IDENTITY")
fi
pkgbuild "${pkg_args[@]}" "$OUTPUT_PATH"

payload_files="$(pkgutil --payload-files "$OUTPUT_PATH")"
case "$payload_files" in
  *TranslateGemma*|*MonlamWhisperTibetan*|*Melong*.aimodel*|*Melong*.gguf)
    fail "Installer payload contains a forbidden model asset"
    ;;
esac
if [[ "$OUTPUT_PATH" != "$STABLE_OUTPUT_PATH" ]]; then
  mkdir -p "$(dirname "$STABLE_OUTPUT_PATH")"
  ln -f "$OUTPUT_PATH" "$STABLE_OUTPUT_PATH"
fi

checksum="$(shasum -a 256 "$OUTPUT_PATH" | cut -d ' ' -f 1)"
printf 'Built %s\n' "$OUTPUT_PATH"
printf 'Stable asset %s\n' "$STABLE_OUTPUT_PATH"
printf 'SHA-256: %s\n' "$checksum"
