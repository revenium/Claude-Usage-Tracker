# Release Process

Claude Usage is distributed by Revenium as one cohesive release unit:

- A universal `Claude Usage.app` preserving bundle ID
  `HamedElfayome.Claude-Usage`
- `Claude-Usage.dmg` — the only downloadable artifact; a Developer ID signed,
  notarized, stapled disk image containing the app plus an `Applications`
  symlink
- `appcast.xml`
- A generated `revenium/tap/claude-usage` Homebrew cask

Published assets are exactly the two listed above. `release-metadata.json`
(tag, commit, version/build, identity, URL, checksum) is still generated
during the release for internal cohesion checks — `scripts/verify_release_artifacts.sh`
consumes it — but it is not uploaded; GitHub's own per-asset SHA-256 digest is
the download-integrity check consumers use instead of an unsigned sidecar file.

The tagged commit, app version/build, DMG, Sparkle signature, appcast URL,
internal metadata, and Homebrew checksum must all describe the same release.
`.github/workflows/release.yml` creates and verifies that unit before publishing
it. It refuses to replace an existing release.

## Distribution identity

The operational owner changed; the application identity did not.

| Property | Required value | Reason |
| --- | --- | --- |
| App name | `Claude Usage` | Product and on-disk compatibility |
| Bundle ID / preference domain | `HamedElfayome.Claude-Usage` | Preserve profiles, preferences, update identity, and Keychain behavior |
| App group | `group.com.claudeusagetracker.shared` | Preserve legacy migration access |
| Minimum macOS | `14.0` | Existing support contract |
| Source repository | `revenium/Claude-Usage-Tracker` | Current operational ownership |
| Sparkle feed | `https://github.com/revenium/Claude-Usage-Tracker/releases/latest/download/appcast.xml` | Stable Revenium-owned HTTPS endpoint |
| Homebrew cask | `revenium/tap/claude-usage` | Existing Revenium tap |

The Developer ID team and Sparkle key are distribution credentials, not bundle
identity. They are injected by the protected release environment and must not
be hard-coded in the project.

## One-time owner setup

As of July 30, 2026, the repository has no Actions variables, secrets, or
environments. The inherited `gh-pages` branch contains prior-owner artifacts,
but GitHub Pages is not configured. Complete every item below before creating
the first Revenium release.

### 1. Protect the release environment

Create a GitHub environment named `release` and require an authorized Revenium
release owner to approve deployments. Restrict tag creation to release
maintainers and require the normal CI and distribution-validation checks on
`main`.

After the first release is proven, enable GitHub immutable releases so tags and
assets cannot be changed after publication. The release workflow refuses to
replace a published or unowned release; it can safely replace only its own
commit-provenance-marked draft after an interrupted attempt.

### 2. Create and back up a Revenium Sparkle key

Use the `generate_keys` binary from the exact Sparkle version resolved by this
project. Use a Revenium-specific account name so another application's key
cannot be selected accidentally.

```bash
xcodebuild -resolvePackageDependencies \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -derivedDataPath build

SPARKLE_BIN="build/SourcePackages/artifacts/sparkle/Sparkle/bin"
"$SPARKLE_BIN/generate_keys" --account revenium-claude-usage
```

The command prints the public key and stores the private key in the login
Keychain. Before moving or deleting any key material, export an encrypted,
access-controlled backup and verify that the backup can be recovered:

```bash
"$SPARKLE_BIN/generate_keys" \
  --account revenium-claude-usage \
  -x /secure/temporary/location/claude-usage-sparkle-private-key
```

Never commit that file or paste it into logs. Store its contents as the
`SPARKLE_PRIVATE_KEY` Actions secret, store the printed public key as the
`SPARKLE_PUBLIC_ED_KEY` Actions variable, and retain a separately protected
owner backup. Remove the temporary export only after the protected backup and
GitHub secret are verified.

The release workflow passes the private key to Sparkle through standard input.
It never writes the key to the repository or release artifacts. Sparkle's
`generate_appcast` rejects a key that does not match the public key embedded in
the release app.

### 3. Configure Apple signing and notarization

Import a valid Developer ID Application certificate into the protected release
configuration. The workflow builds without signing, imports the certificate
into an ephemeral keychain, signs Sparkle's nested components in the documented
order, signs the app with Hardened Runtime, submits with `notarytool`, staples
the ticket, and requires Gatekeeper acceptance.

Set these Actions variables:

- `DEVELOPER_ID_APPLICATION` — exact identity returned by
  `security find-identity -v -p codesigning`
- `APPLE_TEAM_ID` — the 10-character team ID belonging to that identity
- `SPARKLE_PUBLIC_ED_KEY` — the Revenium Ed25519 public key

Set these protected Actions secrets:

- `DEVELOPER_CERTIFICATE_BASE64`
- `CERTIFICATE_PASSWORD`
- `APPLE_ID`
- `APPLE_ID_PASSWORD` — an app-specific password
- `SPARKLE_PRIVATE_KEY`

