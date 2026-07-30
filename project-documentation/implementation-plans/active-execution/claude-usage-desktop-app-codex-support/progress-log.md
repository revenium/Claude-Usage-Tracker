# Progress Log: Claude Usage Desktop App Codex Support

## Active Work

- Project status: Active
- Linear project: `Claude Usage Desktop App Codex Support` (`8fd871e1416e`)
- Umbrella: `PRODUCT-2276`
- Tracking wave: W00 — complete
- Current delivery batch: B03 — Provider core
- Current phases: P05/P06/P07/P08/P09 integrated and locally verified
- Active implementation workers: None; B03 is frozen at P09 commit `5f41158` for exact-hash audit and shipping
- Next action: Complete the independent exact-hash audit, then run the integrated B03 ship pipeline

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
| W03A | UsageKit boundary | P05 | Implemented pending B03 ship |
| W03B | Transport and profile model | P06, P07 | Implemented pending B03 ship |
| W03C | Codex provider | P08 | Implemented pending B03 ship |
| W03D | Refresh integration | P09 | Implemented pending B03 ship |
| W04 | Provider-aware UI parity | P10, P11, P12 | Pending |
| W05A | Cross-cutting parity and distribution | P13, P14, P16 | Pending |
| W05B | Localization/accessibility/UI automation | P15 | Pending |
| W05C | Final parity and ship audit | P17 | Pending |

## Delivery PRs

| Batch | Branch | PR | CI | Review Gate | Merge | Status |
|---|---|---|---|---|---|---|
| B01 Baseline | `feature/codex-support-baseline` | [#7](https://github.com/revenium/Claude-Usage-Tracker/pull/7) | Success | Tessie clean + Greptile 5/5 | `29c7fe1` | Merged |
| B02 Foundations | `feature/codex-support-foundations` | [#8](https://github.com/revenium/Claude-Usage-Tracker/pull/8) | Equivalent exact-head gate passed | All findings fixed; reviewer limits documented | `ab70776` | Merged |
| B03 Provider core | `feature/codex-support-provider-core` | — | UsageKit 49/49; app 349/349; Debug + universal Release | Exact-hash audit pending | — | In progress |
| B04 UI parity | `feature/codex-support-ui-parity` | — | — | — | — | Pending |
| B05 Release readiness | `feature/codex-support-release-readiness` | — | — | — | — | Pending |

## Completed Phases

| Phase | Linear | Worker | Commit | Batch PR | Completed | Summary |
|---|---|---|---|---|---|---|
| P01 | PRODUCT-2282 | baseline_audit | `1009d4f` | #7 | 2026-07-30 | Parser correctness, null compatibility, hermetic UserDefaults tests, canonical validation docs |
| P02 | PRODUCT-2280 | profile_security_integration | `747230b` final head | #8 | 2026-07-30 | Verified profile-keyed Keychain storage, backward migration, explicit credential APIs, startup guard, fail-closed deletion marker |
| P03 | PRODUCT-2279 | profile_security_integration | `747230b` final head | #8 | 2026-07-30 | Atomic current/history files, verified migration, transactional credentials, recoverable cleanup, fault-injected rollback safety |
| P04 | PRODUCT-2277 | menu_reliability_audit | `747230b` final head | #8 | 2026-07-30 | Context menu, stable status items, popover/window/full-screen fixes, CGImage fingerprinting, Cmd+W, captured-profile auto-switch safety |
| P05 | PRODUCT-2281 | usagekit_contracts | `00793e5` | Pending B03 | Pending merge | Foundation-only UsageCore contracts and characterized Claude adapter |
| P06 | PRODUCT-2278 | codex_transport | `0647f4b` | Pending B03 | Pending merge | Bounded request/login-scoped app-server JSONL transport with callback-backed termination, reaping barrier, exact PID exit proof, and zero-orphan census |
| P07 | PRODUCT-2286 | provider_profile_model | `6d07d6a` | Pending B03 | Pending merge | Strict provider-tagged profiles, canonical unique Codex homes, zero-profile provider choice, provider/revision CAS, fail-closed tombstones, verified migration, and transactional link/relink/unlink/delete recovery |
| P08 | PRODUCT-2285 | codex_provider | `ea4c871` integrated head | Pending B03 | Pending merge | ChatGPT account/login/health/dynamic usage provider with one bounded refresh session, required-endpoint health, credit availability, UTC summaries, and process cleanup proof |
| P09 | PRODUCT-2288 | refresh_engine | `5f41158` | Pending B03 | Pending merge | Profile-keyed provider registry/runtime, monotonic latest-wins actor, atomic durable component events, normalized presentation snapshots, terminal deletion/shutdown fences, bounded failures, and legacy Claude side-effect parity |

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
| 2026-07-30 | P06 Codex transport package | warnings-as-errors `swift test` and Release package test | PASS | Independently rerun: 31 passed in each configuration; Foundation-only and leak/diff scans clean |
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

## Blockers

- None at initialization.
- Release signing, notarization, Pages/appcast, and Homebrew publication may require Revenium secrets or repository permissions; verify during P16.

## Decisions

- All architecture decisions are settled in `decisions.md`.
- No open decisions at initialization.

## Daily Summaries

### 2026-07-29 / 2026-07-30 UTC

- Completed upstream, repository, architecture, Codex app-server, baseline-test, localization, CI, and release-infrastructure audits.
- Chose one modular app with a Foundation-only UsageKit seam.
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
