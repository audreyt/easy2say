#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/v2s.xcodeproj"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/.build/universal-pkg}"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Release/v2s.app"
OUTPUT_PATH="${OUTPUT_PATH:-}"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-}"

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
require_cmd xcodebuild

[[ -d "$PROJECT_PATH" ]] || fail "Xcode project not found: $PROJECT_PATH"

mkdir -p "$BUILD_ROOT"
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

[[ -d "$APP_PATH" ]] || fail "Built app not found: $APP_PATH"
assert_no_optional_models "$APP_PATH"
assert_universal_machos "$APP_PATH"

codesign --force --deep --sign - --timestamp=none "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

version="$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")"
[[ -n "$version" ]] || fail "Could not read CFBundleShortVersionString"

if [[ -z "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="$BUILD_ROOT/v2s-${version}-universal.pkg"
fi
mkdir -p "$(dirname "$OUTPUT_PATH")"
rm -f "$OUTPUT_PATH"

pkg_args=(
  --component "$APP_PATH"
  --install-location /Applications
  --identifier com.franklioxygen.v2s.pkg
  --version "$version"
)
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

checksum="$(shasum -a 256 "$OUTPUT_PATH" | cut -d ' ' -f 1)"
printf 'Built %s\n' "$OUTPUT_PATH"
printf 'SHA-256: %s\n' "$checksum"
