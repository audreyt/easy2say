#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/v2s.xcodeproj"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/.build/universal-pkg}"
DERIVED_DATA="$BUILD_ROOT/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Release/Easy2Say.app"
PACKAGE_SCRIPTS_DIR="$ROOT_DIR/packaging/macos/scripts"
STABLE_OUTPUT_PATH="${STABLE_OUTPUT_PATH:-$BUILD_ROOT/Easy2Say-universal.pkg}"
OUTPUT_PATH="${OUTPUT_PATH:-}"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-}"
APPLICATION_IDENTITY="${APPLICATION_IDENTITY:-}"
APPLICATION_ENTITLEMENTS="${APPLICATION_ENTITLEMENTS:-$ROOT_DIR/Config/DeveloperID.entitlements}"
REUSE_SIGNED_APP="${REUSE_SIGNED_APP:-0}"
SIGNING_KEYCHAIN="${SIGNING_KEYCHAIN:-}"
SIGNING_KEYCHAIN_PASSWORD="${SIGNING_KEYCHAIN_PASSWORD:-}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"
SPARKLE_BIN_DIR="${SPARKLE_BIN_DIR:-$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-easy2say}"
RELEASE_NOTES_PATH="${RELEASE_NOTES_PATH:-}"

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

NOTARY_LAST_SUBMISSION_ID=""

notarize_path() {
  local target="$1"
  local plist_out="$2"
  local submission_id=""
  local status=""

  xcrun notarytool submit "$target" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --wait --output-format plist > "$plist_out" || true

  if [[ -f "$plist_out" ]]; then
    status="$(plutil -extract status raw "$plist_out" 2>/dev/null || true)"
    submission_id="$(plutil -extract id raw "$plist_out" 2>/dev/null || true)"
  fi

  if [[ "$status" != "Accepted" ]]; then
    printf 'error: notarization failed for %s (status: %s, submission: %s)\n' \
      "$target" "${status:-unknown}" "${submission_id:-unknown}" >&2
    if [[ -n "$submission_id" ]]; then
      xcrun notarytool log "$submission_id" \
        --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" >&2 || true
    fi
    exit 1
  fi

  printf 'Notarization accepted for %s (submission %s)\n' "$target" "$submission_id"
  NOTARY_LAST_SUBMISSION_ID="$submission_id"
}

assert_notarized_source() {
  local target="$1"
  local assess_type="$2"
  local output

  if ! output="$(spctl --assess --type "$assess_type" -vv "$target" 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "Gatekeeper assessment failed: $target"
  fi
  printf '%s\n' "$output"
  case "$output" in
    *'source=Notarized Developer ID'*) ;;
    *) fail "Expected 'source=Notarized Developer ID' for $target" ;;
  esac
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
if [[ -n "$SIGNING_KEYCHAIN_PASSWORD" ]]; then
  require_cmd security
fi
if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
  require_cmd ditto
  require_cmd spctl
  require_cmd xcrun
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
  if [[ -n "$SIGNING_KEYCHAIN_PASSWORD" ]]; then
    security unlock-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN"
  fi
fi

if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
  [[ -n "$APPLICATION_IDENTITY" ]] || fail "APPLICATION_IDENTITY is required when NOTARY_KEYCHAIN_PROFILE is set"
  [[ -n "$INSTALLER_IDENTITY" ]] || fail "INSTALLER_IDENTITY is required when NOTARY_KEYCHAIN_PROFILE is set"
fi

mkdir -p "$BUILD_ROOT"
if [[ "$REUSE_SIGNED_APP" == "0" ]]; then
  rm -rf "$DERIVED_DATA"

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
    SWIFT_VERSION=5.0 \
    OTHER_SWIFT_FLAGS='-disable-sandbox' \
    DISABLE_TASK_SANDBOXING=YES \
    clean build
fi

[[ -d "$APP_PATH" ]] || fail "Built app not found: $APP_PATH"
assert_no_optional_models "$APP_PATH"
assert_universal_machos "$APP_PATH"

version="$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")"
[[ -n "$version" ]] || fail "Could not read CFBundleShortVersionString"
bundle_name="$(plutil -extract CFBundleName raw "$APP_PATH/Contents/Info.plist")"
bundle_display_name="$(plutil -extract CFBundleDisplayName raw "$APP_PATH/Contents/Info.plist")"
bundle_executable="$(plutil -extract CFBundleExecutable raw "$APP_PATH/Contents/Info.plist")"
bundle_identifier="$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Contents/Info.plist")"
[[ "$bundle_name" == "Easy2Say" ]] || fail "Unexpected CFBundleName: $bundle_name"
[[ "$bundle_display_name" == "Easy2Say" ]] || fail "Unexpected CFBundleDisplayName: $bundle_display_name"
[[ "$bundle_executable" == "Easy2Say" ]] || fail "Unexpected CFBundleExecutable: $bundle_executable"
[[ "$bundle_identifier" == "com.franklioxygen.v2s" ]] || fail "Unexpected bundle identifier: $bundle_identifier"

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

