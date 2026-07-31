# Progress Log: Claude Usage Desktop App Codex Support

## Active Work

- Project status: Active
- Linear project: `Claude Usage Desktop App Codex Support` (`8fd871e1416e`)
- Umbrella: `PRODUCT-2276`
- Tracking wave: W00 — complete
- Current delivery batch: B05 — Release readiness and final parity
- Current phase: P17 final hosted/ship gate; P13–P16 implementation and local acceptance are complete
- B04 merged: PR [#10](https://github.com/revenium/Claude-Usage-Tracker/pull/10), squash `64047219d03ba1aa11401dfc94fa38f89c4add32`
- B05 base: `64047219d03ba1aa11401dfc94fa38f89c4add32`
- B05 complete local-matrix source: `8b6a3c2ebd780ed4bed8a90b089edd9fbbf84500`
- B05 hosted correction source: `8cd3f2ba49eb30a4bc5bfab90648f0bd7fc7bc51`
- Current validation: 610/610 app tests in serial and parallel modes; 80 UsageKit tests in Debug and Release with one intentional opt-in live-smoke skip; installed Codex 0.145.0 smoke 1/1; 9×994 localization keys and 15/15 fixtures; Debug/universal Release and UI build-for-testing; static/forbidden audit and independent exact-head review clean. Hosted app and distribution CI pass through `869ada4`; the sandbox-aware runner-container correction passes 21/21 parser/security tests, app and dedicated UI `build-for-testing`, diff hygiene, and exact independent review at `8cd3f2b`.
- Review-size prerequisite: PR [#12](https://github.com/revenium/Claude-Usage-Tracker/pull/12) merged as `16b2a87`; B05 merged that base at `5448504` and now changes exactly 99 files.
- Next action: push the final tracking head, require hosted `Codex UI parity` 11/11 plus app/distribution CI, complete the canonical Tessie and `$codex-ship-pr skip-review` audits, merge, then archive/delete inherited `gh-pages` by exact SHA and reconcile Linear

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
| W03A | UsageKit boundary | P05 | Complete |
| W03B | Transport and profile model | P06, P07 | Complete |
| W03C | Codex provider | P08 | Complete |
| W03D | Refresh integration | P09 | Complete |
| W04 | Provider-aware UI parity | P10, P11, P12 | Complete — merged |
| W05A | Cross-cutting parity and distribution | P13, P14, P16 | Complete |
| W05B | Localization/accessibility/UI automation | P15 | Complete — hosted runtime remains a B05 merge gate |
| W05C | Final parity and ship audit | P17 | In progress — hosted CI and ship audit |

## Delivery PRs

| Batch | Branch | PR | CI | Review Gate | Merge | Status |
|---|---|---|---|---|---|---|
| B01 Baseline | `feature/codex-support-baseline` | [#7](https://github.com/revenium/Claude-Usage-Tracker/pull/7) | Success | Tessie clean + Greptile 5/5 | `29c7fe1` | Merged |
| B02 Foundations | `feature/codex-support-foundations` | [#8](https://github.com/revenium/Claude-Usage-Tracker/pull/8) | Equivalent exact-head gate passed | All findings fixed; reviewer limits documented | `ab70776` | Merged |
| B03 Provider core | `feature/codex-support-provider-core` | [#9](https://github.com/revenium/Claude-Usage-Tracker/pull/9) | Exact-head local matrix passed; fork-wide hosted-CI exception audited | Greptile 5/5 at `728d84e`; latch valid; Tessie size limit documented | `2fd330f` | Merged |
| B04 UI parity | `feature/codex-support-ui-parity` | [#10](https://github.com/revenium/Claude-Usage-Tracker/pull/10) | 519 app / 80 package Debug+Release / strict+universal builds | Greptile 5/5; exact-head latch valid | `6404721` | Merged |
| B05 Release readiness | `feature/codex-support-release-readiness` | [#11](https://github.com/revenium/Claude-Usage-Tracker/pull/11) | Exact local matrix green; hosted-only canonicalization, process-root, and runner-sandbox boundaries corrected through `8cd3f2b`; exact-head rerun pending | Independent source and all focused correction reviews CLEAN; Tessie pending on 99-file diff | — | Active — ship gate running |

## Completed Phases

| Phase | Linear | Worker | Commit | Batch PR | Completed | Summary |
|---|---|---|---|---|---|---|
| P01 | PRODUCT-2282 | baseline_audit | `1009d4f` | #7 | 2026-07-30 | Parser correctness, null compatibility, hermetic UserDefaults tests, canonical validation docs |
| P02 | PRODUCT-2280 | profile_security_integration | `747230b` final head | #8 | 2026-07-30 | Verified profile-keyed Keychain storage, backward migration, explicit credential APIs, startup guard, fail-closed deletion marker |
| P03 | PRODUCT-2279 | profile_security_integration | `747230b` final head | #8 | 2026-07-30 | Atomic current/history files, verified migration, transactional credentials, recoverable cleanup, fault-injected rollback safety |
| P04 | PRODUCT-2277 | menu_reliability_audit | `747230b` final head | #8 | 2026-07-30 | Context menu, stable status items, popover/window/full-screen fixes, CGImage fingerprinting, Cmd+W, captured-profile auto-switch safety |
| P05 | PRODUCT-2281 | usagekit_contracts | `728d84e` final PR head | #9 | 2026-07-30 | App-framework-free provider contracts validate arbitrary dynamic windows and persist typed partial-usage health without inventing data; ADRs D001–D013 record the package seam and dependency direction |
| P06 | PRODUCT-2278 | codex_transport | `728d84e` final PR head | #9 | 2026-07-30 | Concurrent JSON-RPC correlation, deterministic cancellation, blocked-write bounds, stable-identity process-tree teardown, retained-child re-census, immediate terminal delivery, schema provenance, and zero-process proof |
| P07 | PRODUCT-2286 | provider_profile_model | `728d84e` final PR head | #9 | 2026-07-30 | Provider-tagged profiles bind canonical Codex homes to device/inode identity; exact-path relink upgrades legacy unresolved links and captures same-path replacements |
| P08 | PRODUCT-2285 | codex_provider | `728d84e` final PR head | #9 | 2026-07-30 | Dynamic and legacy limits, optional-usage partial success, supported/unsupported account modes, complete typed login outcomes, scoped cleanup, and live installed-Codex proof |
| P09 | PRODUCT-2288 | refresh_engine | `728d84e` final PR head | #9 | 2026-07-30 | Profile-keyed latest-wins runtime separates durable commit from presentation and fences same-profile pending work, cross-profile concurrency, dispatch, stale/deleted/shutdown results, and overlapping timers |
| P10 | PRODUCT-2283 | b04_p10_setup_settings | `e44e15b` final PR head | #10 | 2026-07-30 | Provider-aware onboarding, mixed-profile CRUD, canonical home linking/relinking, official login, account health, capability gating, and one typed settings window |
| P11 | PRODUCT-2287 | b04_p11_popover | `e44e15b` final PR head | #10 | 2026-07-30 | Arbitrary dynamic groups/windows, plan, credits, daily usage, reset/pace controls, normalized error states, and preserved Claude shell behavior |
| P12 | PRODUCT-2284 | b04_p12_menu_icons | `e44e15b` final PR head | #10 | 2026-07-30 | Stable provider/window menu metrics, compatible legacy persistence, dynamic status items/icons, exact action fences, and provider-aware appearance |
| P13 | PRODUCT-2293 | b05_p13_history_notifications | `0670bdd` source, integrated in B05 | B05 | 2026-07-30 | Provider-tagged history/export, dynamic-window restart-safe notification ledger, threshold/reset deduplication, and capability-gated Claude automation |
| P14 | PRODUCT-2289 | b05_p14_final_corrections | `f574aaa` integrated, final test proof at `8b6a3c2` | B05 | 2026-07-30 | Provider recovery, fail-closed redaction, bounded diagnostics, stable process identity, exact-PID late reaping, and adversarial cleanup proof |
| P15 | PRODUCT-2291 | b05_p15_readiness_audit | `194d9e5` integrated, exact review at `8b6a3c2` | B05 | 2026-07-30 | Nine 994-key catalogs, 15-case validator, accessibility/focus/keyboard work, docs, isolated 11-method native UI automation, and CI enforcement |
| P16 | PRODUCT-2292 | b05_p16_distribution | `49e0f78` integrated in B05 | B05 | 2026-07-30 | Revenium release/update destinations, fail-closed signed/notarized cohesive release unit, recoverable draft publication, and narrow Homebrew token scope |

## Completed B04 Parallel Phases

| Phase | Linear | Branch | Worktree | Worker | Ownership |
|---|---|---|---|---|---|
| P10 | PRODUCT-2283 | `work/codex-ui-setup-settings` | `phase-04-ui-setup-settings` | `b04_p10_setup_settings` | Setup, profile management, settings, account/login UI |
| P11 | PRODUCT-2287 | `work/codex-ui-popover` | `phase-04-ui-popover` | `b04_p11_popover` | Normalized popover presentation and additive daily-usage series |
| P12 | PRODUCT-2284 | `work/codex-ui-menu-icons` | `phase-04-ui-menu-icons` | `b04_p12_menu_icons` | Status items, menus, metric configuration, appearance, icon rendering |

## Current Corrective Architecture and Safety Guarantees

- `UsageKit` uses Foundation plus narrowly scoped Darwin process primitives. It models provider-neutral accounts, health, capabilities, dynamic limit groups/windows, summaries, credits, and typed errors without app, UI, credential, or persistence dependencies.
- Codex subprocesses are request-scoped for reads and login-scoped for interactive authentication. The transport correlates multiple in-flight numeric or string IDs, bounds output and time, handles cancellation before launch, and requires direct-child plus observed-descendant cleanup.
- Process ownership is tied to stable PID/start-time identity before signaling or accepting exit. Synthetic protocol fixtures carry generated-schema version and source provenance without user payloads.
- A linked `CODEX_HOME` is persisted as a canonical path plus filesystem device/inode. Registry capture and process construction validate the same identity, and process launch validates it again. A path replaced by a symlink or different directory fails closed.
- Legacy path-only Codex links decode and re-encode without losing profile metadata, but remain unresolved and cannot reach executable resolution or provider construction until the user relinks; an explicit same-path relink records identity and a same-path replacement records the new inode.
- Codex provider reads required account and rate-limit data in one scoped session. Missing, unsupported, or malformed optional token usage preserves the usable report and records typed degraded health.
- Refresh orchestration owns concurrency by profile UUID. Provider identity, provider revision, input generation, invocation order, presentation context, deletion tombstones, and terminal shutdown fence persistence and UI publication.
- Durable accepted events and current-context presented events are distinct. Claude history/API commits can complete independently, while notifications, statusline writes, alerts, success feedback, and auto-switching run only for current eligible Claude presentation.
- The centralized Codex production gate is enabled after P15 parity and the local P17 matrix passed; the branch still cannot merge until hosted UI and ship gates pass. Production code does not read, copy, mutate, delete, or log `auth.json`, and unlink/disconnect does not log out Codex or alter shell state.

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
| 2026-07-30 | B03 ship gate | `$codex-ship-pr skip-review --linear PRODUCT-2281 --auto-merge` | PASS | PR #9 exact-head review reached Greptile 5/5; all audits passed; squash-merged as `2fd330f` |
| 2026-07-30 | B04 shared UI bootstrap | full app and UsageKit suites, strict build, login stress, safety/process scans | PASS | `cefea32`: 419/419 app tests; 77 package tests with one expected live-smoke skip; 80/80 login-race stress passes; no residual fake processes |
| 2026-07-30 | B04 integrated UI parity | focused/full app suites, package Debug+Release, strict/universal builds, static/safety scans, three semantic reviews | PASS | `8f90c66`: 100/100 focused and 519/519 full app tests; 80 package tests in each configuration with one expected opt-in skip; arm64+x86_64 Release; reviews clean |

## Blockers

- No product or architecture decision blocks the B05 code merge.
- Hosted macOS CI must execute all 11 Codex UI tests with zero failures, skips, or expected failures before merge; the local host cannot run the suite because Developer Mode/TCC blocks automation before the first test body.
- The first public release remains blocked on protected release variables/secrets and D158 human UAT in a backed-up disposable user or VM. No public release tag will be created during B05 shipping.

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
- Shipped B03 through `$codex-ship-pr skip-review`: Greptile's exact-head re-review reached 5/5 with no new findings, the canonical score-4 latch validated, all three review surfaces and commit intent passed audit, and PR #9 squash-merged as `2fd330f`; PRODUCT-2281, PRODUCT-2278, PRODUCT-2286, PRODUCT-2285, and PRODUCT-2288 are Done.
- Created the fresh B04 integration worktree from merged `upstream/main`; the serialized D046 provider-factory and normalized-presentation bootstrap now precedes parallel P10/P11/P12 implementation.
- Completed and independently validated the B04 shared bootstrap at `cefea32`: stateless fresh Codex provider creation, one whole-product availability gate, profile-keyed normalized presentation projection, concurrent/idempotent login cancellation, and a provider-neutral profile-specific settings navigation seam.
- Started P10, P11, and P12 concurrently in isolated Revenium worktrees with non-overlapping production ownership; the PM retains localization, project tracking, and integration files.
- Integrated P10, P11, and P12 in dependency order, then closed cross-workstream gaps in production settings routing, same-provider setup defaults, Claude popover parity, dynamic accessibility identity, time/pace presentation, and hosted-test dependency lifetime.
- Froze B04 implementation at `8f90c66` after 100/100 focused and 519/519 full app tests, 80-test UsageKit Debug and Release runs, strict-concurrency and universal Release builds, static/safety scans, and three clean independent semantic reviews.
- Shipped B04 through `$codex-ship-pr skip-review`: the exact-head Greptile review was 5/5 with no findings, the canonical score-4 latch validated, all review surfaces and commit intent passed audit, and PR #10 squash-merged as `6404721`; PRODUCT-2283, PRODUCT-2287, and PRODUCT-2284 are Done.
- Created B05 from the freshly fetched B04 merge and started P13, P14, and P16 concurrently in isolated Revenium worktrees with non-overlapping production ownership; the PM retains project tracking and final integration.
- Integrated P13 history, versioned mixed-provider export, dynamic-window notifications, and automation gating, then corrected seven independent-review findings with a versioned restart-safe per-window delivery ledger, high-water threshold semantics, bounded missing-window retention, capability-driven settings normalization, provider-aware automation visibility, and profile-scoped chart identity.
- Verified final P13 correction `0670bdd` with 550/550 app tests, UsageKit Debug and Release runs of 80 tests with the one expected opt-in live-smoke skip, focused crash/restart/in-flight/profile-deletion regressions, diff hygiene, and an `arm64` + `x86_64` universal Release build; an exact-commit independent follow-up review is active.
- Reopened P14 after its first independent review found raw standalone JWT/custom-path leakage, a continuous-writer timeout escape, overstated process-group containment, ambiguous census handling, unverified raw-log deletion, and an A→B→A diagnostics-result race; a dedicated corrective worker now owns the diagnostics worktree while P16 continues independently.
- Closed the P13 follow-up findings with threshold-settings reconciliation, future-ledger preservation, tokenized in-flight reservations, pre-finalization notification cleanup, runtime capability gates, and schema-v3 exact date encoding; the complete corrective focused matrix passed before the exact-source full suite.
- Froze P13 at `0670bdd` after an independent clean exact-commit audit and 111/111 reviewer-focused tests; all history/export/notification/automation acceptance criteria are complete, while the Linear ticket remains In Progress until the B05 delivery PR merges.
- Integrated P14 commits through `9ce3065`; the combined P13/P14 focused matrix passes 89/89 and a fresh exact-source P14 follow-up review is active.
- Verified the combined P13/P14 integration with 574/574 full app tests and a successful universal Release build containing `arm64` and `x86_64`.
- The exact-source P14 follow-up kept the workstream open after finding four residual gaps: punctuation-bound custom paths, fail-open PID-identity fallback, destructive API-route redaction, and missing event-driven late-child reaping. It independently passed 52 combined focused tests plus three repetitions each of continuous-writer, `setsid`, and stubborn-tree containment before handing the four corrections to a separate worker.
- Integrated P16 as `500d743` from source commit `752a4bd`: Revenium-owned fail-closed Sparkle configuration, signed/notarized cohesive GitHub Release automation, release-asset appcast, Homebrew tap publication, operational-link rehoming, distribution validation, and release runbooks. The worker validated 9/9 focused configuration tests, 80 UsageKit tests with the one expected opt-in skip, both app configurations, a universal executable, real pinned Sparkle signing tools, a strict temporary-tap cask audit, and an ad-hoc cohesive release unit; independent exact-commit review is active.
- Completed the read-only P15 inventory: all nine expected catalogs parse, but key parity, duplicate definitions, approximately 188 untranslated provider call-site keys, one Korean placeholder signature, accessibility semantics, keyboard focus, and the complete absence of an isolated XCUITest target/harness remain real acceptance gaps.
- Started P15 from the integrated P13/P14/P16 head in `phase-05-localization-ui-tests`, with explicit `UITesting` isolation, full catalog/validator repair, scenario-complete provider UI automation, accessibility/focus semantics, CI enforcement, and Codex support documentation as the serialized scope.
- P16's exact-commit review found two release-security defects: an ungated manual Homebrew path could expose the cross-repository token to tag-owned code, and direct publication could strand a public partial release that retries refused to repair. Corrective `9bac28c` removes manual dispatch, proves source/metadata/main ancestry before rendering, exposes the tap token only to one optimistic-SHA Contents API write, and publishes through a provenance-owned draft that is re-downloaded and fully verified before going public; expanded distribution validators pass.
- P15 checkpoint `03649aa` establishes a compile-time plus explicit-argument-gated UI automation boundary with isolated defaults/data/bundle identity and no production migration, Keychain, updates, notifications, prompts, browser, monitor, or retry startup. Its parser suite passes 5/5 and the `UITesting` arm64 app builds; project/UI-test wiring continues while a separate worker owns validator fixtures and all nine catalogs.
- Completed P15's isolated localization lane and integrated it into the P15 worktree as `a81de2f`: every shipped catalog now has the same 937 unique keys, all nine pass `plutil`, the 14-case validator fixture matrix passes, source localization helpers are covered, placeholder signatures match, obsolete Korean-only keys have no source consumers, and the inherited Korean `%@` defect is repaired.
- Closed the remaining P16 release-security follow-up in `9f1508e` and `49e0f78`: the Homebrew tap token is no longer injected into the main release job, and all four remotely downloaded draft assets must be byte-identical to the locally signed and verified release unit before publication.
- An independent exact-head P16 review is clean after distribution, YAML, duplicate-key, embedded-shell, diff, token-scope, ancestry, optimistic-SHA, owned-draft, exact-asset, remote-byte-identity, and no-`gh-pages`-consumer checks. P16 is implementation-complete; only the combined B05 full-app/distribution gate remains.
- Native P15 UI automation is structurally buildable, but this workstation blocks the runner before the first test body because Developer Mode/TCC automation access is disabled. Per D149, machine-wide security was not changed while Jason is offline; successful hosted macOS CI runtime execution remains a non-waivable merge gate.
- Completed a read-only P17 preflight: installed Codex 0.145.0, checked-in schema provenance, app-server availability, and official ChatGPT login classification are ready for the opt-in live smoke without reading `auth.json`; the centralized production gate remains off. A valid local Developer ID identity exists, but the repository has no protected release environment, variables, or secrets and Apple notarization/Sparkle/Homebrew publication credentials are unavailable, so D151 permits the audited code merge but prohibits a public release tag. Per D152, the exact inherited `gh-pages` SHA will be backed up and deleted only after B05 merges, when remote `main` no longer consumes it.
- Completed P14 at integrated `f574aaa` after two rounds of independent security follow-up: strict full/protocol-relative URL-path redaction, punctuation-bound local-path redaction, stable-identity descendant traversal, exact-PID late reaping, and same-refresh PID reuse now fail closed. The integrated focused suite passed 31/31, the author repeated 50 adversarial checks with zero residual fixtures, and the final exact-patch/blob audit is CLEAN.
- Integrated P17 production enablement and the 17-workstream parity audit as `3957daf`; the centralized gate is on while explicit disabled setup/registry/refresh paths remain covered. Its source-focused selection passed 70/70.
- Executed the opt-in installed Codex 0.145.0 account/rate-limit smoke through the official app-server against the existing ChatGPT-authenticated home: 1/1 passed without reading `auth.json`, and the post-test app-server/diagnostics fixture census was zero. P17 remains active until P15 menu/localization corrections, exact-head gates, hosted XCUITest, ship audit, and merge complete.
- Integrated final P15 parity at `194d9e5`: all nine catalogs now contain exactly 994 keys, 15/15 validator fixtures pass, and the isolated native UI suite contains exactly 11 test methods spanning setup, both login modes, mixed profiles, menus/status/popover lifecycle, settings/history, all nine locales, and fail-closed startup.
- Closed the final production-on test assumptions at `6b38053`, then reopened one saturated-host diagnostics regression when independent review found its conditional PID assertion could mask a fixture that never launched.
- Superseded D160 with D161 and committed `8b6a3c2`: the continuous writer must reach a bounded PID-file handshake or fail, after which the exact PID must exit. The focused test passed once plus five repetitions and the independent exact-head review is CLEAN.
- Verified exact source `8b6a3c2` with 610/610 app tests in both serial and parallel modes; 80 UsageKit tests in Debug and Release with one intentional opt-in live-smoke skip; a separate installed Codex 0.145.0 smoke at 1/1; zero residual app-server/fixture processes; Debug and universal Release builds; an `arm64` + `x86_64` executable; and a successful UI `build-for-testing`.
- Final exact-source static gates pass: 9×994 localization keys, 15/15 fixtures, distribution and all six workflow YAML files, 43/43 embedded workflow shell blocks, five release/localization scripts under `bash -n` and ShellCheck, project/scheme parsing, synthetic-fixture provenance, and forbidden credential/billing/shell/`gh-pages` runtime scans.
- Per D158, merge-safe synthetic Claude/mixed-provider UAT is green. Real official login, notification permission/sound, VoiceOver, migration, and localized visual UAT remains mandatory before the first public release in a backed-up disposable macOS user or VM; it does not waive the hosted 11/11 merge gate.
- Opened and shipped prerequisite PR #12 through the canonical Tessie gate, Build/Test, all three review-surface audit, and an exact-head squash merge as `16b2a87`. It moves 16 byte-identical synthetic validator fixtures and removes the inherited funding link from the B05 diff without changing runtime behavior.
- Hosted Distribution Validation first exposed an unavailable `rg` dependency and then a runner/Xcode mismatch. Corrections `519c8d2` and `050be58` make the validator portable and pin all release-validation workflows to Xcode 26.0.1; the hosted distribution job passes and the local workflow matrix now covers 46 embedded shell blocks.
- The first hosted app/UI run executed the intended gates and exposed one trailing-slash unit mismatch plus a fail-closed UI fixture-root rejection. Correction `5acc2ec` uses strict canonical path-component ancestry, passes all seven parser tests and UI `build-for-testing`, and received a CLEAN focused independent review.
- Merged the freshly fetched PR #12 `main` commit into B05 at `5448504`; the resulting PR diff is exactly 99 files, restoring canonical Tessie review eligibility before the final CI/review run.
- The `5acc2ec` hosted rerun passed Build/Test (UsageKit 80 with one opt-in skip, app 610/610, Debug and Release) and Distribution Validation, then proved that the XCUITest runner and launched application receive different process-local temporary roots. Per D164, `869ada4` introduces one UI-test-only canonical `/tmp/claude-usage-ui-<valid UUID>` contract with existing-directory, direct-child, home-nesting, path-component, and symlink-escape checks. Its focused parser/security suite passed 18/18, the dedicated UI-testing build passed, and the exact three-file review is CLEAN.
- The `869ada4` hosted run passed Build/Test and Distribution Validation but proved Xcode forcibly sandboxes the UI runner and denies its direct `/tmp` fixture creation. D164 and D165 are therefore superseded by D166. Correction `8cd3f2b` lets the runner use its permitted process temp while the app derives the exact known runner-container anchor from `getpwuid_r(getuid())` plus the hardcoded `.xctrunner` identity; no environment value can broaden it. The expanded focused contract suite passed 21/21, app and dedicated UI builds-for-testing passed, and an exact three-file security/correctness review is CLEAN.
