# Codex Subscription Support — Final Parity Audit

## Audit status

This document is the P17 release gate for the Product project
`Claude Usage Desktop App Codex Support` and umbrella `PRODUCT-2276`. It maps
the 17 implementation workstreams to their acceptance evidence and records the
remaining ship gates without treating unavailable release credentials as a
successful release.

The P17 candidate changes the one shared
`UsageProviderFeatureAvailability.production` value to enable Codex in setup,
refresh, diagnostics, and UI composition roots. An explicit
`.testing(codexRefreshEnabled: false)` path remains covered so tests and future
emergency controls can prove that disabled operation fails closed before home,
executable, or provider dependencies run.

This audit is maintained on the B05 integration branch. The complete local
matrix remains bound to exact source commit
`8b6a3c2ebd780ed4bed8a90b089edd9fbbf84500`. Hosted CI then exposed a
portable temporary-root canonicalization edge case; the focused seven-test
correction and independent review are bound to
`5acc2ec5e501870dfe7c9e36bd9d15f80967ec6e`. That rerun proved the runner
and launched application receive different process-local temporary roots on
hosted macOS. Commit `869ada4bc21d9c9aae1ec2440f2e4318c4ae4da5`
strengthened the root contract, but its hosted run proved Xcode's sandboxed UI
runner cannot write directly under `/tmp`. The final sandbox-aware correction,
21-test focused gate, app and UI-testing builds, and exact-diff review are
bound to `8cd3f2ba49eb30a4bc5bfab90648f0bd7fc7bc51`. PR #12 moved the
16 unchanged synthetic localization fixtures and inherited funding-link
deletion into `main` as `16b2a8764e0b1e9d83e98c983a14b5a1a7e244c7`;
B05 merged that base at `5448504`, leaving an exact 99-file reviewer diff.
Hosted CI on the resulting final PR head remains the authoritative integration
gate. At the current checkpoint:

- P01–P16 have completed implementation and independent acceptance evidence.
- P15 is complete at the integrated source: all nine catalogs contain exactly
  994 keys, all 15 localization-validator fixtures pass, the 11-test native UI
  suite builds, no test is skipped or marked as an expected failure, and the
  independent exact-head review is clean. Hosted execution remains a mandatory
  PR gate because this workstation blocks UI automation at the Developer
  Mode/TCC boundary before the first test body.
- P14 is final at integrated commit `f574aaa`, including the complete
  redaction/process corrections. The final saturated-host regression now
  requires a bounded PID-file handshake and unconditional exact-process exit
  proof at `8b6a3c2`; its exact-head independent review is clean.
- P17 production enablement, explicit disabled-path hardening, local exact-head
  gates, merge-safe synthetic Claude/mixed-provider UAT, and the installed
  Codex live smoke are complete. Hosted UI CI and the ship audit remain the
  code-merge gates.

Accordingly, this document is a complete coverage map and gate checklist, not
permission to publish a release tag by itself.

## Product and architecture invariants

The implementation is acceptable only while all of these remain true:

1. Claude and Codex ship in one app, bundle, process, settings system, menu
   system, and release train.
2. Every profile has exactly one provider. Existing untagged profiles migrate
   as Claude; Codex profiles store only a canonical `CODEX_HOME` reference and
   non-secret metadata.
3. Codex usage is obtained from the installed official Codex app-server, using
   bounded request-scoped sessions for reads and a login-scoped session for
   official interactive login.
4. Production code never reads, copies, edits, deletes, or logs `auth.json`;
   never swaps tokens or mutates a shell; and never logs out the underlying
   Codex account when an app profile is unlinked or deleted.
5. Scope is ChatGPT/Codex subscription usage. OpenAI Platform billing and
   reset-credit redemption are excluded.
6. Dynamic provider data flows through normalized `UsageReport` contracts.
   AppKit, SwiftUI, Keychain, localization, persistence, and app singletons
   remain outside `UsageKit`.
7. Missing CLI, invalid/replaced homes, unsupported authentication, protocol
   drift, malformed output, cancellation, timeout, and optional-usage failure
   fail safely and produce provider-specific recovery.
