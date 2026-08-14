# Security Policy

## Supported versions

Revenium provides security fixes for the latest stable release of RevvyTach.
Install the current version from:

- [Revenium GitHub Releases](https://github.com/revenium/RevvyTach/releases/latest)
- [Revenium Homebrew tap](https://github.com/revenium/homebrew-tap)

## Report a vulnerability privately

Do not open a public issue for a suspected vulnerability.

Use the repository's
[private security advisory form](https://github.com/revenium/RevvyTach/security/advisories/new).
If GitHub advisories are unavailable, email
[support@revenium.io](mailto:support@revenium.io) with:

- A description of the issue and its impact
- Reproduction steps or a proof of concept
- Affected versions and macOS versions
- Any suggested mitigation
- A safe way to contact you

Revenium will acknowledge the report, investigate it, coordinate remediation,
and credit the reporter when requested and appropriate.

## Sensitive data

RevvyTach handles account credentials and local usage state:

- Claude and API secrets are stored in macOS Keychain.
- Codex authentication files are read through supported local tooling; the app
  must not copy raw credentials into profiles, diagnostics, logs, or reports.
- Profile metadata and usage history remain on the Mac.
- Feedback opens a reviewable Revenium GitHub issue draft; the app does not
  forward feedback to a third-party collection endpoint.
- The app has no telemetry or cloud sync.

Never include real session keys, API keys, OAuth tokens, account identifiers,
Sparkle private keys, Apple credentials, certificates, or diagnostic archives
containing personal data in a public issue.

## Release and update security

Official releases are:

1. Built from a stable tag already contained in `main`
2. Tested before packaging
3. Signed with a configured Developer ID Application identity
4. Submitted to Apple's notary service and stapled — both the app and the disk image that contains it
5. Assessed by Gatekeeper
6. Packaged as a single Developer ID signed, notarized `.dmg` (GitHub publishes a SHA-256 digest for every release asset; no separate checksum sidecar is needed or published)
7. Signed with a Revenium-owned Sparkle Ed25519 key
8. Verified for version, build, commit, URL, and checksum cohesion against internal release metadata before publishing
9. Distributed through the Revenium GitHub repository and Homebrew tap

The production Sparkle feed is:

```text
https://github.com/revenium/RevvyTach/releases/latest/download/appcast.xml
```

Debug and ordinary local Release builds contain no feed or Sparkle public key,
so they cannot accidentally consume another owner's production channel.

See [RELEASING.md](RELEASING.md) for the executable verification checklist.

## Verify a downloaded release

Download `RevvyTach.dmg` from the release, then:

1. Compare its checksum to the digest GitHub reports for that asset (shown on
   the release page, or via `gh release view <tag> --json assets`):

   ```bash
   shasum -a 256 RevvyTach.dmg
   gh release view vX.Y.Z --repo revenium/RevvyTach \
     --json assets --jq '.assets[] | select(.name == "RevvyTach.dmg") | .digest'
   ```

   The two SHA-256 values must match.

2. Verify the disk image itself, then mount it and verify the app inside
   without launching it. The disk image is the artifact you actually
   downloaded, so it carries its own signature and notarization ticket —
   verify the container, not just its payload:

   ```bash
   xcrun stapler validate RevvyTach.dmg
   spctl --assess --type open --context context:primary-signature \
     --verbose=4 RevvyTach.dmg

   mount_point=$(hdiutil attach -nobrowse -readonly RevvyTach.dmg \
     | awk -F'\t' '/\/Volumes\// { print $NF; exit }')
   app_path="$mount_point/RevvyTach.app"

   codesign --verify --deep --strict --verbose=2 "$app_path"
   xcrun stapler validate "$app_path"
   spctl --assess --type execute --verbose=4 "$app_path"

   hdiutil detach "$mount_point"
   ```

   All five checks must pass before you trust and launch the app.

For non-security bugs, use
[Revenium GitHub Issues](https://github.com/revenium/RevvyTach/issues).
