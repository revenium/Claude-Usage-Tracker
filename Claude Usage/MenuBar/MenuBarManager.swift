import Cocoa
import SwiftUI
import Combine
import UsageCore

@MainActor
enum ProviderPopoverDetachmentLifecycle {
    static func shouldDetach() -> Bool { true }

    static func makeWindow(
        contentViewController: NSViewController,
        delegate: NSWindowDelegate?
    ) -> NSPanel {
        let window = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 280,
                height: 600
            ),
            styleMask: [
                .titled,
                .closable,
                .nonactivatingPanel,
                .hudWindow,
            ],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = contentViewController
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 280, height: 600))
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.isRestorable = false
        window.delegate = delegate
        window.backgroundColor = .clear
        return window
    }

    static func closedRetainedWindow(
        _ closingWindow: NSWindow?,
        retainedWindow: NSWindow?
    ) -> Bool {
        guard let closingWindow, let retainedWindow else {
            return false
        }
        return closingWindow === retainedWindow
    }

    static func shouldCloseDetachedWindow(
        target: ProviderStatusItemIdentity?,
        profiles: [Profile],
        activatedProfileID: UUID? = nil,
        changedProfileID: UUID? = nil,
        displayModeChanged: Bool = false,
        selectedProfileIDs: Set<UUID>? = nil
    ) -> Bool {
        guard let target else { return true }
        if displayModeChanged { return true }
        if let selectedProfileIDs,
           !selectedProfileIDs.contains(target.profileID) {
            return true
        }
        if let activatedProfileID,
           activatedProfileID != target.profileID {
            return true
        }
        if let changedProfileID,
           changedProfileID != target.profileID {
            return false
        }
        return !ProviderMenuPresentationBuilder.isStillCurrent(
            target,
            profiles: profiles
        )
    }
}

nonisolated struct RefreshTimingPolicy: Equatable, Sendable {
    struct TimerFire: Equatable, Sendable {
        let occurredAt: Date
        let trigger: UsageRefreshTrigger
    }

    static let networkDebounce: TimeInterval = 2
    static let wakeDebounce: TimeInterval = 10
    static let wakeDelay: TimeInterval = 3
    static let timerToleranceFraction = 0.1

    let interval: TimeInterval
    let tolerance: TimeInterval

    init(interval: TimeInterval) {
        self.interval = interval
        tolerance = interval * Self.timerToleranceFraction
    }

    static func shouldRefreshForNetworkAvailability(
        hasRefreshableProfile: Bool,
        elapsedSinceLastTrigger: TimeInterval
    ) -> Bool {
        hasRefreshableProfile
            && elapsedSinceLastTrigger > networkDebounce
    }

    static func shouldRefreshAfterWake(
        elapsedSinceLastAutomaticRefresh: TimeInterval
    ) -> Bool {
        elapsedSinceLastAutomaticRefresh > wakeDebounce
    }

    static func timerFired(at date: Date) -> TimerFire {
        TimerFire(occurredAt: date, trigger: .timer)
    }
}

@MainActor
class MenuBarManager: NSObject, ObservableObject {
    enum UsageProjectionTarget: Equatable {
        case primary
        case clickedProfile
    }

    final class RefreshSideEffectRouter {
        struct Hooks {
            let recordNormalized:
                (AcceptedUsageRefreshEvent, UsageReport) -> Void
            let recordClaude:
                (AcceptedUsageRefreshEvent, ClaudeUsage) -> Void
            let writeStatusline:
                (AcceptedUsageRefreshEvent, ClaudeUsage) -> Void
            let notifyNormalized:
                (AcceptedUsageRefreshEvent, UsageReport) -> Void
            let autoSwitch:
                (
                    AcceptedUsageRefreshEvent,
                    ClaudeUsage,
                    Profile
                ) -> Void
            let recordAPI:
                (AcceptedUsageRefreshEvent, APIUsage) -> Void
            let finalizeBatch: (UsageRefreshBatchResult) -> Void
            let recordBatchSuccess:
                (UsageRefreshBatchResult) -> Void
            let recordClaudeBatchSuccess:
                (UsageRefreshBatchResult) -> Void
            let showBatchSuccess:
                (UsageRefreshBatchResult) -> Void
            let autoSwitchBatch:
                (
                    UsageRefreshBatchResult,
                    ClaudeUsage,
                    Profile
                ) -> Void
            let logFailure:
                (UsageRefreshFailureEvent, AppError) -> Void
            let recordInteractiveFailure:
                (UsageRefreshFailureEvent, AppError) -> Void
            let showInteractiveFailure:
                (UsageRefreshFailureEvent, AppError) -> Void
        }

        private let hooks: Hooks

        init(hooks: Hooks) {
            self.hooks = hooks
        }

        func committed(_ event: AcceptedUsageRefreshEvent) {
            if event.acceptedComponents.contains(.providerUsage),
               event.capabilities.supports(.usageHistory),
               event.identity.providerID != .claude,
               let report = event.currentUsage.report,
               report.providerID == event.identity.providerID {
                hooks.recordNormalized(event, report)
            }
            if event.identity.providerID == .claude,
               event.acceptedComponents.contains(.providerUsage),
               let usage = event.currentUsage.claudeUsage {
                hooks.recordClaude(event, usage)
            }
            if event.identity.providerID == .claude,
               event.acceptedComponents.contains(.claudeAPI),
               let usage = event.currentUsage.apiUsage {
                hooks.recordAPI(event, usage)
            }
            if event.acceptedComponents.contains(.providerUsage),
               event.capabilities.supports(.usageNotifications),
               let report = event.currentUsage.report,
               report.providerID == event.identity.providerID {
                // Notifications are profile-scoped committed effects, not
                // presentation effects. Multi-profile refreshes intentionally
                // have no single interactive presentation target.
                hooks.notifyNormalized(event, report)
            }
        }

        func presented(
            _ event: AcceptedUsageRefreshEvent,
            currentContext: UsagePresentationContext,
            activeProfile: Profile?
        ) {
            guard event.acceptedComponents.contains(.providerUsage),
                  let activeProfile,
                  activeProfile.providerID
                    == event.identity.providerID,
                  activeProfile.providerRevision
                    == event.identity.providerRevision,
                  MenuBarManager
                    .shouldApplyInteractiveRefreshSideEffects(
                        eventContext: event.presentationContext,
                        currentContext: currentContext,
                        eventProfileID: event.identity.profileID,
                        activeProfileID: activeProfile.id
                    ) else {
                return
            }
            if event.identity.providerID == .claude,
               let usage = event.currentUsage.claudeUsage {
                if event.capabilities.supports(
                    .statusLineIntegration
                ) {
                    hooks.writeStatusline(event, usage)
                }
                if event.capabilities.supports(
                    .automaticProfileSwitch
                ) {
                    hooks.autoSwitch(
                        event,
                        usage,
                        activeProfile
                    )
                }
            }
        }

        func finished(
            _ result: UsageRefreshBatchResult,
            currentContext: UsagePresentationContext,
            latestInvocationOrder: UInt64,
            activeProfile: Profile?,
            activeSnapshot: PresentationSnapshot?
        ) {
            guard result.isLatestBatch,
                  result.invocationOrder == latestInvocationOrder,
                  result.presentationContext == currentContext else {
                return
            }
            hooks.finalizeBatch(result)
            guard result.outcomes.values.contains(where: {
                if case .accepted = $0 { return true }
                return false
            }) else {
                return
            }
            if result.presentationContext.mode == .single {
                guard let focusedProfileID =
                        result.presentationContext.focusedProfileID,
                      activeProfile?.id == focusedProfileID,
                      case .accepted =
                        result.outcomes[focusedProfileID],
                      let activeSnapshot,
                      activeSnapshot.profileID == focusedProfileID,
                      activeSnapshot.presentationEpoch
                        == result.presentationContext.epoch,
                      activeSnapshot.providerID
                        == activeProfile?.providerID,
                      activeSnapshot.providerRevision
                        == activeProfile?.providerRevision else {
                    return
                }
                hooks.recordBatchSuccess(result)
                if activeSnapshot.providerID == .claude {
                    hooks.recordClaudeBatchSuccess(result)
                }
                if result.trigger.isUserInitiated {
                    hooks.showBatchSuccess(result)
                }
                return
            }
            guard let activeProfile,
                  let outcome = result.outcomes[activeProfile.id],
                  case .accepted = outcome,
                  let activeSnapshot,
                  activeSnapshot.providerID == .claude,
                  activeSnapshot.capabilities.supports(
                      .automaticProfileSwitch
                  ),
                  let usage = activeSnapshot.claudeUsage else {
                return
            }
            hooks.autoSwitchBatch(
                result,
                usage,
                activeProfile
            )
        }

        func failed(
            _ event: UsageRefreshFailureEvent,
            error: AppError,
            currentContext: UsagePresentationContext,
            activeProfileID: UUID?
        ) {
            hooks.logFailure(event, error)
            guard event.component != .claudeAPI,
                  event.identity.providerID == .claude,
                  MenuBarManager
                    .shouldApplyInteractiveRefreshSideEffects(
                        eventContext: event.presentationContext,
                        currentContext: currentContext,
                        eventProfileID: event.identity.profileID,
                        activeProfileID: activeProfileID
                    ) else {
                return
            }
            hooks.recordInteractiveFailure(event, error)
            if event.trigger.isUserInitiated {
                hooks.showInteractiveFailure(event, error)
            }
        }
    }

    nonisolated enum PeriodicHistoryComponent: Hashable {
        case session
        case weekly
    }

    private var statusItem: NSStatusItem?  // Legacy - kept for backwards compatibility
    private var statusBarUIManager: StatusBarUIManager?
    private var refreshTimer: Timer?
    private var freshnessDeadlineTimer: Timer?
    @Published private(set) var profileUsagePresentations:
        [UUID: PresentationSnapshot] = [:]
    @Published private(set) var usage: ClaudeUsage = .empty
    @Published private(set) var status: ClaudeStatus = .unknown
    @Published private(set) var apiUsage: APIUsage?
    @Published private(set) var isRefreshing: Bool = false

    // Error tracking for stale data / credential banners
    @Published private(set) var hasCredentialError: Bool = false
    @Published private(set) var consecutiveRefreshFailures: Int = 0
    @Published private(set) var lastRefreshError: String? = nil
    // Type-safe sibling of `lastRefreshError`, kept in sync with it, so the
    // popover's refresh-failure banner can select a genuinely relevant
    // explanation instead of a generic "failed" message.
    @Published private(set) var lastRefreshFailureKind:
        ProviderRefreshFailureKind? = nil
    // The earliest time the engine will attempt another scheduled refresh
    // for the failing profile, derived from its backoff window and any
    // server `Retry-After` hint. `nil` when no failure is active or the
    // failure carried no such hint.
    @Published private(set) var lastRefreshFailureRetryAt: Date? = nil
    @Published private(set) var lastSuccessfulRefreshTime: Date? = nil

    // Multi-profile mode: track which profile's icon was clicked
    @Published private(set) var clickedProfileId: UUID?
    @Published private(set) var clickedProfileUsage: ClaudeUsage?
    @Published private(set) var clickedProfileAPIUsage: APIUsage?

    // Track when refresh was last triggered (for distinguishing user vs auto refresh)
    private var lastRefreshTriggerTime: Date = .distantPast

    // Track last known reset times for history recording
    private var lastKnownSessionResetTime: [UUID: Date] = [:]
    private var lastKnownWeeklyResetTime: [UUID: Date] = [:]
    private var lastKnownAPIResetTime: [UUID: Date] = [:]

    // Track if a reset was just recorded to prevent duplicate periodic snapshots
    private var resetJustRecorded: [UUID: (session: Bool, weekly: Bool)] = [:]

    // Popover for beautiful SwiftUI interface
    private var popover: NSPopover?

    // Event monitor for closing popover on outside click
    private var eventMonitor: Any?

    // Debounce the status-item click that also dismisses a transient popover.
    private var lastPopoverCloseDate: Date = .distantPast
    private weak var lastPopoverCloseButton: NSStatusBarButton?

    // Detached window reference (when popover is detached)
    private var detachedWindow: NSWindow?

    // Settings window reference
    private var settingsWindow: NSWindow?
    private var settingsController:
        SettingsWindowNavigationController?

    // GitHub star prompt window reference
    private var githubPromptWindow: NSWindow?

    // Feedback prompt window reference
    private var feedbackWindow: NSWindow?

    // Track which button is currently showing the popover
    private weak var currentPopoverButton: NSStatusBarButton?
    private var currentPopoverTarget:
        ProviderStatusItemIdentity?
    private var contextMenuTarget: ProviderStatusItemIdentity?

