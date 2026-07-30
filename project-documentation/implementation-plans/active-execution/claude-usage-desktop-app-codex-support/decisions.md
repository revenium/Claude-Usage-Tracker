# Decisions Log: Claude Usage Desktop App Codex Support

All decisions below were settled during planning and approved before implementation. There are no open decisions at initialization.

---

### D001 — Ship one modular application
- Context: Full parity could use the existing app, a companion, or multiple targets.
- Options: One modular app / Separate companion / Multiple targets with shared core
- **Decision: One modular app with an enforced provider seam.**
- Rationale: A separate parity app retains most implementation cost and adds release, migration, support, and UX complexity.
- Status: RESOLVED — approved 2026-07-29

### D002 — Enforce the seam with a local static Swift package
- Context: Provider abstractions need a boundary that prevents UI and persistence coupling.
- Options: Local UsageKit package / App-folder protocols / Runtime plugins
- **Decision: Add a Foundation-only UsageKit package containing UsageCore and CodexUsageProvider.**
- Rationale: It provides a compile-time boundary without plugin-SDK complexity.
- Status: RESOLVED — approved 2026-07-29

### D003 — Normalize usage instead of extending ClaudeUsage
- Context: Codex exposes dynamic groups and windows that do not fit Claude’s fixed model.
- Options: Add Codex fields to ClaudeUsage / Dynamic UsageReport / Unrelated models indefinitely
- **Decision: Move view and storage consumers toward normalized UsageReport, with a Claude adapter.**
- Rationale: Dynamic provider-neutral groups avoid repeated provider conditionals.
- Status: RESOLVED — approved 2026-07-29

### D004 — Keep app-specific concerns outside UsageKit
- Context: Persistence and presentation dependencies could leak into provider code.
- Options: Package owns everything / App owns platform and persistence concerns
- **Decision: UsageKit remains Foundation-only; the app owns persistence, Keychain, UI, localization, and lifecycle.**
- Rationale: Provider code stays independently testable.
- Status: RESOLVED — approved 2026-07-29

### D005 — Use one provider per profile
- Context: A profile could combine providers or represent one provider identity.
- Options: Mixed-provider profile / One provider per profile
- **Decision: Each profile has one tagged provider; existing untagged profiles default to Claude.**
- Rationale: It preserves identity, refresh, credential, history, and notification isolation.
- Status: RESOLVED — approved 2026-07-29

### D006 — Isolate Codex accounts by CODEX_HOME
- Context: Codex multi-account support needs a safe identity boundary.
- Options: Swap tokens/auth files / Canonical CODEX_HOME per profile
- **Decision: Store only a canonical CODEX_HOME reference and reject duplicate or symlink-equivalent homes.**
- Rationale: This uses Codex’s official boundary without touching credentials.
- Status: RESOLVED — approved 2026-07-29

### D007 — Require the official installed Codex CLI/app-server
- Context: The app could bundle Codex, read files directly, or use the installed service.
- Options: Bundle CLI / Read files / Require installed CLI and app-server
- **Decision: Require a capability-equivalent installed Codex CLI/app-server.**
- Rationale: It uses supported account/usage APIs without bundled binaries or credential parsing.
- Status: RESOLVED — approved 2026-07-29

### D008 — Support linking and official in-app login
- Context: Codex profiles need setup and authentication.
- Options: Existing-home only / In-app login only / Both
- **Decision: Support linking an existing CODEX_HOME and official browser/device login through app-server.**
- Rationale: This covers existing and first-time users without inventing authentication.
- Status: RESOLVED — approved 2026-07-29

### D009 — Unlink without deleting credentials
- Context: Removing a Codex profile could affect the underlying Codex account.
- Options: Delete credentials / Unlink only
- **Decision: Disconnect and profile deletion only unlink app state.**
- Rationale: The app does not own Codex authentication data.
- Status: RESOLVED — approved 2026-07-29

### D010 — Never access auth.json or swap tokens
- Context: Direct credential access creates security and ownership risks.
- Options: Read/copy/edit auth.json / Official app-server only
- **Decision: Never read, copy, edit, delete, or log auth.json; never swap tokens or mutate the shell.**
- Rationale: Official APIs provide the needed account and usage data.
- Status: RESOLVED — approved 2026-07-29

