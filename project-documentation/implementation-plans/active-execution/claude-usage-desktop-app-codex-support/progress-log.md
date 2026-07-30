# Progress Log: Claude Usage Desktop App Codex Support

## Active Work

- Project status: Active
- Linear project: `Claude Usage Desktop App Codex Support` (`8fd871e1416e`)
- Umbrella: `PRODUCT-2276`
- Tracking wave: W00 — complete
- Current delivery batch: B03 — Provider core
- Current phases: P05/P06/P07/P08/P09 implemented, validated, and pending B03 ship
- Corrective source commit: `3c236b4`; exact validation evidence is recorded for ship
- Current validation: exact-tree package, live Codex, full app, Debug, strict-concurrency, universal Release, TSan, localization, process-census, and safety gates pass
- Next action: run the B03 `$codex-ship-pr skip-review --linear PRODUCT-2281 --auto-merge` pipeline

## Repository State at Initialization

- Base: `upstream/main`
- Base commit: `aaeb9e74747f0197dc7d8935a2b64ea37a4e81e5`
- Project branch: `feature/codex-subscription-support`
- B01 branch: `feature/codex-support-baseline`
- Project worktree: `/Users/jason/gitclone/hc-repo/worktrees/Claude-Usage-Tracker/worktree-a`
- B01 worktree: `/Users/jason/gitclone/hc-repo/worktrees/Claude-Usage-Tracker/phase-01-baseline`
- Existing untracked paths preserved: `.cache/`, `.serena/`

## Known Baseline

- `xcodebuild -list` succeeds.
- The app has one app target and one unit-test target.
- The original baseline ran 103 unit tests with one parser failure.
- P01 reviewed head runs 105 unit tests: 105 pass, 0 fail, 0 skip.
- `UsageLimitParsing` rejects explicit incompatible or malformed kinds while retaining missing-kind compatibility.
- `SharedDataStoreTests` now use isolated, injected UserDefaults suites; 20 repeated runs pass.
- Localization validation currently fails for every non-English catalog.
- Localization debt is assigned to P15 after provider UI strings stabilize; it is not a B01 acceptance gate.
- Current CI builds Debug, runs unit tests, builds Release, and uploads an unsigned artifact.
- Current CI does not gate localization, package tests, UI tests, signing, or release smoke tests.
- Original upstream contains no Codex/OpenAI subscription support.

## Wave Status

| Wave | Description | Phases | Status |
|---|---|---|---|
| W00 | Linear tracking initialization | 17 child issues | Complete |
| W01 | Green baseline | P01 | Complete |
| W02 | Safety foundations | P02, P03, P04 | Complete |
| W03A | UsageKit boundary | P05 | Implemented and validated; pending B03 ship |
| W03B | Transport and profile model | P06, P07 | Implemented and validated; pending B03 ship |
| W03C | Codex provider | P08 | Implemented and validated; pending B03 ship |
| W03D | Refresh integration | P09 | Implemented and validated; pending B03 ship |
| W04 | Provider-aware UI parity | P10, P11, P12 | Pending |
| W05A | Cross-cutting parity and distribution | P13, P14, P16 | Pending |
| W05B | Localization/accessibility/UI automation | P15 | Pending |
| W05C | Final parity and ship audit | P17 | Pending |

## Delivery PRs

