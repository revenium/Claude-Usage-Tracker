import AppKit
import UsageCore
import XCTest
@testable import Claude_Usage

@MainActor
final class MenuReliabilityTests: HostedAppTestCase {
    private final class MenuTarget: NSObject {
        @objc func refresh() {}
        @objc func settings() {}
        @objc func quit() {}
    }

    private final class ThreadSafeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ value: String) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    func testRefreshTimingPolicyPreservesTimerReachabilityAndWakeRules() {
        let timer = RefreshTimingPolicy(interval: 60)
        XCTAssertEqual(timer.interval, 60)
        XCTAssertEqual(timer.tolerance, 6, accuracy: 0.000_001)
        XCTAssertEqual(RefreshTimingPolicy.wakeDelay, 3)

        XCTAssertFalse(
            RefreshTimingPolicy.shouldRefreshForNetworkAvailability(
                hasRefreshableProfile: false,
                elapsedSinceLastTrigger: 60
            )
        )
        XCTAssertFalse(
            RefreshTimingPolicy.shouldRefreshForNetworkAvailability(
                hasRefreshableProfile: true,
                elapsedSinceLastTrigger: 2
            )
        )
        XCTAssertTrue(
            RefreshTimingPolicy.shouldRefreshForNetworkAvailability(
                hasRefreshableProfile: true,
                elapsedSinceLastTrigger: 2.001
            )
        )

        XCTAssertFalse(
            RefreshTimingPolicy.shouldRefreshAfterWake(
                elapsedSinceLastAutomaticRefresh: 10
            )
        )
        XCTAssertTrue(
            RefreshTimingPolicy.shouldRefreshAfterWake(
                elapsedSinceLastAutomaticRefresh: 10.001
            )
        )

        let firedAt = Date(timeIntervalSinceReferenceDate: 12_345)
        let fire = RefreshTimingPolicy.timerFired(at: firedAt)
        XCTAssertEqual(fire.occurredAt, firedAt)
        XCTAssertEqual(fire.trigger, .timer)
    }

    /// Pure decision logic backing the display-sleep/Low-Power-Mode
    /// adaptations. Exercised directly here so the behavior is asserted
    /// without depending on a real display sleep or a live power-state
    /// toggle — `MenuBarManager`'s observers just feed this function.
    func testAutoRefreshTimingWithholdsTimerWhileDisplayIsAsleep() {
        XCTAssertNil(
            RefreshTimingPolicy.autoRefreshTiming(
                baseInterval: 30,
                isDisplayAsleep: true,
                isLowPowerModeEnabled: false
            )
        )
        // Low Power Mode being on at the same time changes nothing — a
        // sleeping display always wins, there is nothing to redraw either way.
        XCTAssertNil(
            RefreshTimingPolicy.autoRefreshTiming(
                baseInterval: 30,
                isDisplayAsleep: true,
                isLowPowerModeEnabled: true
            )
        )
    }

    func testAutoRefreshTimingUsesBaseIntervalWhenAwakeAndNotThrottled() {
        guard let timing = RefreshTimingPolicy.autoRefreshTiming(
            baseInterval: 30,
            isDisplayAsleep: false,
            isLowPowerModeEnabled: false
        ) else {
            return XCTFail("Expected a timing policy while awake")
        }
        XCTAssertEqual(timing.interval, 30)
        XCTAssertEqual(timing.tolerance, 3, accuracy: 0.000_001)
    }

    func testAutoRefreshTimingDoublesIntervalInLowPowerMode() {
        guard let timing = RefreshTimingPolicy.autoRefreshTiming(
            baseInterval: 30,
            isDisplayAsleep: false,
            isLowPowerModeEnabled: true
        ) else {
            return XCTFail("Expected a timing policy while awake")
        }
        XCTAssertEqual(
            timing.interval,
            30 * RefreshTimingPolicy.lowPowerModeIntervalMultiplier
        )
        XCTAssertEqual(timing.interval, 60)
        // Tolerance is still the same fraction of the (now longer) interval.
        XCTAssertEqual(timing.tolerance, 6, accuracy: 0.000_001)

        // Restoring Low Power Mode to off with the same base interval
        // restores the original cadence immediately — no lingering state.
        let restored = RefreshTimingPolicy.autoRefreshTiming(
            baseInterval: 30,
            isDisplayAsleep: false,
            isLowPowerModeEnabled: false
        )
        XCTAssertEqual(restored?.interval, 30)
    }

    func testAutoRefreshTimingScalesWithDifferentProfileIntervals() {
        // A profile configured with a longer per-profile interval still
        // gets doubled under Low Power Mode, same as the default 30s case.
        let timing = RefreshTimingPolicy.autoRefreshTiming(
            baseInterval: 120,
            isDisplayAsleep: false,
            isLowPowerModeEnabled: true
        )
        XCTAssertEqual(timing?.interval, 240)
    }

    /// Reproduces the double-fetch regression a system wake used to cause:
    /// `didWakeNotification` schedules a fetch `wakeDelay` (3s) out, but
    /// `screensDidWakeNotification` — delivered for the same system wake —
    /// fetches immediately and stamps `lastAutoRefreshTime` in the
    /// meantime. By the time the deferred fetch actually runs, re-checking
    /// against the now-updated `lastAutoRefreshTime` must suppress it.
    func testDeferredWakeRefreshSuppressedWhenAlreadyRefreshedInDebounceWindow() {
        let wakeDetectedAt = Date(timeIntervalSinceReferenceDate: 100_000)

        // At the moment the wake was first observed, nothing had refreshed
        // in a long time, so the deferred fetch would have been scheduled.
        XCTAssertTrue(
            RefreshTimingPolicy.shouldRefreshAfterWake(
                elapsedSinceLastAutomaticRefresh: 3_600
            )
        )

        // Before the deferred block runs, a concurrent path (the
        // display-wake handler, which fetches with no delay) already
        // refreshed and stamped `lastAutoRefreshTime`.
        let concurrentRefreshAt = wakeDetectedAt.addingTimeInterval(0.5)

        // The deferred block fires `wakeDelay` after the original wake —
        // re-checking against the updated `lastAutoRefreshTime` must now
        // suppress it, since barely any time has passed since that refresh.
        let deferredFiresAt = wakeDetectedAt.addingTimeInterval(
            RefreshTimingPolicy.wakeDelay
        )
        XCTAssertFalse(
            RefreshTimingPolicy.shouldFireDeferredWakeRefresh(
                lastAutoRefreshTime: concurrentRefreshAt,
                at: deferredFiresAt,
                isDisplayAsleep: false
            )
        )
    }

    func testDeferredWakeRefreshProceedsWhenNothingElseRefreshedMeanwhile() {
        let wakeDetectedAt = Date(timeIntervalSinceReferenceDate: 100_000)
        // No concurrent refresh happened — `lastAutoRefreshTime` is still
        // the stale value from long before the wake.
        let staleLastRefresh = wakeDetectedAt.addingTimeInterval(-3_600)
        let deferredFiresAt = wakeDetectedAt.addingTimeInterval(
            RefreshTimingPolicy.wakeDelay
        )
        XCTAssertTrue(
            RefreshTimingPolicy.shouldFireDeferredWakeRefresh(
                lastAutoRefreshTime: staleLastRefresh,
                at: deferredFiresAt,
                isDisplayAsleep: false
            )
        )
    }

    /// The deferred wake fetch is the one path that could otherwise refresh
    /// while the display is asleep: the display can go back to sleep during
    /// the three-second `wakeDelay` (a brief wake, or the lid closing
    /// again), and the periodic timer's protection via `autoRefreshTiming`
    /// does not apply to a block that was already scheduled. Everything
    /// else about this case is identical to the "proceeds" test above, so
    /// the display state is the only thing deciding the outcome.
    func testDeferredWakeRefreshSuppressedWhenDisplayWentBackToSleep() {
        let wakeDetectedAt = Date(timeIntervalSinceReferenceDate: 100_000)
        let staleLastRefresh = wakeDetectedAt.addingTimeInterval(-3_600)
        let deferredFiresAt = wakeDetectedAt.addingTimeInterval(
            RefreshTimingPolicy.wakeDelay
        )

        XCTAssertFalse(
            RefreshTimingPolicy.shouldFireDeferredWakeRefresh(
                lastAutoRefreshTime: staleLastRefresh,
                at: deferredFiresAt,
                isDisplayAsleep: true
            ),
            "A display that slept again during wakeDelay must suppress the"
                + " deferred fetch, even though the debounce would allow it"
        )
    }

    /// The guarantee that actually matters for the missed-`screensDidWake`
    /// recovery path: after a system wake, auto-refresh is schedulable — not
    /// just that the recovered flag happens to equal `false`. Checks both
    /// halves together (the flag `isDisplayAsleepAfterSystemWake()` reports,
    /// and that feeding it into `autoRefreshTiming` yields a real timer),
    /// under both Low Power Mode states, so this fails if either half of the
    /// recovery breaks even though the flag alone would still read `false`.
    func testSystemWakeAlwaysLeadsToARunningAutoRefreshTimer() {
        let recoveredState = RefreshTimingPolicy.isDisplayAsleepAfterSystemWake()
        XCTAssertFalse(recoveredState)

        for isLowPowerModeEnabled in [true, false] {
            XCTAssertNotNil(
                RefreshTimingPolicy.autoRefreshTiming(
                    baseInterval: 30,
                    isDisplayAsleep: recoveredState,
                    isLowPowerModeEnabled: isLowPowerModeEnabled
                ),
                "Expected a scheduled timer after system-wake recovery (Low Power Mode: \(isLowPowerModeEnabled))"
            )
        }
    }

    func testAutomaticRefreshTriggersRemainTypedAndNonInteractive() {
        let triggers: [(UsageRefreshTrigger, String)] = [
            (.startup, "startup"),
            (.timer, "timer"),
            (.networkAvailable, "networkAvailable"),
            (.wake, "wake")
        ]

        for (trigger, rawValue) in triggers {
            XCTAssertEqual(trigger.rawValue, rawValue)
            XCTAssertFalse(trigger.isUserInitiated)
        }
    }

    func testContextMenuContainsExpectedLocalizedActionsAndShortcuts() {
        let target = MenuTarget()
        let menu = MenuBarManager.makeContextMenu(
            target: target,
            refreshAction: #selector(MenuTarget.refresh),
            settingsAction: #selector(MenuTarget.settings),
            quitAction: #selector(MenuTarget.quit)
        )

        XCTAssertEqual(menu.items.count, 4)
        let refresh = menu.items[0]
        XCTAssertEqual(refresh.title, "common.refresh".localized)
        XCTAssertEqual(refresh.action, #selector(MenuTarget.refresh))
        XCTAssertTrue(refresh.target === target)
        XCTAssertEqual(refresh.keyEquivalent, "")
        XCTAssertTrue(menu.items[1].isSeparatorItem)

        let settings = menu.items[2]
        XCTAssertEqual(settings.title, "common.settings".localized)
        XCTAssertEqual(settings.action, #selector(MenuTarget.settings))
        XCTAssertTrue(settings.target === target)
        XCTAssertEqual(settings.keyEquivalent, ",")
        XCTAssertEqual(settings.keyEquivalentModifierMask, .command)

        let quit = menu.items[3]
        XCTAssertEqual(quit.title, "common.quit".localized)
        XCTAssertEqual(quit.action, #selector(MenuTarget.quit))
        XCTAssertTrue(quit.target === target)
        XCTAssertEqual(quit.keyEquivalent, "q")
        XCTAssertEqual(quit.keyEquivalentModifierMask, .command)
    }

    func testContextMenuQuitDoesNotDependOnCapturedProfileIdentity() {
        var didTerminate = false

        MenuBarManager.performContextMenuQuit {
            didTerminate = true
        }

        XCTAssertTrue(didTerminate)
    }

    func testStatusButtonWiringAndContextEventUseProductionContract()
        throws
    {
        let target = MenuTarget()
        let statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let button = try XCTUnwrap(statusItem.button)
        StatusBarUIManager.configureActionButton(
            button,
            target: target,
            action: #selector(MenuTarget.refresh)
        )

        XCTAssertTrue(button.target === target)
        XCTAssertEqual(button.action, #selector(MenuTarget.refresh))
        let configuredEvents = NSEvent.EventTypeMask(
            rawValue: UInt64(button.sendAction(on: []))
        )
        XCTAssertTrue(configuredEvents.contains(.leftMouseUp))
        XCTAssertTrue(configuredEvents.contains(.rightMouseUp))
        XCTAssertTrue(
            MenuBarManager.isContextMenuEvent(.rightMouseUp)
        )
        XCTAssertFalse(
            MenuBarManager.isContextMenuEvent(.leftMouseUp)
        )
        XCTAssertFalse(MenuBarManager.isContextMenuEvent(nil))
    }

    func testDetachedPopoverLifecycleOwnsWindowContractAndCleanup()
    {
        let controller = NSViewController()
        let window = ProviderPopoverDetachmentLifecycle.makeWindow(
            contentViewController: controller,
            delegate: nil
        )
        defer { window.close() }

        XCTAssertTrue(
            ProviderPopoverDetachmentLifecycle.shouldDetach()
        )
        XCTAssertTrue(window.contentViewController === controller)
        XCTAssertTrue(
            window.collectionBehavior.contains(.fullScreenAuxiliary)
        )
        XCTAssertFalse(window.isRestorable)
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertTrue(
            ProviderPopoverDetachmentLifecycle
                .closedRetainedWindow(
                    window,
                    retainedWindow: window
                )
        )
        XCTAssertFalse(
            ProviderPopoverDetachmentLifecycle
                .closedRetainedWindow(
                    NSWindow(),
                    retainedWindow: window
                )
        )
    }

    func testDetachedPopoverClosesOnActivationRevisionOrDeletion()
    {
        let profile = Profile(
            name: "Codex A",
            providerConfiguration: .codex(.init())
        )
        let target = ProviderStatusItemIdentity(
            profileID: profile.id,
            providerID: profile.providerID,
            providerRevision: profile.providerRevision,
            metricID: .providerPlaceholder(.codex)
        )
        XCTAssertFalse(
            ProviderPopoverDetachmentLifecycle
                .shouldCloseDetachedWindow(
                    target: target,
                    profiles: [profile],
                    activatedProfileID: profile.id
                )
        )
        XCTAssertTrue(
            ProviderPopoverDetachmentLifecycle
                .shouldCloseDetachedWindow(
                    target: target,
                    profiles: [profile],
                    activatedProfileID: UUID()
                )
        )
        var relinked = profile
        relinked.providerRevision += 1
        XCTAssertTrue(
            ProviderPopoverDetachmentLifecycle
                .shouldCloseDetachedWindow(
                    target: target,
                    profiles: [relinked],
                    changedProfileID: profile.id
                )
        )
        var deleting = profile
        deleting.deletionInProgress = true
        XCTAssertTrue(
            ProviderPopoverDetachmentLifecycle
                .shouldCloseDetachedWindow(
                    target: target,
                    profiles: [deleting],
                    changedProfileID: profile.id
                )
        )
        XCTAssertFalse(
            ProviderPopoverDetachmentLifecycle
                .shouldCloseDetachedWindow(
                    target: target,
                    profiles: [profile],
                    changedProfileID: UUID()
                )
        )
        XCTAssertTrue(
            ProviderPopoverDetachmentLifecycle
                .shouldCloseDetachedWindow(
                    target: target,
                    profiles: [profile],
                    displayModeChanged: true
                )
        )
        XCTAssertTrue(
            ProviderPopoverDetachmentLifecycle
                .shouldCloseDetachedWindow(
                    target: target,
                    profiles: [profile],
                    selectedProfileIDs: []
                )
        )
        XCTAssertFalse(
            ProviderPopoverDetachmentLifecycle
                .shouldCloseDetachedWindow(
                    target: target,
                    profiles: [profile],
                    selectedProfileIDs: [profile.id]
                )
        )
    }

    func testPopoverCloseDebounceOnlySuppressesTheSameButtonBriefly() {
        let firstButton = NSObject()
        let secondButton = NSObject()
        let closeDate = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertTrue(
            MenuBarManager.shouldSuppressPopoverOpen(
                button: firstButton,
                lastButton: firstButton,
                lastCloseDate: closeDate,
                now: closeDate.addingTimeInterval(0.1)
            )
        )
        XCTAssertFalse(
            MenuBarManager.shouldSuppressPopoverOpen(
                button: secondButton,
                lastButton: firstButton,
                lastCloseDate: closeDate,
                now: closeDate.addingTimeInterval(0.1)
            )
        )
        XCTAssertFalse(
            MenuBarManager.shouldSuppressPopoverOpen(
                button: firstButton,
                lastButton: firstButton,
                lastCloseDate: closeDate,
                now: closeDate.addingTimeInterval(0.25)
            )
        )
    }

    func testCredentialChangeRoutingRefreshesOnlyAffectedVisibleProfiles() {
        let profileA = UUID()
        let profileB = UUID()

        let inactiveSingle = MenuBarManager.credentialChangeRouting(
            changedProfileID: profileA,
            activeProfileID: profileB,
            selectedProfileIDs: [],
            isMultiProfileMode: false
        )
        XCTAssertEqual(inactiveSingle.invalidation, .profile(profileA))
        XCTAssertFalse(inactiveSingle.shouldRefreshVisibleProfiles)

        let selectedMulti = MenuBarManager.credentialChangeRouting(
            changedProfileID: profileA,
            activeProfileID: profileB,
            selectedProfileIDs: [profileA],
            isMultiProfileMode: true
        )
        XCTAssertEqual(selectedMulti.invalidation, .profile(profileA))
        XCTAssertTrue(selectedMulti.shouldRefreshVisibleProfiles)

        let legacy = MenuBarManager.credentialChangeRouting(
            changedProfileID: nil,
            activeProfileID: profileB,
            selectedProfileIDs: [],
            isMultiProfileMode: false
        )
        XCTAssertEqual(legacy.invalidation, .allCapturedProfiles)
        XCTAssertTrue(legacy.shouldRefreshVisibleProfiles)
    }

    func testDeferredCredentialRefreshRechecksCapturedVisibilityScope() {
        let profileA = UUID()
        let profileB = UUID()
        let routingAtNotification =
            MenuBarManager.credentialChangeRouting(
                changedProfileID: profileA,
                activeProfileID: profileA,
                selectedProfileIDs: [],
                isMultiProfileMode: false
            )
        XCTAssertTrue(routingAtNotification.shouldRefreshVisibleProfiles)

        XCTAssertFalse(
            MenuBarManager.shouldExecuteCredentialRefresh(
                routingAtNotification,
                activeProfileID: profileB,
                selectedProfileIDs: [],
                isMultiProfileMode: false
            )
        )

        let legacy = MenuBarManager.credentialChangeRouting(
            changedProfileID: nil,
            activeProfileID: profileA,
            selectedProfileIDs: [],
            isMultiProfileMode: false
        )
        XCTAssertTrue(
            MenuBarManager.shouldExecuteCredentialRefresh(
                legacy,
                activeProfileID: profileB,
                selectedProfileIDs: [],
                isMultiProfileMode: false
            )
        )
    }

    func testSingleProfilePopoverRefreshProjectsToPrimaryUsage() {
        let profileID = UUID()
        XCTAssertEqual(
            MenuBarManager.usageProjectionTarget(
                displayMode: .single,
                clickedProfileID: profileID,
                snapshotProfileID: profileID
            ),
            .primary
        )
    }

    func testMultiProfileClickedRefreshProjectsToClickedUsage() {
        let activeID = UUID()
        let clickedID = UUID()
        XCTAssertEqual(
            MenuBarManager.usageProjectionTarget(
                displayMode: .multi,
                clickedProfileID: clickedID,
                snapshotProfileID: clickedID
            ),
            .clickedProfile
        )
        XCTAssertEqual(
            MenuBarManager.usageProjectionTarget(
                displayMode: .multi,
                clickedProfileID: clickedID,
                snapshotProfileID: activeID
            ),
            .primary
        )
    }

    func testProfileUsagePresentationsRetainClaudeAndCodexSnapshots()
        throws
    {
        let claudeID = UUID()
        let codexID = UUID()
        var claudeUsage = ClaudeUsage.empty
        claudeUsage.sessionTokensUsed = 17
        let codexReport = try makeUsageReport(
            providerID: .codex,
            fetchedAt: Date(timeIntervalSinceReferenceDate: 2_500)
        )
        let presentations = [
            claudeID: makePresentationSnapshot(
                profileID: claudeID,
                providerID: .claude,
                claudeUsage: claudeUsage
            ),
            codexID: makePresentationSnapshot(
                profileID: codexID,
                providerID: .codex,
                report: codexReport
            )
        ]

        let claude = MenuBarManager.selectDisplayedUsagePresentation(
            displayMode: .single,
            clickedProfileID: nil,
            activeProfileID: claudeID,
            presentations: presentations
        )
        let codex = MenuBarManager.selectDisplayedUsagePresentation(
            displayMode: .multi,
            clickedProfileID: codexID,
            activeProfileID: claudeID,
            presentations: presentations
        )

        XCTAssertEqual(presentations.count, 2)
        XCTAssertEqual(claude?.providerID, .claude)
        XCTAssertEqual(claude?.claudeUsage?.sessionTokensUsed, 17)
        XCTAssertEqual(codex?.providerID, .codex)
        XCTAssertEqual(codex?.report, codexReport)
    }

    func testMenuBarManagerPublishesAtomicProfilePresentationDictionary()
        throws
    {
        let claudeProfile = Profile(name: "Claude")
        let codexProfile = Profile(
            name: "Codex",
            providerConfiguration: .codex(.init())
        )
        let profileManager = retain(makeIsolatedProfileManager())
        profileManager.profiles = [claudeProfile, codexProfile]
        profileManager.activeProfile = claudeProfile
        profileManager.displayMode = .multi
        let apiService = retain(ClaudeAPIService(
            profileManager: profileManager,
            systemCredentialsReader: { nil }
        ))
        let statusService = retain(ClaudeStatusService())
        let runtime = retain(UsageRefreshRuntime.live(
            profileManager: profileManager,
            apiService: apiService,
            statusService: statusService,
            featureAvailability: .testing()
        ))
        let providerUIDependencies = retain(
            ProviderUIDependencies(
                profileManager: profileManager,
                codexProviderFactory: CodexProviderFactory(
                    availability: .testing()
                )
            )
        )
        let manager = retain(MenuBarManager(
            apiService: apiService,
            statusService: statusService,
            profileManager: profileManager,
            refreshRuntime: runtime,
            providerUIDependencies: providerUIDependencies
        ))
        let context = UsagePresentationContext(
            epoch: 6,
            focusedProfileID: claudeProfile.id,
            visibleProfileIDs: [
                claudeProfile.id,
                codexProfile.id
            ],
            mode: .multi
        )
        let claudeSnapshot = makePresentationSnapshot(
            profileID: claudeProfile.id,
            profileName: claudeProfile.name,
            providerID: .claude,
            presentationEpoch: context.epoch
        )
        let codexSnapshot = makePresentationSnapshot(
            profileID: codexProfile.id,
            profileName: codexProfile.name,
            providerID: .codex,
            presentationEpoch: context.epoch,
            report: try makeUsageReport(
                providerID: .codex,
                fetchedAt: Date(
                    timeIntervalSinceReferenceDate: 2_750
                )
            )
        )

        runtime.presentationStore.activate(context)
        XCTAssertTrue(
            runtime.presentationStore.publish(
                claudeSnapshot,
                expected: context
            )
        )
        XCTAssertTrue(
            runtime.presentationStore.publish(
                codexSnapshot,
                expected: context
            )
        )

        XCTAssertEqual(manager.profileUsagePresentations.count, 2)
        XCTAssertEqual(
            manager.usagePresentation(
                for: claudeProfile.id
            )?.providerID,
            .claude
        )
        XCTAssertEqual(
            manager.usagePresentation(
                for: codexProfile.id
            )?.report,
            codexSnapshot.report
        )
        XCTAssertEqual(
            manager.displayedUsagePresentation?.profileID,
            claudeProfile.id
        )

        profileManager.activeProfile = codexProfile
        XCTAssertEqual(
            manager.displayedUsagePresentation?.profileID,
            codexProfile.id
        )

        runtime.presentationStore.purge(
            profileID: codexProfile.id
        )
        XCTAssertNil(
            manager.usagePresentation(for: codexProfile.id)
        )
        XCTAssertNil(manager.displayedUsagePresentation)
        XCTAssertEqual(manager.profileUsagePresentations.count, 1)

        manager.cleanup()

        XCTAssertTrue(manager.profileUsagePresentations.isEmpty)
    }

    func testSetViewedProfileChangesDisplayWithoutActivating() {
        let claudeProfile = Profile(name: "jc@example.com")
        let codexProfile = Profile(
            name: "codex",
            providerConfiguration: .codex(.init())
        )
        let profileManager = retain(makeIsolatedProfileManager())
        profileManager.profiles = [claudeProfile, codexProfile]
        profileManager.activeProfile = claudeProfile
        profileManager.displayMode = .multi
        let apiService = retain(ClaudeAPIService(
            profileManager: profileManager,
            systemCredentialsReader: { nil }
        ))
        let statusService = retain(ClaudeStatusService())
        let runtime = retain(UsageRefreshRuntime.live(
            profileManager: profileManager,
            apiService: apiService,
            statusService: statusService,
            featureAvailability: .testing()
        ))
        let providerUIDependencies = retain(
            ProviderUIDependencies(
                profileManager: profileManager,
                codexProviderFactory: CodexProviderFactory(
                    availability: .testing()
                )
            )
        )
        let manager = retain(MenuBarManager(
            apiService: apiService,
            statusService: statusService,
            profileManager: profileManager,
            refreshRuntime: runtime,
            providerUIDependencies: providerUIDependencies
        ))
        let context = UsagePresentationContext(
            epoch: 1,
            focusedProfileID: claudeProfile.id,
            visibleProfileIDs: [claudeProfile.id, codexProfile.id],
            mode: .multi
        )
        runtime.presentationStore.activate(context)
        XCTAssertTrue(
            runtime.presentationStore.publish(
                makePresentationSnapshot(
                    profileID: claudeProfile.id,
                    profileName: claudeProfile.name,
                    providerID: .claude,
                    presentationEpoch: context.epoch
                ),
                expected: context
            )
        )
        XCTAssertTrue(
            runtime.presentationStore.publish(
                makePresentationSnapshot(
                    profileID: codexProfile.id,
                    profileName: codexProfile.name,
                    providerID: .codex,
                    presentationEpoch: context.epoch
                ),
                expected: context
            )
        )

        // Default view follows the active (Claude) profile.
        XCTAssertEqual(
            manager.displayedUsagePresentation?.profileID,
            claudeProfile.id
        )

        manager.setViewedProfile(codexProfile.id)

        XCTAssertEqual(manager.clickedProfileId, codexProfile.id)
        XCTAssertEqual(
            manager.displayedUsagePresentation?.profileID,
            codexProfile.id
        )
        // Activation state must be untouched — the switch is view-only.
        XCTAssertEqual(profileManager.activeProfile?.id, claudeProfile.id)
        XCTAssertFalse(profileManager.isActive(codexProfile))

        manager.cleanup()
    }

    func testSetViewedProfileChangesDisplayWithoutActivatingInSingleMode() {
        let claudeProfile = Profile(name: "jc@example.com")
        let codexProfile = Profile(
            name: "codex",
            providerConfiguration: .codex(.init())
        )
        let profileManager = retain(makeIsolatedProfileManager())
        profileManager.profiles = [claudeProfile, codexProfile]
        profileManager.activeProfile = claudeProfile
        profileManager.displayMode = .single
        let apiService = retain(ClaudeAPIService(
            profileManager: profileManager,
            systemCredentialsReader: { nil }
        ))
        let statusService = retain(ClaudeStatusService())
        let runtime = retain(UsageRefreshRuntime.live(
            profileManager: profileManager,
            apiService: apiService,
            statusService: statusService,
            featureAvailability: .testing()
        ))
        let providerUIDependencies = retain(
            ProviderUIDependencies(
                profileManager: profileManager,
                codexProviderFactory: CodexProviderFactory(
                    availability: .testing()
                )
            )
        )
        let manager = retain(MenuBarManager(
            apiService: apiService,
            statusService: statusService,
            profileManager: profileManager,
            refreshRuntime: runtime,
            providerUIDependencies: providerUIDependencies
        ))
        let context = UsagePresentationContext(
            epoch: 1,
            focusedProfileID: claudeProfile.id,
            visibleProfileIDs: [claudeProfile.id, codexProfile.id],
            mode: .multi
        )
        runtime.presentationStore.activate(context)
        XCTAssertTrue(
            runtime.presentationStore.publish(
                makePresentationSnapshot(
                    profileID: claudeProfile.id,
                    profileName: claudeProfile.name,
                    providerID: .claude,
                    presentationEpoch: context.epoch
                ),
                expected: context
            )
        )
        XCTAssertTrue(
            runtime.presentationStore.publish(
                makePresentationSnapshot(
                    profileID: codexProfile.id,
                    profileName: codexProfile.name,
                    providerID: .codex,
                    presentationEpoch: context.epoch
                ),
                expected: context
            )
        )

        // Default view follows the active (Claude) profile.
        XCTAssertEqual(
            manager.displayedUsagePresentation?.profileID,
            claudeProfile.id
        )

        manager.setViewedProfile(codexProfile.id)

        XCTAssertEqual(manager.clickedProfileId, codexProfile.id)
        XCTAssertEqual(
            manager.displayedUsagePresentation?.profileID,
            codexProfile.id
        )
        // Activation state must be untouched — the switch is view-only.
        XCTAssertEqual(profileManager.activeProfile?.id, claudeProfile.id)
        XCTAssertFalse(profileManager.isActive(codexProfile))

        manager.cleanup()
    }

    func testSetViewedProfileIgnoresUnknownProfileID() {
        let claudeProfile = Profile(name: "jc@example.com")
        let profileManager = retain(makeIsolatedProfileManager())
        profileManager.profiles = [claudeProfile]
        profileManager.activeProfile = claudeProfile
        profileManager.displayMode = .multi
        let apiService = retain(ClaudeAPIService(
            profileManager: profileManager,
            systemCredentialsReader: { nil }
        ))
        let statusService = retain(ClaudeStatusService())
        let runtime = retain(UsageRefreshRuntime.live(
            profileManager: profileManager,
            apiService: apiService,
            statusService: statusService,
            featureAvailability: .testing()
        ))
        let providerUIDependencies = retain(
            ProviderUIDependencies(
                profileManager: profileManager,
                codexProviderFactory: CodexProviderFactory(
                    availability: .testing()
                )
            )
        )
        let manager = retain(MenuBarManager(
            apiService: apiService,
            statusService: statusService,
            profileManager: profileManager,
            refreshRuntime: runtime,
            providerUIDependencies: providerUIDependencies
        ))

        manager.setViewedProfile(UUID())

        XCTAssertNil(manager.clickedProfileId)
        manager.cleanup()
    }

    func testSingleProfilePresentationHonorsClickedProfile() {
        let activeID = UUID()
        let clickedID = UUID()
        let presentations = [
            activeID: makePresentationSnapshot(
                profileID: activeID,
                providerID: .claude
            ),
            clickedID: makePresentationSnapshot(
                profileID: clickedID,
                providerID: .codex
            )
        ]

        let selected = MenuBarManager.selectDisplayedUsagePresentation(
            displayMode: .single,
            clickedProfileID: clickedID,
            activeProfileID: activeID,
            presentations: presentations
        )

        XCTAssertEqual(selected?.profileID, clickedID)
    }

    func testMultiProfilePresentationSelectsClickedThenActive() {
        let activeID = UUID()
        let clickedID = UUID()
        let presentations = [
            activeID: makePresentationSnapshot(
                profileID: activeID,
                providerID: .claude
            ),
            clickedID: makePresentationSnapshot(
                profileID: clickedID,
                providerID: .codex
            )
        ]

        let clicked = MenuBarManager.selectDisplayedUsagePresentation(
            displayMode: .multi,
            clickedProfileID: clickedID,
            activeProfileID: activeID,
            presentations: presentations
        )
        let active = MenuBarManager.selectDisplayedUsagePresentation(
            displayMode: .multi,
            clickedProfileID: nil,
            activeProfileID: activeID,
            presentations: presentations
        )

        XCTAssertEqual(clicked?.profileID, clickedID)
        XCTAssertEqual(active?.profileID, activeID)
    }

    func testMissingClickedPresentationNeverLeaksActiveProfile() {
        let activeID = UUID()
        let missingClickedID = UUID()
        let presentations = [
            activeID: makePresentationSnapshot(
                profileID: activeID,
                providerID: .claude
            )
        ]

        let selected = MenuBarManager.selectDisplayedUsagePresentation(
            displayMode: .multi,
            clickedProfileID: missingClickedID,
            activeProfileID: activeID,
            presentations: presentations
        )

        XCTAssertNil(selected)
    }

    func testPresentationSelectionPreservesSnapshotAndReflectsRemoval()
        throws
    {
        let profileID = UUID()
        let fetchedAt = Date(timeIntervalSinceReferenceDate: 3_000)
        let report = try makeUsageReport(
            providerID: .codex,
            fetchedAt: fetchedAt
        )
        let capabilities = ProviderCapabilities([
            .account: .available,
            .usageLimits: .available
        ])
        let failure = ProviderRefreshFailure(
            kind: .transport,
            occurredAt: fetchedAt.addingTimeInterval(10),
            isRecoverable: true,
            consecutiveCount: 2
        )
        let snapshot = makePresentationSnapshot(
            profileID: profileID,
            profileName: "Codex Team",
            providerID: .codex,
            providerRevision: 4,
            presentationEpoch: 9,
            capabilities: capabilities,
            report: report,
            activity: .refreshing(
                requestID: UUID(),
                trigger: .manual,
                startedAt: fetchedAt
            ),
            lastSuccessfulAt: fetchedAt,
            currentFailure: failure
        )
        var presentations = [profileID: snapshot]

        let selected = MenuBarManager.selectDisplayedUsagePresentation(
            displayMode: .single,
            clickedProfileID: nil,
            activeProfileID: profileID,
            presentations: presentations
        )

        XCTAssertEqual(selected?.profileID, profileID)
        XCTAssertEqual(selected?.profileName, "Codex Team")
        XCTAssertEqual(selected?.providerRevision, 4)
        XCTAssertEqual(selected?.presentationEpoch, 9)
        XCTAssertEqual(selected?.capabilities, capabilities)
        XCTAssertEqual(selected?.configurationState, .ready)
        XCTAssertEqual(selected?.report, report)
        XCTAssertEqual(selected?.activity, snapshot.activity)
        XCTAssertEqual(selected?.lastSuccessfulAt, fetchedAt)
        XCTAssertEqual(selected?.currentFailure, failure)

        presentations.removeValue(forKey: profileID)
        XCTAssertNil(
            MenuBarManager.selectDisplayedUsagePresentation(
                displayMode: .single,
                clickedProfileID: nil,
                activeProfileID: profileID,
                presentations: presentations
            )
        )
    }

    func testClaudePresentationRemainsCompatibleWithLegacyPopoverProjection() {
        let profileID = UUID()
        var claudeUsage = ClaudeUsage.empty
        claudeUsage.sessionTokensUsed = 23
        let apiUsage = APIUsage(
            currentSpendCents: 31,
            resetsAt: Date(timeIntervalSinceReferenceDate: 4_000),
            prepaidCreditsCents: 69,
            currency: "USD",
            apiTokenCostCents: nil,
            apiCostByModel: nil,
            costBySource: nil,
            dailyCostCents: nil
        )
        let snapshot = makePresentationSnapshot(
            profileID: profileID,
            providerID: .claude,
            claudeUsage: claudeUsage,
            claudeAPIUsage: apiUsage
        )

        let selected = MenuBarManager.selectDisplayedUsagePresentation(
            displayMode: .single,
            clickedProfileID: nil,
            activeProfileID: profileID,
            presentations: [profileID: snapshot]
        )

        XCTAssertEqual(
            MenuBarManager.popoverUsage(
                clickedProfileID: nil,
                clickedProfileUsage: nil,
                activeProfileUsage: selected?.claudeUsage ?? .empty
            ).sessionTokensUsed,
            23
        )
        XCTAssertEqual(
            MenuBarManager.popoverAPIUsage(
                clickedProfileID: nil,
                clickedProfileAPIUsage: nil,
                activeProfileAPIUsage: selected?.claudeAPIUsage
            ),
            apiUsage
        )
    }

    func testClickedProfileNeverFallsBackToActiveUsage() {
        let clickedID = UUID()
        var activeUsage = ClaudeUsage.empty
        activeUsage.sessionTokensUsed = 99
        let activeAPI = APIUsage(
            currentSpendCents: 99,
            resetsAt: Date(timeIntervalSinceReferenceDate: 1_000),
            prepaidCreditsCents: 1,
            currency: "USD",
            apiTokenCostCents: nil,
            apiCostByModel: nil,
            costBySource: nil,
            dailyCostCents: nil
        )

        let beforeSnapshot = MenuBarManager.popoverUsage(
            clickedProfileID: clickedID,
            clickedProfileUsage: nil,
            activeProfileUsage: activeUsage
        )
        XCTAssertEqual(beforeSnapshot.sessionTokensUsed, 0)
        XCTAssertNil(
            MenuBarManager.popoverAPIUsage(
                clickedProfileID: clickedID,
                clickedProfileAPIUsage: nil,
                activeProfileAPIUsage: activeAPI
            )
        )

        var clickedUsage = ClaudeUsage.empty
        clickedUsage.sessionTokensUsed = 11
        XCTAssertEqual(
            MenuBarManager.popoverUsage(
                clickedProfileID: clickedID,
                clickedProfileUsage: clickedUsage,
                activeProfileUsage: activeUsage
            ).sessionTokensUsed,
            11
        )
        XCTAssertEqual(
            MenuBarManager.popoverUsage(
                clickedProfileID: nil,
                clickedProfileUsage: nil,
                activeProfileUsage: activeUsage
            ).sessionTokensUsed,
            99
        )
        XCTAssertEqual(
            MenuBarManager.popoverAPIUsage(
                clickedProfileID: nil,
                clickedProfileAPIUsage: nil,
                activeProfileAPIUsage: activeAPI
            ),
            activeAPI
        )
    }

    func testFailureRoutingRequiresExactContextAndActiveProfile() {
        let profileID = UUID()
        let context = UsagePresentationContext(
            epoch: 7,
            focusedProfileID: profileID,
            visibleProfileIDs: [profileID]
        )
        let event = UsageRefreshFailureEvent(
            sequence: 1,
            identity: ProviderRefreshIdentity(
                profileID: profileID,
                providerID: .claude,
                providerRevision: 0
            ),
            profileName: "A",
            inputGeneration: 0,
            invocationOrder: 1,
            trigger: .timer,
            presentationContext: context,
            component: .providerUsage,
            failure: ProviderRefreshFailure(
                kind: .transport,
                occurredAt: Date(timeIntervalSince1970: 1),
                isRecoverable: true,
                consecutiveCount: 1
            )
        )

        XCTAssertTrue(
            MenuBarManager.isCurrentFailureEvent(
                event,
                presentationContext: context,
                activeProfileID: profileID
            )
        )
        XCTAssertFalse(
            MenuBarManager.isCurrentFailureEvent(
                event,
                presentationContext: UsagePresentationContext(
                    epoch: 8,
                    focusedProfileID: profileID,
                    visibleProfileIDs: [profileID]
                ),
                activeProfileID: profileID
            )
        )
        XCTAssertFalse(
            MenuBarManager.isCurrentFailureEvent(
                event,
                presentationContext: context,
                activeProfileID: UUID()
            )
        )
        XCTAssertTrue(
            MenuBarManager.isCurrentRefreshInput(
                eventInputGeneration: event.inputGeneration,
                eventInvocationOrder: event.invocationOrder,
                currentInputGeneration: 0,
                currentInvocationOrder: 1
            )
        )
        XCTAssertFalse(
            MenuBarManager.isCurrentRefreshInput(
                eventInputGeneration: event.inputGeneration,
                eventInvocationOrder: event.invocationOrder,
                currentInputGeneration: 1,
                currentInvocationOrder: 1
            )
        )
        XCTAssertFalse(
            MenuBarManager.isCurrentRefreshInput(
                eventInputGeneration: event.inputGeneration,
                eventInvocationOrder: event.invocationOrder,
                currentInputGeneration: 0,
                currentInvocationOrder: 2
            )
        )
    }

    func testResetHistorySuppressesDuplicatePeriodicComponents() {
        XCTAssertEqual(
            MenuBarManager.periodicHistoryComponents(
                sessionResetRecorded: false,
                weeklyResetRecorded: false
            ),
            [.session, .weekly]
        )
        XCTAssertEqual(
            MenuBarManager.periodicHistoryComponents(
                sessionResetRecorded: true,
                weeklyResetRecorded: false
            ),
            [.weekly]
        )
        XCTAssertEqual(
            MenuBarManager.periodicHistoryComponents(
                sessionResetRecorded: false,
                weeklyResetRecorded: true
            ),
            [.session]
        )
        XCTAssertTrue(
            MenuBarManager.periodicHistoryComponents(
                sessionResetRecorded: true,
                weeklyResetRecorded: true
            ).isEmpty
        )
    }

    func testRefreshFailureReconstructsCanonicalSafeLegacyErrors() {
        let cases: [(ErrorCode, AppError)] = [
            (.sessionKeyNotFound, .sessionKeyNotFound()),
            (
                .sessionKeyInvalid,
                .sessionKeyInvalid(reason: "safe")
            ),
            (
                .sessionKeyExpired,
                AppError(
                    code: .sessionKeyExpired,
                    message: "error.session_key_invalid".localized,
                    technicalDetails: "safe",
                    isRecoverable: true,
                    recoverySuggestion:
                        "error.session_key_not_found.suggestion"
                            .localized
                )
            ),
            (.apiUnauthorized, .apiUnauthorized()),
            (.apiRateLimited, .apiRateLimited()),
            (.apiServerError, .apiServerError(statusCode: 500)),
            (.networkTimeout, .networkTimeout()),
            (.networkUnavailable, .networkUnavailable()),
            (.storageWriteFailed, .storageWriteFailed())
        ]

        for (code, expected) in cases {
            let actual = MenuBarManager.appError(
                for: ProviderRefreshFailure(
                    kind: .transport,
                    occurredAt: Date(
                        timeIntervalSinceReferenceDate: 1
                    ),
                    isRecoverable: true,
                    consecutiveCount: 1,
                    legacyErrorCode: code
                )
            )

            XCTAssertEqual(actual.code, expected.code)
            XCTAssertEqual(actual.message, expected.message)
            XCTAssertEqual(
                actual.recoverySuggestion,
                expected.recoverySuggestion
            )
            XCTAssertNil(actual.underlyingError)
        }
    }

    func testPersistenceFailureUsesCanonicalLocalizedStorageError() {
        let error = MenuBarManager.appError(
            for: ProviderRefreshFailure(
                kind: .persistence,
                occurredAt: Date(
                    timeIntervalSinceReferenceDate: 1
                ),
                isRecoverable: true,
                consecutiveCount: 1
            )
        )

        XCTAssertEqual(error.code, .storageWriteFailed)
        XCTAssertEqual(
            error.message,
            "error.storage_write_failed".localized
        )
        XCTAssertEqual(
            error.recoverySuggestion,
            "error.storage_write_failed.suggestion".localized
        )
        XCTAssertEqual(
            error.technicalDetails,
            "Usage persistence transaction was rejected"
        )
        XCTAssertTrue(error.isRecoverable)
        XCTAssertNil(error.underlyingError)
    }

    func testInteractiveRefreshSideEffectsAreSingleProfileOnly() {
        let profileID = UUID()
        let single = UsagePresentationContext(
            epoch: 1,
            focusedProfileID: profileID,
            visibleProfileIDs: [profileID],
            mode: .single
        )
        XCTAssertTrue(
            MenuBarManager
                .shouldApplyInteractiveRefreshSideEffects(
                    eventContext: single,
                    currentContext: single,
                    eventProfileID: profileID,
                    activeProfileID: profileID
                )
        )

        let multi = UsagePresentationContext(
            epoch: 2,
            focusedProfileID: profileID,
            visibleProfileIDs: [profileID],
            mode: .multi
        )
        XCTAssertFalse(
            MenuBarManager
                .shouldApplyInteractiveRefreshSideEffects(
                    eventContext: multi,
                    currentContext: multi,
                    eventProfileID: profileID,
                    activeProfileID: profileID
                )
        )
    }

    func testRefreshSideEffectRouterSeparatesCommitAndPresentedEffects()
    {
        let profileID = UUID()
        let context = UsagePresentationContext(
            epoch: 10,
            focusedProfileID: profileID,
            visibleProfileIDs: [profileID],
            mode: .single
        )
        var activeProfile = Profile(
            id: profileID,
            name: "Current name"
        )
        activeProfile.notificationSettings = NotificationSettings(
            enabled: true
        )
        let capturedSettings = NotificationSettings(
            enabled: false,
            soundName: "Captured sound"
        )
        let event = makeAcceptedEvent(
            profileID: profileID,
            context: context,
            profileName: "Initiating name",
            notificationSettings: capturedSettings,
            components: [.providerUsage, .claudeAPI]
        )
        let recorder = ThreadSafeRecorder()
        let router = makeSideEffectRouter(recorder)

        router.committed(event)

        XCTAssertEqual(
            recorder.snapshot(),
            [
                "api-history:Initiating name",
                "notify:Initiating name:false:Captured sound"
            ]
        )

        router.presented(
            event,
            currentContext: context,
            activeProfile: activeProfile
        )

        XCTAssertEqual(
            recorder.snapshot(),
            [
                "api-history:Initiating name",
                "notify:Initiating name:false:Captured sound",
                "auto:\(profileID.uuidString)"
            ]
        )
    }

    func testRefreshSideEffectRouterCapabilityGatesAutomaticSwitch()
    {
        let profile = Profile(name: "Claude")
        let context = UsagePresentationContext(
            epoch: 10,
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            mode: .single
        )
        let event = makeAcceptedEvent(
            profileID: profile.id,
            context: context,
            capabilities: ProviderCapabilities([
                .usageHistory: .available,
                .usageNotifications: .available,
                .automaticProfileSwitch: .unavailable
            ]),
            components: [.providerUsage]
        )
        let recorder = ThreadSafeRecorder()
        let router = makeSideEffectRouter(recorder)

        router.committed(event)
        router.presented(
            event,
            currentContext: context,
            activeProfile: profile
        )

        XCTAssertEqual(
            recorder.snapshot(),
            ["notify:Captured:true:default"]
        )
    }

    func testRefreshSideEffectRouterCommitsMultiProfileNotifications()
    {
        let profile = Profile(name: "Claude")
        let context = UsagePresentationContext(
            epoch: 11,
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id, UUID()],
            mode: .multi
        )
        let event = makeAcceptedEvent(
            profileID: profile.id,
            context: context,
            components: [.providerUsage]
        )
        let recorder = ThreadSafeRecorder()
        let router = makeSideEffectRouter(recorder)

        router.committed(event)
        router.presented(
            event,
            currentContext: context,
            activeProfile: profile
        )

        XCTAssertEqual(
            recorder.snapshot(),
            ["notify:Captured:true:default"]
        )
    }

    func testRefreshSideEffectRouterSuppressesInteractiveAEffectsAfterB()
    {
        let profileA = UUID()
        let profileB = UUID()
        let context = UsagePresentationContext(
            epoch: 11,
            focusedProfileID: profileA,
            visibleProfileIDs: [profileA],
            mode: .single
        )
        let event = makeAcceptedEvent(
            profileID: profileA,
            context: context,
            components: [.providerUsage, .claudeAPI]
        )
        let recorder = ThreadSafeRecorder()
        let router = makeSideEffectRouter(recorder)

        router.committed(event)
        router.presented(
            event,
            currentContext: context,
            activeProfile: Profile(id: profileB, name: "B")
        )

        XCTAssertEqual(
            recorder.snapshot(),
            [
                "api-history:Captured",
                "notify:Captured:true:default"
            ]
        )
    }

    func testRefreshSideEffectRouterPreservesViewedFailureForMixedBatch()
    {
        let successfulProfileID = UUID()
        let activeProfile = Profile(name: "Active")
        let context = UsagePresentationContext(
            epoch: 12,
            focusedProfileID: activeProfile.id,
            visibleProfileIDs: [
                successfulProfileID,
                activeProfile.id
            ],
            mode: .multi
        )
        let result = UsageRefreshBatchResult(
            batchID: UUID(),
            invocationOrder: 4,
            outcomes: [
                successfulProfileID: .accepted,
                activeProfile.id: .failed
            ],
            trigger: .manual,
            presentationContext: context,
            isLatestBatch: true
        )
        let recorder = ThreadSafeRecorder()
        let router = makeSideEffectRouter(recorder)

        router.finished(
            result,
            currentContext: context,
            latestInvocationOrder: 4,
            activeProfile: activeProfile,
            activeSnapshot: nil
        )

        XCTAssertEqual(
            recorder.snapshot(),
            ["batch-finalized"]
        )
    }

    func testRefreshSideEffectRouterRejectsReentrantlyStaleBatch()
    {
        let profile = Profile(name: "Active")
        let context = UsagePresentationContext(
            epoch: 14,
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            mode: .single
        )
        let recorder = ThreadSafeRecorder()
        let router = makeSideEffectRouter(recorder)
        router.finished(
            UsageRefreshBatchResult(
                batchID: UUID(),
                invocationOrder: 4,
                outcomes: [profile.id: .accepted],
                trigger: .manual,
                presentationContext: context,
                isLatestBatch: true
            ),
            currentContext: context,
            latestInvocationOrder: 5,
            activeProfile: profile,
            activeSnapshot: makeSnapshot(
                profile: profile,
                context: context
            )
        )

        XCTAssertTrue(recorder.snapshot().isEmpty)
    }

    func testRefreshSideEffectRouterCompletesSingleBatchEffectsOnce()
    {
        let profile = Profile(name: "Active")
        let context = UsagePresentationContext(
            epoch: 15,
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            mode: .single
        )
        let result = UsageRefreshBatchResult(
            batchID: UUID(),
            invocationOrder: 5,
            outcomes: [profile.id: .accepted],
            trigger: .manual,
            presentationContext: context,
            isLatestBatch: true
        )
        let recorder = ThreadSafeRecorder()
        let router = makeSideEffectRouter(recorder)

        router.finished(
            result,
            currentContext: context,
            latestInvocationOrder: 5,
            activeProfile: profile,
            activeSnapshot: makeSnapshot(
                profile: profile,
                context: context
            )
        )

        XCTAssertEqual(
            recorder.snapshot(),
            [
                "batch-finalized",
                "single-success",
                "claude-circuit-success",
                "success-toast"
            ]
        )
    }

    func testRefreshSideEffectRouterCapabilityGatesBatchAutomaticSwitch()
    {
        let profile = Profile(name: "Claude")
        let context = UsagePresentationContext(
            epoch: 15,
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            mode: .multi
        )
        let result = UsageRefreshBatchResult(
            batchID: UUID(),
            invocationOrder: 5,
            outcomes: [profile.id: .accepted],
            trigger: .timer,
            presentationContext: context,
            isLatestBatch: true
        )
        let unavailableRecorder = ThreadSafeRecorder()
        let unavailableRouter = makeSideEffectRouter(
            unavailableRecorder
        )
        unavailableRouter.finished(
            result,
            currentContext: context,
            latestInvocationOrder: 5,
            activeProfile: profile,
            activeSnapshot: makePresentationSnapshot(
                profileID: profile.id,
                providerID: .claude,
                presentationEpoch: context.epoch,
                capabilities: ProviderCapabilities([
                    .automaticProfileSwitch: .unavailable
                ]),
                claudeUsage: .empty
            )
        )
        XCTAssertEqual(
            unavailableRecorder.snapshot(),
            ["batch-finalized"]
        )

        let availableRecorder = ThreadSafeRecorder()
        let availableRouter = makeSideEffectRouter(
            availableRecorder
        )
        availableRouter.finished(
            result,
            currentContext: context,
            latestInvocationOrder: 5,
            activeProfile: profile,
            activeSnapshot: makePresentationSnapshot(
                profileID: profile.id,
                providerID: .claude,
                presentationEpoch: context.epoch,
                capabilities: ProviderCapabilities([
                    .automaticProfileSwitch: .available
                ]),
                claudeUsage: .empty
            )
        )
        XCTAssertEqual(
            availableRecorder.snapshot(),
            ["batch-finalized", "batch-auto-switch"]
        )
    }

    func testRefreshSideEffectRouterDoesNotResetClaudeCircuitForCodex()
    {
        let profile = Profile(
            name: "Codex",
            providerConfiguration: .codex(.init())
        )
        let context = UsagePresentationContext(
            epoch: 16,
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            mode: .single
        )
        let result = UsageRefreshBatchResult(
            batchID: UUID(),
            invocationOrder: 6,
            outcomes: [profile.id: .accepted],
            trigger: .manual,
            presentationContext: context,
            isLatestBatch: true
        )
        let recorder = ThreadSafeRecorder()
        let router = makeSideEffectRouter(recorder)

        router.finished(
            result,
            currentContext: context,
            latestInvocationOrder: 6,
            activeProfile: profile,
            activeSnapshot: makeSnapshot(
                profile: profile,
                context: context
            )
        )

        XCTAssertEqual(
            recorder.snapshot(),
            [
                "batch-finalized",
                "single-success",
                "success-toast"
            ]
        )
    }

    func testRefreshSideEffectRouterRequiresExactSingleSnapshot()
    {
        let profile = Profile(name: "Claude")
        let context = UsagePresentationContext(
            epoch: 17,
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            mode: .single
        )
        let result = UsageRefreshBatchResult(
            batchID: UUID(),
            invocationOrder: 7,
            outcomes: [profile.id: .accepted],
            trigger: .manual,
            presentationContext: context,
            isLatestBatch: true
        )
        let recorder = ThreadSafeRecorder()
        let router = makeSideEffectRouter(recorder)

        router.finished(
            result,
            currentContext: context,
            latestInvocationOrder: 7,
            activeProfile: profile,
            activeSnapshot: nil
        )

        XCTAssertEqual(recorder.snapshot(), ["batch-finalized"])
    }

    func testRefreshSideEffectRouterGatesFailurePresentation()
    {
        let profileID = UUID()
        let context = UsagePresentationContext(
            epoch: 13,
            focusedProfileID: profileID,
            visibleProfileIDs: [profileID],
            mode: .single
        )
        let event = UsageRefreshFailureEvent(
            sequence: 1,
            identity: ProviderRefreshIdentity(
                profileID: profileID,
                providerID: .claude,
                providerRevision: 0
            ),
            profileName: "Captured",
            inputGeneration: 0,
            invocationOrder: 1,
            trigger: .manual,
            presentationContext: context,
            component: .providerUsage,
            failure: ProviderRefreshFailure(
                kind: .unauthenticated,
                occurredAt: Date(
                    timeIntervalSinceReferenceDate: 1
                ),
                isRecoverable: true,
                consecutiveCount: 1,
                legacyErrorCode: .sessionKeyNotFound
            )
        )
        let recorder = ThreadSafeRecorder()
        let router = makeSideEffectRouter(recorder)
        let error = MenuBarManager.appError(for: event.failure)

        router.failed(
            event,
            error: error,
            currentContext: context,
            activeProfileID: profileID
        )
        router.failed(
            event,
            error: error,
            currentContext: UsagePresentationContext(
                epoch: 14,
                focusedProfileID: profileID,
                visibleProfileIDs: [profileID],
                mode: .single
            ),
            activeProfileID: profileID
        )

        XCTAssertEqual(
            recorder.snapshot(),
            [
                "failure-log:E1000",
                "circuit-failure",
                "failure-alert",
                "failure-log:E1000"
            ]
        )
    }

    func testImageFingerprintUsesStableCGImageBytes() {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(
            rect: NSRect(x: 0, y: 0, width: 4, height: 4)
        ).fill()
        image.unlockFocus()

        let first = StatusBarUIManager.imageFingerprint(image)
        let second = StatusBarUIManager.imageFingerprint(image)

        XCTAssertNotNil(first)
        XCTAssertFalse(first?.isEmpty ?? true)
        XCTAssertEqual(first, second)
    }

    func testBorderlessSettingsWindowRecognizesCommandW() {
        XCTAssertTrue(
            BorderlessSettingsWindow.isCloseShortcut(
                modifierFlags: .command,
                charactersIgnoringModifiers: "w"
            )
        )
        XCTAssertTrue(
            BorderlessSettingsWindow.isCloseShortcut(
                modifierFlags: [.command, .shift],
                charactersIgnoringModifiers: "W"
            )
        )
        XCTAssertFalse(
            BorderlessSettingsWindow.isCloseShortcut(
                modifierFlags: [],
                charactersIgnoringModifiers: "w"
            )
        )
        XCTAssertFalse(
            BorderlessSettingsWindow.isCloseShortcut(
                modifierFlags: .command,
                charactersIgnoringModifiers: "q"
            )
        )
    }

    func testMenuBarNotificationIsEnqueuedAfterPendingProfileMutation() {
        let center = NotificationCenter()
        let queue = DispatchQueue(
            label: "MenuReliabilityTests.notification-order"
        )
        let recorder = ThreadSafeRecorder()
        let notificationName = Notification.Name(
            "MenuReliabilityTests.notification"
        )
        let notificationPosted = expectation(
            description: "notification posted"
        )

        let observer = center.addObserver(
            forName: notificationName,
            object: nil,
            queue: nil
        ) { _ in
            recorder.append("notification")
            notificationPosted.fulfill()
        }
        defer { center.removeObserver(observer) }

        queue.async {
            recorder.append("mutation")
        }
        MenuBarNotificationDelivery.enqueue(
            notificationName,
            queue: queue,
            center: center
        )

        wait(for: [notificationPosted], timeout: 1)
        XCTAssertEqual(
            recorder.snapshot(),
            ["mutation", "notification"]
        )
    }

    func testAppearanceWarningCardEnqueuesNotificationAfterModeMutation() {
        let center = NotificationCenter()
        let queue = DispatchQueue(
            label: "MenuReliabilityTests.appearance-warning-order"
        )
        let recorder = ThreadSafeRecorder()
        let notificationPosted = expectation(
            description: "display mode notification posted"
        )
        let observer = center.addObserver(
            forName: .displayModeChanged,
            object: nil,
            queue: nil
        ) { _ in
            recorder.append("notification")
            notificationPosted.fulfill()
        }
        defer { center.removeObserver(observer) }

        AppearanceSettingsView.disableMultiProfile(
            updateDisplayMode: {
                queue.async {
                    recorder.append("mutation")
                }
            },
            queue: queue,
            center: center
        )

        wait(for: [notificationPosted], timeout: 1)
        XCTAssertEqual(
            recorder.snapshot(),
            ["mutation", "notification"]
        )
    }

    func testProfileDeletionErrorUsesAuthoredLocalizedDescription() {
        let presentation = ProfileDeletionErrorPresentation(
            error: LocalizedDeletionError.expected
        )
        XCTAssertEqual(presentation.message, "Safe deletion failure")
    }

    func testProfileDeletionErrorDoesNotExposeOpaqueErrorPayload() {
        let secret = "DELETE_ERROR_SECRET_FIXTURE"
        let opaqueError = NSError(
            domain: "MenuReliabilityTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: secret]
        )

        let presentation = ProfileDeletionErrorPresentation(
            error: opaqueError
        )
        XCTAssertEqual(
            presentation.message,
            ProfileDeletionErrorPresentation.genericMessage
        )
        XCTAssertFalse(presentation.message.contains(secret))
    }

    private func makeAcceptedEvent(
        profileID: UUID,
        context: UsagePresentationContext,
        profileName: String = "Captured",
        notificationSettings: NotificationSettings =
            NotificationSettings(),
        capabilities: ProviderCapabilities =
            ProviderCapabilities([
                .usageHistory: .available,
                .usageNotifications: .available,
                .automaticProfileSwitch: .available
            ]),
        components: Set<AcceptedUsageComponent>
    ) -> AcceptedUsageRefreshEvent {
        var usage = ClaudeUsage.empty
        usage.sessionTokensUsed = 42
        let api = APIUsage(
            currentSpendCents: 42,
            resetsAt: Date(timeIntervalSinceReferenceDate: 2_000),
            prepaidCreditsCents: 58,
            currency: "USD",
            apiTokenCostCents: nil,
            apiCostByModel: nil,
            costBySource: nil,
            dailyCostCents: nil
        )
        return AcceptedUsageRefreshEvent(
            sequence: 1,
            identity: ProviderRefreshIdentity(
                profileID: profileID,
                providerID: .claude,
                providerRevision: 0
            ),
            inputGeneration: 0,
            invocationOrder: 1,
            profileName: profileName,
            notificationSettings: notificationSettings,
            trigger: .manual,
            presentationContext: context,
            capabilities: capabilities,
            previousUsage: nil,
            currentUsage: ProfileCurrentUsage(
                providerID: .claude,
                providerRevision: 0,
                report:
                    components.contains(.providerUsage)
                        ? try! makeUsageReport(
                            providerID: .claude,
                            fetchedAt: Date(
                                timeIntervalSinceReferenceDate:
                                    2_000
                            )
                        )
                        : nil,
                claudeUsage:
                    components.contains(.providerUsage)
                        ? usage
                        : nil,
                apiUsage:
                    components.contains(.claudeAPI)
                        ? api
                        : nil
            ),
            acceptedComponents: components,
            committedAt: Date(
                timeIntervalSinceReferenceDate: 2_000
            )
        )
    }

    private func makeSnapshot(
        profile: Profile,
        context: UsagePresentationContext
    ) -> PresentationSnapshot {
        PresentationSnapshot(
            profileID: profile.id,
            profileName: profile.name,
            providerID: profile.providerID,
            providerRevision: profile.providerRevision,
            presentationEpoch: context.epoch,
            capabilities: ProviderCapabilities(),
            configurationState: .ready,
            report: nil,
            claudeUsage: nil,
            claudeAPIUsage: nil,
            activity: .idle,
            lastSuccessfulAt: Date(
                timeIntervalSinceReferenceDate: 2_000
            ),
            currentFailure: nil
        )
    }

    private func makePresentationSnapshot(
        profileID: UUID,
        profileName: String = "Profile",
        providerID: ProviderID,
        providerRevision: UInt64 = 0,
        presentationEpoch: UInt64 = 1,
        capabilities: ProviderCapabilities = ProviderCapabilities(),
        report: UsageReport? = nil,
        claudeUsage: ClaudeUsage? = nil,
        claudeAPIUsage: APIUsage? = nil,
        activity: UsageRefreshActivity = .idle,
        lastSuccessfulAt: Date? = nil,
        currentFailure: ProviderRefreshFailure? = nil
    ) -> PresentationSnapshot {
        PresentationSnapshot(
            profileID: profileID,
            profileName: profileName,
            providerID: providerID,
            providerRevision: providerRevision,
            presentationEpoch: presentationEpoch,
            capabilities: capabilities,
            configurationState: .ready,
            report: report,
            claudeUsage: claudeUsage,
            claudeAPIUsage: claudeAPIUsage,
            activity: activity,
            lastSuccessfulAt: lastSuccessfulAt,
            currentFailure: currentFailure
        )
    }

    private func makeUsageReport(
        providerID: ProviderID,
        fetchedAt: Date
    ) throws -> UsageReport {
        try UsageReport(
            providerID: providerID,
            health: ProviderHealth(
                status: .healthy,
                checkedAt: fetchedAt
            ),
            limitGroups: [],
            fetchedAt: fetchedAt,
            staleAt: fetchedAt.addingTimeInterval(60)
        )
    }

    private func makeSideEffectRouter(
        _ recorder: ThreadSafeRecorder
    ) -> MenuBarManager.RefreshSideEffectRouter {
        retain(MenuBarManager.RefreshSideEffectRouter(
            hooks: .init(
                recordNormalized: { event, _ in
                    recorder.append("history:\(event.profileName)")
                },
                recordClaude: { _, _ in },
                notifyNormalized: { event, _ in
                    recorder.append(
                        "notify:\(event.profileName):"
                            + "\(event.notificationSettings.enabled):"
                            + event.notificationSettings.soundName
                    )
                },
                autoSwitch: { _, _, profile in
                    recorder.append(
                        "auto:\(profile.id.uuidString)"
                    )
                },
                recordAPI: { event, _ in
                    recorder.append(
                        "api-history:\(event.profileName)"
                    )
                },
                finalizeBatch: { _ in
                    recorder.append("batch-finalized")
                },
                recordBatchSuccess: { _ in
                    recorder.append("single-success")
                },
                recordClaudeBatchSuccess: { _ in
                    recorder.append("claude-circuit-success")
                },
                showBatchSuccess: { _ in
                    recorder.append("success-toast")
                },
                autoSwitchBatch: { _, _, _ in
                    recorder.append("batch-auto-switch")
                },
                logFailure: { _, error in
                    recorder.append(
                        "failure-log:\(error.code.rawValue)"
                    )
                },
                recordInteractiveFailure: { _, _ in
                    recorder.append("circuit-failure")
                },
                showInteractiveFailure: { _, _ in
                    recorder.append("failure-alert")
                }
            )
        ))
    }
}

private enum LocalizedDeletionError: LocalizedError {
    case expected

    var errorDescription: String? {
        "Safe deletion failure"
    }
}