### D011 — Scope support to ChatGPT/Codex subscriptions
- Context: OpenAI Platform billing is a different product and data model.
- Options: Subscription only / Subscription plus Platform billing
- **Decision: Support ChatGPT/Codex subscription usage only.**
- Rationale: This matches Claude subscription parity without conflating billing systems.
- Status: RESOLVED — approved 2026-07-29

### D012 — Display reset credits without redemption
- Context: App-server exposes credit/reset information.
- Options: Display only / Redemption controls
- **Decision: Display reset credits read-only.**
- Rationale: Redemption is outside usage-monitor scope and is consequential.
- Status: RESOLVED — approved 2026-07-29

### D013 — Use bounded request-scoped app-server sessions
- Context: App-server can launch per request or remain persistent.
- Options: Request-scoped / Persistent pool / XPC helper
- **Decision: Use request-scoped refresh sessions and login-scoped login sessions behind injected transport.**
- Rationale: Startup is small, lifecycle complexity is lower, and future pooling remains possible.
- Status: RESOLVED — approved 2026-07-29

### D014 — Preserve product compatibility and branding
- Context: Adding Codex could trigger a rename or new identity.
- Options: Rename/rebundle / Preserve Claude Usage identity
- **Decision: Keep the app name, bundle identity, preferences, migration behavior, macOS 14 minimum, and current nine locales.**
- Rationale: It avoids an unrelated migration and distribution expansion.
- Status: RESOLVED — approved 2026-07-29

### D015 — Rehome releases to Revenium
- Context: The fork still references the original maintainer’s release infrastructure.
- Options: Keep original destinations / Move to Revenium
- **Decision: Move release, update, support, source, feedback, appcast, and Homebrew destinations to Revenium.**
- Rationale: A Revenium build must not publish through or update into the original maintainer’s channels.
- Status: RESOLVED — approved 2026-07-29

### D016 — Selectively adapt upstream work
- Context: Original upstream has many post-fork commits but no Codex implementation.
- Options: Wholesale merge / Ignore / Selectively adapt
- **Decision: Selectively adapt verified Keychain, file persistence, bounded-process, and menu/window reliability ideas.**
- Rationale: Wholesale merge would overwrite Revenium profile switching and Fable work.
- Status: RESOLVED — approved 2026-07-29

### D017 — Exclude unrelated upstream features
- Context: Upstream includes Dynamic Island, sponsor/heartbeat, statusline expansion, locale additions, and Fable changes.
- Options: Include all / Keep Codex scope focused
- **Decision: Exclude those unrelated features and broad menu refactors.**
- Rationale: They do not reduce Codex parity risk and enlarge regression scope.
- Status: RESOLVED — approved 2026-07-29

### D018 — Use five sequential audited PR batches
- Context: One PR is too large, while 17 PRs add coordination overhead.
- Options: One PR / Seventeen PRs / Five cohesive batches
- **Decision: Deliver baseline, foundations, provider core, UI parity, and release readiness as five PRs to upstream/main.**
- Rationale: The batches keep review coherent while preserving dependency order.
- Status: RESOLVED — approved 2026-07-29

### D019 — Permit audited auto-merge
- Context: Each PR otherwise needs separate human merge approval.
- Options: Stop ready / Merge after verified gates
- **Decision: Run `$codex-ship-pr skip-review --auto-merge` for each PR and merge when all gates pass.**
- Rationale: Jason explicitly granted merge authority.
- Status: RESOLVED — approved 2026-07-29

### D020 — Keep Codex feature-gated until final parity
- Context: Intermediate batches may compile while surfaces remain incomplete.
- Options: Enable incrementally / Keep internal until final audit
- **Decision: Keep Codex disabled for normal users until P17 passes.**
- Rationale: This prevents partial exposure while allowing mergeable batches.
- Status: RESOLVED — approved 2026-07-29

### D021 — Avoid premature provider-framework complexity
- Context: Future providers are possible but not planned.
- Options: Full plugin SDK / Clean static seams
- **Decision: Keep clean provider contracts without runtime discovery or universal authentication.**
- Rationale: It preserves reasonable extensibility without speculative complexity.
- Status: RESOLVED — approved 2026-07-29

### D022 — Defer localization remediation to P15
- Context: Existing non-English catalogs have baseline debt, and Codex UI strings will continue changing through B04.
- Options: Repair all catalogs in B01 / Remediate once after provider UI stabilizes
- **Decision: Track existing and new localization remediation in P15, not B01.**
- Rationale: This avoids translating a moving string surface twice while preserving a final mandatory CI gate.
- Status: RESOLVED — directed 2026-07-29