The current workstation has a usable Developer ID identity, but the workflow
does not assume a person's certificate or team. The release owner must confirm
that the configured identity is the intended long-term Revenium signer.

### 4. Configure the Revenium Homebrew tap

`revenium/homebrew-tap` exists but does not yet contain a cask. Create a
fine-grained token (or GitHub App credential) with Contents write access only
to that repository and save it as the `HOMEBREW_TAP_TOKEN` repository secret in
`revenium/Claude-Usage-Tracker`.

The first successful release creates:

```text
Casks/claude-usage.rb
```

Later releases update only its version and SHA-256. The workflow runs
`brew audit`, `brew fetch`, and a dry-run install before committing the cask.

### 5. Remove the inherited Pages hazard

GitHub Pages must remain disabled; the active application and workflows never
read or write `gh-pages`.

Before deleting or rewriting that branch, create a recoverable archive and
record its commit SHA. Then either delete the inherited branch or replace it
with a neutral archival notice that contains no appcast or release ZIP. Verify
in repository Settings that Pages publishes from `None`, and verify the Pages
API remains disabled. Do not enable Pages for this release design.

This cleanup is intentionally an owner action because deleting or rewriting a
remote branch is destructive. The application is safe before that action:
ordinary builds contain no feed, and production accepts only the Revenium
GitHub Releases URL plus the Revenium key.

### 6. Recommended repository protections

- Enable secret scanning and push protection.
- Require CI and Distribution Validation on `main`.
- Protect stable `vX.Y.Z` tags or use a release ruleset.
- Require approval on the `release` environment.
- Enable immutable releases after the bootstrap release.
- Keep GitHub Pages disabled.

## Configure values with GitHub CLI

Use interactive prompts or standard input so secrets do not appear in shell
history:

```bash
REPO="revenium/Claude-Usage-Tracker"

gh variable set SPARKLE_PUBLIC_ED_KEY --repo "$REPO"
gh variable set DEVELOPER_ID_APPLICATION --repo "$REPO"
gh variable set APPLE_TEAM_ID --repo "$REPO"

gh secret set DEVELOPER_CERTIFICATE_BASE64 --repo "$REPO"
gh secret set CERTIFICATE_PASSWORD --repo "$REPO"
gh secret set APPLE_ID --repo "$REPO"
gh secret set APPLE_ID_PASSWORD --repo "$REPO"
gh secret set SPARKLE_PRIVATE_KEY --repo "$REPO"
gh secret set HOMEBREW_TAP_TOKEN --repo "$REPO"
```

List names—not values—to confirm configuration:

```bash
gh variable list --repo "$REPO"
gh secret list --repo "$REPO"
```

## Release checklist

### 1. Prepare a release PR

1. Update `MARKETING_VERSION` in both app configurations.
2. Increment `CURRENT_PROJECT_VERSION` in both app configurations.
3. Add a matching `## [X.Y.Z] - YYYY-MM-DD` entry to `CHANGELOG.md`.
4. Run the full PR validation suite.
5. Merge through the normal reviewed PR process.

The build number is Sparkle's comparison version and must always increase,
including patch releases.

### 2. Validate the exact merged commit

```bash
git fetch upstream main --tags
git switch main
git merge --ff-only upstream/main

./scripts/validate_distribution.sh
./scripts/validate_localizations.sh
swift test --package-path Packages/UsageKit

xcodebuild test \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -configuration Debug \
  -destination "platform=macOS" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
```

### 3. Create an annotated stable tag

```bash
VERSION="X.Y.Z"
git tag -a "v$VERSION" -m "Release v$VERSION"
git push upstream "v$VERSION"
```

The release job checks that:

- The tag is exactly `vX.Y.Z`.
- The tag commit is contained in `origin/main`.
- The tag matches the app target's `MARKETING_VERSION`.
- `CURRENT_PROJECT_VERSION` is numeric.
- Every required variable and secret is present.

### 4. Watch the release workflow

Monitor:

```text
https://github.com/revenium/Claude-Usage-Tracker/actions
```

The workflow performs, in order:

1. Distribution, localization, package, and app test gates.
2. Universal Release build with the protected feed and public key injected.
3. Developer ID signing of Sparkle components and the app.
4. Hardened Runtime and entitlement verification.
5. Apple notarization, ticket stapling, and Gatekeeper assessment of the app.
6. Disk image creation (DMG with an `Applications` symlink), Developer ID
   signing, notarization, and stapling of the disk image itself.
7. Appcast generation and Ed25519 signature verification.
8. Metadata, version, URL, length, checksum, architecture, bundle identity,
   entitlements, and notarization cohesion verification.
9. Provenance-owned draft creation, exact asset upload, remote re-download and
   full cohesion verification, followed by publication.
10. Revenium Homebrew cask audit and a single optimistic-SHA Contents API
    update after the release commit is proven to be on `main`.

### 5. Independently verify the published unit

Download the two published assets:

```bash
TAG="vX.Y.Z"
mkdir -p /tmp/claude-usage-release
gh release download "$TAG" \
  --repo revenium/Claude-Usage-Tracker \
  --dir /tmp/claude-usage-release
```

`release-metadata.json` is generated during release for cohesion checking but
is not published (GitHub's own per-asset digest replaces the old checksum
sidecar for download integrity). `verify_release_artifacts.sh` still needs a
metadata file, so reconstruct it from the tagged source and the downloaded
DMG — this is exactly what the manual **Verify Published Appcast** workflow
does:

```bash
git checkout "$TAG"
version=${TAG#v}
build=$(xcodebuild -project 'Claude Usage.xcodeproj' -target 'Claude Usage' \
  -configuration Release -showBuildSettings \
  | awk '/ CURRENT_PROJECT_VERSION = / { print $3; exit }')
sha256=$(shasum -a 256 /tmp/claude-usage-release/Claude-Usage.dmg | awk '{ print $1 }')

jq -n \
  --arg tag "$TAG" --arg version "$version" --arg build "$build" \
  --arg commit "$(git rev-parse HEAD)" \
  --arg bundleIdentifier 'HamedElfayome.Claude-Usage' \
  --arg minimumSystemVersion '14.0' \
  --arg artifactURL "https://github.com/revenium/Claude-Usage-Tracker/releases/download/$TAG/Claude-Usage.dmg" \
  --arg sha256 "$sha256" \
  '{tag: $tag, version: $version, build: $build, commit: $commit,
    bundleIdentifier: $bundleIdentifier, minimumSystemVersion: $minimumSystemVersion,
    artifactURL: $artifactURL, sha256: $sha256}' \
  > /tmp/claude-usage-release/release-metadata.json

./scripts/verify_release_artifacts.sh \
  --require-developer-id \
  --require-notarization \
  /tmp/claude-usage-release/Claude-Usage.dmg \
  /tmp/claude-usage-release/appcast.xml \
  /tmp/claude-usage-release/release-metadata.json
```

The manual **Verify Published Appcast** workflow repeats this check and also
verifies the DMG's Sparkle signature with the protected signing key.

### 6. Verify Homebrew

```bash
brew update
brew tap revenium/tap
brew audit --cask --strict revenium/tap/claude-usage
brew fetch --cask --force revenium/tap/claude-usage
brew install --cask --dry-run --require-sha revenium/tap/claude-usage
```

On a disposable clean-machine test account, perform one real install and
launch:

```bash
brew install --cask revenium/tap/claude-usage
open -a "Claude Usage"
```

Confirm About and Updates open Revenium destinations and that existing
profiles/preferences remain available when upgrading over an earlier build.

## Controlled Sparkle smoke test

Ordinary Debug builds use channel `development`, contain no feed or key, and
cannot check for updates. Ordinary local Release builds use channel
`production` but also contain no feed or key, so they remain disabled.

For an intentional smoke test only, a Debug build accepts channel `testing`
with an explicitly supplied HTTPS feed and test public key. Release compilation
does not contain this path.

1. Generate a disposable test key with Sparkle. Do not commit it.
2. Build an older Debug app with `REVENIUM_UPDATE_CHANNEL=testing`,
   `SPARKLE_FEED_URL=<controlled Revenium HTTPS appcast>`, and
   `SPARKLE_PUBLIC_ED_KEY=<test public key>`.
3. Build a higher-numbered Debug app with the same bundle ID and key.
4. Use `generate_appcast --ed-key-file -` to publish the second app to the
   controlled feed.
5. Launch the older build twice, choose Check for Updates, install, and verify
   the new version and preserved test profile.
6. Remove the controlled artifact and dispose of the test key after retaining
   any evidence needed for the release record.

Never point the controlled test at a prior maintainer's production feed.

## Evidence classification

| Evidence | What it proves |
| --- | --- |
| Unsigned local Debug/Release build | Compilation, embedded identity, and update isolation |
| Ad-hoc `codesign` result | Bundle structure only; **not** Developer ID or notarization |
| `codesign` with Developer ID + timestamp | Authenticated signer and Hardened Runtime |
| Successful `notarytool` log | Apple accepted the submitted artifact |
| `stapler validate` + `spctl --assess` | Ticket is attached and Gatekeeper accepts the app |
| Sparkle signature verification | Archive matches the configured Ed25519 key |
| `brew fetch` | Cask URL resolves and checksum matches |
| Clean-account upgrade | Runtime compatibility and preference/profile preservation |

Do not describe a local or ad-hoc artifact as notarized.

## Primary documentation

- [Sparkle basic setup and signing](https://sparkle-project.org/documentation/)
- [Sparkle publishing](https://sparkle-project.org/documentation/publishing/)
- [Sparkle code signing](https://sparkle-project.org/documentation/sandboxing/)
- [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [GitHub Actions workflow permissions](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
- [GitHub Actions secrets](https://docs.github.com/en/actions/concepts/security/secrets)
- [Homebrew Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)
- [Homebrew tap guide](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)