8. Existing Claude behavior, app name, bundle identifier, preferences domain,
   macOS 14 minimum, and the nine-locale product boundary remain compatible.
9. Release, update, support, source, feedback, appcast, and Homebrew
   destinations are Revenium-owned and fail closed when required protected
   configuration is absent.

## Seventeen-workstream coverage matrix

Status values distinguish accepted implementation evidence from exact-head or
hosted gates still required before the B05 merge.

| Workstream | Linear | Acceptance coverage | Evidence at audit snapshot | Disposition |
|---|---|---|---|---|
| P01 — deterministic baseline | `PRODUCT-2282` | Weekly-scope parser correctness, missing-kind compatibility, hermetic defaults, repeatable unit/build gates | 105/105 baseline tests; `SharedDataStoreTests` passed 20 repetitions; Debug and Release builds passed; localization debt was explicitly assigned to P15 | Complete, merged in PR #7 |
| P02 — Keychain migration | `PRODUCT-2280` | No plaintext profile secrets; verified write/readback before legacy deletion; rollback, retry, idempotency, deletion, and profile isolation | 12 focused and 218 final full-app tests; post-audit security suites passed; Debug/Release builds and leak scans clean | Complete, merged in PR #8 |
| P03 — file-backed usage/history | `PRODUCT-2279` | Atomic current/history files, verified legacy migration, corrupt/interrupted/version-skew safety, bounded profile isolation and cleanup | Durable-storage suites passed 17/17; integrated safety matrix passed; fault-injected rollback and exact installed-file verification reviewed | Complete, merged in PR #8 |
| P04 — menu/window reliability | `PRODUCT-2277` | Right-click Refresh/Settings/Quit, stable status items, full-screen and detach behavior, Cmd+W, modern macOS layout, stable CGImage rendering | Focused reliability 5/5; full suite and both app builds passed; only selected upstream reliability changes were adapted | Complete, merged in PR #8 |
| P05 — UsageKit and Claude adapter | `PRODUCT-2281` | App-framework-free provider contracts, arbitrary groups/windows, explicit optional capabilities, Claude characterization | UsageCore 14/14; UsageKit Debug/Release 74 tests with one intentional live-smoke skip; 396/396 app tests; strict/universal/TSan gates | Complete, merged in PR #9 |
| P06 — subprocess/JSONL transport | `PRODUCT-2278` | Initialize ordering, request correlation, partial input, notification routing, bounded stdout/stderr/time, cancellation, exit/error races, redaction, process-tree cleanup | Transport 38/38 in Debug and Release; terminal and close stress 10/10; retained FD cleanup 20/20; stable PID identity, schema provenance, and zero-process census | Complete, merged in PR #9 |
| P07 — provider profiles/migration | `PRODUCT-2286` | Closed provider tags, legacy-Claude migration, canonical physical homes, duplicate/symlink/replacement rejection, no token or shell mutation | Profile core 46/46; golden profile/current/history migrations; exact-path legacy relink and replacement-inode coverage; 396/396 app tests | Complete, merged in PR #9 |
| P08 — Codex provider/login/usage | `PRODUCT-2285` | Account, health, dynamic and legacy limits, optional daily usage, credits, official browser/device login, unsupported API-key/Bedrock handling | Provider suite 21/21; UsageKit Debug/Release passed; installed Codex 0.145.0 account/rate-limit live smoke passed 1/1 | Complete, merged in PR #9 |
| P09 — refresh orchestration | `PRODUCT-2288` | Profile-keyed latest-wins actors, cross-profile concurrency, provider/revision/input fences, deletion/shutdown safety, Claude side-effect preservation | Refresh engine under TSan 99/99 with no race signature; overlapping timer regression passed; 396/396 app tests; strict/universal gates | Complete, merged in PR #9 |
| P10 — onboarding/profiles/settings | `PRODUCT-2283` | Provider choice, zero-profile setup, home link/relink, official login, mixed CRUD, health/account state, typed settings routing, unlink/delete semantics | Integrated B04 focused matrix 100/100 and full app 519/519; setup/settings semantic review clean | Complete, merged in PR #10 |
| P11 — normalized popover | `PRODUCT-2287` | Dynamic groups/windows, plan, credits, optional summaries, resets/pace, loading/stale/empty/error/unsupported states, Claude shell parity | Integrated B04 focused 100/100 and full app 519/519; independent Claude-shell and cross-integration reviews clean | Complete, merged in PR #10 |
| P12 — menus/status/icons | `PRODUCT-2284` | All status-item and menu actions, mixed-profile switching, provider-aware metrics/thresholds/display/appearance/error state | Provider menu presentation 37/37; integrated B04 focused 100/100 and full app 519/519; independent semantic review clean | Complete, merged in PR #10 |
| P13 — history/export/notifications/automation | `PRODUCT-2293` | Provider-tagged normalized history/export, dynamic-window threshold/reset deduplication, restart safety, Claude-only capability gates | Focused 28/28 plus independent reviewer matrix 111/111; full app 550/550; UsageKit Debug/Release passed; universal Release contains arm64+x86_64 | Complete in B05 |
| P14 — errors/redaction/health/diagnostics | `PRODUCT-2289` | Actionable recovery, CLI/app-server/auth/usage health, safe support diagnostics, token/path/environment redaction, bounded diagnostic process lifecycle | Integrated `f574aaa`: 31/31 diagnostics tests; 50/50 repeated adversarial checks; zero residual fixtures; strict full/protocol-relative URL and local-path redaction; identity-bound PID-reuse traversal; exact-PID late reaping; identical source/integrated patch and blobs | Complete in B05; independent exact-head review CLEAN |
| P15 — localization/accessibility/docs/UI tests | `PRODUCT-2291` | Exact nine-locale parity, placeholder/source validation, accessibility/focus/keyboard semantics, setup/login/mixed/menu/settings/error/refresh/unlink automation, support docs | Exact source `8b6a3c2`: 9×994 catalog keys; 15/15 validator fixtures; 11 UI test methods with no skips/expected failures; UI `build-for-testing` passed; 610/610 app tests in serial and parallel modes; independent exact-head review CLEAN. Hosted corrections culminate at `8cd3f2b`: 21 parser/security tests plus app and UI `build-for-testing` passed; exact-diff review CLEAN. | Complete in B05; hosted 11/11 runtime rerun is the PR gate |
| P16 — Revenium distribution | `PRODUCT-2292` | Revenium destinations, identity compatibility, signed/notarized cohesive ZIP/checksum/appcast/Homebrew automation, explicit missing-secret failure | Exact source `8b6a3c2`: distribution/YAML, 43 workflow shell blocks, and five release scripts passed; Debug/universal Release passed. The ripgrep-free validator and Xcode 26.0.1 pin subsequently passed 46 workflow shell blocks and hosted Distribution Validation. Cohesive release unit, Sparkle 2.9.4 tools, temporary-tap audit, token isolation, optimistic-SHA publication, owned-draft recovery, and remote byte identity independently reviewed clean. | Complete in B05; protected release execution externally blocked |
| P17 — final audit/UAT/ship | `PRODUCT-2290` | Evidence reconciliation, production enablement, full current-tree gates, live installed-Codex smoke, mixed/Claude UAT, distribution proof, forbidden-behavior audit | Exact source `8b6a3c2`: 610/610 app tests serial and parallel; UsageKit Debug/Release 80 tests with one intentional opt-in live skip; Debug/universal Release and UI test build passed; installed Codex 0.145.0 smoke passed 1/1; zero residual app-server/fixture processes; static/forbidden audit and independent review clean. PR #12 merged exact static prerequisites and restored a 99-file Tessie-reviewable B05 diff. | **Pending exact-head hosted 11/11 UI CI, reviewer gate, and ship audit** |