### D023 — Treat Keychain read failures as unresolved
- Context: A storage error is not evidence that a profile secret is absent.
- Options: Convert errors to nil / Preserve unresolved state and retry
- **Decision: Never let a Keychain read error imply deletion; ordinary profile saves are credential-neutral for nil values.**
- Rationale: It prevents unrelated metadata or usage saves from deleting credentials during transient Keychain failures.
- Status: RESOLVED — proceeded 2026-07-30

### D024 — Preserve per-field migration fallbacks
- Context: One credential field can fail migration after other fields have passed verified Keychain readback.
- Options: Keep the whole plaintext profile / Keep only unresolved per-profile, per-field retry sources
- **Decision: Scrub successful fields and retain only explicit unresolved field fallbacks until their verified migration succeeds.**
- Rationale: This minimizes plaintext exposure without risking data loss or making the migration all-or-nothing.
- Status: RESOLVED — proceeded 2026-07-30

### D025 — Keep failed profile deletion retryable
- Context: Removing profile identity before secure and file cleanup is verified can create undiscoverable orphaned data.
- Options: Remove and log cleanup failures / Retain the profile and surface failure
- **Decision: Retain the profile record unless all app-owned secure and file artifacts are verified removed.**
- Rationale: The retained identity provides a safe recovery handle for retrying cleanup.
- Status: RESOLVED — proceeded 2026-07-30

### D026 — Use recoverable versioned usage files
- Context: Atomic replacement alone does not cover post-install corruption, interrupted migration, or schema skew.
- Options: One primary JSON file / Versioned envelopes with verified writes, `.bak` recovery, and quarantine
- **Decision: Use versioned per-profile envelopes with verified temporary/install reads, backups, and corrupt-file quarantine.**
- Rationale: Legacy sources can be scrubbed only after the installed representation is proven readable and equivalent.
- Status: RESOLVED — proceeded 2026-07-30

### D027 — Preserve a verified migration after an unguarded hosted test launch
- Context: One hosted P02 test reached AppDelegate startup before the XCTest guard was added; migration markers are set and the legacy session file is absent, but there is no reliable pre-test snapshot.
- Options: Infer and roll back user state / Preserve the verified destination and prevent any future hosted startup migration
- **Decision: Preserve the migrated state, add an early hosted-XCTest guard, and document the event without reading or logging secret material.**
- Rationale: The migration verifies profile-keyed targets before cleanup, whereas a rollback without a known prior state could destroy valid credentials.
- Status: RESOLVED — proceeded 2026-07-30

### D028 — Retain established precedence for duplicate legacy credentials
- Context: Existing profile Keychain, legacy global Keychain, and plaintext file/UserDefaults sources may disagree during upgrade.
- Options: Block until manually reconciled / Select the established runtime winner and clean superseded sources after verification
- **Decision: Use profile-keyed, then global Keychain, then plaintext file/UserDefaults precedence.**
- Rationale: This matches prior runtime behavior and allows superseded plaintext to be removed only after selected-target and source-change verification.
- Status: RESOLVED — proceeded 2026-07-30

### D029 — Keep Codex request params method-specific
- Context: The current app-server schema requires object params for `account/read`, while rate-limit and usage reads accept only null or omitted params.
- Options: Normalize every transport nil to `{}` / Let typed callers provide each method's schema shape
- **Decision: Keep transport lossless and make the typed Codex provider supply required object params only for methods that declare them.**
- Rationale: Generic empty-object normalization would make otherwise valid no-param methods schema-invalid.
- Status: RESOLVED — proceeded 2026-07-30

### D030 — Make complete credential updates recoverable transactions
- Context: A sequence of verified Keychain mutations can fail after one field changes, or metadata persistence can fail after all fields change.
- Options: Return failure with partial application / Snapshot and restore every prior field, marking failed rollback reads unresolved
- **Decision: Treat complete and single-field credential updates as recoverable transactions with verified rollback.**
- Rationale: A throwing update must not silently leave Keychain and profile metadata describing different credential sets.
- Status: RESOLVED — proceeded 2026-07-30