    private let dataStore = DataStore.shared
    private let networkMonitor = NetworkMonitor.shared
    private let profileManager: ProfileManager
    private let providerUIDependencies: ProviderUIDependencies
    private let autoStartService = AutoStartSessionService.shared
    private let refreshRuntime: UsageRefreshRuntime
    private var refreshEventObserver: UUID?
    private var refreshPresentedEventObserver: UUID?
    private var refreshFailureObserver: UUID?
    private var refreshBatchObserver: UUID?
    private var presentationEpoch: UInt64 = 0
    private var hasCleanedUpResources = false
    private lazy var refreshSideEffectRouter =
        RefreshSideEffectRouter(
            hooks: .init(
                recordNormalized: { event, report in
                    UsageHistoryService.shared
                        .recordNormalizedReport(
                            report,
                            for: event.identity.profileID,
                            providerID:
                                event.identity.providerID,
                            recordedAt: event.committedAt
                        )
                },
                recordClaude: { [weak self] event, usage in
                    self?.recordAcceptedClaude(
                        event,
                        usage: usage
                    )
                },
                writeStatusline: { event, usage in
                    guard StatuslineService.shared.isInstalled else {
                        return
                    }
                    StatuslineService.shared.writeUsageCache(
                        usage: usage,
                        profileName: event.profileName
                    )
                },
                notifyNormalized: { event, report in
                    NotificationManager.shared.checkAndNotify(
                        report: report,
                        previousReport:
                            event.previousUsage?.report,
                        profileID: event.identity.profileID,
                        profileName: event.profileName,
                        settings: event.notificationSettings,
                        now: Date()
                    )
                },
                autoSwitch: { [weak self] event, usage, profile in
                    self?.checkAutoSwitchIfNeeded(
                        usage: usage,
                        currentProfile: profile,
                        expectedProfileID:
                            event.identity.profileID,
                        expectedPresentationEpoch:
                            event.presentationContext.epoch
                    )
                },
                recordAPI: { [weak self] event, usage in
                    self?.recordAcceptedAPI(
                        event,
                        usage: usage
                    )
                },
                finalizeBatch: { [weak self] _ in
                    self?.updateAllStatusBarIcons()
                },
                recordBatchSuccess: { [weak self] _ in
                    self?.recordSuccessfulSingleBatch()
                },
                recordClaudeBatchSuccess: { _ in
                    ErrorRecovery.shared.recordSuccess(for: .api)
                },
                showBatchSuccess: { [weak self] _ in
                    self?.showSuccessNotification()
                },
                autoSwitchBatch: {
                    [weak self] result, usage, profile in
                    self?.checkAutoSwitchIfNeeded(
                        usage: usage,
                        currentProfile: profile,
                        expectedProfileID: profile.id,
                        expectedPresentationEpoch:
                            result.presentationContext.epoch
                    )
                },
                logFailure: { event, error in
                    Self.logRefreshFailure(event, error: error)
                },
                recordInteractiveFailure: { _, _ in
                    ErrorRecovery.shared.recordFailure(for: .api)
                },
                showInteractiveFailure: { _, error in
                    ErrorPresenter.shared.showAlert(for: error)
                }
            )
        )

    init(
        apiService: ClaudeAPIService,
        statusService: ClaudeStatusService,
        profileManager: ProfileManager,
        refreshRuntime: UsageRefreshRuntime? = nil,
        providerUIDependencies: ProviderUIDependencies
    ) {
        self.profileManager = profileManager
        self.providerUIDependencies = providerUIDependencies
        self.refreshRuntime = refreshRuntime
            ?? UsageRefreshRuntime.live(
                profileManager: profileManager,
                apiService: apiService,
                statusService: statusService
            )
        super.init()
        refreshEventObserver = self.refreshRuntime.eventHub.observe {
            [weak self] event in
            self?.handleCommittedRefresh(event)
        }
        refreshPresentedEventObserver =
            self.refreshRuntime.eventHub.observePresented {
                [weak self] event in
                self?.handlePresentedRefresh(event)
        }
        refreshFailureObserver =
            self.refreshRuntime.eventHub.observeFailures {
                [weak self] event in
                self?.handleFailedRefresh(event)
            }
        refreshBatchObserver =
            self.refreshRuntime.eventHub.observeBatches {
                [weak self] result in
                self?.handleCompletedRefreshBatch(result)
            }
        bindRefreshPresentation()
    }

    private func bindRefreshPresentation() {
        refreshRuntime.presentationStore.$snapshots
            .sink { [weak self] snapshots in
                guard let self else { return }
                self.profileUsagePresentations = snapshots
                ProviderMenuCatalogStore.shared.publish(
                    profiles: self.profileManager.profiles,
                    snapshots: snapshots
                )
                guard let snapshot =
                        Self.selectDisplayedUsagePresentation(
                            displayMode:
                                self.profileManager.displayMode,
                            clickedProfileID:
                                self.clickedProfileId,
                            activeProfileID:
                                self.profileManager.activeProfile?.id,
                            presentations: snapshots
                        ) else {
                    self.resetVisibleRefreshProjection()
                    return
                }
                if Self.usageProjectionTarget(
                    displayMode: self.profileManager.displayMode,
                    clickedProfileID: self.clickedProfileId,
                    snapshotProfileID: snapshot.profileID
                ) == .clickedProfile {
                    self.clickedProfileUsage =
                        snapshot.claudeUsage
                    self.clickedProfileAPIUsage =
                        snapshot.claudeAPIUsage
                } else {
                    self.usage = snapshot.claudeUsage ?? .empty
                    self.apiUsage = snapshot.claudeAPIUsage
                }
                self.applyBannerProjection(from: snapshot)
                self.updateAllStatusBarIcons()
            }
            .store(in: &cancellables)

        refreshRuntime.presentationStore.$claudeStatus
            .map(\.status)
            .sink { [weak self] in
                self?.status = $0
            }
            .store(in: &cancellables)

        refreshRuntime.presentationStore.$claudeStatus
            .compactMap {
                presentation
                    -> (UInt64, ProviderRefreshFailure)? in
                presentation.failure.map {
                    (presentation.presentationEpoch, $0)
                }
            }
            .removeDuplicates {
                $0.0 == $1.0 && $0.1 == $1.1
            }
            .sink { [weak self] epoch, failure in
                guard let self,
                      self.refreshRuntime.presentationContext.epoch
                        == epoch else {
                    return
                }
                let error = Self.appError(for: failure)
                ErrorLogger.shared.log(error, severity: .info)
                LoggingService.shared.log(
                    "MenuBarManager: Claude status refresh failed"
                )
            }
            .store(in: &cancellables)
    }

    private func applyBannerProjection(
        from snapshot: PresentationSnapshot?
    ) {
        isRefreshing = snapshot?.activity.isInFlight ?? false
        lastSuccessfulRefreshTime = snapshot?.lastSuccessfulAt
        consecutiveRefreshFailures =
            snapshot?.currentFailure?.consecutiveCount ?? 0
        hasCredentialError =
            snapshot?.currentFailure?.isCredentialFailure ?? false
        lastRefreshError = snapshot?.currentFailure.map {
            String(describing: $0.kind)
        }
        lastRefreshFailureKind = snapshot?.currentFailure?.kind
        lastRefreshFailureRetryAt =
            snapshot?.currentFailure?.retryNotBefore
    }

    private func activateRefreshPresentation() {
        presentationEpoch &+= 1
        let visibleProfiles: [Profile]
        if profileManager.displayMode == .multi {
            visibleProfiles = profileManager.profiles.filter(
                \.isSelectedForDisplay
            )
        } else {
            visibleProfiles = [profileManager.activeProfile]
                .compactMap { $0 }
            clickedProfileId = nil
            clickedProfileUsage = nil
            clickedProfileAPIUsage = nil
        }
        let visibleProfileIDs = Set(visibleProfiles.map(\.id))
        if profileManager.displayMode == .multi,
           let clickedProfileId,
           !visibleProfileIDs.contains(clickedProfileId) {
            self.clickedProfileId = nil
            clickedProfileUsage = nil
            clickedProfileAPIUsage = nil
        }
        refreshRuntime.activate(
            profiles: profileManager.profiles,
            focusedProfileID:
                profileManager.displayMode == .multi
                    ? clickedProfileId
                        ?? profileManager.activeProfile?.id
                    : profileManager.activeProfile?.id,
            visibleProfileIDs: visibleProfileIDs,
            epoch: presentationEpoch,
            mode: profileManager.displayMode == .multi
                ? .multi
                : .single
        )
    }

    private func resetVisibleRefreshProjection() {
        if profileManager.displayMode == .multi,
           clickedProfileId != nil {
            clickedProfileUsage = nil
            clickedProfileAPIUsage = nil
        } else {
            usage = .empty
            apiUsage = nil
        }
        isRefreshing = false
        lastSuccessfulRefreshTime = nil
        consecutiveRefreshFailures = 0
        hasCredentialError = false
        lastRefreshError = nil
        lastRefreshFailureKind = nil
        lastRefreshFailureRetryAt = nil
    }

    private func canAttemptUsageRefresh(_ profile: Profile) -> Bool {
        switch profile.providerConfiguration {
        case .claude:
            return profile.hasUsageCredentials
        case .codex(let configuration):
            return configuration.linkedHome != nil
                && refreshRuntime.registry.isRefreshEnabled(
                    for: .codex
                )
        }
    }

    private func effectiveIconConfiguration(
        for profile: Profile
    ) -> MenuBarIconConfiguration {
        profile.iconConfig.adaptedForProvider(profile.providerID)
    }

    nonisolated static func usageProjectionTarget(
        displayMode: ProfileDisplayMode,
        clickedProfileID: UUID?,
        snapshotProfileID: UUID
    ) -> UsageProjectionTarget {
        displayMode == .multi
            && clickedProfileID == snapshotProfileID
            ? .clickedProfile
            : .primary
    }

    func usagePresentation(
        for profileID: UUID
    ) -> PresentationSnapshot? {
        profileUsagePresentations[profileID]
    }

    var displayedUsagePresentation: PresentationSnapshot? {
        Self.selectDisplayedUsagePresentation(
            displayMode: profileManager.displayMode,
            clickedProfileID: clickedProfileId,
            activeProfileID: profileManager.activeProfile?.id,
            presentations: profileUsagePresentations
        )
    }

    nonisolated static func selectDisplayedUsagePresentation(
        displayMode: ProfileDisplayMode,
        clickedProfileID: UUID?,
        activeProfileID: UUID?,
        presentations: [UUID: PresentationSnapshot]
    ) -> PresentationSnapshot? {
        switch displayMode {
        case .single:
            guard let activeProfileID else { return nil }
            return presentations[activeProfileID]
        case .multi:
            if let clickedProfileID {
                return presentations[clickedProfileID]
            }
            guard let activeProfileID else { return nil }
            return presentations[activeProfileID]
        }
    }

    /// Changes which profile's data the popover displays, without touching
    /// activation state for either provider. The header's profile switcher
    /// and the "Active accounts" chips both call this — selecting or
    /// tapping a profile there is a pure view change; the only way to
    /// change which profile is *active* for a provider remains the
    /// explicit "Make Active" affordance / context menu, which continues
    /// to call `ProfileManager.activateProfile(_:)` directly.
    func setViewedProfile(_ id: UUID) {
        guard profileManager.profiles.contains(where: { $0.id == id }) else {
            return
        }
        clickedProfileId = id
        let snapshot = refreshRuntime.presentationStore.snapshot(for: id)
        clickedProfileUsage = snapshot?.claudeUsage
        clickedProfileAPIUsage = snapshot?.claudeAPIUsage
        applyBannerProjection(from: snapshot)
    }

    static func popoverUsage(
        clickedProfileID: UUID?,
        clickedProfileUsage: ClaudeUsage?,
        activeProfileUsage: ClaudeUsage
    ) -> ClaudeUsage {
        guard clickedProfileID != nil else {
            return activeProfileUsage
        }
        return clickedProfileUsage ?? .empty
    }

    static func popoverAPIUsage(
        clickedProfileID: UUID?,
        clickedProfileAPIUsage: APIUsage?,
        activeProfileAPIUsage: APIUsage?
    ) -> APIUsage? {
        guard clickedProfileID != nil else {
            return activeProfileAPIUsage
        }
        return clickedProfileAPIUsage
    }

    private var hasRefreshableVisibleProfile: Bool {
        if profileManager.displayMode == .multi {
            return profileManager.profiles.contains {
                $0.isSelectedForDisplay
                    && canAttemptUsageRefresh($0)
            }
        }
        return profileManager.activeProfile.map(
            canAttemptUsageRefresh
        ) ?? false
    }

    private func handleCommittedRefresh(
        _ event: AcceptedUsageRefreshEvent
    ) {
        refreshSideEffectRouter.committed(event)
    }

    private func handlePresentedRefresh(
        _ event: AcceptedUsageRefreshEvent
    ) {
        guard Self.isCurrentRefreshInput(
            eventInputGeneration: event.inputGeneration,
            eventInvocationOrder: event.invocationOrder,
            currentInputGeneration:
                refreshRuntime.inputLedger.generation(
                    for: event.identity.profileID
                ),
            currentInvocationOrder:
                refreshRuntime.inputLedger.invocationOrder(
                    for: event.identity.profileID
                )
        ) else {
            return
        }
        refreshSideEffectRouter.presented(
            event,
            currentContext: refreshRuntime.presentationContext,
            activeProfile: profileManager.activeProfile
        )
    }

