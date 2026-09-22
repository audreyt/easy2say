# Homebrew distribution

`easy2say.rb.template` describes the direct macOS package published from
`audreyt/easy2say`. Replace `__VERSION__` and `__SHA256__` with the GitHub
release values before placing it in a tap.

The cask downloads `Easy2Say-universal.pkg`, installs `Easy2Say.app` under
`/Applications`, and uninstalls the retained package identifier
`com.franklioxygen.v2s.pkg`. Bundle identifiers and Application Support paths
remain unchanged so existing users keep their settings and model caches.

`scripts/build_universal_pkg.sh` emits both the versioned package and the stable
`Easy2Say-universal.pkg` hard link used by the cask and website.

No Homebrew tap automation is configured in this fork. GitHub Releases is the
source of truth.

## Release signing

`scripts/build_universal_pkg.sh` signs the app and installer with Developer ID,
submits both to Apple notarization, and staples the tickets when these
environment variables are set:

- `SIGNING_KEYCHAIN` — keychain holding the Developer ID identities.
- `SIGNING_KEYCHAIN_PASSWORD` — unlocks that keychain before signing.
- `APPLICATION_IDENTITY` / `INSTALLER_IDENTITY` — the Developer ID Application
  and Developer ID Installer identity names.
- `NOTARY_KEYCHAIN_PROFILE` — notarytool credentials profile created via
  `xcrun notarytool store-credentials`.
- `RELEASE_NOTES_PATH` — optional markdown release notes copied next to the
  Sparkle archive for `generate_appcast`.

Without them the script keeps producing an unsigned, un-notarized package.

Never upload a pkg whose `pkgutil --check-signature` output lacks
"Notarization: trusted by the Apple notary service".
