# GitHub Configuration

Internal reference for CI/CD workflows and GitHub configuration.

## Workflows

### `build.yml` — Continuous Integration

**Triggers:** PRs to `main`, pushes to `main`

**Purpose:** Validate package, localization, app, and native UI behavior before
merge.

**CI gates across both jobs:**
1. Validate all nine localization catalogs and their exact key parity
2. Run the localization validator's positive and negative fixture suite
3. Run the UsageKit package tests
4. Build the Debug configuration (required for the app test host)
5. Run the app unit and integration tests
6. Build the Release configuration
7. Upload the `.app` artifact (7-day retention)
8. Run all 11 isolated Codex native UI flows in the `UITesting` configuration
9. Reject anything except 11 passed, zero failed/skipped/expected failures,
   and upload the UI `.xcresult` plus parsed summary for diagnosis

**Why `macos-15`:** The project uses
`PBXFileSystemSynchronizedRootGroup` and selects Xcode 26.0.1 for the current
Swift and native UI toolchain. The native UI job uses an explicit arm64 macOS
destination.

**Why code signing is disabled in PR CI:** Pull-request builds intentionally do
not receive signing credentials. The protected release workflow signs and
notarizes distribution artifacts separately. PR build flags bypass signing:
```
CODE_SIGN_IDENTITY=""
CODE_SIGNING_REQUIRED=NO
CODE_SIGNING_ALLOWED=NO
```

### Canonical local validation

Run the same build and test boundaries locally before opening a pull request:

```bash
./scripts/validate_localizations.sh
./scripts/tests/test_validate_localizations.sh
swift test --package-path Packages/UsageKit

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

xcodebuild build-for-testing \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage UI Tests" \
  -configuration UITesting \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
```

For changes involving concurrency or persistent state, also repeat the full test
suite and run it with parallel testing enabled. Tests must use injected,
test-scoped storage rather than `UserDefaults.standard`.

The hosted `codex-ui-tests` job runs the native suite because local execution
requires macOS UI automation authorization. A local `build-for-testing` proves
the conditional bootstrap and XCUITest sources compile, but does not replace
the hosted execution gate. The result summary is mechanically checked for the
frozen 11-test count and zero skips.

Localization validation is fail-closed: every supported catalog currently has
the same 998 keys, and the fixture suite proves malformed catalogs, missing or
extra keys/locales, placeholder drift, empty values, and missing deferred UI
states are rejected.

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
7. Create or recover only the workflow-owned, commit-provenance-marked draft
8. Upload, re-download, and verify the draft's exact four-asset release unit
9. Publish that verified draft without changing its assets
10. Audit and update `revenium/homebrew-tap/Casks/claude-usage.rb` only after publication

**Outputs:**
- `Claude-Usage.zip` — App bundle for distribution
- `Claude-Usage.zip.sha256` — SHA256 checksum for verification
- `appcast.xml` — Sparkle feed with the archive's Ed25519 signature
- `release-metadata.json` — tag, commit, version/build, identity, URL, and checksum

The workflow does not use GitHub Pages, a personal release token, or a
hard-coded Apple team/key. It publishes only after re-downloading and verifying
its exact private draft asset set. An interrupted run may replace only its own
commit-provenance-marked draft; published and unowned releases are immutable to
the workflow. The reusable Homebrew job receives only the published tag from a
successful protected release job and independently verifies the artifact,
metadata, checksum, and merged commit before writing the tap.

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
| `macos-15` runner | Provides the pinned Xcode 26.0.1 project and UI-test toolchain |
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