## P17 production-gate proof

The gate must remain centralized:

- `UsageProviderFeatureAvailability.production.codexRefreshEnabled == true`.
- `CodexProviderFactory()` and production composition roots use that value by
  default.
- `CodexProviderFactoryTests` proves a production factory is enabled and still
  short-circuits an unlinked home before dependency resolution.
- `UsageProviderRegistryTests` proves production availability is enabled and a
  separately injected `.testing(codexRefreshEnabled: false)` registry fails
  before resolver or provider-factory calls.
- `CodexProfileSetupTests` proves production can durably create a Codex profile
  while an explicitly disabled setup dependency rejects creation.
- `UsageRefreshEngineTests` preserves the disabled hydration regression with
  `.testing(codexRefreshEnabled: false)` and proves it does not resolve the
  executable.
- `ProviderDiagnosticsTests` proves an explicit-off Codex diagnostic returns
  an inert snapshot before home validation, executable resolution/validation,
  version probing, or provider construction.
- `CodexProfileSetupTests` proves both draft and existing-profile Codex
  request capture reject explicit-off availability before injected operations
  run.

No second production flag, environment switch, or UI-only bypass is permitted.
The initial focused P17 selection passed 70/70 with zero failures or skips. The
disabled diagnostics/UI capture correction passed 67/67 with zero failures or
skips in `/tmp/claude-usage-p17-disabled-gates-20260730.xcresult`, and its
independent exact-commit follow-up is clean at `7ab9e39`.