| Batch | Branch | PR | CI | Review Gate | Merge | Status |
|---|---|---|---|---|---|---|
| B01 Baseline | `feature/codex-support-baseline` | [#7](https://github.com/revenium/Claude-Usage-Tracker/pull/7) | Success | Tessie clean + Greptile 5/5 | `29c7fe1` | Merged |
| B02 Foundations | `feature/codex-support-foundations` | [#8](https://github.com/revenium/Claude-Usage-Tracker/pull/8) | Equivalent exact-head gate passed | All findings fixed; reviewer limits documented | `ab70776` | Merged |
| B03 Provider core | `feature/codex-support-provider-core` | [#9](https://github.com/revenium/Claude-Usage-Tracker/pull/9) | Review-correction tree: UsageKit Debug/Release 74 total each; app 396/396; Debug/strict/universal Release/TSan passed | Greptile 4/5; sole finding fixed and exact-head re-review pending; Tessie size limit documented | — | Review correction validated |
| B04 UI parity | `feature/codex-support-ui-parity` | — | — | — | — | Pending |
| B05 Release readiness | `feature/codex-support-release-readiness` | — | — | — | — | Pending |

## Completed Phases

| Phase | Linear | Worker | Commit | Batch PR | Completed | Summary |
|---|---|---|---|---|---|---|
| P01 | PRODUCT-2282 | baseline_audit | `1009d4f` | #7 | 2026-07-30 | Parser correctness, null compatibility, hermetic UserDefaults tests, canonical validation docs |
| P02 | PRODUCT-2280 | profile_security_integration | `747230b` final head | #8 | 2026-07-30 | Verified profile-keyed Keychain storage, backward migration, explicit credential APIs, startup guard, fail-closed deletion marker |
| P03 | PRODUCT-2279 | profile_security_integration | `747230b` final head | #8 | 2026-07-30 | Atomic current/history files, verified migration, transactional credentials, recoverable cleanup, fault-injected rollback safety |
| P04 | PRODUCT-2277 | menu_reliability_audit | `747230b` final head | #8 | 2026-07-30 | Context menu, stable status items, popover/window/full-screen fixes, CGImage fingerprinting, Cmd+W, captured-profile auto-switch safety |
| P05 | PRODUCT-2281 | usagekit_contracts | `3c236b4` corrective source | Pending B03 | Pending merge | App-framework-free provider contracts validate arbitrary dynamic windows and persist typed partial-usage health without inventing data; ADRs D001–D013 record the package seam and dependency direction |
| P06 | PRODUCT-2278 | codex_transport | `3c236b4` corrective source | Pending B03 | Pending merge | Concurrent JSON-RPC correlation, deterministic cancellation, blocked-write bounds, stable-identity process-tree teardown, retained-child re-census, immediate terminal delivery, schema provenance, and zero-process proof |
| P07 | PRODUCT-2286 | provider_profile_model | `3c236b4` corrective source | Pending B03 | Pending merge | Provider-tagged profiles bind canonical Codex homes to device/inode identity; exact-path relink upgrades legacy unresolved links and captures same-path replacements |
| P08 | PRODUCT-2285 | codex_provider | `3c236b4` corrective source | Pending B03 | Pending merge | Dynamic and legacy limits, optional-usage partial success, supported/unsupported account modes, complete typed login outcomes, scoped cleanup, and live installed-Codex proof |
| P09 | PRODUCT-2288 | refresh_engine | `3c236b4` corrective source | Pending B03 | Pending merge | Profile-keyed latest-wins runtime separates durable commit from presentation and fences same-profile pending work, cross-profile concurrency, dispatch, stale/deleted/shutdown results, and overlapping timers |

## Current Corrective Architecture and Safety Guarantees

- `UsageKit` uses Foundation plus narrowly scoped Darwin process primitives. It models provider-neutral accounts, health, capabilities, dynamic limit groups/windows, summaries, credits, and typed errors without app, UI, credential, or persistence dependencies.
- Codex subprocesses are request-scoped for reads and login-scoped for interactive authentication. The transport correlates multiple in-flight numeric or string IDs, bounds output and time, handles cancellation before launch, and requires direct-child plus observed-descendant cleanup.
- Process ownership is tied to stable PID/start-time identity before signaling or accepting exit. Synthetic protocol fixtures carry generated-schema version and source provenance without user payloads.
- A linked `CODEX_HOME` is persisted as a canonical path plus filesystem device/inode. Registry capture and process construction validate the same identity, and process launch validates it again. A path replaced by a symlink or different directory fails closed.
- Legacy path-only Codex links decode and re-encode without losing profile metadata, but remain unresolved and cannot reach executable resolution or provider construction until the user relinks; an explicit same-path relink records identity and a same-path replacement records the new inode.
- Codex provider reads required account and rate-limit data in one scoped session. Missing, unsupported, or malformed optional token usage preserves the usable report and records typed degraded health.
- Refresh orchestration owns concurrency by profile UUID. Provider identity, provider revision, input generation, invocation order, presentation context, deletion tombstones, and terminal shutdown fence persistence and UI publication.
- Durable accepted events and current-context presented events are distinct. Claude history/API commits can complete independently, while notifications, statusline writes, alerts, success feedback, and auto-switching run only for current eligible Claude presentation.
- Codex remains disabled for normal production use until P17. Production code does not read, copy, mutate, delete, or log `auth.json`, and unlink/disconnect does not log out Codex or alter shell state.

## Latest Acceptance Work by Ticket

- P05 / PRODUCT-2281: added explicit more-than-two-window round-trip and duplicate validation, plus Codable coverage for the partial optional-usage health state.
- P06 / PRODUCT-2278: added concurrent out-of-order response routing, deterministic prelaunch and blocked-write cancellation, stable PID/start-time ownership, child/grandchild and retained-child re-census, terminal-error delivery before cleanup, expected-home identity checks, exact generated-schema provenance, and repeated zero-process proof.
- P07 / PRODUCT-2286: added device/inode binding, same-path replacement and symlink-repoint rejection, exact legacy path-only load/re-encode/same-path upgrade behavior, distinct-home/case/symlink identity coverage, golden profile/current/history migration with idempotence, and activation spies proving no Claude effects for Codex.
- P08 / PRODUCT-2285: covered browser/device/already-authenticated/cancel/timeout/server-error login, ChatGPT and unsupported API-key/Bedrock modes, dynamic and legacy limits, optional-usage partial success, required health endpoints, no-logout disconnect, and a no-payload/no-path live smoke against installed Codex 0.145.0.
- P09 / PRODUCT-2288: added same-profile latest-pending and cross-profile concurrency, provider dispatch exclusivity, capture/fetch/commit/presentation fences, split Claude core/API commits, stale/deletion/shutdown terminality, and timer/network/wake policy coverage including overlapping automatic timers.

## Verification Evidence

| Date | Scope | Command/check | Result | Evidence |
|---|---|---|---|---|
| 2026-07-29 | P01 unit suite | `xcodebuild test ... -destination "platform=macOS"` | PASS | Reviewed head: 105 passed, 0 failed, 0 skipped |
| 2026-07-29 | P01 storage isolation | `SharedDataStoreTests` repeated 20 times | PASS | Per-test UUID suites remained isolated |
| 2026-07-29 | P01 Debug build | unsigned `xcodebuild build -configuration Debug` | PASS | `** BUILD SUCCEEDED **` |
| 2026-07-29 | P01 Release build | unsigned `xcodebuild build -configuration Release` | PASS | `** BUILD SUCCEEDED **` |
| 2026-07-29 | P01 diff hygiene | `git diff --check` | PASS | No whitespace errors |
| 2026-07-30 | P04 focused reliability suite | `MenuReliabilityTests` | PASS | 5 passed, 0 failed |
| 2026-07-30 | P04 full unit suite | unsigned `xcodebuild test` | PASS | All suites passed |
| 2026-07-30 | P04 Debug build | unsigned `xcodebuild build -configuration Debug` | PASS | `** BUILD SUCCEEDED **` |
| 2026-07-30 | P03 durable storage suites | `AtomicJSONFileStoreTests`, `ProfileUsageFileStoreTests`, `UsageHistoryServiceTests` | PASS | Independently rerun: 17 passed, 0 failed |
| 2026-07-30 | P02 profile security integration | focused tests + full app suite + Release build | PASS | 12 focused and 136 full tests passed; zero failures/skips; Release build and leak scans clean |
| 2026-07-30 | P02 hosted-test isolation | startup guard assertion + non-secret state audit | PASS with recorded incident | Future XCTest launches return before defaults/Keychain/file migration; one pre-guard launch is documented in D027 |
| 2026-07-30 | B02 pre-integration suite | full unsigned Debug `xcodebuild test` after P02/P03 primitive/P04 integration | PASS | Independently rerun: 153 passed, 0 failed, 0 skipped |
| 2026-07-30 | B02 focused integrated safety suite | security/current usage/file/history/menu selected tests | PASS | Independently rerun after P03 integration: 44 passed, 0 failed |
| 2026-07-30 | B02 semantic/security review | two read-only changed-code and call-site audits | FIXED | Closed six earlier findings plus final deletion-resurrection, unresolved-read, backup-preparation, and CLI success-reporting blockers |
| 2026-07-30 | B02 final full unit suite | unsigned Debug `xcodebuild test` at `9808277` | PASS | 166 passed, 0 failed, 0 skipped |
| 2026-07-30 | B02 final Debug/Release builds | unsigned `xcodebuild build` in both configurations | PASS | Both configurations exited successfully; only pre-existing warnings remain |
| 2026-07-30 | B02 post-audit focused safety suite | profile security, current usage, and atomic storage suites | PASS | Independently rerun: 39 passed, 0 failed |
| 2026-07-30 | B02 post-audit full unit suite | unsigned Debug `xcodebuild test` at `4c9890c` | PASS | xcresult summary: 178 passed, 0 failed, 0 skipped |
| 2026-07-30 | B02 post-audit Debug/Release builds | unsigned `xcodebuild build` in both configurations at `4c9890c` | PASS | Both configurations exited successfully; only baseline warnings remain |
| 2026-07-30 | P05 UsageCore package | `swift test` and `swift test -c release` | PASS | Independently rerun: 13 passed in each configuration |
| 2026-07-30 | P05 Claude adapter | focused adapter tests + full app suite + Debug build | PASS | Worker: 10 adapter tests and 120 full-app tests passed; independent package/diff/security audit passed |
| 2026-07-30 | P06 Codex transport package | warnings-as-errors `swift test` and Release package test | PASS | Independently rerun: 31 passed in each configuration; app-framework boundary and leak/diff scans clean |
| 2026-07-30 | P06 post-test process census | exact fake-server PID/PPID/state check | FAIL — correction active | Found one PID-1-reparented CPU-running fake server after a green suite; exact fixture process terminated and P06 reopened |
| 2026-07-30 | P06 lifecycle correction | warnings-as-errors package suite plus exact PID/reaping assertions | PASS | Corrective `0647f4b`; independent Debug 31/31; lifecycle suite repeated five cycles; exact PIDs reached ESRCH |
| 2026-07-30 | P06 corrected process census | pre/post fixture-process census | PASS | Zero fake app-server processes before and after the independently rerun package suite |
| 2026-07-30 | B02 final corrective head | production-shared A→B regression + full suite + Debug/Release | PASS | 1 focused and 218 full tests passed; both app executables verified at `747230b` |
| 2026-07-30 | B02 final review/merge | all three review surfaces + independent exact-hash audit | PASS with documented reviewer limits | Six threads resolved; Tessie size ceiling and exhausted Greptile budget recorded in D37-D38; merged as `ab70776` |
| 2026-07-30 | B03 integrated UsageKit | `swift test --package-path Packages/UsageKit` | PASS | 49 passed, 0 failed after P05/P06/P08 cherry-pick onto fresh `upstream/main` |
| 2026-07-30 | P07 provider profile core | focused provider-core and security/current-usage integration suites | PASS | Frozen `6d07d6a`: 41/41 provider-core and 51/51 storage integration tests passed |
| 2026-07-30 | P07 full app suite | unsigned `xcodebuild test` at frozen `6d07d6a` | PASS | Independent xcresult summary: 269 passed, 0 failed, 0 skipped |
| 2026-07-30 | P07 package/build gates | UsageKit package plus Debug and universal Release app builds | PASS | 49/49 package tests; both app configurations succeeded; diff check clean |
| 2026-07-30 | P07 exact-hash semantic audit | provider identity, migration, Keychain isolation, rollback, tombstone lifecycle, and P09 handoff | PASS | Independent clean verdict on `6d07d6ac55e1512effd2eadef90dac89cb721321` |
| 2026-07-30 | P09 refresh engine/runtime suite | serial `UsageRefreshEngineTests` | PASS | Frozen implementation: 76 passed, 0 failed, 0 skipped; covers arrival inversion, component ordering, cancellation quiescence, stale presentation, status ABA, deletion, and shutdown |
| 2026-07-30 | B03 focused provider/menu/storage gate | refresh engine, registry, menu reliability, provider core, and current-usage integration suites | PASS | Independently rerun: 168 passed, 0 failed, 0 skipped before final race hardening; all affected regressions included again in the full final suite |
| 2026-07-30 | B03 final full app suite | unsigned serial `xcodebuild test` at frozen P09 source | PASS | xcresult summary: 349 passed, 0 failed, 0 skipped |
| 2026-07-30 | B03 package gates | `swift test` and `swift test -c release --package-path Packages/UsageKit` | PASS | 49 passed, 0 failed in each configuration; post-test fake app-server process census was empty |
| 2026-07-30 | B03 app build gates | unsigned Debug, strict-concurrency diagnostic Debug, and universal Release | PASS | Debug executable built; universal executable contains `arm64` and `x86_64`; P09 files emit no strict-concurrency diagnostics |
| 2026-07-30 | B03 safety scans | diff, credential pattern, `auth.json`, old refresh owner, and process scans | PASS | No whitespace or credential-pattern findings; production has zero `auth.json` references; old coordinator/executor references are absent |
| 2026-07-30 | Corrective P05 UsageCore suite | `swift test --package-path Packages/UsageKit -Xswiftc -warnings-as-errors --filter UsageCoreTests` | PASS | Current working tree: 14 passed, 0 failed |
| 2026-07-30 | Corrective P08 provider suite | `swift test --package-path Packages/UsageKit -Xswiftc -warnings-as-errors --filter CodexUsageProviderTests.CodexUsageProviderTests` | PASS WITH INTENTIONAL SKIP | Current working tree: 21 passed, 0 failed, 1 opt-in live smoke skipped in this invocation; the live smoke was executed separately and passed below |
| 2026-07-30 | Corrective P06 blocked-write regression | `TransportTests/testBlockedStdinWriteIsCoveredByTheRequestTimeout` under an external 60-second timeout | PASS | Current working tree: 1 passed in 0.405 seconds; post-test fake-process census empty |
| 2026-07-30 | Corrective source/static gates | Swift parse, shell syntax, fixture JSON validation, generated-schema provenance validation, and scoped `git diff --check` | PASS | Current corrective sources and synthetic fixtures pass their non-runtime checks |
| 2026-07-30 | Corrective P06 transport suite | Debug and Release warnings-as-errors transport tests | PASS | Exact source `3c236b4`: 35 passed, 0 failed in each configuration; late descendants and blocked-write cancellation are deterministic and the process census is empty |
| 2026-07-30 | Corrective UsageKit Debug | full warnings-as-errors package suite | PASS WITH EXPECTED SKIP | Exact source `3c236b4`: 71 total, 0 failures, 1 expected opt-in live-smoke skip |
| 2026-07-30 | Corrective UsageKit Release | full optimized warnings-as-errors package suite | FIXED THEN PASS | The first earlier run exposed a typed terminal-error race; exact source `3c236b4` reran 71 total with 0 failures and 1 expected opt-in live-smoke skip |
| 2026-07-30 | Corrective installed-Codex smoke | explicit live account/rate-limit smoke against Codex 0.145.0 | PASS | 1 passed, 0 failed; the smoke prints neither payloads nor paths |
| 2026-07-30 | Corrective optimized duplicate-response regression | duplicate response and terminal-error behavior in optimized execution | PASS | 10 passed, 0 failed after the terminal-error race correction |
| 2026-07-30 | Corrective profile relink suite | `ProfileProviderCoreTests` | PASS | Exact source `3c236b4`: 46 passed, 0 failed; same-path legacy upgrade and replacement-inode capture included |
| 2026-07-30 | Corrective full serial app suite | unsigned serial `xcodebuild test` | PASS | Exact source `3c236b4`: xcresult summary 396 passed, 0 failed, 0 skipped |
| 2026-07-30 | Corrective P09 overlapping-timer regression | focused overlapping automatic-timer coverage | PASS | Current settled tree: 1 passed, 0 failed |
| 2026-07-30 | Corrective app build gates | unsigned Debug, strict-concurrency Debug, universal Release | PASS | Exact source `3c236b4`: all builds succeeded; no new B03 diagnostics; Release executable has `arm64` and `x86_64` |
| 2026-07-30 | Corrective Thread Sanitizer gate | `UsageRefreshEngineTests` with TSan runtime | PASS | Exact source `3c236b4`: 99 passed, 0 failed/skipped; no ThreadSanitizer race signature |
| 2026-07-30 | Corrective final safety gates | diff/JSON/XML/shell/locales/schema/secret/auth/process scans | PASS | Static syntax and all nine locale files pass; schema has 347 generated files and exact 10-method provenance; production Codex paths have no `auth.json` access; process census is empty; known locale keyset drift remains P15 |
| 2026-07-30 | Corrective remaining gate | `$codex-ship-pr skip-review --linear PRODUCT-2281 --auto-merge` | PENDING | Local exact-source verification and independent semantic/safety reviews are clean |

## Blockers

- No product or architecture decision is blocking B03.
- Only the B03 commit/push/PR review/CI/auto-merge ship gate remains.
- Release signing, notarization, Pages/appcast, and Homebrew publication may require Revenium secrets or repository permissions; verify during P16.

## Decisions

- All architecture decisions are settled in `decisions.md`.
- No open decisions at initialization.

## Daily Summaries

### 2026-07-29 / 2026-07-30 UTC

- Completed upstream, repository, architecture, Codex app-server, baseline-test, localization, CI, and release-infrastructure audits.
- Chose one modular app with an app-framework-free UsageKit seam (Foundation plus narrowly scoped Darwin process primitives).
- Defined 17 work units, dependency waves, and five sequential PR batches.
- Created the Linear project, PRODUCT-2276 umbrella, all 17 child issues, dependency relations, and links to PRODUCT-1022/PRODUCT-1237.
- Implemented and independently verified P01 on `feature/codex-support-baseline`.
- Shipped PR #7 through Tessie and Greptile gates; fixed the sole review finding and merged as `29c7fe1`.
- Integrated the verified P04 menu/window reliability commit into B02.
- Integrated the verified P02 Keychain primitive and started serialized profile migration/lifecycle wiring.
- Completed and integrated P02 verified profile-keyed credential storage, legacy migration, explicit credential APIs, and hosted-test startup isolation.
- Recorded one pre-guard hosted test startup: migration completion markers are set and the legacy session file is absent; no secret contents were inspected and no state was rolled back without a trustworthy prior snapshot.
- Integrated the P03 durable history/file primitive; current usage hydration and profile lifecycle cleanup remain in the serialized integration step.
- Completed P03 current-usage migration/hydration, exact installed-file verification, component-isolated explicit writes, throwing history/profile cleanup, failure-visible deletion, and partial-deletion runtime scrubbing.
- Added recoverable Keychain/metadata transactions after review found that a late field or metadata failure could otherwise partially apply a complete credential update.
- Completed and independently audited dependency-independent P05 UsageKit contracts plus the Claude characterization adapter while B02 storage work finishes.
- Started P06 bounded Codex app-server transport after the UsageCore contracts passed independent Debug/Release package tests.
- Completed and independently verified P06 bounded transport against the current local Codex 0.145.0 schema, including handshake ordering, process bounds, cancellation/reaping, EOF/exit races, method-specific params, environment isolation, and redaction.
- Reopened P06 after the independent post-test process census found that a forced-termination fake server could outlive a passing suite; acceptance now requires PID-level termination proof and repeated zero-orphan censuses.
- Corrected P06 process ownership: successful cleanup now requires the Foundation termination callback, bounded SIGKILL escalation, and a `waitUntilExit` reaping barrier; independent reruns prove exact fixture PIDs reach ESRCH and leave a zero-orphan census.
- Started dependency-independent P08 typed account/rate-limit/usage/login provider work on the verified combined P05/P06 package boundary.
- User authorized implementation and audited auto-merge for every delivery PR.
- Completed P07 with strict closed provider tags, canonical physical Codex homes, zero-profile bootstrap, post-choice legacy Claude migration, provider/revision immutability, transactional Codex home changes, and fail-closed deletion tombstones.
- Closed P07 review findings covering existing-v3 migration clobbering, stale revision reset, provider/Keychain boundary bypasses, durable-marker corruption, ordinary-save identity changes, deletion recovery ordering, and active-survivor transitions.
- Independently verified frozen P07 at 269/269 full app tests, 49/49 package tests, both app builds, and a clean exact-hash semantic audit.
- Started P09 profile-keyed provider refresh orchestration on the frozen P07 contract.
- Completed P09 with one-running/one-latest-pending profile actors, parallel Claude core/API fetches with serialized component commits, Runtime-issued monotonic ordering, strict provider/revision/input fences, profile-keyed normalized presentation, and a production-disabled Codex gate.
- Preserved Claude history, notifications, statusline, circuit recovery, manual feedback, and auto-switch semantics at their original single/multi-profile boundaries while removing the transitional refresh owners.
- Closed final concurrency audits for actor/MainActor reentrancy, accepted-but-stale presentation, queued loading ownership, status A→B→A coalescing, deletion tombstones, terminal shutdown, child-process quiescence, and batch normalization.
- Froze P09 at `5f41158167319b2e445b29139e62822786467166` after 76/76 engine tests, 349/349 full app tests, 49/49 package tests in Debug and Release, strict-concurrency diagnostics with no P09 warnings, and Debug/universal Release builds.
- Prepared B04 dependency ownership: a short serialized bootstrap will expose the reusable fresh Codex provider factory and normalized profile snapshot projection before P10 setup/settings, P11 popover, and P12 menu/status/icon work proceed in parallel.
- Reopened the frozen B03 source after independent acceptance audits found gaps in concurrent response routing, process-tree cleanup, Codex-home identity binding, legacy path-only links, optional usage degradation, login outcomes, refresh side-effect fencing, and exact migration fixtures.
- Implemented the corrective acceptance work across P05–P09. Focused provider/core checks and the blocked-write transport regression passed before the settled-tree package and app validations below.
- Verified corrective source `3c236b4` with 35/35 transport tests in Debug and Release, 71-test UsageKit Debug and Release runs, a 1/1 live smoke against installed Codex 0.145.0, 10/10 optimized duplicate-response regressions, 396/396 serial app tests, 46/46 profile-core tests, and 99/99 refresh-engine tests under TSan.
- The first earlier optimized Release run exposed a typed terminal-error race. The implementation was corrected; exact-source Debug, strict-concurrency, universal Release, TSan, localization, process-census, and safety gates now pass, leaving only the audited ship pipeline.
- Greptile's sole B03 finding exposed a real termination-timeout edge: process waiting could throw before stream handlers and descriptors were released. Cleanup is now unconditional, preserves the original timeout, and is covered by retained-instance FD accounting in both configurations.
- A repeated exact-head comparison then reproduced a pre-waiter terminal race in which clean process exit could discard responses or notifications that had already been decoded and routed. Terminal input now preserves those frames for exactly-once draining, while explicit close atomically discards them and gives in-flight requests the typed local cancellation cause.
- Final review-correction validation passed 38/38 transport tests and 74/74 UsageKit tests in both Debug and Release, with only the intentional opt-in live-smoke skip; terminal drain, explicit close, and FD cleanup each passed repeated cross-configuration stress runs, and the unsigned app plus strict-concurrency integration builds succeeded with no new UsageKit diagnostics.
- An additional SwiftPM Thread Sanitizer run compiled successfully but could not start because Xcode's TSan runtime dylib was rejected by the host platform's code-signing policy; deterministic actor barriers, serial stress, and the previously passing app TSan matrix remain the concurrency evidence for this batch.
