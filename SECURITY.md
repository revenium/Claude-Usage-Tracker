# Security Policy

## Supported versions

Revenium provides security fixes for the latest stable release of Claude Usage.
Install the current version from:

- [Revenium GitHub Releases](https://github.com/revenium/Claude-Usage-Tracker/releases/latest)
- [Revenium Homebrew tap](https://github.com/revenium/homebrew-tap)

## Report a vulnerability privately

Do not open a public issue for a suspected vulnerability.

Use the repository's
[private security advisory form](https://github.com/revenium/Claude-Usage-Tracker/security/advisories/new).
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

Claude Usage handles account credentials and local usage state:

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
4. Submitted to Apple's notary service and stapled
5. Assessed by Gatekeeper
6. Archived with a SHA-256 checksum
7. Signed with a Revenium-owned Sparkle Ed25519 key
8. Published with metadata tying version, build, commit, URL, and checksum
9. Distributed through the Revenium GitHub repository and Homebrew tap

The production Sparkle feed is:

```text
https://github.com/revenium/Claude-Usage-Tracker/releases/latest/download/appcast.xml
```

Debug and ordinary local Release builds contain no feed or Sparkle public key,
so they cannot accidentally consume another owner's production channel.

See [RELEASING.md](RELEASING.md) for the executable verification checklist.

## Verify a downloaded release

Download `Claude-Usage.zip`, `Claude-Usage.zip.sha256`, `appcast.xml`, and
`release-metadata.json` from the same release, then run:

```bash
./scripts/verify_release_artifacts.sh \
  --require-developer-id \
  --require-notarization \
  Claude-Usage.zip \
  appcast.xml \
  Claude-Usage.zip.sha256 \
  release-metadata.json
```

For non-security bugs, use
[Revenium GitHub Issues](https://github.com/revenium/Claude-Usage-Tracker/issues).
