# Release Process

RevvyTach is distributed by Revenium as one cohesive release unit:

- A universal `RevvyTach.app` with bundle ID
  `com.revenium.RevvyTach`
- `RevvyTach.dmg` — the only downloadable artifact; a Developer ID signed,
  notarized, stapled disk image containing the app plus an `Applications`
  symlink
- `appcast.xml`
- A generated `revenium/tap/revvytach` Homebrew cask

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

The app was renamed to RevvyTach in v4.0.0; on first launch the renamed app
adopts the legacy identity's preferences and Application Support data via
`LegacyIdentityMigrationService` (Keychain items use bundle-ID-independent
service names and need no migration).

| Property | Required value | Reason |
| --- | --- | --- |
| App name | `RevvyTach` | Product identity |
| Bundle ID / preference domain | `com.revenium.RevvyTach` | Update identity; legacy `HamedElfayome.Claude-Usage` data is adopted by first-launch migration |
| App group | `group.com.claudeusagetracker.shared` | Preserve legacy migration access |
| Minimum macOS | `14.0` | Existing support contract |
| Source repository | `revenium/RevvyTach` | Current operational ownership |
| Sparkle feed | `https://github.com/revenium/RevvyTach/releases/latest/download/appcast.xml` | Stable Revenium-owned HTTPS endpoint; pre-rename installs reach it through the GitHub repo-rename redirect |
| Homebrew cask | `revenium/tap/revvytach` | Existing Revenium tap |
| Legacy app copy in the DMG | `Claude Usage.app` | Keeps Sparkle in-app updates working for pre-rename (3.x) installs — see below |

### The legacy-named app copy is load-bearing

The DMG ships **two identical copies** of the app: `RevvyTach.app` and
`Claude Usage.app`. This is deliberate and must not be "cleaned up".

Sparkle locates the app inside a downloaded archive with
`SUInstaller installSourcePathInUpdateFolder:forHost:`, which matches on the
**host's** bundle filename, the host's `CFBundleName`, or the host's bundle
identifier. The v4.0.0 rename changed the app filename *and* the bundle ID at
the same time, so for a 3.x host (`Claude Usage.app` /
`HamedElfayome.Claude-Usage`) all three rules miss. Sparkle then reports "No
suitable install is found", which `SPUInstallerDriver` surfaces to the user as
the badly misleading **"The update is improperly signed and could not be
validated."** — even though the signature is perfectly valid.

The legacy-named copy restores the first matching rule, so 3.x installs can
update in place. Sparkle installs to `host.bundlePath`, so a 3.x machine keeps
the app at `/Applications/Claude Usage.app` while its contents become RevvyTach;
its `CFBundleName` is then `RevvyTach`, so every subsequent update matches the
`CFBundleName` rule against `RevvyTach.app` and needs no special handling.

A 4.x host may match either copy (the bundle IDs are identical) — harmless,
because the copies are byte-identical and Sparkle installs to the host's own
path either way. `scripts/verify_release_artifacts.sh` enforces both presence
and byte-identity, and `scripts/validate_distribution.sh` enforces that the
release workflow still stages the copy. The copy roughly doubles the DMG
(~13 MB → ~27 MB); it can be dropped once no 3.x installs remain in the wild,
which is a deliberate future decision, not a cleanup.

The Developer ID team and Sparkle key are distribution credentials, not bundle
identity. They are injected by the protected release environment and must not
be hard-coded in the project. This includes the `keychain-access-groups`
entitlement: the entitlements files carry `$(DEVELOPMENT_TEAM)` as a
placeholder rather than the literal team ID. Xcode resolves it itself for any
signed local build; the release workflow signs with a bare `codesign` call
rather than through an Xcode build phase, so it resolves the placeholder
explicitly from the `APPLE_TEAM_ID` Actions variable into a runner-local copy
of the entitlements immediately before signing.

The same rule applies to the `UAT` build configuration (bundle ID
`com.revenium.RevvyTach.uat`, used to run this app's own feature work
against a real menu bar without touching a real installation's Keychain
items or preferences — see `KeychainBuildVariant`/`AppBuildVariant` in
`Claude Usage/Shared/Services/KeychainService.swift` and
`Claude Usage/Shared/Utilities/Constants.swift`). Its committed build
settings specify `CODE_SIGN_IDENTITY = "Developer ID Application"` (the
generic form, so it resolves against whatever matching certificate exists
in the local keychain) but deliberately carry **no** `DEVELOPMENT_TEAM` —
Xcode requires one to resolve Developer ID signing regardless of
`CODE_SIGN_STYLE`, and baking a specific person's team ID into this shared
project file is exactly what this section exists to prevent. Supply it at
build time instead:

```bash
xcodebuild build -scheme "Claude Usage" -configuration UAT \
  DEVELOPMENT_TEAM=<your 10-character team ID>
```

Verify with `codesign -dv --verbose=2` on the built app: it must show your
team's `TeamIdentifier` and no `adhoc` flag. An ad-hoc-signed UAT build
cannot hold an Accessibility (or any other TCC) grant stably — ad-hoc
signatures change on every rebuild, so macOS re-prompts on every launch.