    private func handleCompletedRefreshBatch(
        _ result: UsageRefreshBatchResult
    ) {
        let activeProfile = profileManager.activeProfile
        refreshSideEffectRouter.finished(
            result,
            currentContext: refreshRuntime.presentationContext,
            latestInvocationOrder:
                refreshRuntime.inputLedger.latestInvocationOrder,
            activeProfile: activeProfile,
            activeSnapshot: activeProfile.flatMap {
                refreshRuntime.presentationStore.snapshot(
                    for: $0.id
                )
            }
        )
    }

    private func handleFailedRefresh(
        _ event: UsageRefreshFailureEvent
    ) {
        guard Self.isCurrentRefreshInput(
            eventInputGeneration: event.inputGeneration,
            eventInvocationOrder: event.invocationOrder,
            currentInputGeneration:
                refreshRuntime.inputLedger.generation(
                    for: event.identity.profileID
                ),
            currentInvocationOrder:
                refreshRuntime.inputLedger.invocationOrder(
                    for: event.identity.profileID
                )
        ) else {
            return
        }
        let appError = Self.appError(
            for: event.failure,
            providerID: event.identity.providerID
        )
        refreshSideEffectRouter.failed(
            event,
            error: appError,
            currentContext: refreshRuntime.presentationContext,
            activeProfileID: profileManager.activeProfile?.id
        )
    }

    private func recordAcceptedClaude(
        _ event: AcceptedUsageRefreshEvent,
        usage newUsage: ClaudeUsage
    ) {
        let previous = event.previousUsage?.claudeUsage
        checkAndRecordSessionReset(
            profileId: event.identity.profileID,
            previousUsage: previous,
            newUsage: newUsage
        )
        checkAndRecordWeeklyReset(
            profileId: event.identity.profileID,
            previousUsage: previous,
            newUsage: newUsage
        )
        let resetFlags =
            resetJustRecorded[event.identity.profileID]
            ?? (session: false, weekly: false)
        let periodicComponents =
            Self.periodicHistoryComponents(
                sessionResetRecorded: resetFlags.session,
                weeklyResetRecorded: resetFlags.weekly
            )
        if periodicComponents.contains(.session) {
            UsageHistoryService.shared.recordSessionPeriodic(
                for: event.identity.profileID,
                usage: newUsage
            )
        }
        if periodicComponents.contains(.weekly) {
            UsageHistoryService.shared.recordWeeklyPeriodic(
                for: event.identity.profileID,
                usage: newUsage
            )
        }
        resetJustRecorded[event.identity.profileID] = (
            session: false,
            weekly: false
        )
    }

    private func recordAcceptedAPI(
        _ event: AcceptedUsageRefreshEvent,
        usage newUsage: APIUsage
    ) {
        checkAndRecordBillingCycleReset(
            profileId: event.identity.profileID,
            previousUsage: event.previousUsage?.apiUsage,
            newUsage: newUsage
        )
    }

    private func recordSuccessfulSingleBatch() {
        consecutiveRefreshFailures = 0
        lastRefreshError = nil
        lastRefreshFailureKind = nil
        lastRefreshFailureRetryAt = nil
        hasCredentialError = false
        lastSuccessfulRefreshTime = Date()
    }

    private static func logRefreshFailure(
        _ event: UsageRefreshFailureEvent,
        error appError: AppError
    ) {
        switch event.component {
        case .claudeAPI:
            ErrorLogger.shared.log(appError, severity: .info)
            LoggingService.shared.log(
                "MenuBarManager: Claude API billing refresh failed"
            )
        case .providerUsage, .capture, .persistence:
            guard event.identity.providerID == .claude else {
                ErrorLogger.shared.log(appError, severity: .info)
                LoggingService.shared.log(
                    "MenuBarManager: Provider refresh failed (\(event.failure.kind))"
                )
                return
            }
            ErrorLogger.shared.log(appError, severity: .error)
            LoggingService.shared.logError(
                "MenuBarManager: Claude usage refresh failed (\(event.failure.kind))"
            )
        }
    }

    nonisolated static func isCurrentFailureEvent(
        _ event: UsageRefreshFailureEvent,
        presentationContext: UsagePresentationContext,
        activeProfileID: UUID?
    ) -> Bool {
        event.presentationContext == presentationContext
            && event.identity.profileID == activeProfileID
    }

    nonisolated static func isCurrentRefreshInput(
        eventInputGeneration: UInt64,
        eventInvocationOrder: UInt64,
        currentInputGeneration: UInt64,
        currentInvocationOrder: UInt64
    ) -> Bool {
        eventInputGeneration == currentInputGeneration
            && eventInvocationOrder == currentInvocationOrder
    }

    nonisolated static func
        shouldApplyInteractiveRefreshSideEffects(
            eventContext: UsagePresentationContext,
            currentContext: UsagePresentationContext,
            eventProfileID: UUID,
            activeProfileID: UUID?
        ) -> Bool {
        eventContext.mode == .single
            && eventContext == currentContext
            && eventProfileID == activeProfileID
    }

    nonisolated static func periodicHistoryComponents(
        sessionResetRecorded: Bool,
        weeklyResetRecorded: Bool
    ) -> Set<PeriodicHistoryComponent> {
        var components = Set<PeriodicHistoryComponent>()
        if !sessionResetRecorded {
            components.insert(.session)
        }
        if !weeklyResetRecorded {
            components.insert(.weekly)
        }
        return components
    }

    static func appError(
        for failure: ProviderRefreshFailure,
        providerID: ProviderID? = nil
    ) -> AppError {
        if providerID == .codex,
           let presentation =
            ProviderErrorMapper.presentation(for: failure) {
            return .provider(presentation)
        }
        let code: ErrorCode
        if let legacyErrorCode = failure.legacyErrorCode {
            code = legacyErrorCode
        } else {
            switch failure.kind {
            case .unauthenticated:
                code = .apiUnauthorized
            case .timedOut:
                code = .networkTimeout
            case .malformedResponse, .protocolMismatch:
                code = .apiInvalidResponse
            case .persistence:
                // Durable commit rejection is provider-neutral. Never
                // relabel it as a transient provider outage.
                return .storageWriteFailed()
            default:
                code = .apiGenericError
            }
        }
        switch code {
        case .sessionKeyNotFound:
            return .sessionKeyNotFound()
        case .sessionKeyInvalid:
            return .sessionKeyInvalid(
                reason: "Typed refresh credential validation failed"
            )
        case .sessionKeyExpired:
            return AppError(
                code: .sessionKeyExpired,
                message: "error.session_key_invalid".localized,
                technicalDetails:
                    "Typed refresh credential validation expired",
                isRecoverable: true,
                recoverySuggestion:
                    "error.session_key_not_found.suggestion".localized
            )
        case .apiUnauthorized:
            return .apiUnauthorized()
        case .apiRateLimited:
            return .apiRateLimited()
        case .apiServerError:
            // The typed refresh boundary deliberately discards raw HTTP
            // payloads. Use a canonical safe representative status.
            return .apiServerError(statusCode: 500)
        case .networkTimeout:
            return .networkTimeout()
        case .networkUnavailable:
            return .networkUnavailable()
        case .storageWriteFailed:
            return .storageWriteFailed()
        default:
            return AppError(
                code: code,
                message:
                    "Usage refresh failed (\(failure.kind))",
                isRecoverable: failure.isRecoverable
            )
        }
    }

    // Combine cancellables for profile observation
    private var cancellables = Set<AnyCancellable>()

    // Track if we've handled the first profile switch (to allow returning to initial profile)
    private var hasHandledFirstProfileSwitch = false

    // Track which profiles have already triggered auto-switch (prevents repeated firing)
    private var autoSwitchedProfileIds: Set<UUID> = []

    // Observer for refresh interval changes
    private var refreshIntervalObserver: NSKeyValueObservation?

    // Observer for icon style changes
    private var iconStyleObserver: NSObjectProtocol?

    // Observer for icon configuration changes
    private var iconConfigObserver: NSObjectProtocol?

    // Observer for credential changes (add, remove, update)
    private var credentialsObserver: NSObjectProtocol?

    // Observers for provider relinking and profile deletion fences
    private var providerConfigurationObserver: NSObjectProtocol?
    private var profileDeletionStartedObserver: NSObjectProtocol?
    private var profileDeletionCompletedObserver: NSObjectProtocol?

    // Observer for display mode changes (single/multi profile)
    private var displayModeObserver: NSObjectProtocol?

    // Observer for multi-profile selection and visual configuration changes
    private var multiProfileConfigObserver: NSObjectProtocol?

    // Observer for screen/display changes (headless mode support)
    private var screenObserver: NSObjectProtocol?

    // Observer for wake-from-sleep
    private var wakeObserver: NSObjectProtocol?
    private var lastAutoRefreshTime: Date = .distantPast

    // MARK: - Image Caching (CPU Optimization)
    private var cachedImage: NSImage?
    private var cachedImageKey: String = ""
    private var updateDebounceTimer: Timer?
    private var cachedIsDarkMode: Bool = false

    func setup() {
        // Initialize cached appearance to avoid layout recursion
        cachedIsDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        // Observe profile changes - CRITICAL: Set up before anything else
        observeProfileChanges()
        activateRefreshPresentation()

        // Initialize status bar UI manager
        statusBarUIManager = StatusBarUIManager()
        statusBarUIManager?.delegate = self

        // Check if we should use multi-profile mode
        if profileManager.displayMode == .multi {
            // Multi-profile mode - setup with selected profiles
            setupMultiProfileMode(refreshTrigger: nil)
        } else {
            // Single profile mode - setup with active profile's config
            if let profile = profileManager.activeProfile,
               profile.providerID != .claude {
                updateProviderSingleDisplay(
                    profile: profile,
                    config: effectiveIconConfiguration(for: profile)
                )
            } else {
                let config = profileManager.activeProfile.map {
                    effectiveIconConfiguration(for: $0)
                } ?? .default
                let canRefresh = profileManager.activeProfile.map(
                    canAttemptUsageRefresh
                ) ?? false

                // Preserve the characterized Claude placeholder and autosave
                // behavior when usage credentials are unavailable.
                let displayConfig: MenuBarIconConfiguration
                if !canRefresh {
                    displayConfig = MenuBarIconConfiguration(
                        colorMode: config.colorMode,
                        singleColorHex: config.singleColorHex,
                        showIconNames: config.showIconNames,
                        metrics: config.metrics.map { metric in
                            var updatedMetric = metric
                            updatedMetric.isEnabled = false
                            return updatedMetric
                        }
                    )
                } else {
                    displayConfig = config
                }

                statusBarUIManager?.setup(
                    target: self,
                    action: #selector(togglePopover),
                    config: displayConfig
                )
            }
        }

        // Setup popover
        setupPopover()

        // Load saved data from active profile first (provides immediate feedback)
        // BUT only if profile has usage credentials - CLI alone can't show usage
        if let profile = profileManager.activeProfile {
            if canAttemptUsageRefresh(profile) {
                // Profile has usage credentials - show saved usage data if available
                if let savedUsage = profile.claudeUsage {
                    usage = savedUsage
                }
                if let savedAPIUsage = profile.apiUsage {
                    apiUsage = savedAPIUsage
                }
            } else {
                // No usage credentials - clear any old usage data and show default logo
                usage = .empty
                apiUsage = nil
                LoggingService.shared.log("MenuBarManager: Profile has no usage credentials, showing default logo")
            }
            updateAllStatusBarIcons()
        }

        // Start network monitoring - fetch data when network is available
        networkMonitor.onNetworkAvailable = { [weak self] in
            // Only refresh if we haven't refreshed recently (avoid duplicate on startup)
            guard let self = self else { return }

            let elapsed = Date().timeIntervalSince(
                self.lastRefreshTriggerTime
            )
            let hasRefreshableProfile =
                self.hasRefreshableVisibleProfile
            guard RefreshTimingPolicy
                    .shouldRefreshForNetworkAvailability(
                        hasRefreshableProfile:
                            hasRefreshableProfile,
                        elapsedSinceLastTrigger: elapsed
                    ) else {
                if !hasRefreshableProfile {
                    LoggingService.shared.log(
                        "Skipping network-available refresh (no usage credentials)"
                    )
                } else {
                    LoggingService.shared.log(
                        "Skipping network-available refresh (too soon after last refresh)"
                    )
                }
                return
            }
            self.refreshUsage(trigger: .networkAvailable)
        }
        networkMonitor.startMonitoring()

        // Initial data fetch (with small delay for launch-at-login scenarios)
        // Only if profile has usage credentials (not just CLI)
        if hasRefreshableVisibleProfile {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.refreshUsage(trigger: .startup)
            }
        } else {
            LoggingService.shared.log("Skipping initial refresh (no usage credentials)")
        }