notary_app_submission_id=""
notary_pkg_submission_id=""
if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
  notary_zip="$BUILD_ROOT/Easy2Say-${version}-notary.zip"
  rm -f "$notary_zip"
  ditto -c -k --keepParent "$APP_PATH" "$notary_zip"
  notarize_path "$notary_zip" "$BUILD_ROOT/notary-app.plist"
  notary_app_submission_id="$NOTARY_LAST_SUBMISSION_ID"
  xcrun stapler staple "$APP_PATH"
  assert_notarized_source "$APP_PATH" exec
fi

if [[ -z "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="$BUILD_ROOT/Easy2Say-${version}-universal.pkg"
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

if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
  notarize_path "$OUTPUT_PATH" "$BUILD_ROOT/notary-pkg.plist"
  notary_pkg_submission_id="$NOTARY_LAST_SUBMISSION_ID"
  xcrun stapler staple "$OUTPUT_PATH"
  assert_notarized_source "$OUTPUT_PATH" install
  pkg_signature="$(pkgutil --check-signature "$OUTPUT_PATH")"
  printf '%s\n' "$pkg_signature"
  case "$pkg_signature" in
    *'Notarization: trusted by the Apple notary service'*) ;;
    *) fail "Package notarization is not trusted: $OUTPUT_PATH" ;;
  esac
fi

if [[ "$OUTPUT_PATH" != "$STABLE_OUTPUT_PATH" ]]; then
  mkdir -p "$(dirname "$STABLE_OUTPUT_PATH")"
  ln -f "$OUTPUT_PATH" "$STABLE_OUTPUT_PATH"
fi

sparkle_zip=""
sparkle_appcast=""
if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
  sparkle_dir="$BUILD_ROOT/Sparkle"
  sparkle_zip="$sparkle_dir/Easy2Say-${version}.app.zip"
  sparkle_appcast="$sparkle_dir/appcast.xml"
  mkdir -p "$sparkle_dir"
  rm -f "$sparkle_dir"/*.zip "$sparkle_dir"/*.md "$sparkle_appcast"
  ditto -c -k --keepParent "$APP_PATH" "$sparkle_zip"
  if [[ -n "$RELEASE_NOTES_PATH" ]]; then
    [[ -f "$RELEASE_NOTES_PATH" ]] || fail "Release notes not found: $RELEASE_NOTES_PATH"
    cp "$RELEASE_NOTES_PATH" "$sparkle_dir/Easy2Say-${version}.app.md"
  fi
  "$SPARKLE_BIN_DIR/generate_appcast" \
    --account "$SPARKLE_ACCOUNT" \
    --link https://easy2say.ai/ \
    --embed-release-notes \
    --download-url-prefix "https://github.com/audreyt/easy2say/releases/download/v${version}/" \
    "$sparkle_dir"
  [[ -f "$sparkle_appcast" ]] || fail "generate_appcast did not produce $sparkle_appcast"
  appcast_xml="$(<"$sparkle_appcast")"
  case "$appcast_xml" in
    *"sparkle:shortVersionString>${version}<"*) ;;
    *) fail "Appcast is missing sparkle:shortVersionString for $version" ;;
  esac
  case "$appcast_xml" in
    *"releases/download/v${version}/Easy2Say-${version}.app.zip"*) ;;
    *) fail "Appcast enclosure URL does not match v${version} download prefix" ;;
  esac
  sparkle_public_key="$("$SPARKLE_BIN_DIR/generate_keys" -p --account "$SPARKLE_ACCOUNT")"
  bundle_public_key="$(plutil -extract SUPublicEDKey raw "$APP_PATH/Contents/Info.plist")"
  [[ "$sparkle_public_key" == "$bundle_public_key" ]] \
    || fail "Sparkle public key ($sparkle_public_key) does not match SUPublicEDKey ($bundle_public_key)"
fi

checksum="$(shasum -a 256 "$OUTPUT_PATH" | cut -d ' ' -f 1)"
checksum_path="$BUILD_ROOT/Easy2Say-${version}.sha256"
printf '%s  %s\n' "$checksum" "$(basename "$STABLE_OUTPUT_PATH")" > "$checksum_path"
printf 'Built %s\n' "$OUTPUT_PATH"
printf 'Stable asset %s\n' "$STABLE_OUTPUT_PATH"
if [[ -n "$sparkle_zip" ]]; then
  printf 'Sparkle archive %s\n' "$sparkle_zip"
  printf 'Sparkle appcast %s\n' "$sparkle_appcast"
fi
printf 'SHA-256 file %s\n' "$checksum_path"
printf 'SHA-256: %s\n' "$checksum"
if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
  printf 'Notary submission (app): %s\n' "$notary_app_submission_id"
  printf 'Notary submission (pkg): %s\n' "$notary_pkg_submission_id"
fi