## P15 UI and accessibility coverage

The `Claude Usage UI Tests` target uses the real production views with an
explicit compile-time `UITesting` configuration and launch-argument gate. Its
state, defaults, data, bundle identity, secret store, app-server, browser
behavior, and setup completion are isolated from normal application startup.
The eleven deterministic test methods cover:

1. First-run provider choice, Codex home verification, profile naming, setup
   completion, and active-profile state.
2. Linked-account refresh, unlink cancel/confirm, unsupported account
   recovery, and deterministic unavailable/error refresh.
3. Device-code login start, code and verification link presentation, and
   cancellation without real browser or network access.
4. Browser-login dispatch through the production login route without opening a
   real browser.
5. Mixed Claude/Codex rows and exact stable-profile actions.
6. Settings, history, popover, refresh, and settings navigation.
7. Exact provider targets and Refresh/Settings/Quit menu routing.
8. Menu, status, and detached-popover lifecycle with stale-target no-ops.
9. True no-profile status selection that fails closed.
10. Semantic setup rendering across all nine supported locales.
11. Fail-closed runtime launch gating.

The hosted `Codex UI parity` CI job is non-waivable. A successful
`build-for-testing` is structural evidence only; it does not replace hosted
runtime execution.

The first hosted run executed all 11 test methods, but ten scenario launches
correctly failed closed at application launch before exercising their intended
scenario state. Commit `5acc2ec` replaced string-prefix containment with strict
canonical path-component ancestry and removed trailing-slash sensitivity. Its
seven parser tests and UI-testing build passed, and an independent focused
review returned CLEAN.

The next hosted run proved a second platform boundary: XCUITest's runner and
launched app receive different `FileManager.default.temporaryDirectory`
values. Commit `869ada4` introduced a canonical `/tmp` contract with UUID,
directory, home-nesting, and path-escape validation. Its focused
parser/security suite passed 18/18, the dedicated UI-testing build passed, and
an exact three-file review returned CLEAN. Hosted execution then failed before
app launch because Xcode forcibly sandboxes its UI runner and denies direct
`/tmp` fixture creation.

Commit `8cd3f2b` uses the sandbox rather than bypassing it. The runner creates
under its own permitted `FileManager.default.temporaryDirectory`; the tested
non-sandboxed app independently derives the exact trusted anchor from
`getpwuid_r(getuid())` plus
`Library/Containers/com.revenium.Claude-UsageUITests.xctrunner/Data/tmp`.
No environment value can broaden that anchor. Existing canonical directory,
UUID basename, strict root/home containment, and path/symlink-escape checks
remain mandatory. The focused parser/security suite passed 21/21, both app and
dedicated UI build-for-testing gates passed, and the exact three-file review
returned CLEAN. The exact final-head hosted rerun must still prove all 11
runtime methods.

## Forbidden-behavior audit

Before merge, static and semantic review must confirm:

- No production source opens, decodes, copies, rewrites, deletes, or logs
  `auth.json`.
- No production flow invokes `account/logout`; unlink and delete affect only
  app-owned profile metadata, current usage, history, notifications, and
  app-owned secrets.