### D031 — Prefer a valid current-usage destination over a retry source
- Context: The retry envelope can survive a crash after current-v1 is installed, and that file can later contain a newer refresh.
- Options: Reapply the retry envelope / Use the valid installed file and scrub the retry source
- **Decision: A valid current-v1 file is authoritative; write retry data only when no valid destination exists.**
- Rationale: This makes migration idempotent without overwriting newer durable usage with stale legacy data.
- Status: RESOLVED — proceeded 2026-07-30

### D032 — Verify subprocess closure at the operating-system boundary
- Context: P06 returned successful cancellation tests while one fake app-server remained CPU-running and reparented to PID 1.
- Options: Rely on async task completion / Capture the launched PID and require it to disappear, then run a zero-orphan census
- **Decision: Process-lifecycle acceptance requires exact PID disappearance and repeated before/after fixture censuses.**
- Rationale: A bounded request is not actually bounded if its subprocess survives the owning task or session.
- Status: RESOLVED — proceeded 2026-07-30

### D033 — Persist a scrubbed deletion record before cleanup
- Context: A retryable deletion retains profile identity, but surviving migration envelopes can recreate credentials or usage that earlier cleanup steps already removed.
- Options: Preserve the original profile until every cleanup step succeeds / Persist a deletion-in-progress profile with all secret and usage retry data scrubbed before destructive cleanup
- **Decision: Persist the scrubbed deletion-in-progress record first, then perform verified Keychain and file cleanup.**
- Rationale: The profile remains discoverable and retryable without allowing a failed cleanup or relaunch to resurrect deleted data.
- Status: RESOLVED — proceeded 2026-07-30

### D034 — Roll back atomic files only after target installation
- Context: Backup preparation can fail while the current primary is still valid and untouched.
- Options: Run backup restoration for every write-stage failure / Separate pre-install failure from post-install rollback
- **Decision: Backup-preparation and target-rename failures leave the primary untouched; rollback begins only after a successful target install.**
- Rationale: A failed attempt to stage protection for a new value must never take the currently readable value offline.
- Status: RESOLVED — proceeded 2026-07-30

### D035 — Use one app-server session per complete provider refresh
- Context: Opening a process for each account, rate-limit, and optional usage RPC triples startup cost and overall-timeout budgets.
- Options: One process per RPC / One initialized request-scoped process for the refresh
- **Decision: Run the complete Codex refresh in one initialized session with one overall deadline, then close and prove the child reaped.**
- Rationale: This preserves the no-pool boundary while making refresh snapshots coherent and truly bounded.
- Status: RESOLVED — proceeded 2026-07-30

### D036 — Require every mandatory usage endpoint for healthy status
- Context: `account/read` can succeed while required `account/rateLimits/read` is missing or malformed, leaving every real usage refresh unusable.
- Options: Treat identity alone as healthy / Probe identity and required rate limits together
- **Decision: Codex health requires both account and rate-limit reads in one health-scoped session; optional usage history remains non-fatal.**
- Rationale: A provider that cannot produce its minimum usage report must not be labeled healthy.
- Status: RESOLVED — proceeded 2026-07-30

### D037 — Keep provider kind stable while modeling an unlinked Codex profile
- Context: Unlink and delete are separate operations, but a Codex UUID cannot retain a valid home reference after unlink or change provider kind.
- Options: Delete/convert the profile or store an invalid path / Make the verified linked-home reference optional
- **Decision: A profile UUID's provider kind is immutable; Codex configuration retains `linkedHome = nil` after unlink and accepts only a verified canonical home when linked.**
- Rationale: The profile and settings survive unlink without an invalid sentinel or any Codex-owned credential mutation.
- Status: RESOLVED — proceeded 2026-07-30

### D038 — Permit a zero-profile first-run bootstrap
- Context: Persisting an implicit Claude profile before onboarding conflicts with immutable provider kind when the user chooses Codex first.
- Options: Privileged provider conversion / Create no profile until provider selection
- **Decision: First-run setup may have zero profiles and creates the selected provider with a new UUID only after setup commits.**
- Rationale: This avoids orphan placeholders, premature Claude side effects, and a provider-conversion loophole.
- Status: RESOLVED — proceeded 2026-07-30

