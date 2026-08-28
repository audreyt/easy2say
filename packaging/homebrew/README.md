# Homebrew distribution

`easy2say.rb.template` describes the direct macOS package published from
`audreyt/easy2say`. Replace `__VERSION__` and `__SHA256__` with the GitHub
release values before placing it in a tap.

The cask downloads `Easy2say-universal.pkg`, installs `Easy2say.app` under
`/Applications`, and uninstalls the retained package identifier
`com.franklioxygen.v2s.pkg`. Bundle identifiers and Application Support paths
remain unchanged so existing users keep their settings and model caches.

`scripts/build_universal_pkg.sh` emits both the versioned package and the stable
`Easy2say-universal.pkg` hard link used by the cask and website.

No Homebrew tap automation is configured in this fork. GitHub Releases is the
source of truth.

## Gatekeeper

The app is ad-hoc signed and the installer is unsigned until Developer ID
Application and Developer ID Installer identities are available. A quarantined
download is therefore expected to be rejected by Gatekeeper. Users must
Control-click the package and choose **Open**, or approve it under
**System Settings → Privacy & Security**.

Removing `com.apple.quarantine` from `/Applications/Easy2say.app` is a
command-line bypass, not proof that the normal **Open Anyway** flow works.
