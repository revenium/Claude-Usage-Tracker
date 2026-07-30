# GitHub Configuration

Internal reference for CI/CD workflows and GitHub configuration.

## Workflows

### `build.yml` — Continuous Integration

**Triggers:** PRs to `main`, pushes to `main`

**Purpose:** Validate that code compiles and tests pass before merge.

**Steps:**
1. Build Debug configuration (required for test host)
2. Run unit tests (`xcodebuild test`)
3. Build Release configuration
4. Upload `.app` artifact (7-day retention)

**Why `macos-15`:** The project uses `PBXFileSystemSynchronizedRootGroup` (Xcode 16 feature). This project format requires Xcode 16+, which is only available on `macos-15` runners.

**Why code signing is disabled:** The app is unsigned (no Apple Developer certificate). Build flags bypass signing:
```
CODE_SIGN_IDENTITY=""
CODE_SIGNING_REQUIRED=NO
CODE_SIGNING_ALLOWED=NO
```

### Canonical local validation

Run the same build and test boundaries locally before opening a pull request:

```bash
xcodebuild build \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -configuration Debug \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO

xcodebuild test \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -configuration Debug \
  -destination "platform=macOS" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO

xcodebuild build \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -configuration Release \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
```

For changes involving concurrency or persistent state, also repeat the full test
suite and run it with parallel testing enabled. Tests must use injected,
test-scoped storage rather than `UserDefaults.standard`.

The localization validator currently reports pre-existing catalog drift. Do not
weaken or bypass it: localization parity is tracked as a dedicated remediation
workstream and must be green before Codex support ships.

---

### `distribution-validation.yml` — Distribution Safety

**Triggers:** Pull requests changing distribution-owned files and matching
pushes to `main`

**Purpose:** Reject prior-owner operational endpoints, unpinned Actions,
invalid or duplicate workflow YAML, invalid plists/scripts, changed upgrade
identity, non-isolated local feeds, and invalid Homebrew templates. It also
builds ordinary Debug and Release configurations and proves both contain empty
feed/key defaults.

### `release.yml` — Credential-Gated Releases

**Trigger:** Push of a stable `vX.Y.Z` tag already contained in `main`

**Environment:** Protected `release`

**Steps:**
1. Validate release identity, configuration, localization, package tests, and app tests
2. Build a universal Release app with injected Revenium feed/public key
3. Sign the app and Sparkle components with the configured Developer ID identity
4. Notarize, staple, and require Gatekeeper acceptance
5. Create ZIP, checksum, appcast, and release metadata
6. Verify app identity, architectures, entitlements, checksum, Sparkle signature, URLs, version/build, and notarization
7. Publish one GitHub Release containing all cohesive assets
8. Audit and update `revenium/tap/claude-usage`

**Outputs:**
- `Claude-Usage.zip` — App bundle for distribution
- `Claude-Usage.zip.sha256` — SHA256 checksum for verification
- `appcast.xml` — Sparkle feed with the archive's Ed25519 signature
- `release-metadata.json` — tag, commit, version/build, identity, URL, and checksum

The workflow does not use GitHub Pages, a personal release token, or a
hard-coded Apple team/key. It publishes only after re-downloading and verifying
its exact private draft asset set. An interrupted run may replace only its own
commit-provenance-marked draft; published and unowned releases are immutable to
the workflow.

### `generate-appcast.yml` — Published Appcast Verification

**Trigger:** Manual

Downloads an existing release unit and independently re-runs artifact,
notarization, public-key, and Sparkle signature verification. Appcast generation
is part of the atomic release job; this workflow never rewrites Pages or
published artifacts.

### `update-homebrew-cask.yml` — Revenium Tap Update

**Trigger:** Called only by a successful protected `release.yml` job; retry the
failed reusable job from the original release run

Creates/updates `Casks/claude-usage.rb` in `revenium/homebrew-tap` from the
published artifact checksum. It verifies that release metadata names the exact
merged tag commit, renders and audits before exposing the tap token, then uses
one optimistic-SHA Contents API write. There is no manual tag-owned token path.

---

## Release Process

See [RELEASING.md](../RELEASING.md). Version and changelog changes go through
a reviewed PR. An authorized release owner tags the exact merged commit; the
protected workflow verifies and publishes it.

---

## Technical Constraints

| Constraint | Reason |
|------------|--------|
| `macos-15` runner | Xcode 16 required for project format |
| PR builds use no code signing | Signing credentials are isolated to the protected release environment |
| Debug build before tests | Test target needs `TEST_HOST` from Debug build |
| 20-min timeout | Prevents hung builds from consuming minutes |
| Bundle ID remains `HamedElfayome.Claude-Usage` | Preserves preferences, profiles, Keychain behavior, and update compatibility |
| Local feed/key defaults are empty | Prevents development builds from consuming a production feed |
| Production appcast is a GitHub Release asset | Keeps source, artifact, checksum, signature, and feed under Revenium ownership |

---

## Issue Templates

- `bug_report.yml` — Structured bug reports with version/OS fields
- `feature_request.yml` — Feature suggestions with problem/solution format
- `documentation.yml` — Documentation improvements
- `config.yml` — Links to Discussions for questions