        // Start auto-refresh timer with active profile's interval
        startAutoRefresh()

        // Start auto-start session service (5-minute cycle for all profiles)
        autoStartService.start()

        // Observe icon configuration changes
        observeIconConfigChanges()

        // Observe session key updates
        observeCredentialChanges()
        observeProviderLifecycleChanges()

        // Observe display mode changes (single/multi profile)
        observeDisplayModeChanges()
        observeMultiProfileConfigChanges()

        // Setup headless mode observer if enabled (for Remote Desktop support)
        setupHeadlessModeObserver()

        // Setup wake-from-sleep observer for auto-refresh
        setupWakeObserver()

        // Setup global keyboard shortcuts
        setupShortcuts()
    }

    private func setupShortcuts() {
        let shortcutManager = ShortcutManager.shared
        shortcutManager.onTogglePopover = { [weak self] in
            self?.togglePopover(nil)
        }
        shortcutManager.onRefresh = { [weak self] in
            self?.refreshUsage(trigger: .manual)
        }
        shortcutManager.onOpenSettings = { [weak self] in
            self?.preferencesClicked()
        }
        shortcutManager.onNextProfile = { [weak self] in
            self?.switchToNextProfile()
        }
        shortcutManager.startListening()
    }

    func cleanup() {
        cleanupResources()
        refreshRuntime.shutdown(profiles: profileManager.profiles)
    }

    func cleanupAndWaitForTermination() async {
        cleanupResources()
        await refreshRuntime.shutdownAndWait(
            profiles: profileManager.profiles
        )
    }

    private func cleanupResources() {
        guard !hasCleanedUpResources else { return }
        hasCleanedUpResources = true
        ShortcutManager.shared.stopListening()
        refreshTimer?.invalidate()
        refreshTimer = nil
        freshnessDeadlineTimer?.invalidate()
        freshnessDeadlineTimer = nil
        networkMonitor.stopMonitoring()
        autoStartService.stop()
        profileUsagePresentations.removeAll()
        cancellables.removeAll()  // Clean up Combine subscriptions
        refreshIntervalObserver?.invalidate()
        refreshIntervalObserver = nil
        if let iconStyleObserver = iconStyleObserver {
            NotificationCenter.default.removeObserver(iconStyleObserver)
            self.iconStyleObserver = nil
        }
        if let iconConfigObserver = iconConfigObserver {
            NotificationCenter.default.removeObserver(iconConfigObserver)
            self.iconConfigObserver = nil
        }
        if let credentialsObserver = credentialsObserver {
            NotificationCenter.default.removeObserver(credentialsObserver)
            self.credentialsObserver = nil
        }
        if let providerConfigurationObserver {
            NotificationCenter.default.removeObserver(
                providerConfigurationObserver
            )
            self.providerConfigurationObserver = nil
        }
        if let profileDeletionStartedObserver {
            NotificationCenter.default.removeObserver(
                profileDeletionStartedObserver
            )
            self.profileDeletionStartedObserver = nil
        }
        if let profileDeletionCompletedObserver {
            NotificationCenter.default.removeObserver(
                profileDeletionCompletedObserver
            )
            self.profileDeletionCompletedObserver = nil
        }
        if let displayModeObserver = displayModeObserver {
            NotificationCenter.default.removeObserver(displayModeObserver)
            self.displayModeObserver = nil
        }
        if let multiProfileConfigObserver = multiProfileConfigObserver {
            NotificationCenter.default.removeObserver(multiProfileConfigObserver)
            self.multiProfileConfigObserver = nil
        }
        if let screenObserver = screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let wakeObserver = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        detachedWindow?.close()
        detachedWindow = nil
        settingsController?.window.close()
        settingsController = nil
        settingsWindow = nil
        statusItem = nil
        statusBarUIManager?.cleanup()
        statusBarUIManager = nil
        contextMenuTarget = nil
        currentPopoverTarget = nil

        // Clean up history tracking dictionaries to prevent memory leaks
        lastKnownSessionResetTime.removeAll()
        lastKnownWeeklyResetTime.removeAll()
        lastKnownAPIResetTime.removeAll()
        resetJustRecorded.removeAll()
        if let refreshEventObserver {
            refreshRuntime.eventHub.removeObserver(refreshEventObserver)
            self.refreshEventObserver = nil
        }
        if let refreshPresentedEventObserver {
            refreshRuntime.eventHub.removeObserver(
                refreshPresentedEventObserver
            )
            self.refreshPresentedEventObserver = nil
        }
        if let refreshFailureObserver {
            refreshRuntime.eventHub.removeObserver(
                refreshFailureObserver
            )
            self.refreshFailureObserver = nil
        }
        if let refreshBatchObserver {
            refreshRuntime.eventHub.removeObserver(
                refreshBatchObserver
            )
            self.refreshBatchObserver = nil
        }
    }

    /// Cleans up tracking data for a specific profile (called when profile is deleted)
    func cleanupProfile(_ profileId: UUID) {
        lastKnownSessionResetTime.removeValue(forKey: profileId)
        lastKnownWeeklyResetTime.removeValue(forKey: profileId)
        lastKnownAPIResetTime.removeValue(forKey: profileId)
        resetJustRecorded.removeValue(forKey: profileId)
        autoSwitchedProfileIds.remove(profileId)
    }

    // MARK: - Profile Observation

    private func observeProfileChanges() {
        // Store the initial profile ID to skip only the very first startup update
        let initialProfileId = profileManager.activeProfile?.id

        // Observe active profile changes
        profileManager.$activeProfile
            .removeDuplicates { oldProfile, newProfile in
                // Only trigger if the profile ID actually changed
                let result = oldProfile?.id == newProfile?.id
                if !result {
                    LoggingService.shared.log("MenuBarManager: Profile ID changed from \(oldProfile?.id.uuidString ?? "nil") to \(newProfile?.id.uuidString ?? "nil")")
                }
                return result
            }
            .dropFirst()  // Skip the initial value
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newProfile in
                guard let self else { return }
                self.activateRefreshPresentation()
                guard let profile = newProfile else { return }

                // Skip ONLY if this is the startup profile AND we haven't switched yet
                if !self.hasHandledFirstProfileSwitch && profile.id == initialProfileId {
                    LoggingService.shared.log("MenuBarManager: Skipping initial startup profile update to: \(profile.name)")
                    self.hasHandledFirstProfileSwitch = true
                    return
                }

                // Mark that we've handled at least one profile switch
                self.hasHandledFirstProfileSwitch = true

                self.handleProfileSwitch(to: profile)
            }
            .store(in: &cancellables)

        LoggingService.shared.log("MenuBarManager: Observing profile changes (initial: \(initialProfileId?.uuidString ?? "nil"))")
    }

    private func handleProfileSwitch(to profile: Profile) {
        LoggingService.shared.log("MenuBarManager: Handling profile switch to: \(profile.name)")
        closeDetachedWindowIfInvalidated(
            activatedProfileID: profile.id
        )

        // 1. Load saved data from new profile (for immediate display)
        if let savedUsage = profile.claudeUsage {
            usage = savedUsage
        } else {
            usage = .empty
        }

        if let savedAPIUsage = profile.apiUsage {
            apiUsage = savedAPIUsage
        } else {
            apiUsage = nil
        }

        // 2. Update refresh interval with profile's setting
        restartAutoRefreshWithInterval(profile.refreshInterval)

        // 3. Update menu bar based on current display mode
        if profileManager.displayMode == .multi {
            // Multi-profile mode: update button images in-place — do NOT call setupMultiProfileMode()
            // here because that tears down and recreates all NSStatusItems, which causes macOS to
            // assign new internal window IDs even when autosaveNames are identical.  Tools like
            // Bartender / Ice track items by those IDs, so rebuilding defeats the static-ID goal.
            // The set of displayed profiles hasn't changed; only the data needs refreshing.
            updateAllStatusBarIcons()
        } else {
            // Single profile mode - update menu bar configuration
            updateMenuBarDisplay(
                with: effectiveIconConfiguration(for: profile)
            )
        }

        // 4. Recreate popover with new profile data
        recreatePopover()

        // 5. Trigger immediate refresh ONLY if profile has usage credentials
        if canAttemptUsageRefresh(profile) {
            self.lastRefreshTriggerTime = Date()
            refreshUsage(trigger: .profileActivation)
        } else {
            LoggingService.shared.log("MenuBarManager: Skipping refresh for profile without usage credentials")
        }
    }

    private func recreatePopover() {
        // Close existing popover if open
        if popover?.isShown == true {
            closePopover()
        }

        // Recreate popover with fresh content
        let newPopover = NSPopover()
        newPopover.contentSize = Constants.WindowSizes.popoverSize
        newPopover.behavior = .semitransient
        // Native animated resizing recurses indefinitely with preferredContentSize
        // on macOS 26/27. PopoverContentView provides a fixed-size content animation.
        newPopover.animates = false
        newPopover.delegate = self
        newPopover.contentViewController = createContentViewController()

        self.popover = newPopover

        LoggingService.shared.log("MenuBarManager: Popover recreated for profile switch")
    }

    private func closeDetachedWindowIfInvalidated(
        activatedProfileID: UUID? = nil,
        changedProfileID: UUID? = nil,
        displayModeChanged: Bool = false,
        selectedProfileIDs: Set<UUID>? = nil
    ) {
        let hasPresentedSurface =
            detachedWindow != nil || popover?.isShown == true
        guard hasPresentedSurface,
              ProviderPopoverDetachmentLifecycle
                .shouldCloseDetachedWindow(
                    target: currentPopoverTarget,
                    profiles: profileManager.profiles,
                    activatedProfileID: activatedProfileID,
                    changedProfileID: changedProfileID,
                    displayModeChanged: displayModeChanged,
                    selectedProfileIDs: selectedProfileIDs
                ) else {
            return
        }
        if popover?.isShown == true {
            closePopover()
        }
        if let detachedWindow {
            detachedWindow.close()
            self.detachedWindow = nil
        }
        currentPopoverTarget = nil
    }

    private func updateMenuBarDisplay(with config: MenuBarIconConfiguration) {
        // Skip if in multi-profile mode - this method is for single profile mode only
        guard profileManager.displayMode == .single else {
            LoggingService.shared.log("MenuBarManager: Skipping updateMenuBarDisplay (in multi-profile mode)")
            return
        }

        if let profile = profileManager.activeProfile,
           profile.providerID != .claude {
            updateProviderSingleDisplay(
                profile: profile,
                config: config.adaptedForProvider(profile.providerID)
            )
            return
        }

        // Check if active profile has usage credentials (not just CLI)
        let canRefresh = profileManager.activeProfile.map(
            canAttemptUsageRefresh
        ) ?? false

        // If no usage credentials, use an empty config (will show default logo)
        let displayConfig: MenuBarIconConfiguration
        if !canRefresh {
            // Create config with no enabled metrics (will trigger default logo)
            displayConfig = MenuBarIconConfiguration(
                colorMode: config.colorMode,
                singleColorHex: config.singleColorHex,
                showIconNames: config.showIconNames,
                metrics: config.metrics.map { metric in
                    var updatedMetric = metric
                    updatedMetric.isEnabled = false
                    return updatedMetric
                }
            )
        } else {
            displayConfig = config
        }

        statusBarUIManager?.updateConfiguration(
            target: self,
            action: #selector(togglePopover),
            config: displayConfig
        )
        if let activeProfile = profileManager.activeProfile,
           activeProfile.providerID == .claude {
            // Retained legacy buttons must capture the newly active identity
            // before the next run-loop turn can accept a click.
            statusBarUIManager?.bindLegacySingleProfile(activeProfile)
        }

        // Defer icon update to next run loop iteration to let NSStatusBar finalize layout
        DispatchQueue.main.async { [weak self] in
            self?.updateAllStatusBarIcons()
        }
    }

    private func updateProviderSingleDisplay(
        profile: Profile,
        config: MenuBarIconConfiguration
    ) {
        let now = Date()
        let presentation =
            ProviderMenuPresentationBuilder.presentation(
                profile: profile,
                snapshot: profileUsagePresentations[profile.id],
                now: now,
                isActive: true
            )
        statusBarUIManager?.updateProviderSingle(
            presentation: presentation,
            target: self,
            action: #selector(togglePopover),
            config: config
        )
        scheduleFreshnessDeadline(for: [presentation], now: now)
    }

    private func restartAutoRefreshWithInterval(_ interval: TimeInterval) {
        refreshTimer?.invalidate()
        refreshTimer = nil

        let timing = RefreshTimingPolicy(interval: interval)
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: timing.interval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleAutomaticTimerFire()
            }
        }
        refreshTimer?.tolerance = timing.tolerance

        LoggingService.shared.log("Updated refresh interval to \(interval)s")
    }

    private func setupPopover() {
        let popover = NSPopover()
        popover.contentSize = Constants.WindowSizes.popoverSize
        popover.behavior = .semitransient  // Changed to allow detaching
        popover.animates = false
        popover.delegate = self

        popover.contentViewController = createContentViewController()
        self.popover = popover
    }

    private func createContentViewController() -> NSHostingController<PopoverContentView> {
        // Create SwiftUI content view
        let contentView = PopoverContentView(
            manager: self,
            profileManager: profileManager,
            onRefresh: { [weak self] in
                guard let self else { return }
                self.refreshPopover(
                    target: self.popoverActionTarget()
                )
            },
            onManageProfiles: { [weak self] in
                guard let self else { return }
                self.openPopoverManageProfiles(
                    target: self.popoverActionTarget()
                )
            },
            onPreferences: { [weak self] in
                guard let self else { return }
                self.openPopoverSettings(
                    target: self.popoverActionTarget()
                )
            }
        )

        let hostingController = NSHostingController(rootView: contentView)
        hostingController.preferredContentSize = Constants.WindowSizes.popoverSize
        hostingController.sizingOptions = .preferredContentSize
        return hostingController
    }

    private func popoverActionTarget() -> ProviderStatusItemIdentity? {
        if let currentPopoverTarget {
            return currentPopoverTarget
        }
        let profileID = profileManager.displayMode == .multi
            ? clickedProfileId ?? profileManager.activeProfile?.id
            : profileManager.activeProfile?.id
        guard let profileID,
              let profile = profileManager.profiles.first(
                where: { $0.id == profileID }
              ) else {
            return nil
        }
        return ProviderStatusItemIdentity(
            profileID: profile.id,
            providerID: profile.providerID,
            providerRevision: profile.providerRevision,
            metricID: nil
        )
    }

    private func refreshPopover(
        target: ProviderStatusItemIdentity?
    ) {
        guard let target else { return }
        capturedTargetRouter().route(.refresh, target: target)
    }

    private func openPopoverSettings(
        target: ProviderStatusItemIdentity?
    ) {
        guard let target else { return }
        capturedTargetRouter().route(
            .popoverSettings,
            target: target
        )
    }

    private func openPopoverManageProfiles(
        target: ProviderStatusItemIdentity?
    ) {
        guard let target else { return }
        capturedTargetRouter().route(
            .manageProfiles,
            target: target
        )
    }

    nonisolated static func popoverSettingsDestination(
        for target: ProviderStatusItemIdentity
    ) -> SettingsNavigationDestination {
        ProviderCapturedTargetActionRouter
            .popoverSettingsDestination(for: target)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if Self.isContextMenuEvent(NSApp.currentEvent?.type) {
            showContextMenu(for: sender as? NSStatusBarButton)
            return
        }

        // Determine which button was clicked
        let clickedButton: NSStatusBarButton?
        if let button = sender as? NSStatusBarButton {
            clickedButton = button
        } else if statusBarUIManager?.isInMultiProfileMode == true,
                  let activeId = profileManager.activeProfile?.id,
                  let activeButton = statusBarUIManager?.button(for: activeId) {
            // Multi-profile mode: use the active profile's button
            clickedButton = activeButton
        } else {
            // Single profile mode: fallback to primary button
            clickedButton = statusBarUIManager?.primaryButton
        }

        guard let button = clickedButton else { return }
        guard let identity =
                ProviderStatusItemReconciliation.resolvedIdentity(
                    captured:
                        statusBarUIManager?.statusIdentity(for: button),
                    fallbackProfile: profileManager.activeProfile
                ) else {
            return
        }
        let routed = capturedTargetRouter(
            openPopover: { [weak self] target, profile in
                self?.toggleValidatedPopover(
                    from: button,
                    target: target,
                    profile: profile
                )
            }
        ).route(.openPopover, target: identity)
        if !routed {
            LoggingService.shared.logWarning(
                "Ignored status-item action for stale provider identity"
            )
        }
    }

    private func toggleValidatedPopover(
        from button: NSStatusBarButton,
        target: ProviderStatusItemIdentity,
        profile: Profile
    ) {
        // In multi-profile mode, determine which profile was clicked
        if statusBarUIManager?.isInMultiProfileMode == true,
           profileManager.profiles.contains(where: {
               $0.id == profile.id
           }) {
            clickedProfileId = profile.id
            let snapshot = refreshRuntime.presentationStore.snapshot(
                for: profile.id
            )
            clickedProfileUsage = snapshot?.claudeUsage
            clickedProfileAPIUsage = snapshot?.claudeAPIUsage
            applyBannerProjection(from: snapshot)
            LoggingService.shared.log("Multi-profile popover: showing data for '\(profile.name)'")
        } else {
            // Single profile mode - use active profile
            clickedProfileId = nil
            clickedProfileUsage = nil
            clickedProfileAPIUsage = nil
        }

        // If there's a detached window, close it
        if let window = detachedWindow {
            window.close()
            detachedWindow = nil
            currentPopoverButton = nil
            currentPopoverTarget = nil
            return
        }

        // Otherwise toggle the popover
        if let popover = popover {
            if popover.isShown {
                // Check if clicking the same button or a different one
                if currentPopoverButton === button {
                    // Same button - close the popover
                    closePopover()
                } else {
                    // Different button - close current and show at new position
                    // Close synchronously. Replacing the hosting controller while an
                    // asynchronous close is in progress can trigger BAD_ACCESS.
                    popover.close()
                    stopMonitoringForOutsideClicks()
                    NSApp.activate(ignoringOtherApps: true)
                    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                    currentPopoverButton = button
                    currentPopoverTarget = target
                    startMonitoringForOutsideClicks()
                }
            } else {
                // Treat the status-item click that dismissed this same popover as
                // a close, rather than immediately bouncing the popover open again.
                if Self.shouldSuppressPopoverOpen(
                    button: button,
                    lastButton: lastPopoverCloseButton,
                    lastCloseDate: lastPopoverCloseDate
                ) {
                    return
                }

                // Stop any existing monitor first
                stopMonitoringForOutsideClicks()
                // Update content view controller for current profile data
                popover.contentViewController = createContentViewController()
                NSApp.activate(ignoringOtherApps: true)
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                currentPopoverButton = button
                currentPopoverTarget = target
                startMonitoringForOutsideClicks()
            }
        }
    }

    nonisolated static func isContextMenuEvent(
        _ eventType: NSEvent.EventType?
    ) -> Bool {
        eventType == .rightMouseUp
    }

    static func shouldSuppressPopoverOpen(
        button: AnyObject,
        lastButton: AnyObject?,
        lastCloseDate: Date,
        now: Date = Date()
    ) -> Bool {
        guard let lastButton, button === lastButton else { return false }
        return now.timeIntervalSince(lastCloseDate) < 0.25
    }

    static func makeContextMenu(
        target: AnyObject,
        refreshAction: Selector,
        settingsAction: Selector,
        quitAction: Selector
    ) -> NSMenu {
        let menu = NSMenu()

        let refreshItem = NSMenuItem(
            title: "common.refresh".localized,
            action: refreshAction,
            keyEquivalent: ""
        )
        refreshItem.target = target
        menu.addItem(refreshItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "common.settings".localized,
            action: settingsAction,
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = target
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(
            title: "common.quit".localized,
            action: quitAction,
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = target
        menu.addItem(quitItem)

        return menu
    }

    static func makeProviderContextMenu(
        presentation: ProviderMenuPresentation,
        target: AnyObject,
        activateAction: Selector,
        refreshAction: Selector,
        accountSettingsAction: Selector,
        appearanceAction: Selector,
        manageProfilesAction: Selector,
        quitAction: Selector
    ) -> NSMenu {
        let menu = NSMenu()
        let heading = NSMenuItem(
            title: "\(presentation.appearance.displayName) — "
                + presentation.profileName,
            action: nil,
            keyEquivalent: ""
        )
        heading.isEnabled = false
        menu.addItem(heading)
        if presentation.actions.contains(where: {
            $0.kind == .activate
        }) {
            let activate = NSMenuItem(
                title: "menu.provider.make_active".localized,
                action: activateAction,
                keyEquivalent: ""
            )
            activate.target = target
            menu.addItem(activate)
        }
        let refresh = NSMenuItem(
            title: "common.refresh".localized,
            action: refreshAction,
            keyEquivalent: ""
        )
        refresh.target = target
        menu.addItem(refresh)
        menu.addItem(.separator())

        let account = NSMenuItem(
            title: String(
                format: "menu.provider.account".localized,
                presentation.appearance.displayName
            ),
            action: accountSettingsAction,
            keyEquivalent: ""
        )
        account.target = target
        menu.addItem(account)
        let appearance = NSMenuItem(
            title: "menu.provider.appearance".localized,
            action: appearanceAction,
            keyEquivalent: ""
        )
        appearance.target = target
        menu.addItem(appearance)
        let profiles = NSMenuItem(
            title: "menu.provider.manage_profiles".localized,
            action: manageProfilesAction,
            keyEquivalent: ""
        )
        profiles.target = target
        menu.addItem(profiles)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "common.quit".localized,
            action: quitAction,
            keyEquivalent: "q"
        )
        quit.keyEquivalentModifierMask = .command
        quit.target = target
        menu.addItem(quit)
        return menu
    }

    nonisolated static func usesLegacyContextMenu(
        for providerID: ProviderID
    ) -> Bool {
        providerID == .claude
    }

    private func showContextMenu(for button: NSStatusBarButton?) {
        guard let button, let window = button.window else { return }
        let identity =
            ProviderStatusItemReconciliation.resolvedIdentity(
                captured:
                    statusBarUIManager?.statusIdentity(for: button),
                fallbackProfile: profileManager.activeProfile
            )
        guard let identity,
              let profile = currentProfile(for: identity) else {
            return
        }
        contextMenuTarget = identity
        let presentation =
            ProviderMenuPresentationBuilder.presentation(
                profile: profile,
                snapshot: profileUsagePresentations[profile.id],
                now: Date(),
                isActive: profileManager.isActive(profile)
            )
        let menu: NSMenu
        if Self.usesLegacyContextMenu(for: profile.providerID) {
            menu = Self.makeContextMenu(
                target: self,
                refreshAction: #selector(contextMenuRefresh),
                settingsAction: #selector(contextMenuLegacySettings),
                quitAction: #selector(contextMenuQuit)
            )
        } else {
            menu = Self.makeProviderContextMenu(
                presentation: presentation,
                target: self,
                activateAction: #selector(contextMenuActivate),
                refreshAction: #selector(contextMenuRefresh),
                accountSettingsAction:
                    #selector(contextMenuProviderSettings),
                appearanceAction: #selector(contextMenuAppearance),
                manageProfilesAction:
                    #selector(contextMenuManageProfiles),
                quitAction: #selector(contextMenuQuit)
            )
        }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = window.convertToScreen(buttonRect)
        menu.popUp(positioning: nil, at: screenRect.origin, in: nil)
    }

    @objc private func contextMenuRefresh() {
        guard let target = contextMenuTarget else { return }
        capturedTargetRouter().route(.refresh, target: target)
    }

    @objc private func contextMenuActivate() {
        guard let target = contextMenuTarget else { return }
        capturedTargetRouter().route(.activate, target: target)
    }

    @objc private func contextMenuProviderSettings() {
        guard let target = contextMenuTarget else { return }
        capturedTargetRouter().route(
            .providerAccount,
            target: target
        )
    }

    @objc private func contextMenuLegacySettings() {
        guard let target = contextMenuTarget else { return }
        capturedTargetRouter().route(
            .legacySettings,
            target: target
        )
    }

    @objc private func contextMenuAppearance() {
        guard let target = contextMenuTarget else { return }
        capturedTargetRouter().route(
            .appearance,
            target: target
        )
    }

    @objc private func contextMenuManageProfiles() {
        guard let target = contextMenuTarget else { return }
        capturedTargetRouter().route(
            .manageProfiles,
            target: target
        )
    }

    @objc private func contextMenuQuit() {
        Self.performContextMenuQuit {
            NSApplication.shared.terminate(nil)
        }
    }

    nonisolated static func performContextMenuQuit(
        terminate: () -> Void
    ) {
        terminate()
    }

    private func currentProfile(
        for target: ProviderStatusItemIdentity
    ) -> Profile? {
        capturedTargetRouter().currentProfile(for: target)
    }

    private func capturedTargetRouter(
        openPopover:
            ProviderCapturedTargetActionRouter.TargetSink? = nil,
        detachPopover:
            ProviderCapturedTargetActionRouter.TargetSink? = nil
    ) -> ProviderCapturedTargetActionRouter {
        ProviderCapturedTargetActionRouter(
            profiles: { [weak self] in
                guard let self else { return [] }
                return Self.capturedActionProfiles(
                    displayMode: self.profileManager.displayMode,
                    activeProfile:
                        self.profileManager.activeProfile,
                    profiles: self.profileManager.profiles
                )
            },
            sinks: .init(
                openPopover: openPopover ?? { _, _ in },
                detachPopover: detachPopover ?? { _, _ in },
                refresh: { [weak self] _, profile in
                    guard let self else { return }
                    self.lastRefreshTriggerTime = Date()
                    ProviderManualRefreshDispatcher {
                        [weak self] profiles, trigger in
                        self?.refreshRuntime.refresh(
                            profiles: profiles,
                            trigger: trigger
                        )
                    }.dispatch(profile: profile)
                },
                activate: { [weak self] target, _ in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.capturedTargetRouter()
                                .currentProfile(for: target) != nil else {
                            return
                        }
                        await self.profileManager.activateProfile(
                            target.profileID
                        )
                    }
                },
                settings: {
                    [weak self] destination, _, _ in
                    self?.navigateToSettings(destination)
                },
                quit: { _, _ in
                    NSApp.terminate(nil)
                }
            )
        )
    }

    static func capturedActionProfiles(
        displayMode: ProfileDisplayMode,
        activeProfile: Profile?,
        profiles: [Profile]
    ) -> [Profile] {
        switch displayMode {
        case .single:
            guard let activeProfile,
                  !activeProfile.deletionInProgress else {
                return []
            }
            return [activeProfile]
        case .multi:
            let selectedProfiles = profiles.filter {
                $0.isSelectedForDisplay && !$0.deletionInProgress
            }
            if selectedProfiles.isEmpty,
               let activeProfile,
               !activeProfile.deletionInProgress {
                return [activeProfile]
            }
            return selectedProfiles
        }
    }

    private func navigateToSettings(
        _ destination: SettingsNavigationDestination
    ) {
        showSettings(destination: destination)
    }

    private func closePopover() {
        popover?.performClose(nil)
        stopMonitoringForOutsideClicks()
        lastPopoverCloseButton = currentPopoverButton
        currentPopoverButton = nil
        currentPopoverTarget = nil
        lastPopoverCloseDate = Date()
    }

    private func startMonitoringForOutsideClicks() {
        // Only monitor when popover is shown (not detached)
        // Stop monitoring if popover gets detached
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self,
                  let popover = self.popover,
                  popover.isShown,
                  self.detachedWindow == nil else { return }
            self.closePopover()
        }
    }

    private func stopMonitoringForOutsideClicks() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func closePopoverOrWindow() {
        if let window = detachedWindow {
            window.close()
            detachedWindow = nil
        } else {
            popover?.performClose(nil)
        }
    }

    // MARK: - Status Bar Icon Updates

    /// Updates all enabled status bar icons
    private func updateAllStatusBarIcons() {
        let now = Date()
        if profileManager.displayMode == .multi {
            let visible = profileManager.profiles.filter(
                \.isSelectedForDisplay
            )
            let presentations =
                ProviderMenuPresentationBuilder.presentations(
                    profiles: visible,
                    snapshots: profileUsagePresentations,
                    now: now,
                    isActive: profileManager.isActive
                )
            let config = profileManager.multiProfileConfig
            statusBarUIManager?.updateProviderMultiProfileButtons(
                presentations: presentations,
                profiles: profileManager.profiles,
                config: config,
                activeClaudeProfileID: profileManager.activeClaudeProfileID,
                isActive: profileManager.isActive
            )
            scheduleFreshnessDeadline(for: presentations, now: now)
        } else {
            guard let profile = profileManager.activeProfile else {
                freshnessDeadlineTimer?.invalidate()
                freshnessDeadlineTimer = nil
                return
            }
            let presentation =
                ProviderMenuPresentationBuilder.presentation(
                    profile: profile,
                    snapshot: profileUsagePresentations[profile.id],
                    now: now,
                    isActive: true
                )
            if profile.providerID == .claude {
                statusBarUIManager?.updateAllButtons(
                    usage: usage,
                    apiUsage: apiUsage
                )
                statusBarUIManager?.bindLegacySingleProfile(profile)
            } else {
                statusBarUIManager?.updateProviderSingle(
                    presentation: presentation,
                    target: self,
                    action: #selector(togglePopover),
                    config: effectiveIconConfiguration(for: profile)
                )
            }
            scheduleFreshnessDeadline(
                for: [presentation],
                now: now
            )
        }
    }

    private func scheduleFreshnessDeadline(
        for presentations: [ProviderMenuPresentation],
        now: Date
    ) {
        freshnessDeadlineTimer?.invalidate()
        freshnessDeadlineTimer = nil
        guard let deadline =
                ProviderMenuPresentationBuilder.nextFreshnessDeadline(
                    presentations: presentations
                ) else {
            return
        }
        let interval = max(0.01, deadline.timeIntervalSince(now))
        freshnessDeadlineTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateAllStatusBarIcons()
            }
        }
        freshnessDeadlineTimer?.tolerance = min(1, interval * 0.05)
    }

    /// Updates a specific metric's status bar icon
    private func updateStatusBarIcon(for metricType: MenuBarMetricType) {
        statusBarUIManager?.updateButton(
            for: metricType,
            usage: usage,
            apiUsage: apiUsage
        )
    }

    // Legacy method kept for backwards compatibility (now uses new system)
    private func updateStatusButton(_ button: NSStatusBarButton, usage: ClaudeUsage) {
        // This method is deprecated but kept for any remaining references
        // The new system handles updates through updateAllStatusBarIcons()
        updateAllStatusBarIcons()
    }

    // MARK: - Icon Style: Battery (Classic)

    private func startAutoRefresh() {
        let interval = profileManager.activeProfile?.refreshInterval ?? 30.0
        let timing = RefreshTimingPolicy(interval: interval)
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: timing.interval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleAutomaticTimerFire()
            }
        }
        refreshTimer?.tolerance = timing.tolerance
        LoggingService.shared.log("Started auto-refresh with interval: \(interval)s")
    }

    private func handleAutomaticTimerFire(at date: Date = Date()) {
        let fire = RefreshTimingPolicy.timerFired(at: date)
        lastAutoRefreshTime = fire.occurredAt
        refreshUsage(trigger: fire.trigger)
    }

    private func setupWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let timeSinceLastRefresh =
                    Date().timeIntervalSince(
                        self.lastAutoRefreshTime
                    )
                guard RefreshTimingPolicy.shouldRefreshAfterWake(
                    elapsedSinceLastAutomaticRefresh:
                        timeSinceLastRefresh
                ) else {
                    LoggingService.shared.log(
                        "MenuBarManager: Skipping wake refresh (debounce)"
                    )
                    return
                }
                LoggingService.shared.log(
                    "MenuBarManager: Wake from sleep detected, refreshing after delay"
                )
                DispatchQueue.main.asyncAfter(
                    deadline: .now()
                        + RefreshTimingPolicy.wakeDelay
                ) { [weak self] in
                    self?.lastAutoRefreshTime = Date()
                    self?.refreshUsage(trigger: .wake)
                }
            }
        }
    }

    private func restartAutoRefresh() {
        // Invalidate existing timer
        refreshTimer?.invalidate()
        refreshTimer = nil

        // Start new timer with updated interval
        startAutoRefresh()
    }

    private func observeRefreshIntervalChanges() {
        // Observe the same UserDefaults instance that DataStore uses
        refreshIntervalObserver = dataStore.userDefaults.observe(\.refreshInterval, options: [.new]) { [weak self] _, change in
            if let newValue = change.newValue, newValue > 0 {
                DispatchQueue.main.async {
                    self?.restartAutoRefresh()
                }
            }
        }
    }

    private func observeIconStyleChanges() {
        // Observe icon style changes from settings (now consolidated with menuBarIconConfigChanged)
        iconStyleObserver = NotificationCenter.default.addObserver(
            forName: .menuBarIconConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cachedImageKey = ""
                self.updateAllStatusBarIcons()
            }
        }
    }

    private func observeCredentialChanges() {
        // Observe credential changes (add, remove, or update)
        credentialsObserver = NotificationCenter.default.addObserver(
            forName: .credentialsChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            let changedProfileID = Self.credentialChangeProfileID(
                from: notification
            )

            // The observer is explicitly delivered on the main queue. Keep
            // invalidation synchronous with the notification so an already
            // completed fetch cannot win a later actor scheduling race.
            let routing = MainActor.assumeIsolated {
                let routing = Self.credentialChangeRouting(
                    changedProfileID: changedProfileID,
                    activeProfileID: self.profileManager.activeClaudeProfile?.id,
                    selectedProfileIDs: Set(
                        self.profileManager.profiles.lazy
                            .filter(\.isSelectedForDisplay)
                            .map(\.id)
                    ),
                    isMultiProfileMode:
                        self.profileManager.displayMode == .multi
                )
                switch routing.invalidation {
                case .profile(let profileID):
                    self.refreshRuntime.invalidate(profileID: profileID)
                case .allCapturedProfiles:
                    self.refreshRuntime.invalidateAll(
                        profiles: self.profileManager.profiles
                    )
                }
                self.activateRefreshPresentation()
                return routing
            }

            guard routing.shouldRefreshVisibleProfiles else {
                MainActor.assumeIsolated {
                    LoggingService.shared.logInfo(
                        "Credentials changed for an inactive profile - captured work invalidated without refreshing visible profiles"
                    )
                }
                return
            }

            Task { @MainActor in
                let selectedProfileIDs = Set(
                    self.profileManager.profiles.lazy
                        .filter(\.isSelectedForDisplay)
                        .map(\.id)
                )
                guard Self.shouldExecuteCredentialRefresh(
                    routing,
                    activeProfileID: self.profileManager.activeClaudeProfile?.id,
                    selectedProfileIDs: selectedProfileIDs,
                    isMultiProfileMode:
                        self.profileManager.displayMode == .multi
                ) else {
                    LoggingService.shared.logInfo(
                        "Credential refresh became stale before execution - skipping visible profile work"
                    )
                    return
                }

            if self.profileManager.displayMode == .multi {
                    LoggingService.shared.logInfo(
                        "Credentials changed for a visible profile - refreshing selected profiles"
                    )
                    self.updateMultiProfileDisplay()
                    self.lastRefreshTriggerTime = Date()
                    self.refreshUsage(trigger: .credentialsChanged)
                    return
                }

                // Check if active profile has usage credentials
                guard let profile = self.profileManager.activeProfile,
                      self.canAttemptUsageRefresh(profile) else {
                    LoggingService.shared.logInfo("Credentials changed but no usage credentials - showing default logo")

                    // Reconfigure menu bar to show default logo
                    let config = self.profileManager.activeProfile.map {
                        self.effectiveIconConfiguration(for: $0)
                    } ?? .default
                    self.updateMenuBarDisplay(with: config)
                    return
                }

                LoggingService.shared.logInfo("Credentials changed - triggering immediate refresh")

                // Reconfigure menu bar to show metrics (in case we were showing default logo)
                let config = self.effectiveIconConfiguration(for: profile)
                self.updateMenuBarDisplay(with: config)

                // Mark this as user-triggered
                self.lastRefreshTriggerTime = Date()

                self.refreshUsage(trigger: .credentialsChanged)
            }
        }
    }

    private func observeProviderLifecycleChanges() {
        providerConfigurationObserver =
            NotificationCenter.default.addObserver(
                forName: .providerConfigurationChanged,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let profileID = Self.credentialChangeProfileID(
                    from: notification
                )
                MainActor.assumeIsolated {
                    guard let self, let profileID else {
                        return
                    }
                    self.closeDetachedWindowIfInvalidated(
                        changedProfileID: profileID
                    )
                    ProviderMenuCatalogStore.shared.publish(
                        profiles: self.profileManager.profiles,
                        snapshots: self.profileUsagePresentations
                    )
                    self.refreshRuntime.invalidate(
                        profileID: profileID
                    )
                    self.refreshRuntime.presentationStore.purge(
                        profileID: profileID
                    )
                    self.activateRefreshPresentation()

                    let isVisible =
                        self.profileManager.displayMode == .multi
                            ? self.profileManager.profiles.contains {
                                $0.id == profileID
                                    && $0.isSelectedForDisplay
                            }
                            : self.profileManager.activeProfile?.id
                                == profileID
                    guard isVisible else { return }
                    self.refreshUsage(
                        trigger:
                            .providerConfigurationChanged
                    )
                }
            }

        profileDeletionStartedObserver =
            NotificationCenter.default.addObserver(
                forName: .profileDeletionStarted,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let profileID = Self.credentialChangeProfileID(
                    from: notification
                )
                MainActor.assumeIsolated {
                    guard let self, let profileID else {
                        return
                    }
                    self.closeDetachedWindowIfInvalidated(
                        changedProfileID: profileID
                    )
                    ProviderMenuCatalogStore.shared.invalidate(
                        profileID: profileID
                    )
                    self.refreshRuntime.beginDeletion(
                        profileID: profileID
                    )
                    self.cleanupProfile(profileID)
                    if self.profileManager.displayMode == .multi {
                        self.updateMultiProfileDisplay()
                    }
                }
            }

        profileDeletionCompletedObserver =
            NotificationCenter.default.addObserver(
                forName: .profileDeletionCompleted,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let profileID = Self.credentialChangeProfileID(
                    from: notification
                )
                MainActor.assumeIsolated {
                    guard let self, let profileID else {
                        return
                    }
                    ProviderMenuCatalogStore.shared.invalidate(
                        profileID: profileID
                    )
                    self.refreshRuntime.completeDeletion(
                        profileID: profileID
                    )
                    self.activateRefreshPresentation()
                    if self.profileManager.displayMode == .multi {
                        self.updateMultiProfileDisplay()
                    }
                }
            }
    }

    nonisolated struct CredentialChangeRouting: Equatable, Sendable {
        enum Invalidation: Equatable, Sendable {
            case profile(UUID)
            case allCapturedProfiles
        }

        enum RefreshScope: Equatable, Sendable {
            case none
            case activeProfile(UUID)
            case selectedProfile(UUID)
            case conservative
        }

        let invalidation: Invalidation
        let refreshScope: RefreshScope

        nonisolated var shouldRefreshVisibleProfiles: Bool {
            refreshScope != .none
        }
    }

    static func credentialChangeRouting(
        changedProfileID: UUID?,
        activeProfileID: UUID?,
        selectedProfileIDs: Set<UUID>,
        isMultiProfileMode: Bool
    ) -> CredentialChangeRouting {
        guard let changedProfileID else {
            return CredentialChangeRouting(
                invalidation: .allCapturedProfiles,
                refreshScope: .conservative
            )
        }

        let refreshScope: CredentialChangeRouting.RefreshScope
        if isMultiProfileMode {
            refreshScope =
                selectedProfileIDs.contains(changedProfileID)
                ? .selectedProfile(changedProfileID)
                : .none
        } else {
            refreshScope =
                activeProfileID == changedProfileID
                ? .activeProfile(changedProfileID)
                : .none
        }
        return CredentialChangeRouting(
            invalidation: .profile(changedProfileID),
            refreshScope: refreshScope
        )
    }

    static func shouldExecuteCredentialRefresh(
        _ routing: CredentialChangeRouting,
        activeProfileID: UUID?,
        selectedProfileIDs: Set<UUID>,
        isMultiProfileMode: Bool
    ) -> Bool {
        switch routing.refreshScope {
        case .none:
            return false
        case .activeProfile(let profileID):
            return !isMultiProfileMode && activeProfileID == profileID
        case .selectedProfile(let profileID):
            return isMultiProfileMode
                && selectedProfileIDs.contains(profileID)
        case .conservative:
            return true
        }
    }

    nonisolated static func credentialChangeProfileID(
        from notification: Notification
    ) -> UUID? {
        if let profileID = notification.object as? UUID {
            return profileID
        }
        for key in ["profileID", "profileId"] {
            if let profileID = notification.userInfo?[key] as? UUID {
                return profileID
            }
            if let value = notification.userInfo?[key] as? String,
               let profileID = UUID(uuidString: value) {
                return profileID
            }
        }
        return nil
    }

    private func observeIconConfigChanges() {
        // Observe configuration changes (metrics enabled/disabled, order changes, etc.)
        iconConfigObserver = NotificationCenter.default.addObserver(
            forName: .menuBarIconConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            // Reload configuration from active profile (already on main queue)
            Task { @MainActor in
                // Handle differently based on display mode
                if self.profileManager.displayMode == .multi {
                    self.updateMultiProfileDisplay()
                } else {
                    // Single profile mode
                    let newConfig = self.profileManager.activeProfile.map {
                        self.effectiveIconConfiguration(for: $0)
                    } ?? .default
                    self.updateMenuBarDisplay(with: newConfig)
                }
            }
        }
    }

    private func observeMultiProfileConfigChanges() {
        multiProfileConfigObserver = NotificationCenter.default.addObserver(
            forName: .multiProfileConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.closeDetachedWindowIfInvalidated(
                    selectedProfileIDs: Set(
                        self.profileManager.getSelectedProfiles()
                            .map(\.id)
                    )
                )
                self.activateRefreshPresentation()
                self.updateMultiProfileDisplay()
                self.refreshUsage(trigger: .displayChanged)
            }
        }
    }

    private func observeDisplayModeChanges() {
        // Observe display mode changes (single/multi profile)
        displayModeObserver = NotificationCenter.default.addObserver(
            forName: .displayModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            Task { @MainActor in
                self.handleDisplayModeChange()
            }
        }
    }

    private func handleDisplayModeChange() {
        let displayMode = profileManager.displayMode

        LoggingService.shared.log("MenuBarManager: Display mode changed to \(displayMode.rawValue)")
        closeDetachedWindowIfInvalidated(
            displayModeChanged: true
        )
        activateRefreshPresentation()

        if displayMode == .multi {
            // Switch to multi-profile mode
            setupMultiProfileMode()
        } else {
            // Switch back to single profile mode
            setupSingleProfileMode()
            refreshUsage(trigger: .displayChanged)
        }
    }

    // MARK: - Headless Mode (Remote Desktop Support)

    private func setupHeadlessModeObserver() {
        // Always observe screen changes to support headless Mac setups (Remote Desktop)
        LoggingService.shared.log("MenuBarManager: Setting up screen change observer for headless support")

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScreenChange()
            }
        }
    }

    private func handleScreenChange() {
        // Only proceed if we have screens now
        guard !NSScreen.screens.isEmpty else { return }

        // Check if status bar needs retry (button is nil means it failed on headless startup)
        guard let uiManager = statusBarUIManager else { return }

        if !uiManager.hasValidStatusBar {
            LoggingService.shared.log("MenuBarManager: Headless mode - display connected, retrying status bar setup (screens: \(NSScreen.screens.count))")
            setup()
        }
    }

    /// Returns whether the status bar has at least one valid button
    func hasValidStatusBar() -> Bool {
        return statusBarUIManager?.hasValidStatusBar ?? false
    }

    private func setupMultiProfileMode(
        refreshTrigger: UsageRefreshTrigger? = .displayChanged
    ) {
        let selectedProfiles = profileManager.getSelectedProfiles()
        let config = profileManager.multiProfileConfig
        statusBarUIManager?.setupMultiProfile(
            profiles: selectedProfiles,
            target: self,
            action: #selector(togglePopover)
        )

        // Defer icon update to next run loop iteration to let NSStatusBar finalize layout
        DispatchQueue.main.async { [weak self] in
            self?.updateAllStatusBarIcons()
        }

        LoggingService.shared.log("MenuBarManager: Multi-profile mode enabled with \(selectedProfiles.count) profiles, style=\(config.iconStyle.rawValue)")

        if let refreshTrigger {
            refreshAllSelectedProfiles(trigger: refreshTrigger)
        }
    }

    /// Applies multi-profile selection and visual changes without recreating
    /// retained NSStatusItems, preserving their macOS and third-party ordering.
    private func updateMultiProfileDisplay() {
        statusBarUIManager?.updateMultiProfileConfiguration(
            profiles: profileManager.profiles,
            target: self,
            action: #selector(togglePopover)
        )

        DispatchQueue.main.async { [weak self] in
            self?.updateAllStatusBarIcons()
        }

        LoggingService.shared.log("MenuBarManager: Multi-profile display updated incrementally")
    }

    /// Refreshes usage data for all profiles selected for multi-profile display
    private func refreshAllSelectedProfiles(
        trigger: UsageRefreshTrigger
    ) {
        let selectedProfiles = profileManager.profiles.filter {
            $0.isSelectedForDisplay && canAttemptUsageRefresh($0)
        }

        guard !selectedProfiles.isEmpty else {
            LoggingService.shared.log("MenuBarManager: No selected profiles with usage credentials to refresh")
            updateAllStatusBarIcons()
            return
        }

        LoggingService.shared.log("MenuBarManager: Refreshing \(selectedProfiles.count) selected profiles for multi-profile mode")
        refreshRuntime.refresh(
            profiles: selectedProfiles,
            trigger: trigger
        )
    }

    private func setupSingleProfileMode() {
        guard let profile = profileManager.activeProfile else { return }

        let canRefresh = canAttemptUsageRefresh(profile)
        let config = effectiveIconConfiguration(for: profile)

        if profile.providerID != .claude {
            updateProviderSingleDisplay(
                profile: profile,
                config: config
            )
            LoggingService.shared.log(
                "MenuBarManager: Provider single profile mode enabled"
            )
            return
        }

        // If no usage credentials, create empty config to show default logo
        let displayConfig: MenuBarIconConfiguration
        if !canRefresh {
            displayConfig = MenuBarIconConfiguration(
                colorMode: config.colorMode,
                singleColorHex: config.singleColorHex,
                showIconNames: config.showIconNames,
                metrics: config.metrics.map { metric in
                    var updatedMetric = metric
                    updatedMetric.isEnabled = false
                    return updatedMetric
                }
            )
        } else {
            displayConfig = config
        }

        statusBarUIManager?.setup(target: self, action: #selector(togglePopover), config: displayConfig)

        // Defer icon update to next run loop iteration to let NSStatusBar finalize layout
        DispatchQueue.main.async { [weak self] in
            self?.updateAllStatusBarIcons()
        }

        LoggingService.shared.log("MenuBarManager: Single profile mode enabled")
    }

    func refreshUsage(
        trigger: UsageRefreshTrigger = .manual
    ) {
        // In multi-profile mode, refresh ALL selected profiles
        if profileManager.displayMode == .multi {
            refreshAllSelectedProfiles(trigger: trigger)
            return
        }

        // Single profile mode - refresh only active profile
        guard let profile = profileManager.activeProfile else {
            LoggingService.shared.log("MenuBarManager.refreshUsage: No active profile")
            return
        }

        // Detailed logging
        LoggingService.shared.log("MenuBarManager.refreshUsage called:")
        LoggingService.shared.log("  - Profile: '\(profile.name)'")
        LoggingService.shared.log(
            "  - canAttemptUsageRefresh: \(canAttemptUsageRefresh(profile))"
        )

        // Check for usage credentials (Claude.ai or API Console, not just CLI)
        guard canAttemptUsageRefresh(profile) else {
            LoggingService.shared.log("MenuBarManager: Skipping refresh - no usage credentials")
            // Update icons to show default logo if needed
            updateAllStatusBarIcons()
            return
        }

        LoggingService.shared.log("MenuBarManager: Proceeding with refresh")
        refreshRuntime.refresh(
            profiles: [profile],
            trigger: trigger
        )
    }

    /// Shows a brief success notification for user-triggered refreshes
    private func showSuccessNotification() {
        NotificationManager.shared.sendSuccessNotification()
    }

    // MARK: - Auto-Switch Profile on Session Limit

    /// Checks if the current profile hit 100% and switches to the next available one
    private func checkAutoSwitchIfNeeded(
        usage: ClaudeUsage,
        currentProfile: Profile,
        expectedProfileID: UUID,
        expectedPresentationEpoch: UInt64
    ) {
        guard profileManager.activeClaudeProfile?.id == expectedProfileID,
              currentProfile.id == expectedProfileID,
              refreshRuntime.presentationContext.epoch
                == expectedPresentationEpoch else {
            return
        }

        // Guard: feature must be enabled
        guard SharedDataStore.shared.loadAutoSwitchProfileEnabled() else { return }
        guard providerUIDependencies.capabilities(
            for: currentProfile.providerID
        ).supports(.automaticProfileSwitch) else {
            return
        }

        // Guard: need more than 1 profile
        let profiles = profileManager.profiles
        guard profiles.count > 1 else { return }

        let profileId = currentProfile.id

        // If usage dropped below 100%, clear the flag (session reset)
        if usage.effectiveSessionPercentage < 100.0 {
            autoSwitchedProfileIds.remove(profileId)
            return
        }

        // Guard: usage must be >= 100%
        guard usage.effectiveSessionPercentage >= 100.0 else { return }

        // Guard: don't re-trigger for this profile
        guard !autoSwitchedProfileIds.contains(profileId) else { return }

        // Mark as triggered
        autoSwitchedProfileIds.insert(profileId)

        // Find the next available profile
        guard let nextProfile = findNextAvailableProfile(after: currentProfile) else {
            LoggingService.shared.log("AutoSwitch: All profiles at 100% or unavailable, staying on '\(currentProfile.name)'")
            return
        }

        LoggingService.shared.log("AutoSwitch: Switching from '\(currentProfile.name)' to '\(nextProfile.name)'")

        // Activate the next profile
        let fromName = currentProfile.name
        let toName = nextProfile.name
        Task { @MainActor [weak self] in
            guard let self,
                  self.profileManager.activeProfile?.id
                    == expectedProfileID,
                  self.refreshRuntime.presentationContext.epoch
                    == expectedPresentationEpoch else {
                self?.autoSwitchedProfileIds.remove(profileId)
                return
            }
            await profileManager.activateProfile(nextProfile.id)

            await MainActor.run {
                // Send notification
                NotificationManager.shared.sendAutoSwitchNotification(fromProfile: fromName, toProfile: toName)

                // Post notification for UI reactivity
                NotificationCenter.default.post(name: .autoSwitchProfileTriggered, object: nil)
            }
        }
    }

    /// Finds the next profile with available session capacity, wrapping around
    private func findNextAvailableProfile(after currentProfile: Profile) -> Profile? {
        let profiles = profileManager.profiles
        guard let currentIndex = profiles.firstIndex(where: { $0.id == currentProfile.id }) else { return nil }

        let count = profiles.count
        for offset in 1..<count {
            let index = (currentIndex + offset) % count
            let candidate = profiles[index]

            // Must support this automation and have compatible usage data.
            guard providerUIDependencies.capabilities(
                for: candidate.providerID
            ).supports(.automaticProfileSwitch),
                  candidate.providerID == .claude,
                  candidate.hasUsageCredentials else {
                continue
            }

            // If no saved usage data, treat as available
            guard let candidateUsage = candidate.claudeUsage else { return candidate }

            // Must be below 100%
            if candidateUsage.effectiveSessionPercentage < 100.0 {
                return candidate
            }
        }

        return nil
    }

    // MARK: - Reset Detection for History Recording

    /// Normalizes a date to minute precision for comparison (ignores seconds)
    private func normalizeToMinute(_ date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return calendar.date(from: components) ?? date
    }

    /// Checks if a session reset occurred and records a snapshot if so
    private func checkAndRecordSessionReset(
        profileId: UUID,
        previousUsage: ClaudeUsage?,
        newUsage: ClaudeUsage
    ) {
        let lastKnown = lastKnownSessionResetTime[profileId]
        let newResetTime = normalizeToMinute(newUsage.sessionResetTime)

        // First time seeing this profile - just record the reset time
        if lastKnown == nil {
            lastKnownSessionResetTime[profileId] = newResetTime
            return
        }

        // Normalize the last known time for comparison
        let normalizedLastKnown = normalizeToMinute(lastKnown!)

        // Check if reset time changed (indicates a reset occurred)
        // Use != instead of > to handle clock changes and backward time jumps
        if newResetTime != normalizedLastKnown {
            // Reset detected! Record snapshot of the previous usage
            LoggingService.shared.log("History: Session reset detected for profile \(profileId.uuidString.prefix(8)). Old: \(normalizedLastKnown), New: \(newResetTime)")
            if let prevUsage = previousUsage {
                UsageHistoryService.shared.recordSessionReset(
                    for: profileId,
                    previousUsage: prevUsage,
                    resetTime: prevUsage.sessionResetTime
                )
            }

            // Mark that session reset was just recorded to prevent duplicate periodic snapshot
            var flags = resetJustRecorded[profileId] ?? (session: false, weekly: false)
            flags.session = true
            resetJustRecorded[profileId] = flags
        }

        // Update the last known reset time
        lastKnownSessionResetTime[profileId] = newResetTime
    }

    /// Checks if a weekly reset occurred and records a snapshot if so
    private func checkAndRecordWeeklyReset(
        profileId: UUID,
        previousUsage: ClaudeUsage?,
        newUsage: ClaudeUsage
    ) {
        let lastKnown = lastKnownWeeklyResetTime[profileId]
        let newResetTime = normalizeToMinute(newUsage.weeklyResetTime)

        // First time seeing this profile - just record the reset time
        if lastKnown == nil {
            lastKnownWeeklyResetTime[profileId] = newResetTime
            LoggingService.shared.log("History: Initial weekly reset time for profile \(profileId.uuidString.prefix(8)): \(newResetTime)")
            return
        }

        // Normalize the last known time for comparison
        let normalizedLastKnown = normalizeToMinute(lastKnown!)

        // Check if reset time changed (indicates a reset occurred)
        // Use != instead of > to handle clock changes and backward time jumps
        if newResetTime != normalizedLastKnown {
            // Reset detected! Record snapshot of the previous usage
            LoggingService.shared.log("History: Weekly reset detected for profile \(profileId.uuidString.prefix(8)). Old: \(normalizedLastKnown), New: \(newResetTime)")
            if let prevUsage = previousUsage {
                UsageHistoryService.shared.recordWeeklyReset(
                    for: profileId,
                    previousUsage: prevUsage,
                    resetTime: prevUsage.weeklyResetTime
                )
            }

            // Mark that weekly reset was just recorded to prevent duplicate periodic snapshot
            var flags = resetJustRecorded[profileId] ?? (session: false, weekly: false)
            flags.weekly = true
            resetJustRecorded[profileId] = flags
        }

        // Update the last known reset time
        lastKnownWeeklyResetTime[profileId] = newResetTime
    }

    /// Checks if a billing cycle reset occurred and records a snapshot if so
    private func checkAndRecordBillingCycleReset(
        profileId: UUID,
        previousUsage: APIUsage?,
        newUsage: APIUsage
    ) {
        let lastKnown = lastKnownAPIResetTime[profileId]
        let newResetTime = normalizeToMinute(newUsage.resetsAt)

        // First time seeing this profile - just record the reset time
        if lastKnown == nil {
            lastKnownAPIResetTime[profileId] = newResetTime
            LoggingService.shared.log("History: Initial API reset time for profile \(profileId.uuidString.prefix(8)): \(newResetTime)")
            return
        }

        // Normalize the last known time for comparison
        let normalizedLastKnown = normalizeToMinute(lastKnown!)

        // Check if reset time changed (indicates a reset occurred)
        // Use != instead of > to handle clock changes and backward time jumps
        if newResetTime != normalizedLastKnown {
            // Reset detected! Record snapshot of the previous usage
            LoggingService.shared.log("History: Billing cycle reset detected for profile \(profileId.uuidString.prefix(8)). Old: \(normalizedLastKnown), New: \(newResetTime)")
            if let prevUsage = previousUsage {
                UsageHistoryService.shared.recordBillingCycleReset(
                    for: profileId,
                    previousUsage: prevUsage,
                    resetTime: prevUsage.resetsAt
                )
            }
        }

        // Update the last known reset time
        lastKnownAPIResetTime[profileId] = newResetTime
    }

    @objc private func preferencesClicked() {
        showSettings(destination: .defaultView)
    }

    private func showSettings(
        destination: SettingsNavigationDestination
    ) {
        closePopoverOrWindow()

        if let settingsController {
            settingsController.navigate(to: destination)
            let existingWindow = settingsController.window
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        NSApp.setActivationPolicy(.regular)
        let controller = SettingsWindowBuilder.makeController(
            size: Constants.WindowSizes.settingsWindow,
            dependencies: providerUIDependencies,
            destination: destination
        )
        let window = controller.window
        window.title = "app.window.settings".localized
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        settingsController = controller
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func switchToNextProfile() {
        let profiles = profileManager.profiles
        guard profiles.count > 1,
              let currentId = profileManager.activeProfile?.id,
              let currentIndex = profiles.firstIndex(where: { $0.id == currentId }) else {
            return
        }

        let nextIndex = (profiles.index(after: currentIndex)) % profiles.count
        let nextProfile = profiles[nextIndex]

        Task {
            await profileManager.activateProfile(nextProfile.id)
        }
    }

    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
    }

    /// Shows the GitHub star prompt window
    func showGitHubStarPrompt() {
        // If window already exists, just bring it to front
        if let existingWindow = githubPromptWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Temporarily show dock icon for the prompt window
        NSApp.setActivationPolicy(.regular)

        // Create the GitHub star prompt view
        let promptView = GitHubStarPromptView(
            onStar: { [weak self] in
                self?.handleGitHubStarClick()
            },
            onMaybeLater: { [weak self] in
                self?.handleMaybeLaterClick()
            },
            onDontAskAgain: { [weak self] in
                self?.handleDontAskAgainClick()
            }
        )

        let hostingController = NSHostingController(rootView: promptView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = ""
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 300, height: 145))
        window.center()
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.level = .floating
        window.delegate = self

        // Store reference
        githubPromptWindow = window

        // Mark that we've shown the prompt
        dataStore.saveLastGitHubStarPromptDate(Date())

        // Show the window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleGitHubStarClick() {
        // Open GitHub repository
        if let url = URL(string: Constants.githubRepoURL) {
            NSWorkspace.shared.open(url)
        }

        // Mark as starred
        dataStore.saveHasStarredGitHub(true)

        // Close the prompt window
        githubPromptWindow?.close()
        githubPromptWindow = nil

        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)
    }

    private func handleMaybeLaterClick() {
        // Just close the window - the prompt will show again after the reminder interval
        githubPromptWindow?.close()
        githubPromptWindow = nil

        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)
    }

    private func handleDontAskAgainClick() {
        // Mark to never show again
        dataStore.saveNeverShowGitHubPrompt(true)

        // Close the prompt window
        githubPromptWindow?.close()
        githubPromptWindow = nil

        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Feedback Prompt

    /// Shows the feedback collection prompt window
    func showFeedbackPrompt() {
        if let existingWindow = feedbackWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        NSApp.setActivationPolicy(.regular)

        let promptView = FeedbackPromptView(
            onSubmit: { [weak self] _, _, _, _ in
                SharedDataStore.shared.saveHasSubmittedFeedback(true)
                // Close after a brief delay to show the thanks state
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self?.closeFeedbackWindow()
                }
            },
            onRemindLater: { [weak self] in
                SharedDataStore.shared.saveLastFeedbackPromptDate(Date())
                self?.closeFeedbackWindow()
            },
            onDontAskAgain: { [weak self] in
                SharedDataStore.shared.saveNeverShowFeedbackPrompt(true)
                self?.closeFeedbackWindow()
            }
        )

        let hostingController = NSHostingController(rootView: promptView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = ""
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 380, height: 420))
        window.center()
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.level = .floating
        window.delegate = self

        feedbackWindow = window
        SharedDataStore.shared.saveLastFeedbackPromptDate(Date())

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeFeedbackWindow() {
        feedbackWindow?.close()
        feedbackWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - NSPopoverDelegate
extension MenuBarManager: NSPopoverDelegate {
    func popoverShouldDetach(_ popover: NSPopover) -> Bool {
        ProviderPopoverDetachmentLifecycle.shouldDetach()
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverCloseDate = Date()
        lastPopoverCloseButton = currentPopoverButton
    }

    func detachableWindow(for popover: NSPopover) -> NSWindow? {
        guard let target = popoverActionTarget() else { return nil }
        var createdWindow: NSPanel?
        capturedTargetRouter(
            detachPopover: { [weak self] _, _ in
                guard let self else { return }
                self.stopMonitoringForOutsideClicks()

                // A detached panel owns a fresh controller without popover
                // preferred-size constraints.
                let contentView = PopoverContentView(
                    manager: self,
                    profileManager: self.profileManager,
                    onRefresh: { [weak self] in
                        self?.refreshPopover(target: target)
                    },
                    onManageProfiles: { [weak self] in
                        self?.openPopoverManageProfiles(target: target)
                    },
                    onPreferences: { [weak self] in
                        self?.openPopoverSettings(target: target)
                    }
                )
                let hostingController = NSHostingController(
                    rootView: contentView
                )
                let window = Self.makeDetachedPopoverWindow(
                    contentViewController: hostingController,
                    delegate: self
                )
                self.detachedWindow = window
                createdWindow = window
            }
        ).route(.detachPopover, target: target)
        return createdWindow
    }

    static func makeDetachedPopoverWindow(
        contentViewController: NSViewController,
        delegate: NSWindowDelegate?
    ) -> NSPanel {
        ProviderPopoverDetachmentLifecycle.makeWindow(
            contentViewController: contentViewController,
            delegate: delegate
        )
    }
}

// MARK: - StatusBarUIManagerDelegate
extension MenuBarManager: StatusBarUIManagerDelegate {
    func statusBarAppearanceDidChange() {
        // Safe from infinite loops: StatusBarUIManager's observer deduplicates by
        // appearance name, and setButtonImage() only assigns button.image when the
        // rendered CGImage data actually changes — so even if setting button.image
        // triggers effectiveAppearance KVO, the cycle stops immediately.
        cachedIsDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        cachedImageKey = ""
        updateAllStatusBarIcons()
    }
}

// MARK: - NSWindowDelegate
extension MenuBarManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            if window == settingsWindow {
                // Hide dock icon again when settings window closes
                NSApp.setActivationPolicy(.accessory)
                settingsController = nil
                settingsWindow = nil
            } else if ProviderPopoverDetachmentLifecycle
                .closedRetainedWindow(
                    window,
                    retainedWindow: detachedWindow
                ) {
                // Clear detached window reference when closed
                detachedWindow = nil
                currentPopoverTarget = nil
            } else if window == githubPromptWindow {
                // Hide dock icon again when GitHub prompt window closes
                NSApp.setActivationPolicy(.accessory)
                githubPromptWindow = nil
            }
        }
    }
}