- No Codex path imports Claude credentials, writes shell configuration, or
  swaps process-wide authentication state.
- Codex account support rejects API-key and Bedrock modes as unsupported
  subscription tracking rather than presenting Platform billing.
- Reset credits are display-only and no redemption method is exposed.
- Test fixtures contain synthetic values only; diagnostics and errors contain
  no bearer tokens, API keys, credential JSON, raw environment secrets,
  sensitive home paths, or unbounded process output.
- No workflow reads or writes `gh-pages`; the production update feed is the
  Revenium GitHub Release `appcast.xml` asset.

References to forbidden names inside comments, redaction tests, protocol method
catalogs, and user documentation are expected and must not be confused with
runtime access.

## Final executable gate

Run these checks on the exact integrated B05 head. Any source change after a
result invalidates that result for final sign-off.

### Static, localization, and distribution

```bash
git diff --check upstream/main...HEAD
./scripts/validate_localizations.sh
bash scripts/tests/test_validate_localizations.sh
./scripts/validate_distribution.sh
ruby scripts/validate_yaml_duplicates.rb .github/workflows/*.yml
plutil -lint "Claude Usage.xcodeproj/project.pbxproj"
xmllint --noout "Claude Usage.xcodeproj/xcshareddata/xcschemes/Claude Usage UI Tests.xcscheme"
```

Also syntax-check every embedded workflow `run:` block and every release shell
script, confirm the exact nine `.lproj` catalogs, and repeat credential,
`auth.json`, process-fixture, and production-gate source scans.

### Package and application

```bash
swift test --package-path Packages/UsageKit -Xswiftc -warnings-as-errors
swift test --package-path Packages/UsageKit -c release -Xswiftc -warnings-as-errors

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
  -configuration Debug \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO

xcodebuild build \
  -project "Claude Usage.xcodeproj" \
  -scheme "Claude Usage" \
  -configuration Release \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
```

Verify the universal Release executable contains both `arm64` and `x86_64`.
Run the isolated UI suite on hosted macOS CI and require every flow to execute;
do not convert the local Developer Mode/TCC runner failure into a skip.

### Installed Codex live smoke

The smoke is opt-in and must use only the official Codex CLI/app-server. It
must not print account payloads, linked-home paths, or authentication data.

```bash
CODEX_USAGE_LIVE_SMOKE=1 \
CODEX_USAGE_LIVE_EXECUTABLE=/opt/homebrew/bin/codex \
CODEX_USAGE_LIVE_HOME="${CODEX_HOME:-$HOME/.codex}" \
swift test \
  --package-path Packages/UsageKit \
  --filter CodexUsageProviderTests.CodexUsageProviderTests/testLiveAccountAndRateLimitSmokeWhenExplicitlyEnabled
```

Record the installed CLI version, pass/fail result, and a zero residual
app-server/fixture-process census. Do not record the resolved home path or
inspect `auth.json`.

### UAT split

For the code merge, deterministic synthetic UAT is represented by the exact
source 610-test application suite in both serial and parallel modes, the
80-test UsageKit suites in Debug and Release, the 11-method isolated UI suite,
and the read-only installed-Codex smoke. The hosted UI run must execute all
11 methods with no failure, skip, or expected failure before merge.

Per D158, the following real interactive UAT remains non-waivable before the
first public release, but is intentionally deferred to a backed-up disposable
macOS user or VM so it cannot mutate Jason's normal defaults, Keychain,
profiles, notification permissions, or Codex authentication:

- Existing Claude-only migration, refresh, menu, popover, history, export,
  notifications, settings, and appearance.
- First-run Codex setup by existing home; interrupted setup/resume; browser
  callback login; device-code login and cancellation.
- Missing CLI, unlinked/invalid/replaced home, unauthenticated, unsupported
  account, duplicate/symlink/replaced home, unavailable endpoint, timeout,
  malformed response, and partial optional-usage recovery.
- Mixed Claude/Codex profile switching from status items, menus, popover, and
  settings, including a second Codex profile; left/right-click status actions;
  Refresh/Settings/Quit shortcuts; detach/full-screen/reopen/Cmd+W and
  status-item recovery.