## One-time owner setup

**Status: complete as of August 3, 2026.** All variables, secrets, and the
protected `release` environment below are configured, and v3.1.0 was the first
release produced end-to-end by the workflow (v3.0.3–v3.0.5 were built and
uploaded manually while this setup was incomplete). Keep this section as the
reference for credential rotation or for standing the pipeline up again.

Two operational notes learned during setup:

- Exporting the Developer ID certificate with `security export` fails with
  "User interaction is not allowed" from any non-interactive shell; run the
  export from a real Terminal session where the keychain prompts can appear.
- The `HOMEBREW_TAP_TOKEN` fine-grained PAT must be created with **resource
  owner `revenium`** (the organization). A token whose resource owner is a
  personal account cannot be granted permissions on the org-owned tap
  repository, no matter what its permission list says.

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

`revenium/homebrew-tap` contains `Casks/revvytach.rb` (created by the
v3.1.0 release). The workflow authenticates with the `HOMEBREW_TAP_TOKEN`
repository secret: a fine-grained token with resource owner `revenium` and
Contents write access to only that repository. The current token
(`homebrew-tap-cask-update`) **expires August 3, 2027** — the cask job will
start failing then until a replacement token is generated and the secret
updated.

Releases update only the cask's version and SHA-256. The workflow runs
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
REPO="revenium/RevvyTach"

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

1. Update `MARKETING_VERSION` in all four app configurations (Debug, Release,
   UITesting, UAT).
2. Increment `CURRENT_PROJECT_VERSION` in the same four configurations.
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

### 4. Approve and watch the release workflow

The run pauses on the protected `release` environment until an authorized
reviewer approves it — in the run's page on github.com/…/actions, or from the
CLI (works for the initial run and for any `gh run rerun`, which pauses on the
same gate again):

```bash
REPO="revenium/RevvyTach"
RUN_ID=$(gh run list --repo "$REPO" --workflow Release --limit 1 --json databaseId --jq '.[0].databaseId')
ENV_ID=$(gh api "repos/$REPO/actions/runs/$RUN_ID/pending_deployments" --jq '.[0].environment.id')
gh api "repos/$REPO/actions/runs/$RUN_ID/pending_deployments" \
  -X POST -F "environment_ids[]=$ENV_ID" -f state=approved \
  -f comment="Approving release deployment"
```

Monitor:

```text
https://github.com/revenium/RevvyTach/actions
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
mkdir -p /tmp/revvytach-release
gh release download "$TAG" \
  --repo revenium/RevvyTach \
  --dir /tmp/revvytach-release
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
sha256=$(shasum -a 256 /tmp/revvytach-release/RevvyTach.dmg | awk '{ print $1 }')

jq -n \
  --arg tag "$TAG" --arg version "$version" --arg build "$build" \
  --arg commit "$(git rev-parse HEAD)" \
  --arg bundleIdentifier 'com.revenium.RevvyTach' \
  --arg minimumSystemVersion '14.0' \
  --arg artifactURL "https://github.com/revenium/RevvyTach/releases/download/$TAG/RevvyTach.dmg" \
  --arg sha256 "$sha256" \
  '{tag: $tag, version: $version, build: $build, commit: $commit,
    bundleIdentifier: $bundleIdentifier, minimumSystemVersion: $minimumSystemVersion,
    artifactURL: $artifactURL, sha256: $sha256}' \
  > /tmp/revvytach-release/release-metadata.json

./scripts/verify_release_artifacts.sh \
  --require-developer-id \
  --require-notarization \
  /tmp/revvytach-release/RevvyTach.dmg \
  /tmp/revvytach-release/appcast.xml \
  /tmp/revvytach-release/release-metadata.json
```

The manual **Verify Published Appcast** workflow repeats this check and also
verifies the DMG's Sparkle signature with the protected signing key.

### 6. Verify Homebrew

```bash
brew update
brew tap revenium/tap
brew audit --cask --strict revenium/tap/revvytach
brew fetch --cask --force revenium/tap/revvytach
brew install --cask --dry-run --require-sha revenium/tap/revvytach
```

On a disposable clean-machine test account, perform one real install and
launch:

```bash
brew install --cask revenium/tap/revvytach
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

## Provenance

The binding between a published `RevvyTach.dmg` and the commit it was built
from is established **at release time**, not by any post-hoc check:

- The release builds from a fresh clone of the exact approved commit, then signs
  and notarizes the result. Nothing else touches the artifact.
- The Sparkle EdDSA signature in the published appcast proves the disk image is
  the one the release signer published, and Developer ID + notarization prove
  who signed it and that Apple accepted it.

What this does **not** prove is which commit produced the image. Nothing inside
a published DMG identifies its source revision, so a verifier that re-derives a
`commit` value from a checked-out tag is recording the revision it verified
against, not confirming the artifact's origin — an image built from a different
commit carrying the same version and build number would satisfy every check.
Making that binding artifact-derived would require stamping the commit into the
app's `Info.plist` at build time and verifying it from the mounted image;
that is deliberately out of scope for distribution-only changes.

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