### D039 — Publish one profile-keyed presentation snapshot
- Context: Independent global Claude usage/loading/error fields can combine state from different profiles in a mixed-provider UI.
- Options: Reconstruct view state from legacy globals / Publish atomic snapshots keyed by profile UUID and provider revision
- **Decision: P09 owns profile-keyed snapshots containing identity, revision, capabilities, normalized report, refresh activity, last success, and typed failure.**
- Rationale: Popover, settings, menus, and status items need one captured source of truth that stale work cannot partially mutate.
- Status: RESOLVED — proceeded 2026-07-30

### D040 — Fetch provider and optional API components concurrently
- Context: Claude core usage and API billing have independent latency and failure behavior, but unordered independent presentation can lose a component.
- Options: Wait for both fetches before committing / Fetch concurrently and serialize completed component transactions
- **Decision: Fetch both concurrently, serialize each completed component's durable commit and guarded presentation, and finish the batch only after both child operations quiesce.**
- Rationale: Fast data becomes durable immediately without allowing presentation order to corrupt the merged current-usage envelope.
- Status: RESOLVED — proceeded 2026-07-30

### D041 — Issue latest-wins order before asynchronous engine entry
- Context: Consecutive MainActor refresh calls create tasks whose actor arrival order is not guaranteed.
- Options: Use engine arrival order / Issue and register a monotonic order synchronously at Runtime invocation
- **Decision: Runtime issues the authoritative order before task creation; the input ledger, engine slots, commits, failures, status, activity, and batches all enforce it.**
- Rationale: A delayed older multi-profile enqueue can never replace work from a newer user-visible invocation.
- Status: RESOLVED — proceeded 2026-07-30

### D042 — Bind loading state to ordered request ownership
- Context: Actor-to-MainActor suspension can let an older loading publication arrive after its request completed or after a newer request queued.
- Options: Infer precedence from loading enum cases / Track invocation order, request UUID, and terminal request ownership
- **Decision: Loading state has one ordered request owner; completion clears only that owner, records it terminal, and lower, different, or already-completed publications are rejected.**
- Rationale: This prevents idle flicker, stale spinner resurrection, and loss of queued-to-refreshing transitions.
- Status: RESOLVED — proceeded 2026-07-30

### D043 — Make deletion and shutdown terminal presentation boundaries
- Context: Suspended hydration, activity, status, or result calls can resume after a profile is deleting or the app has purged presentation state.
- Options: Rely on cancellation/context mismatch / Install explicit profile and store terminal fences
- **Decision: Deletion preserves an idle tombstone and rejects all older profile mutations until verified removal; shutdown synchronously purges and permanently rejects every later presentation mutation.**
- Rationale: Neither deleted profiles nor a terminated runtime can be resurrected by delayed work.
- Status: RESOLVED — proceeded 2026-07-30

### D044 — Supersede a durable result whose guarded presentation is stale
- Context: A component can commit and emit its accepted event before an invalidation makes its presentation ineligible.
- Options: Mark every durable commit accepted / Preserve the durable event but supersede the terminal request outcome when its presentation is rejected
- **Decision: A guarded presentation rejection makes the request and batch superseded while retaining the durable accepted event and history; a result already committed and presented before later sibling cancellation remains accepted.**
- Rationale: Latest-batch UI side effects must not run for work the current presentation context rejected.
- Status: RESOLVED — proceeded 2026-07-30

### D045 — Coalesce Claude status by identity and authoritative order
- Context: A delayed status begin can follow its own completion, while A→B→A overlap can leave stale B work queued.
- Options: Fetch every status request / Reuse the running fetch while transferring ordered ownership
- **Decision: Install status ownership before suspension, reject a begin after the same order completed, re-begin on same-context order upgrade, and clear stale different-context pending work on A→B→A.**
- Rationale: One reusable fetch produces the newest eligible status without stuck loading, stale publication, or redundant follow-up.
- Status: RESOLVED — proceeded 2026-07-30

### D046 — Serialize a small shared B04 bootstrap
- Context: P10 needs the refresh provider factory, and P11/P12 otherwise contend for MenuBarManager and legacy Claude-only presentation fields.
- Options: Let each UI phase create private seams / Establish shared factory and normalized projection seams first
- **Decision: Before parallel B04 implementation, expose one reusable fresh Codex provider/executable resolver and one profile-keyed normalized presentation projection from MenuBarManager.**
- Rationale: P10 can then own setup/settings, P11 popover content, P12 menu/status/icon surfaces, and the PM can serialize localization catalogs without overlapping edits.
- Status: RESOLVED — proceeded 2026-07-30

---

## Open Decisions

None.