- Overlapping timer/manual refresh; profile switch/delete/unlink while refresh
  or login is in flight; restart hydration; wake/network loss and recovery.
- Dynamic limit windows, reset labels, plan, credits, daily usage,
  loading/stale/empty/error states, used/remaining display, thresholds, icons,
  history/export, and notification deduplication.
- Codex capability hiding for Claude-only automation and billing controls;
  About/update/support/source/feedback destinations.
- Real notification permission, sound, restart deduplication, and reset
  delivery behavior.
- Keyboard traversal, default/cancel actions, focus restoration, VoiceOver
  labels/values, and representative long-string layout in every supported
  locale.

Screenshots, recordings, copied diagnostics, and logs used as UAT evidence must
not contain secrets, resolved local paths, account payloads, or device codes.

## External release blocker

The repository currently has no protected `release` environment, Actions
variables, or Actions secrets. The first public Revenium release requires:

- Variables: `APPLE_TEAM_ID`, `DEVELOPER_ID_APPLICATION`,
  `SPARKLE_PUBLIC_ED_KEY`.
- Secrets: `APPLE_ID`, `APPLE_ID_PASSWORD`, `CERTIFICATE_PASSWORD`,
  `DEVELOPER_CERTIFICATE_BASE64`, `SPARKLE_PRIVATE_KEY`,
  `HOMEBREW_TAP_TOKEN`.

A valid local Developer ID Application identity is useful for a local signing
smoke, but it does not substitute for protected CI configuration, Apple
notarization credentials, the Revenium Sparkle private key, or a narrow
Homebrew tap token. These values must not be fabricated, inferred, or borrowed
from another product.

This is an explicit blocker to creating a public release tag and claiming
signed/notarized/Sparkle/Homebrew publication. It is not a blocker to merging
the audited code once all non-credential gates, including hosted UI tests,
pass. The release workflow is intentionally fail closed when the values are
absent.

The inherited `gh-pages` branch must remain untouched until B05 has merged.
After merge, archive its exact inherited commit under the approved backup tag,
delete it with an exact leased update, and verify the backup before the first
Revenium release. That post-merge operation is outside this P17 preparation
commit.

## Final verdict record

The release-readiness integrator must replace the entries below with exact
commit-bound evidence:

| Gate | Required verdict |
|---|---|
| P14 corrective integration and independent exact-head audit | PASS — `f574aaa`; 31/31 focused, 50/50 adversarial, zero fixtures, exact-patch/blob review CLEAN |
| P15 independent integrated review | PASS — exact source `8b6a3c2`; P15 patch provenance exact; final corrections and mandatory process handshake reviewed CLEAN; hosted-path corrections through `8cd3f2b` independently reviewed CLEAN |
| Localization validator and fixture suite | PASS — 9×994 keys and 15/15 fixtures at `8b6a3c2` |
| UsageKit Debug and Release suites | PASS — 80 total, 0 failures, 1 intentional opt-in live-smoke skip in each configuration |
| Full application suite | PASS — 610/610, zero failures/skips/expected failures in both serial and parallel modes |
| Debug and universal Release builds | PASS — zero build errors; universal executable contains `arm64` and `x86_64` |
| Hosted Codex UI parity suite | PENDING exact-head rerun after sandbox-aware correction `8cd3f2b` |
| Installed Codex live smoke and zero-process census | PASS — exact source `8b6a3c2`, Codex 0.145.0, 1/1, zero residual app-server/fixture processes |
| Claude-only and mixed-provider UAT | PASS FOR MERGE — exact synthetic matrix green; D158 real interactive UAT remains mandatory before first public release |
| Distribution/static/forbidden-behavior gates | PASS — 43/43 source workflow blocks at `8b6a3c2`; 46/46 after portable validator and Xcode 26.0.1 workflow corrections; 5/5 scripts and distribution/YAML/locales/synthetic-fixture/forbidden-runtime scans clean |
| `$codex-ship-pr skip-review` review, CI, and final audit | PENDING |
| Public signed/notarized release | BLOCKED — credentials/environment absent |

Codex may merge enabled only when every non-publication row above is PASS.
No public tag or release may be created while the final row remains blocked.
