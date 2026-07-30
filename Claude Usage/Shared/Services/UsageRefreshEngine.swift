import Foundation
import Combine
import UsageCore

extension UsageRefreshTrigger {
    var isUserInitiated: Bool {
        self == .manual
    }
}

nonisolated struct UsagePresentationContext: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case single
        case multi
    }

    let epoch: UInt64
    let focusedProfileID: UUID?
    let visibleProfileIDs: Set<UUID>
    let mode: Mode

    init(
        epoch: UInt64,
        focusedProfileID: UUID?,
        visibleProfileIDs: Set<UUID>,
        mode: Mode = .single
    ) {
        self.epoch = epoch
        self.focusedProfileID = focusedProfileID
        self.visibleProfileIDs = visibleProfileIDs
        self.mode = mode
    }

    static let empty = UsagePresentationContext(
        epoch: 0,
        focusedProfileID: nil,
        visibleProfileIDs: [],
        mode: .single
    )
}

nonisolated enum ProviderConfigurationState: Equatable, Sendable {
    case ready
    case disabled
    case unlinked
    case dependencyMissing
    case unauthenticated
    case unsupported
    case invalid
    case deleting
}

nonisolated enum ProviderRefreshFailureKind: Equatable, Sendable {
    case disabled
    case unlinked
    case dependencyMissing
    case unauthenticated
    case unsupportedAccount
    case invalidConfiguration
    case transport
    case protocolMismatch
    case malformedResponse
    case timedOut
    case persistence
    case unknown
}

nonisolated struct ProviderRefreshFailure:
    Equatable,
    @unchecked Sendable
{
    let kind: ProviderRefreshFailureKind
    let occurredAt: Date
    let isRecoverable: Bool
    let consecutiveCount: Int
    let legacyErrorCode: ErrorCode?

    init(
        kind: ProviderRefreshFailureKind,
        occurredAt: Date,
        isRecoverable: Bool,
        consecutiveCount: Int,
        legacyErrorCode: ErrorCode? = nil
    ) {
        self.kind = kind
        self.occurredAt = occurredAt
        self.isRecoverable = isRecoverable
        self.consecutiveCount = consecutiveCount
        self.legacyErrorCode = legacyErrorCode
    }

    var isCredentialFailure: Bool {
        kind == .unauthenticated
    }
}

nonisolated enum UsageRefreshActivity: Equatable, Sendable {
    case idle
    case queued(requestID: UUID, trigger: UsageRefreshTrigger, requestedAt: Date)
    case refreshing(requestID: UUID, trigger: UsageRefreshTrigger, startedAt: Date)

    var isInFlight: Bool {
        switch self {
        case .idle:
            return false
        case .queued, .refreshing:
            return true
        }
    }
}

nonisolated struct PresentationSnapshot: @unchecked Sendable {
    let profileID: UUID
    let profileName: String
    let providerID: ProviderID
    let providerRevision: UInt64
    let presentationEpoch: UInt64
    let capabilities: ProviderCapabilities
    let configurationState: ProviderConfigurationState
    let report: UsageReport?
    let claudeUsage: ClaudeUsage?
    let claudeAPIUsage: APIUsage?
    let activity: UsageRefreshActivity
    let lastSuccessfulAt: Date?
    let currentFailure: ProviderRefreshFailure?
}

struct ClaudeStatusPresentation {
    let presentationEpoch: UInt64
    let status: ClaudeStatus
    let isRefreshing: Bool
    let failedAt: Date?
    let failure: ProviderRefreshFailure?

    static let empty = ClaudeStatusPresentation(
        presentationEpoch: 0,
        status: .unknown,
        isRefreshing: false,
        failedAt: nil,
        failure: nil
    )
}

@MainActor
final class UsagePresentationStore: ObservableObject {
    @Published private(set) var snapshots: [UUID: PresentationSnapshot] = [:]
    @Published private(set) var claudeStatus: ClaudeStatusPresentation = .empty

    private(set) var context: UsagePresentationContext = .empty
    private var activityInvocationOrders: [UUID: UInt64] = [:]
    private var activityRequestIDs: [UUID: UUID] = [:]
    private var completedActivityRequestIDs: [UUID: UUID] = [:]
    private var claudeStatusInvocationOrder: UInt64 = 0
    private var claudeStatusCompletedInvocationOrder: UInt64 = 0
    private var terminalProfileIDs: Set<UUID> = []
    private var isShutdown = false

    func activate(
        _ context: UsagePresentationContext,
        hydrated snapshots: [UUID: PresentationSnapshot] = [:]
    ) {
        guard !isShutdown else { return }
        let retainedDeleting = self.snapshots.filter {
            $0.value.configurationState == .deleting
        }
        self.context = context
        activityInvocationOrders = activityInvocationOrders.filter {
            context.visibleProfileIDs.contains($0.key)
        }
        activityRequestIDs = activityRequestIDs.filter {
            context.visibleProfileIDs.contains($0.key)
        }
        let visibleHydrated = snapshots.filter {
            context.visibleProfileIDs.contains($0.key)
                && $0.value.presentationEpoch
                    == context.epoch
        }
        self.snapshots = retainedDeleting.merging(
            visibleHydrated,
            uniquingKeysWith: {
                retained, _ in retained
            }
        )
        for (profileID, snapshot) in snapshots
        where snapshot.configurationState == .deleting {
            self.snapshots[profileID] = snapshot
        }
        if !context.visibleProfileIDs.contains(
            where: { snapshots[$0]?.providerID == .claude }
        ) {
            claudeStatus = .empty
        }
    }

    @discardableResult
    func publish(
        _ snapshot: PresentationSnapshot,
        expected context: UsagePresentationContext,
        invocationOrder: UInt64? = nil
    ) -> Bool {
        guard self.context == context,
              !isShutdown,
              !terminalProfileIDs.contains(snapshot.profileID),
              context.visibleProfileIDs.contains(snapshot.profileID),
              snapshot.presentationEpoch == context.epoch else {
            return false
        }
        if snapshots[snapshot.profileID]?.configurationState
                == .deleting,
           snapshot.configurationState != .deleting {
            return false
        }
        if let invocationOrder,
           let currentOrder =
                activityInvocationOrders[snapshot.profileID],
           invocationOrder == currentOrder,
           let requestID = activityRequestID(snapshot.activity),
           completedActivityRequestIDs[snapshot.profileID]
                == requestID {
            return false
        }
        if let invocationOrder,
           let currentOrder =
                activityInvocationOrders[snapshot.profileID],
           invocationOrder < currentOrder
                || (
                    invocationOrder == currentOrder
                        && activityRequestIDs[
                            snapshot.profileID
                        ] != nil
                        && activityRequestID(snapshot.activity)
                            != activityRequestIDs[
                                snapshot.profileID
                            ]
                ) {
            return false
        }
        if let invocationOrder,
           let requestID = activityRequestID(
                snapshot.activity
           ) {
            activityInvocationOrders[snapshot.profileID] =
                invocationOrder
            activityRequestIDs[snapshot.profileID] =
                requestID
        } else if case .idle = snapshot.activity {
            if let invocationOrder {
                activityInvocationOrders[snapshot.profileID] =
                    invocationOrder
            }
            activityRequestIDs.removeValue(
                forKey: snapshot.profileID
            )
        }
        snapshots[snapshot.profileID] = snapshot
        return true
    }

    func registerActivityInvocation(
        _ invocationOrder: UInt64,
        profileIDs: some Sequence<UUID>
    ) {
        guard !isShutdown else { return }
        for profileID in profileIDs
        where invocationOrder
            >= (activityInvocationOrders[profileID] ?? 0) {
            if invocationOrder
                > (activityInvocationOrders[profileID] ?? 0) {
                completedActivityRequestIDs.removeValue(
                    forKey: profileID
                )
            }
            activityInvocationOrders[profileID] =
                invocationOrder
            activityRequestIDs.removeValue(forKey: profileID)
        }
    }

    func completeRefreshActivity(
        profileID: UUID,
        requestID: UUID,
        invocationOrder: UInt64,
        replacement: UsageRefreshActivity,
        replacementInvocationOrder: UInt64?,
        expected context: UsagePresentationContext
    ) {
        guard self.context == context,
              !isShutdown,
              !terminalProfileIDs.contains(profileID),
              let snapshot = snapshots[profileID],
              snapshot.presentationEpoch == context.epoch,
              activityInvocationOrders[profileID]
                == invocationOrder,
              activityRequestIDs[profileID] == requestID else {
            return
        }
        snapshots[profileID] = snapshot.withActivity(
            replacement
        )
        if let replacementInvocationOrder,
           let replacementRequestID =
                activityRequestID(replacement) {
            activityInvocationOrders[profileID] =
                replacementInvocationOrder
            activityRequestIDs[profileID] =
                replacementRequestID
            completedActivityRequestIDs.removeValue(
                forKey: profileID
            )
        } else {
            activityInvocationOrders[profileID] =
                invocationOrder
            activityRequestIDs.removeValue(forKey: profileID)
            completedActivityRequestIDs[profileID] =
                requestID
        }
    }

    func registerClaudeStatusInvocation(
        _ invocationOrder: UInt64
    ) {
        guard !isShutdown else { return }
        claudeStatusInvocationOrder = max(
            claudeStatusInvocationOrder,
            invocationOrder
        )
    }

    private func activityRequestID(
        _ activity: UsageRefreshActivity
    ) -> UUID? {
        switch activity {
        case .idle:
            return nil
        case .queued(let requestID, _, _),
                .refreshing(let requestID, _, _):
            return requestID
        }
    }

    func purge(profileID: UUID) {
        snapshots.removeValue(forKey: profileID)
        activityInvocationOrders.removeValue(forKey: profileID)
        activityRequestIDs.removeValue(forKey: profileID)
        completedActivityRequestIDs.removeValue(forKey: profileID)
    }

    func remove(profileID: UUID) {
        terminalProfileIDs.insert(profileID)
        purge(profileID: profileID)
    }

    func markDeleting(profileID: UUID) {
        guard !isShutdown else { return }
        terminalProfileIDs.insert(profileID)
        guard let snapshot = snapshots[profileID] else { return }
        snapshots[profileID] = PresentationSnapshot(
            profileID: snapshot.profileID,
            profileName: snapshot.profileName,
            providerID: snapshot.providerID,
            providerRevision: snapshot.providerRevision,
            presentationEpoch: snapshot.presentationEpoch,
            capabilities: snapshot.capabilities,
            configurationState: .deleting,
            report: snapshot.report,
            claudeUsage: snapshot.claudeUsage,
            claudeAPIUsage: snapshot.claudeAPIUsage,
            activity: .idle,
            lastSuccessfulAt: snapshot.lastSuccessfulAt,
            currentFailure: snapshot.currentFailure
        )
        activityRequestIDs.removeValue(forKey: profileID)
    }

    func purgeAll() {
        snapshots.removeAll()
        activityInvocationOrders.removeAll()
        activityRequestIDs.removeAll()
        completedActivityRequestIDs.removeAll()
        claudeStatus = .empty
    }

    func shutdown() {
        isShutdown = true
        purgeAll()
    }

    func snapshot(for profileID: UUID) -> PresentationSnapshot? {
        snapshots[profileID]
    }

    @discardableResult
    func beginClaudeStatus(
        expected context: UsagePresentationContext,
        invocationOrder: UInt64
    ) -> Bool {
        guard !isShutdown,
              self.context == context,
              claudeStatusInvocationOrder == invocationOrder,
              invocationOrder
                > claudeStatusCompletedInvocationOrder else {
            return false
        }
        claudeStatus = ClaudeStatusPresentation(
            presentationEpoch: context.epoch,
            status: claudeStatus.status,
            isRefreshing: true,
            failedAt: nil,
            failure: nil
        )
        return true
    }

    @discardableResult
    func publishClaudeStatus(
        _ status: ClaudeStatus,
        expected context: UsagePresentationContext,
        invocationOrder: UInt64
    ) -> Bool {
        guard !isShutdown,
              self.context == context,
              claudeStatusInvocationOrder == invocationOrder else {
            return false
        }
        claudeStatusCompletedInvocationOrder = max(
            claudeStatusCompletedInvocationOrder,
            invocationOrder
        )
        claudeStatus = ClaudeStatusPresentation(
            presentationEpoch: context.epoch,
            status: status,
            isRefreshing: false,
            failedAt: nil,
            failure: nil
        )
        return true
    }

    func failClaudeStatus(
        with failure: ProviderRefreshFailure,
        expected context: UsagePresentationContext,
        invocationOrder: UInt64
    ) {
        guard !isShutdown,
              self.context == context,
              claudeStatusInvocationOrder == invocationOrder else {
            return
        }
        claudeStatusCompletedInvocationOrder = max(
            claudeStatusCompletedInvocationOrder,
            invocationOrder
        )
        claudeStatus = ClaudeStatusPresentation(
            presentationEpoch: context.epoch,
            status: claudeStatus.status,
            isRefreshing: false,
            failedAt: failure.occurredAt,
            failure: failure
        )
    }
}

private extension PresentationSnapshot {
    func withActivity(
        _ activity: UsageRefreshActivity
    ) -> PresentationSnapshot {
        PresentationSnapshot(
            profileID: profileID,
            profileName: profileName,
            providerID: providerID,
            providerRevision: providerRevision,
            presentationEpoch: presentationEpoch,
            capabilities: capabilities,
            configurationState: configurationState,
            report: report,
            claudeUsage: claudeUsage,
            claudeAPIUsage: claudeAPIUsage,
            activity: activity,
            lastSuccessfulAt: lastSuccessfulAt,
            currentFailure: currentFailure
        )
    }
}

nonisolated enum AcceptedUsageComponent: Hashable, Sendable {
    case providerUsage
    case claudeAPI
}

nonisolated struct AcceptedUsageRefreshEvent: @unchecked Sendable {
    let sequence: UInt64
    let identity: ProviderRefreshIdentity
    let profileName: String
    let trigger: UsageRefreshTrigger
    let presentationContext: UsagePresentationContext
    let capabilities: ProviderCapabilities
    let previousUsage: ProfileCurrentUsage?
    let currentUsage: ProfileCurrentUsage
    let acceptedComponents: Set<AcceptedUsageComponent>
    let committedAt: Date
}

nonisolated enum UsageRefreshFailureComponent: Equatable, Sendable {
    case providerUsage
    case claudeAPI
    case capture
    case persistence
}

nonisolated struct UsageRefreshFailureCandidate: Sendable {
    let identity: ProviderRefreshIdentity
    let profileName: String
    let inputGeneration: UInt64
    let invocationOrder: UInt64
    let trigger: UsageRefreshTrigger
    let presentationContext: UsagePresentationContext
    let component: UsageRefreshFailureComponent
    let failure: ProviderRefreshFailure
}

nonisolated struct UsageRefreshFailureEvent: Sendable {
    let sequence: UInt64
    let identity: ProviderRefreshIdentity
    let profileName: String
    let invocationOrder: UInt64
    let trigger: UsageRefreshTrigger
    let presentationContext: UsagePresentationContext
    let component: UsageRefreshFailureComponent
    let failure: ProviderRefreshFailure
}

@MainActor
final class UsageRefreshEventHub {
    typealias Observer = @MainActor (AcceptedUsageRefreshEvent) -> Void
    typealias FailureObserver =
        @MainActor (UsageRefreshFailureEvent) -> Void
    typealias BatchObserver =
        @MainActor (UsageRefreshBatchResult) -> Void

    private var nextSequence: UInt64 = 0
    private var observers: [UUID: Observer] = [:]
    private var failureObservers: [UUID: FailureObserver] = [:]
    private var batchObservers: [UUID: BatchObserver] = [:]

    @discardableResult
    func observe(_ observer: @escaping Observer) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
        failureObservers.removeValue(forKey: token)
        batchObservers.removeValue(forKey: token)
    }

    @discardableResult
    func observeFailures(
        _ observer: @escaping FailureObserver
    ) -> UUID {
        let token = UUID()
        failureObservers[token] = observer
        return token
    }

    @discardableResult
    func observeBatches(
        _ observer: @escaping BatchObserver
    ) -> UUID {
        let token = UUID()
        batchObservers[token] = observer
        return token
    }

    func publish(
        identity: ProviderRefreshIdentity,
        profileName: String,
        trigger: UsageRefreshTrigger,
        presentationContext: UsagePresentationContext,
        capabilities: ProviderCapabilities,
        previousUsage: ProfileCurrentUsage?,
        currentUsage: ProfileCurrentUsage,
        acceptedComponents: Set<AcceptedUsageComponent>,
        committedAt: Date
    ) -> AcceptedUsageRefreshEvent {
        nextSequence &+= 1
        let event = AcceptedUsageRefreshEvent(
            sequence: nextSequence,
            identity: identity,
            profileName: profileName,
            trigger: trigger,
            presentationContext: presentationContext,
            capabilities: capabilities,
            previousUsage: previousUsage,
            currentUsage: currentUsage,
            acceptedComponents: acceptedComponents,
            committedAt: committedAt
        )
        for observer in Array(observers.values) {
            observer(event)
        }
        return event
    }

    @discardableResult
    func publishFailure(
        _ candidate: UsageRefreshFailureCandidate
    ) -> UsageRefreshFailureEvent {
        nextSequence &+= 1
        let event = UsageRefreshFailureEvent(
            sequence: nextSequence,
            identity: candidate.identity,
            profileName: candidate.profileName,
            invocationOrder: candidate.invocationOrder,
            trigger: candidate.trigger,
            presentationContext: candidate.presentationContext,
            component: candidate.component,
            failure: candidate.failure
        )
        for observer in Array(failureObservers.values) {
            observer(event)
        }
        return event
    }

    func publishBatch(_ result: UsageRefreshBatchResult) {
        for observer in Array(batchObservers.values) {
            observer(result)
        }
    }
}

nonisolated struct UsageRefreshCommitCandidate: @unchecked Sendable {
    let identity: ProviderRefreshIdentity
    let profileName: String
    let inputGeneration: UInt64
    let invocationOrder: UInt64
    let trigger: UsageRefreshTrigger
    let presentationContext: UsagePresentationContext
    let capabilities: ProviderCapabilities
    let providerResult: ProviderFetchResult?
    let apiUsage: APIUsage?
    let acceptedComponents: Set<AcceptedUsageComponent>
}

nonisolated struct UsageRefreshCommitReceipt: @unchecked Sendable {
    let previousUsage: ProfileCurrentUsage?
    let currentUsage: ProfileCurrentUsage
    let committedAt: Date
}

nonisolated enum UsageRefreshCommitError: Error, Equatable {
    case profileUnavailable
    case providerMismatch
    case providerRevisionMismatch
    case inputInvalidated
    case persistenceRejected
}

@MainActor
protocol UsageRefreshCommitting: AnyObject, Sendable {
    func loadCurrentUsage(
        for identity: ProviderRefreshIdentity
    ) throws -> ProfileCurrentUsage?

    func commit(
        _ candidate: UsageRefreshCommitCandidate
    ) async throws -> UsageRefreshCommitReceipt

    func currentInputGeneration(for profileID: UUID) -> UInt64

    func publishFailure(
        _ candidate: UsageRefreshFailureCandidate,
        snapshot: PresentationSnapshot?,
        presentationStore: UsagePresentationStore
    ) async -> Bool

    func publishCommittedPresentation(
        _ candidate: UsageRefreshCommitCandidate,
        snapshot: PresentationSnapshot,
        presentationStore: UsagePresentationStore
    ) async -> Bool

}

@MainActor
final class UsageRefreshInputLedger {
    private var generations: [UUID: UInt64] = [:]
    private var invocationOrders: [UUID: UInt64] = [:]
    private var deletingProfiles: Set<UUID> = []
    private var latestInvocation: UInt64 = 0

    func generation(for profileID: UUID) -> UInt64 {
        if let generation = generations[profileID] {
            return generation
        }
        generations[profileID] = 0
        return 0
    }

    func register(profileIDs: some Sequence<UUID>) {
        for profileID in profileIDs {
            if generations[profileID] == nil {
                generations[profileID] = 0
            }
            if invocationOrders[profileID] == nil {
                invocationOrders[profileID] = 0
            }
        }
    }

    func registerInvocation(
        _ invocationOrder: UInt64,
        profileIDs: some Sequence<UUID>
    ) {
        latestInvocation = max(
            latestInvocation,
            invocationOrder
        )
        register(profileIDs: profileIDs)
        for profileID in profileIDs {
            invocationOrders[profileID] = max(
                invocationOrders[profileID] ?? 0,
                invocationOrder
            )
        }
    }

    func invocationOrder(for profileID: UUID) -> UInt64 {
        invocationOrders[profileID] ?? 0
    }

    var latestInvocationOrder: UInt64 {
        latestInvocation
    }

    @discardableResult
    func invalidate(profileID: UUID) -> UInt64 {
        let value = (generations[profileID] ?? 0) &+ 1
        generations[profileID] = value
        return value
    }

    func invalidateAll(authoritativeProfileIDs: some Sequence<UUID> = []) {
        register(profileIDs: authoritativeProfileIDs)
        for profileID in Array(generations.keys) {
            generations[profileID] = (generations[profileID] ?? 0) &+ 1
        }
    }

    func beginDeletion(profileID: UUID) {
        deletingProfiles.insert(profileID)
        _ = invalidate(profileID: profileID)
    }

    func completeDeletion(profileID: UUID) {
        // UUIDs are never reused. Retain the terminal tombstone and advance
        // its generation so no delayed MainActor publication can observe an
        // implicit generation-zero ABA after engine removal.
        deletingProfiles.insert(profileID)
        _ = invalidate(profileID: profileID)
    }

    func isDeleting(_ profileID: UUID) -> Bool {
        deletingProfiles.contains(profileID)
    }
}

@MainActor
final class LiveUsageRefreshCommitter: UsageRefreshCommitting {
    private let profileManager: ProfileManager
    private let inputLedger: UsageRefreshInputLedger
    private let eventHub: UsageRefreshEventHub
    private let now: () -> Date

    init(
        profileManager: ProfileManager,
        inputLedger: UsageRefreshInputLedger,
        eventHub: UsageRefreshEventHub,
        now: @escaping () -> Date = Date.init
    ) {
        self.profileManager = profileManager
        self.inputLedger = inputLedger
        self.eventHub = eventHub
        self.now = now
    }

    func loadCurrentUsage(
        for identity: ProviderRefreshIdentity
    ) throws -> ProfileCurrentUsage? {
        try profileManager.loadCurrentUsage(
            for: identity.profileID,
            expectedProviderID: identity.providerID,
            expectedProviderRevision: identity.providerRevision
        )
    }

    func currentInputGeneration(for profileID: UUID) -> UInt64 {
        inputLedger.generation(for: profileID)
    }

    func publishFailure(
        _ candidate: UsageRefreshFailureCandidate,
        snapshot: PresentationSnapshot?,
        presentationStore: UsagePresentationStore
    ) async -> Bool {
        guard inputLedger.generation(
            for: candidate.identity.profileID
        ) == candidate.inputGeneration,
        inputLedger.invocationOrder(
            for: candidate.identity.profileID
        ) == candidate.invocationOrder else {
            return false
        }
        if let snapshot {
            _ = presentationStore.publish(
                snapshot,
                expected: candidate.presentationContext,
                invocationOrder: candidate.invocationOrder
            )
        }
        eventHub.publishFailure(candidate)
        return true
    }

    func publishCommittedPresentation(
        _ candidate: UsageRefreshCommitCandidate,
        snapshot: PresentationSnapshot,
        presentationStore: UsagePresentationStore
    ) async -> Bool {
        guard inputLedger.generation(
            for: candidate.identity.profileID
        ) == candidate.inputGeneration,
        inputLedger.invocationOrder(
            for: candidate.identity.profileID
        ) == candidate.invocationOrder else {
            return false
        }
        _ = presentationStore.publish(
            snapshot,
            expected: candidate.presentationContext,
            invocationOrder: candidate.invocationOrder
        )
        return true
    }

    func commit(
        _ candidate: UsageRefreshCommitCandidate
    ) async throws -> UsageRefreshCommitReceipt {
        guard !inputLedger.isDeleting(candidate.identity.profileID) else {
            throw UsageRefreshCommitError.profileUnavailable
        }
        guard inputLedger.generation(
            for: candidate.identity.profileID
        ) == candidate.inputGeneration,
        inputLedger.invocationOrder(
            for: candidate.identity.profileID
        ) == candidate.invocationOrder else {
            throw UsageRefreshCommitError.inputInvalidated
        }

        let previous = try loadCurrentUsage(for: candidate.identity)
        var current = previous ?? ProfileCurrentUsage(
            providerID: candidate.identity.providerID,
            providerRevision: candidate.identity.providerRevision
        )
        current.providerID = candidate.identity.providerID
        current.providerRevision =
            candidate.identity.providerRevision

        if candidate.acceptedComponents.contains(.providerUsage),
           let providerResult = candidate.providerResult {
            current.report = providerResult.report
            current.claudeUsage = providerResult.claudeUsage
            if candidate.identity.providerID != .claude {
                current.apiUsage = nil
            }
        }
        if candidate.acceptedComponents.contains(.claudeAPI) {
            current.apiUsage = candidate.apiUsage
        }

        let installation = try profileManager.commitCurrentUsage(
            current,
            for: candidate.identity.profileID,
            expectedProviderID: candidate.identity.providerID,
            expectedProviderRevision:
                candidate.identity.providerRevision,
            publishToActiveProfile:
                profileManager.activeProfile?.id
                    == candidate.identity.profileID
        )
        let committedAt = now()
        let receipt = UsageRefreshCommitReceipt(
            previousUsage: installation.previous,
            currentUsage: installation.current,
            committedAt: committedAt
        )
        // The input check, durable installation, exact readback, and accepted
        // event are one non-suspending MainActor transaction in production.
        // Provider-input invalidation therefore orders strictly before or
        // after the installed value and its event.
        _ = eventHub.publish(
            identity: candidate.identity,
            profileName: candidate.profileName,
            trigger: candidate.trigger,
            presentationContext: candidate.presentationContext,
            capabilities: candidate.capabilities,
            previousUsage: receipt.previousUsage,
            currentUsage: receipt.currentUsage,
            acceptedComponents: candidate.acceptedComponents,
            committedAt: receipt.committedAt
        )
        return receipt
    }
}

@MainActor
final class UsageRefreshRuntime {
    let registry: UsageProviderRegistry
    let presentationStore: UsagePresentationStore
    let eventHub: UsageRefreshEventHub
    let inputLedger: UsageRefreshInputLedger
    let engine: UsageRefreshEngine

    private(set) var presentationContext: UsagePresentationContext = .empty
    private let committer: any UsageRefreshCommitting
    private let now: @Sendable () -> Date
    private var isShutdown = false
    private var refreshInvocationOrder: UInt64 = 0

    init(
        registry: UsageProviderRegistry,
        presentationStore: UsagePresentationStore,
        eventHub: UsageRefreshEventHub,
        inputLedger: UsageRefreshInputLedger,
        committer: any UsageRefreshCommitting,
        statusFetch: @escaping UsageRefreshEngine.StatusFetch,
        now: @escaping @Sendable () -> Date = Date.init,
        batchObserver: UsageRefreshEngine.BatchObserver? = nil
    ) {
        self.registry = registry
        self.presentationStore = presentationStore
        self.eventHub = eventHub
        self.inputLedger = inputLedger
        self.committer = committer
        self.now = now
        engine = UsageRefreshEngine(
            committer: committer,
            presentationStore: presentationStore,
            statusFetch: statusFetch,
            now: now,
            batchObserver: { result in
                let normalized = await MainActor.run {
                    let normalized = UsageRefreshBatchResult(
                        batchID: result.batchID,
                        invocationOrder:
                            result.invocationOrder,
                        outcomes: result.outcomes,
                        trigger: result.trigger,
                        presentationContext:
                            result.presentationContext,
                        isLatestBatch:
                            result.isLatestBatch
                                && result.invocationOrder
                                    == inputLedger
                                        .latestInvocationOrder
                    )
                    eventHub.publishBatch(normalized)
                    return normalized
                }
                await batchObserver?(normalized)
            }
        )
    }

    static func live(
        profileManager: ProfileManager,
        apiService: ClaudeAPIService,
        statusService: ClaudeStatusService,
        featureAvailability: UsageProviderFeatureAvailability =
            .production,
        now: @escaping @Sendable () -> Date = Date.init,
        batchObserver: UsageRefreshEngine.BatchObserver? = nil
    ) -> UsageRefreshRuntime {
        let presentationStore = UsagePresentationStore()
        let eventHub = UsageRefreshEventHub()
        let inputLedger = UsageRefreshInputLedger()
        let committer = LiveUsageRefreshCommitter(
            profileManager: profileManager,
            inputLedger: inputLedger,
            eventHub: eventHub,
            now: now
        )
        let registry = UsageProviderRegistry(
            featureAvailability: featureAvailability,
            claudeRequestCapture: { profile in
                let coreRequest = Result {
                    try apiService.captureUsageRequest(for: profile)
                }
                let apiRequest = apiService.captureAPIUsageRequest(
                    for: profile
                )
                if apiRequest == nil {
                    _ = try coreRequest.get()
                }
                let apiFetch: ProviderAPIFetch?
                if let apiRequest {
                    apiFetch = { @Sendable in
                        try await apiService.fetchAPIUsageData(
                            using: apiRequest
                        )
                    }
                } else {
                    apiFetch = nil
                }
                return CapturedClaudeProviderRequest(
                    coreFetch: {
                        try await apiService.fetchUsageData(
                            using: coreRequest.get()
                        )
                    },
                    apiFetch: apiFetch
                )
            },
            codexExecutableResolver: {
                try UsageRefreshRuntime.resolveCodexExecutable()
            },
            codexFetchFactory:
                UsageProviderRegistry.makeFreshCodexFetch,
            now: now
        )
        return UsageRefreshRuntime(
            registry: registry,
            presentationStore: presentationStore,
            eventHub: eventHub,
            inputLedger: inputLedger,
            committer: committer,
            statusFetch: {
                try await statusService.fetchStatus()
            },
            now: now,
            batchObserver: batchObserver
        )
    }

    func activate(
        profiles: [Profile],
        focusedProfileID: UUID?,
        visibleProfileIDs: Set<UUID>,
        epoch: UInt64,
        mode: UsagePresentationContext.Mode = .single
    ) {
        guard !isShutdown else { return }
        inputLedger.register(profileIDs: profiles.map(\.id))
        let context = UsagePresentationContext(
            epoch: epoch,
            focusedProfileID: focusedProfileID,
            visibleProfileIDs: visibleProfileIDs,
            mode: mode
        )
        presentationContext = context

        var hydrated: [UUID: PresentationSnapshot] = [:]
        for profile in profiles
        where visibleProfileIDs.contains(profile.id)
            || profile.deletionInProgress
            || inputLedger.isDeleting(profile.id) {
            let identity = ProviderRefreshIdentity(
                profileID: profile.id,
                providerID: profile.providerID,
                providerRevision: profile.providerRevision
            )
            if profile.deletionInProgress
                || inputLedger.isDeleting(profile.id) {
                let retained = inputLedger.isDeleting(profile.id)
                    ? presentationStore.snapshot(for: profile.id)
                    : nil
                let retainedForIdentity =
                    retained?.providerID == profile.providerID
                        && retained?.providerRevision
                            == profile.providerRevision
                    ? retained
                    : nil
                hydrated[profile.id] = PresentationSnapshot(
                    profileID: profile.id,
                    profileName: profile.name,
                    providerID: profile.providerID,
                    providerRevision: profile.providerRevision,
                    presentationEpoch: epoch,
                    capabilities: capabilities(
                        for: profile.providerID
                    ),
                    configurationState: .deleting,
                    report: retainedForIdentity?.report,
                    claudeUsage:
                        retainedForIdentity?.claudeUsage,
                    claudeAPIUsage:
                        retainedForIdentity?.claudeAPIUsage,
                    activity: .idle,
                    lastSuccessfulAt:
                        retainedForIdentity?.lastSuccessfulAt,
                    currentFailure:
                        retainedForIdentity?.currentFailure
                )
                if !inputLedger.isDeleting(profile.id) {
                    inputLedger.beginDeletion(
                        profileID: profile.id
                    )
                }
                continue
            }
            do {
                let usage = try committer.loadCurrentUsage(
                    for: identity
                )
                let initialState = configurationState(
                    for: profile
                )
                let shouldExposeCachedUsage =
                    initialState == .ready
                        || initialState == .disabled
                hydrated[profile.id] = PresentationSnapshot(
                    profileID: profile.id,
                    profileName: profile.name,
                    providerID: profile.providerID,
                    providerRevision: profile.providerRevision,
                    presentationEpoch: epoch,
                    capabilities: capabilities(
                        for: profile.providerID
                    ),
                    configurationState: initialState,
                    report: shouldExposeCachedUsage
                        ? usage?.report
                        : nil,
                    claudeUsage: shouldExposeCachedUsage
                        ? usage?.claudeUsage
                        : nil,
                    claudeAPIUsage: shouldExposeCachedUsage
                        ? usage?.apiUsage
                        : nil,
                    activity: .idle,
                    lastSuccessfulAt: usage?.report?.fetchedAt,
                    currentFailure: initialState == .ready
                        ? nil
                        : ProviderRefreshFailure(
                            kind: initialState == .disabled
                                ? .disabled
                                : initialState == .unlinked
                                    ? .unlinked
                                    : .unauthenticated,
                            occurredAt: now(),
                            isRecoverable:
                                initialState != .disabled,
                            consecutiveCount: 0
                        )
                )
            } catch {
                hydrated[profile.id] = PresentationSnapshot(
                    profileID: profile.id,
                    profileName: profile.name,
                    providerID: profile.providerID,
                    providerRevision: profile.providerRevision,
                    presentationEpoch: epoch,
                    capabilities: capabilities(
                        for: profile.providerID
                    ),
                    configurationState: .invalid,
                    report: nil,
                    claudeUsage: nil,
                    claudeAPIUsage: nil,
                    activity: .idle,
                    lastSuccessfulAt: nil,
                    currentFailure: ProviderRefreshFailure(
                        kind: .persistence,
                        occurredAt: now(),
                        isRecoverable: true,
                        consecutiveCount: 1
                    )
                )
            }
        }
        presentationStore.activate(context, hydrated: hydrated)
    }

    @discardableResult
    func refresh(
        profiles: [Profile],
        trigger: UsageRefreshTrigger
    ) -> Task<UUID, Never> {
        guard !isShutdown else {
            return Task { UUID() }
        }
        refreshInvocationOrder &+= 1
        let invocationOrder = refreshInvocationOrder
        inputLedger.register(profileIDs: profiles.map(\.id))
        inputLedger.registerInvocation(
            invocationOrder,
            profileIDs: profiles.map(\.id)
        )
        presentationStore.registerActivityInvocation(
            invocationOrder,
            profileIDs: profiles.map(\.id)
        )
        if profiles.contains(
            where: { $0.providerID == .claude }
        ) {
            presentationStore.registerClaudeStatusInvocation(
                invocationOrder
            )
        }
        let context = presentationContext
        var unavailableProfileIDs = Set<UUID>()
        let captured = profiles.compactMap { profile -> CapturedProviderRefreshJob? in
            guard !profile.deletionInProgress,
                  !inputLedger.isDeleting(profile.id) else {
                unavailableProfileIDs.insert(profile.id)
                return nil
            }
            let requestContext = UsageRefreshRequestContext(
                trigger: trigger,
                requestedAt: now(),
                presentationEpoch: context.epoch
            )
            do {
                return try registry.capture(
                    profile: profile,
                    context: requestContext
                )
            } catch {
                publishCaptureFailure(
                    error,
                    profile: profile,
                    context: context,
                    trigger: trigger,
                    invocationOrder: invocationOrder
                )
                unavailableProfileIDs.insert(profile.id)
                return nil
            }
        }
        let generations = Dictionary(
            uniqueKeysWithValues: profiles.map {
                ($0.id, inputLedger.generation(for: $0.id))
            }
        )
        return Task {
            await engine.enqueue(
                captured,
                trigger: trigger,
                presentationContext: context,
                inputGenerations: generations,
                unavailableProfileIDs: unavailableProfileIDs,
                invocationOrder: invocationOrder,
                requestsClaudeStatus: profiles.contains {
                    $0.providerID == .claude
                }
            )
        }
    }

    func invalidate(profileID: UUID) {
        guard !isShutdown else { return }
        _ = inputLedger.invalidate(profileID: profileID)
        Task {
            await engine.invalidate(profileID: profileID)
        }
    }

    func invalidateAll(profiles: [Profile]) {
        guard !isShutdown else { return }
        inputLedger.invalidateAll(
            authoritativeProfileIDs: profiles.map(\.id)
        )
        for profile in profiles {
            Task {
                await engine.invalidate(profileID: profile.id)
            }
        }
    }

    func beginDeletion(profileID: UUID) {
        guard !isShutdown else { return }
        inputLedger.beginDeletion(profileID: profileID)
        presentationStore.markDeleting(profileID: profileID)
        Task {
            await engine.invalidate(profileID: profileID)
        }
    }

    func completeDeletion(profileID: UUID) {
        guard !isShutdown else { return }
        Task {
            await engine.remove(profileID: profileID)
            await MainActor.run {
                inputLedger.completeDeletion(
                    profileID: profileID
                )
            }
        }
    }

    func shutdown(profiles: [Profile]) {
        guard !isShutdown else { return }
        isShutdown = true
        inputLedger.invalidateAll(
            authoritativeProfileIDs: profiles.map(\.id)
        )
        presentationStore.shutdown()
        Task {
            await engine.shutdown()
        }
    }

    private func publishCaptureFailure(
        _ error: Error,
        profile: Profile,
        context: UsagePresentationContext,
        trigger: UsageRefreshTrigger,
        invocationOrder: UInt64
    ) {
        let kind: ProviderRefreshFailureKind
        let state: ProviderConfigurationState
        switch error as? UsageProviderCaptureError {
        case .profileDeletionInProgress:
            return
        case .featureDisabled:
            kind = .disabled
            state = .disabled
        case .codexHomeUnlinked:
            kind = .unlinked
            state = .unlinked
        case .codexExecutableMissing:
            kind = .dependencyMissing
            state = .dependencyMissing
        case .claudeCredentialsUnavailable:
            kind = .unauthenticated
            state = .unauthenticated
        default:
            kind = .invalidConfiguration
            state = .invalid
        }
        let cached = presentationStore.snapshot(for: profile.id)
        presentationStore.publish(
            PresentationSnapshot(
                profileID: profile.id,
                profileName: profile.name,
                providerID: profile.providerID,
                providerRevision: profile.providerRevision,
                presentationEpoch: context.epoch,
                capabilities: capabilities(for: profile.providerID),
                configurationState: state,
                report: cached?.report,
                claudeUsage: cached?.claudeUsage,
                claudeAPIUsage: cached?.claudeAPIUsage,
                activity: .idle,
                lastSuccessfulAt: cached?.lastSuccessfulAt,
                currentFailure: ProviderRefreshFailure(
                    kind: kind,
                    occurredAt: now(),
                    isRecoverable: kind != .disabled,
                    consecutiveCount:
                        (cached?.currentFailure?.consecutiveCount ?? 0) + 1
                )
            ),
            expected: context,
            invocationOrder: invocationOrder
        )
        eventHub.publishFailure(
            UsageRefreshFailureCandidate(
                identity: ProviderRefreshIdentity(
                    profileID: profile.id,
                    providerID: profile.providerID,
                    providerRevision: profile.providerRevision
                ),
                profileName: profile.name,
                inputGeneration:
                    inputLedger.generation(for: profile.id),
                invocationOrder: invocationOrder,
                trigger: trigger,
                presentationContext: context,
                component: .capture,
                failure: ProviderRefreshFailure(
                    kind: kind,
                    occurredAt: now(),
                    isRecoverable: kind != .disabled,
                    consecutiveCount:
                        (cached?.currentFailure?.consecutiveCount ?? 0) + 1
                )
            )
        )
    }

    private func capabilities(for providerID: ProviderID)
        -> ProviderCapabilities {
        registry.capabilities(for: providerID)
    }

    private func configurationState(
        for profile: Profile
    ) -> ProviderConfigurationState {
        switch profile.providerConfiguration {
        case .claude:
            return profile.hasUsageCredentials
                ? .ready
                : .unauthenticated
        case .codex(let configuration):
            guard registry.isRefreshEnabled(for: .codex) else {
                return .disabled
            }
            return configuration.linkedHome == nil
                ? .unlinked
                : .ready
        }
    }

    nonisolated private static func resolveCodexExecutable() throws -> URL {
        let environmentPaths =
            ProcessInfo.processInfo.environment["PATH"]?
                .split(separator: ":")
                .map(String.init) ?? []
        let candidates = environmentPaths + [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin").path
        ]
        for directory in candidates {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(
                atPath: candidate.path
            ) {
                return candidate
            }
        }
        throw UsageProviderCaptureError.codexExecutableMissing
    }
}

nonisolated struct UsageRefreshBatchResult: Sendable {
    nonisolated enum Outcome: Sendable {
        case accepted
        case failed
        case superseded
        case unavailable
    }

    let batchID: UUID
    let invocationOrder: UInt64
    let outcomes: [UUID: Outcome]
    let trigger: UsageRefreshTrigger
    let presentationContext: UsagePresentationContext
    let isLatestBatch: Bool

    var hasCoreSuccess: Bool {
        outcomes.values.contains {
            if case .accepted = $0 { return true }
            return false
        }
    }
}

actor UsageRefreshEngine {
    typealias StatusFetch = @Sendable () async throws -> ClaudeStatus
    typealias BatchObserver =
        @Sendable (UsageRefreshBatchResult) async -> Void

    private struct Request {
        let requestID: UUID
        let batchID: UUID
        let invocationOrder: UInt64
        let trigger: UsageRefreshTrigger
        let presentationContext: UsagePresentationContext
        let inputGeneration: UInt64
        let job: CapturedProviderRefreshJob
    }

    private struct Running {
        enum Phase {
            case fetching
            case committing
        }

        let request: Request
        let generation: UInt64
        let task: Task<Void, Never>
        var phase: Phase
        var providerTerminal = false
        var providerSucceeded = false
        var providerError: Error?
        var apiTerminal: Bool
        var wasSuperseded = false

        var allComponentsTerminal: Bool {
            providerTerminal && apiTerminal
        }

    }

    private enum ComponentCompletion: @unchecked Sendable {
        case provider(Result<ProviderFetchResult, Error>)
        case api(Result<APIUsage, Error>)
    }

    private struct Slot {
        var generation: UInt64 = 0
        var latestInvocationOrder: UInt64 = 0
        var identity: ProviderRefreshIdentity?
        var running: Running?
        var pending: Request?
        var lastSuccess: Date?
        var consecutiveFailures: Int = 0
    }

    private struct Batch {
        var outstanding: Set<UUID>
        var outcomes: [UUID: UsageRefreshBatchResult.Outcome] = [:]
        let trigger: UsageRefreshTrigger
        let presentationContext: UsagePresentationContext
        let generation: UInt64
    }

    private struct StatusRequest {
        let id: UUID
        let context: UsagePresentationContext
        let invocationOrder: UInt64
    }

    private let committer: any UsageRefreshCommitting
    private let presentationStore: UsagePresentationStore
    private let statusFetch: StatusFetch
    private let now: @Sendable () -> Date
    private let batchObserver: BatchObserver?

    private var slots: [UUID: Slot] = [:]
    private var batches: [UUID: Batch] = [:]
    private var statusRunning: (StatusRequest, Task<Void, Never>)?
    private var statusPending: StatusRequest?
    private var isShutdown = false
    private var latestBatchGeneration: UInt64 = 0
    private var latestStatusInvocationOrder: UInt64 = 0
    private var removedProfiles: Set<UUID> = []

    init(
        committer: any UsageRefreshCommitting,
        presentationStore: UsagePresentationStore,
        statusFetch: @escaping StatusFetch,
        now: @escaping @Sendable () -> Date = Date.init,
        batchObserver: BatchObserver? = nil
    ) {
        self.committer = committer
        self.presentationStore = presentationStore
        self.statusFetch = statusFetch
        self.now = now
        self.batchObserver = batchObserver
    }

    @discardableResult
    func enqueue(
        _ jobs: [CapturedProviderRefreshJob],
        trigger: UsageRefreshTrigger,
        presentationContext: UsagePresentationContext,
        inputGenerations: [UUID: UInt64],
        unavailableProfileIDs: Set<UUID> = [],
        invocationOrder: UInt64? = nil,
        requestsClaudeStatus: Bool? = nil
    ) async -> UUID {
        let batchID = UUID()
        let batchGeneration: UInt64
        if let invocationOrder {
            batchGeneration = invocationOrder
            latestBatchGeneration = max(
                latestBatchGeneration,
                invocationOrder
            )
        } else {
            latestBatchGeneration &+= 1
            batchGeneration = latestBatchGeneration
        }
        guard !isShutdown else {
            let profileIDs = Set(
                jobs.map(\.identity.profileID)
            ).union(unavailableProfileIDs)
            await batchObserver?(
                UsageRefreshBatchResult(
                    batchID: batchID,
                    invocationOrder: batchGeneration,
                    outcomes: Dictionary(
                        uniqueKeysWithValues: profileIDs.map {
                            ($0, .superseded)
                        }
                    ),
                    trigger: trigger,
                    presentationContext: presentationContext,
                    isLatestBatch:
                        batchGeneration == latestBatchGeneration
                )
            )
            return batchID
        }
        guard !jobs.isEmpty || !unavailableProfileIDs.isEmpty else {
            await batchObserver?(
                UsageRefreshBatchResult(
                    batchID: batchID,
                    invocationOrder: batchGeneration,
                    outcomes: [:],
                    trigger: trigger,
                    presentationContext: presentationContext,
                    isLatestBatch:
                        batchGeneration == latestBatchGeneration
                )
            )
            return batchID
        }

        let jobProfileIDs = Set(jobs.map(\.identity.profileID))
        var batch = Batch(
            outstanding: jobProfileIDs.union(unavailableProfileIDs),
            trigger: trigger,
            presentationContext: presentationContext,
            generation: batchGeneration
        )
        for profileID in unavailableProfileIDs {
            batch.outstanding.remove(profileID)
            batch.outcomes[profileID] = .unavailable
        }
        batches[batchID] = batch

        let requests = jobs.map { job in
            Request(
                requestID: UUID(),
                batchID: batchID,
                invocationOrder: batchGeneration,
                trigger: trigger,
                presentationContext: presentationContext,
                inputGeneration:
                    inputGenerations[job.identity.profileID] ?? 0,
                job: job
            )
        }
        // Establish ownership for every batch member without suspension.
        // An older multi-profile enqueue that later resumes can therefore
        // never start a member already claimed by a newer invocation.
        for request in requests {
            register(request)
        }
        for request in requests {
            await enqueue(request)
        }

        if requestsClaudeStatus
            ?? jobs.contains(
                where: { $0.identity.providerID == .claude }
            ) {
            await enqueueStatus(
                for: presentationContext,
                invocationOrder: batchGeneration
            )
        }
        if jobs.isEmpty {
            batches.removeValue(forKey: batchID)
            await batchObserver?(
                UsageRefreshBatchResult(
                    batchID: batchID,
                    invocationOrder: batchGeneration,
                    outcomes: batch.outcomes,
                    trigger: trigger,
                    presentationContext: presentationContext,
                    isLatestBatch:
                        batchGeneration
                            == latestBatchGeneration
                )
            )
        }
        return batchID
    }

    func invalidate(profileID: UUID) async {
        guard !isShutdown else { return }
        guard var slot = slots[profileID] else { return }
        slot.generation &+= 1
        if let running = slot.running,
           running.phase == .fetching {
            running.task.cancel()
        }
        let pending = slot.pending
        slot.pending = nil
        slots[profileID] = slot
        if let pending {
            await finishBatchMember(
                pending,
                outcome: .superseded
            )
        }
    }

    func remove(profileID: UUID) async {
        guard !isShutdown else { return }
        removedProfiles.insert(profileID)
        let removedSlot = slots.removeValue(forKey: profileID)
        removedSlot?.running?.task.cancel()
        await presentationStore.remove(profileID: profileID)
        if let running = removedSlot?.running {
            await finishBatchMember(
                running.request,
                outcome: .superseded
            )
        }
        if let pending = removedSlot?.pending {
            await finishBatchMember(
                pending,
                outcome: .superseded
            )
        }
    }

    func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true
        for slot in slots.values {
            slot.running?.task.cancel()
        }
        statusRunning?.1.cancel()
        slots.removeAll()
        batches.removeAll()
        statusRunning = nil
        statusPending = nil
        await presentationStore.shutdown()
    }

    private func enqueue(_ request: Request) async {
        let profileID = request.job.identity.profileID
        guard !removedProfiles.contains(profileID) else {
            await finishBatchMember(
                request,
                outcome: .superseded
            )
            return
        }
        var slot = slots[profileID] ?? Slot()
        guard request.invocationOrder
                == slot.latestInvocationOrder else {
            await finishBatchMember(
                request,
                outcome: .superseded
            )
            return
        }

        if let running = slot.running {
            if running.phase == .fetching {
                running.task.cancel()
            }
            let replaced = slot.pending
            slot.pending = request
            slots[profileID] = slot
            if let replaced {
                await finishBatchMember(
                    replaced,
                    outcome: .superseded
                )
            }
            guard slots[profileID]?.pending?.requestID
                    == request.requestID else {
                return
            }
            await publishActivity(
                for: request,
                activity: .queued(
                    requestID: request.requestID,
                    trigger: request.trigger,
                    requestedAt: now()
                ),
                slot: slot
            )
            return
        }

        slots[profileID] = slot
        await start(request, generation: slot.generation)
    }

    private func register(_ request: Request) {
        let profileID = request.job.identity.profileID
        guard !removedProfiles.contains(profileID) else {
            return
        }
        var slot = slots[profileID] ?? Slot()
        guard request.invocationOrder
                > slot.latestInvocationOrder else {
            return
        }
        if slot.identity != request.job.identity {
            slot.lastSuccess = nil
            slot.consecutiveFailures = 0
        }
        slot.identity = request.job.identity
        slot.latestInvocationOrder = request.invocationOrder
        slot.generation &+= 1
        slots[profileID] = slot
    }

    private func start(
        _ request: Request,
        generation: UInt64
    ) async {
        let profileID = request.job.identity.profileID
        let task = Task { [weak self] in
            await withTaskGroup(
                of: ComponentCompletion.self
            ) { group in
                group.addTask {
                    do {
                        return .provider(
                            .success(
                                try await request.job.coreFetch()
                            )
                        )
                    } catch {
                        return .provider(.failure(error))
                    }
                }
                if let apiFetch = request.job.apiFetch {
                    group.addTask {
                        do {
                            return .api(
                                .success(try await apiFetch())
                            )
                        } catch {
                            return .api(.failure(error))
                        }
                    }
                }
                for await completion in group {
                    // Consume one component at a time so each durable commit
                    // and its presentation publication form a serialized
                    // per-request transaction. Fetches still run in parallel.
                    await self?.componentCompleted(
                        request,
                        generation: generation,
                        completion: completion
                    )
                }
            }
            await self?.componentGroupCompleted(
                request,
                generation: generation
            )
        }
        var slot = slots[profileID] ?? Slot()
        slot.running = Running(
            request: request,
            generation: generation,
            task: task,
            phase: .fetching,
            apiTerminal: request.job.apiFetch == nil
        )
        slots[profileID] = slot
        await publishActivity(
            for: request,
            activity: .refreshing(
                requestID: request.requestID,
                trigger: request.trigger,
                startedAt: now()
            ),
            slot: slot
        )
    }

    private func componentCompleted(
        _ request: Request,
        generation: UInt64,
        completion: ComponentCompletion
    ) async {
        let profileID = request.job.identity.profileID
        guard slots[profileID]?.running?.request.requestID
                == request.requestID else {
            return
        }

        let currentInputGeneration =
            await committer.currentInputGeneration(
                for: profileID
            )
        // Actor reentrancy is possible while consulting the MainActor
        // ledger. Never write the slot captured before that suspension.
        guard var slot = slots[profileID],
              var running = slot.running,
              running.request.requestID == request.requestID else {
            return
        }
        guard slot.generation == generation,
              currentInputGeneration == request.inputGeneration else {
            await markComponentSuperseded(
                request,
                generation: generation,
                completion: completion
            )
            return
        }

        running.phase = .committing
        slot.running = running
        slots[profileID] = slot

        switch completion {
        case .provider(let result):
            await providerCompleted(
                request,
                generation: generation,
                result: result
            )
        case .api(let result):
            await apiCompleted(
                request,
                generation: generation,
                result: result
            )
        }
    }

    private func providerCompleted(
        _ request: Request,
        generation: UInt64,
        result: Result<ProviderFetchResult, Error>
    ) async {
        switch result {
        case .success(let value):
            let providerResult = applyingFreshness(
                value,
                refreshInterval: request.job.refreshInterval
            )
            let candidate = UsageRefreshCommitCandidate(
                identity: request.job.identity,
                profileName: request.job.profileName,
                inputGeneration: request.inputGeneration,
                invocationOrder: request.invocationOrder,
                trigger: request.trigger,
                presentationContext:
                    request.presentationContext,
                capabilities: request.job.capabilities,
                providerResult: providerResult,
                apiUsage: nil,
                acceptedComponents: [.providerUsage]
            )
            do {
                let receipt = try await committer.commit(candidate)
                guard var slot = await checkedSlot(
                    for: request,
                    generation: generation,
                    completion: .provider(result),
                    acceptedOnGenerationMismatch: true
                ), var running = slot.running else {
                    return
                }
                running.providerTerminal = true
                running.providerSucceeded = true
                running.providerError = nil
                running.phase = .fetching
                slot.lastSuccess = receipt.committedAt
                slot.consecutiveFailures = 0
                slot.running = running

                let snapshot = makeSnapshot(
                    request,
                    usage: receipt.currentUsage,
                    activity: terminalActivity(
                        for: request,
                        running: running,
                        slot: slot
                    ),
                    failure: nil,
                    slot: slot
                )
                guard await committer
                    .publishCommittedPresentation(
                        candidate,
                        snapshot: snapshot,
                        presentationStore: presentationStore
                    ) else {
                    await markComponentSuperseded(
                        request,
                        generation: generation,
                        completion: .provider(result)
                    )
                    return
                }
                guard var currentSlot = await checkedSlot(
                    for: request,
                    generation: generation,
                    completion: .provider(result),
                    acceptedOnGenerationMismatch: true
                ), var currentRunning = currentSlot.running
                else {
                    return
                }
                currentRunning.providerTerminal = true
                currentRunning.providerSucceeded = true
                currentRunning.providerError = nil
                currentRunning.phase = .fetching
                currentSlot.lastSuccess = receipt.committedAt
                currentSlot.consecutiveFailures = 0
                currentSlot.running = currentRunning
                slots[request.job.identity.profileID] =
                    currentSlot
            } catch let error as UsageRefreshCommitError
            where error == .inputInvalidated
                || error == .profileUnavailable
                || error == .providerMismatch
                || error == .providerRevisionMismatch {
                await markComponentSuperseded(
                    request,
                    generation: generation,
                    completion: .provider(result)
                )
            } catch {
                await providerFailed(
                    request,
                    generation: generation,
                    error:
                        UsageRefreshCommitError.persistenceRejected,
                    component: .persistence
                )
            }
        case .failure(let error):
            await providerFailed(
                request,
                generation: generation,
                error: error,
                component: .providerUsage
            )
        }
    }

    private func providerFailed(
        _ request: Request,
        generation: UInt64,
        error: Error,
        component: UsageRefreshFailureComponent
    ) async {
        let cached = try? await committer.loadCurrentUsage(
            for: request.job.identity
        )
        guard let slot = await checkedSlot(
            for: request,
            generation: generation,
            completion: .provider(.failure(error))
        ), var running = slot.running else {
            return
        }
        let terminalFailure = failure(
            for: error,
            count: slot.consecutiveFailures + 1
        )
        running.providerTerminal = true
        running.providerSucceeded = false
        running.providerError = error
        running.phase = .fetching
        var presentationSlot = slot
        presentationSlot.running = running
        presentationSlot.consecutiveFailures += 1
        let snapshot = makeSnapshot(
            request,
            usage: cached ?? nil,
            activity: terminalActivity(
                for: request,
                running: running,
                slot: presentationSlot
            ),
            failure: terminalFailure,
            slot: presentationSlot
        )
        let accepted = await committer.publishFailure(
            UsageRefreshFailureCandidate(
                identity: request.job.identity,
                profileName: request.job.profileName,
                inputGeneration: request.inputGeneration,
                invocationOrder: request.invocationOrder,
                trigger: request.trigger,
                presentationContext:
                    request.presentationContext,
                component: component,
                failure: terminalFailure
            ),
            snapshot: snapshot,
            presentationStore: presentationStore
        )
        guard accepted,
              var currentSlot = await checkedSlot(
                for: request,
                generation: generation,
                completion: .provider(.failure(error))
              ), var currentRunning = currentSlot.running else {
            await markComponentSuperseded(
                request,
                generation: generation,
                completion: .provider(.failure(error))
            )
            return
        }
        currentRunning.providerTerminal = true
        currentRunning.providerSucceeded = false
        currentRunning.providerError = error
        currentRunning.phase = .fetching
        currentSlot.consecutiveFailures += 1
        currentSlot.running = currentRunning
        slots[request.job.identity.profileID] = currentSlot
    }

    private func apiCompleted(
        _ request: Request,
        generation: UInt64,
        result: Result<APIUsage, Error>
    ) async {
        switch result {
        case .success(let apiUsage):
            let candidate = UsageRefreshCommitCandidate(
                identity: request.job.identity,
                profileName: request.job.profileName,
                inputGeneration: request.inputGeneration,
                invocationOrder: request.invocationOrder,
                trigger: request.trigger,
                presentationContext:
                    request.presentationContext,
                capabilities: request.job.capabilities,
                providerResult: nil,
                apiUsage: apiUsage,
                acceptedComponents: [.claudeAPI]
            )
            do {
                let receipt = try await committer.commit(candidate)
                guard var slot = await checkedSlot(
                    for: request,
                    generation: generation,
                    completion: .api(result),
                    acceptedOnGenerationMismatch: true
                ), var running = slot.running else {
                    return
                }
                running.apiTerminal = true
                running.phase = .fetching
                slot.running = running
                let providerFailure = running.providerError.map {
                    failure(
                        for: $0,
                        count: slot.consecutiveFailures
                    )
                }
                let snapshot = makeSnapshot(
                    request,
                    usage: receipt.currentUsage,
                    activity: terminalActivity(
                        for: request,
                        running: running,
                        slot: slot
                    ),
                    failure: providerFailure,
                    slot: slot
                )
                guard await committer
                    .publishCommittedPresentation(
                        candidate,
                        snapshot: snapshot,
                        presentationStore: presentationStore
                    ) else {
                    await markComponentSuperseded(
                        request,
                        generation: generation,
                        completion: .api(result)
                    )
                    return
                }
                guard var currentSlot = await checkedSlot(
                    for: request,
                    generation: generation,
                    completion: .api(result),
                    acceptedOnGenerationMismatch: true
                ), var currentRunning = currentSlot.running
                else {
                    return
                }
                currentRunning.apiTerminal = true
                currentRunning.phase = .fetching
                currentSlot.running = currentRunning
                slots[request.job.identity.profileID] =
                    currentSlot
            } catch let error as UsageRefreshCommitError
            where error == .inputInvalidated
                || error == .profileUnavailable
                || error == .providerMismatch
                || error == .providerRevisionMismatch {
                await markComponentSuperseded(
                    request,
                    generation: generation,
                    completion: .api(result)
                )
            } catch {
                await apiFailed(
                    request,
                    generation: generation,
                    error: error
                )
            }
        case .failure(let error):
            await apiFailed(
                request,
                generation: generation,
                error: error
            )
        }
    }

    private func apiFailed(
        _ request: Request,
        generation: UInt64,
        error: Error
    ) async {
        let cached = try? await committer.loadCurrentUsage(
            for: request.job.identity
        )
        let cachedSnapshot = await presentationStore.snapshot(
            for: request.job.identity.profileID
        )
        guard var slot = await checkedSlot(
            for: request,
            generation: generation,
            completion: .api(.failure(error))
        ), var running = slot.running else {
            return
        }
        running.apiTerminal = true
        running.phase = .fetching
        slot.running = running
        let snapshot = makeSnapshot(
            request,
            usage: cached ?? nil,
            activity: terminalActivity(
                for: request,
                running: running,
                slot: slot
            ),
            failure: cachedSnapshot?.currentFailure,
            slot: slot
        )
        let terminalFailure = failure(for: error, count: 1)
        let accepted = await committer.publishFailure(
            UsageRefreshFailureCandidate(
                identity: request.job.identity,
                profileName: request.job.profileName,
                inputGeneration: request.inputGeneration,
                invocationOrder: request.invocationOrder,
                trigger: request.trigger,
                presentationContext:
                    request.presentationContext,
                component: .claudeAPI,
                failure: terminalFailure
            ),
            snapshot: snapshot,
            presentationStore: presentationStore
        )
        guard accepted,
              var currentSlot = await checkedSlot(
                for: request,
                generation: generation,
                completion: .api(.failure(error))
              ), var currentRunning = currentSlot.running else {
            await markComponentSuperseded(
                request,
                generation: generation,
                completion: .api(.failure(error))
            )
            return
        }
        currentRunning.apiTerminal = true
        currentRunning.phase = .fetching
        currentSlot.running = currentRunning
        slots[request.job.identity.profileID] = currentSlot
    }

    private func checkedSlot(
        for request: Request,
        generation: UInt64,
        completion: ComponentCompletion,
        acceptedOnGenerationMismatch: Bool = false
    ) async -> Slot? {
        guard let slot = slots[request.job.identity.profileID],
              slot.running?.request.requestID
                == request.requestID else {
            return nil
        }
        guard slot.generation == generation else {
            await markComponentSuperseded(
                request,
                generation: generation,
                completion: completion,
                accepted: acceptedOnGenerationMismatch
            )
            return nil
        }
        return slot
    }

    private func markComponentSuperseded(
        _ request: Request,
        generation: UInt64,
        completion: ComponentCompletion,
        accepted: Bool = false
    ) async {
        let profileID = request.job.identity.profileID
        guard var slot = slots[profileID],
              var running = slot.running,
              running.request.requestID == request.requestID else {
            return
        }
        markTerminal(
            completion,
            in: &running,
            accepted: accepted
        )
        running.wasSuperseded = true
        running.phase = .fetching
        running.task.cancel()
        slot.running = running
        slots[profileID] = slot
    }

    private func markTerminal(
        _ completion: ComponentCompletion,
        in running: inout Running,
        accepted: Bool
    ) {
        switch completion {
        case .provider:
            running.providerTerminal = true
            running.providerSucceeded = accepted
        case .api:
            running.apiTerminal = true
        }
    }

    private func terminalActivity(
        for request: Request,
        running: Running,
        slot: Slot
    ) -> UsageRefreshActivity {
        // Component publications retain ownership of loading until the
        // entire child group has quiesced.
        return .refreshing(
            requestID: request.requestID,
            trigger: request.trigger,
            startedAt: request.job.requestContext.requestedAt
        )
    }

    private func componentGroupCompleted(
        _ request: Request,
        generation: UInt64
    ) async {
        let profileID = request.job.identity.profileID
        guard let slot = slots[profileID],
              let running = slot.running,
              running.request.requestID == request.requestID,
              running.allComponentsTerminal else {
            return
        }
        let replacementActivity: UsageRefreshActivity
        let replacementInvocationOrder: UInt64?
        if let pending = slot.pending {
            replacementActivity = .queued(
                requestID: pending.requestID,
                trigger: pending.trigger,
                requestedAt:
                    pending.job.requestContext.requestedAt
            )
            replacementInvocationOrder =
                pending.invocationOrder
        } else {
            replacementActivity = .idle
            replacementInvocationOrder = nil
        }
        await presentationStore.completeRefreshActivity(
            profileID: profileID,
            requestID: request.requestID,
            invocationOrder: request.invocationOrder,
            replacement: replacementActivity,
            replacementInvocationOrder:
                replacementInvocationOrder,
            expected: request.presentationContext
        )
        // The store hop permits actor reentrancy. Re-read all state used to
        // classify and retire the running request.
        guard let slot = slots[profileID],
              let running = slot.running,
              running.request.requestID == request.requestID,
              running.allComponentsTerminal else {
            return
        }
        let outcome: UsageRefreshBatchResult.Outcome
        if running.providerSucceeded {
            outcome = .accepted
        } else if running.wasSuperseded
            || slot.generation != running.generation {
            outcome = .superseded
        } else {
            outcome = .failed
        }
        // Keep the terminal task installed while the observer runs so an
        // enqueue that reenters cannot start a replacement before this
        // component group has fully quiesced.
        await finishBatchMember(
            running.request,
            outcome: outcome
        )
        guard var authoritativeSlot = slots[profileID],
              authoritativeSlot.running?.request.requestID
                == request.requestID else {
            return
        }
        authoritativeSlot.running = nil
        slots[profileID] = authoritativeSlot
        await startPendingIfNeeded(profileID: profileID)
    }

    private func startPendingIfNeeded(profileID: UUID) async {
        guard var slot = slots[profileID],
              let pending = slot.pending else {
            return
        }
        slot.pending = nil
        slots[profileID] = slot
        guard pending.invocationOrder
                == slot.latestInvocationOrder,
              !removedProfiles.contains(profileID) else {
            await finishBatchMember(
                pending,
                outcome: .superseded
            )
            return
        }
        await start(pending, generation: slot.generation)
    }

    private func finishBatchMember(
        _ request: Request,
        outcome: UsageRefreshBatchResult.Outcome
    ) async {
        guard var batch = batches[request.batchID] else { return }
        batch.outstanding.remove(request.job.identity.profileID)
        batch.outcomes[request.job.identity.profileID] = outcome
        if batch.outstanding.isEmpty {
            batches.removeValue(forKey: request.batchID)
            let result = UsageRefreshBatchResult(
                batchID: request.batchID,
                invocationOrder: batch.generation,
                outcomes: batch.outcomes,
                trigger: batch.trigger,
                presentationContext:
                    batch.presentationContext,
                isLatestBatch:
                    batch.generation == latestBatchGeneration
            )
            await batchObserver?(result)
        } else {
            batches[request.batchID] = batch
        }
    }

    private func applyingFreshness(
        _ result: ProviderFetchResult,
        refreshInterval: TimeInterval
    ) -> ProviderFetchResult {
        var report = result.report
        let lifetime =
            refreshInterval.isFinite && refreshInterval > 0
                ? max(300, refreshInterval * 2)
                : 300
        report.staleAt = report.fetchedAt.addingTimeInterval(
            lifetime
        )
        return ProviderFetchResult(
            report: report,
            claudeUsage: result.claudeUsage
        )
    }

    private func publishActivity(
        for request: Request,
        activity: UsageRefreshActivity,
        slot: Slot
    ) async {
        let cached = await presentationStore.snapshot(
            for: request.job.identity.profileID
        )
        let snapshot = PresentationSnapshot(
            profileID: request.job.identity.profileID,
            profileName: request.job.profileName,
            providerID: request.job.identity.providerID,
            providerRevision:
                request.job.identity.providerRevision,
            presentationEpoch:
                request.presentationContext.epoch,
            capabilities: request.job.capabilities,
            configurationState: .ready,
            report: cached?.report,
            claudeUsage: cached?.claudeUsage,
            claudeAPIUsage: cached?.claudeAPIUsage,
            activity: activity,
            lastSuccessfulAt: slot.lastSuccess
                ?? cached?.lastSuccessfulAt,
            currentFailure: cached?.currentFailure
        )
        await presentationStore.publish(
            snapshot,
            expected: request.presentationContext,
            invocationOrder: request.invocationOrder
        )
    }

    private func makeSnapshot(
        _ request: Request,
        usage: ProfileCurrentUsage?,
        activity: UsageRefreshActivity,
        failure: ProviderRefreshFailure?,
        slot: Slot
    ) -> PresentationSnapshot {
        PresentationSnapshot(
            profileID: request.job.identity.profileID,
            profileName: request.job.profileName,
            providerID: request.job.identity.providerID,
            providerRevision: request.job.identity.providerRevision,
            presentationEpoch: request.presentationContext.epoch,
            capabilities: request.job.capabilities,
            configurationState: configurationState(for: failure),
            report: usage?.report,
            claudeUsage: usage?.claudeUsage,
            claudeAPIUsage: usage?.apiUsage,
            activity: activity,
            lastSuccessfulAt:
                slot.lastSuccess ?? usage?.report?.fetchedAt,
            currentFailure: failure
        )
    }

    private func configurationState(
        for failure: ProviderRefreshFailure?
    ) -> ProviderConfigurationState {
        switch failure?.kind {
        case nil:
            return .ready
        case .disabled:
            return .disabled
        case .unlinked:
            return .unlinked
        case .dependencyMissing:
            return .dependencyMissing
        case .unauthenticated:
            return .unauthenticated
        case .unsupportedAccount:
            return .unsupported
        case .invalidConfiguration:
            return .invalid
        default:
            return .ready
        }
    }

    private func failure(
        for error: Error?,
        count: Int
    ) -> ProviderRefreshFailure {
        let kind: ProviderRefreshFailureKind
        let recoverable: Bool
        let legacyErrorCode: ErrorCode?
        if let error = error as? UsageProviderError {
            legacyErrorCode = nil
            switch error {
            case .capabilityUnavailable, .invalidConfiguration:
                kind = .invalidConfiguration
                recoverable = false
            case .unauthenticated:
                kind = .unauthenticated
                recoverable = true
            case .unsupportedAccount:
                kind = .unsupportedAccount
                recoverable = false
            case .dependencyMissing:
                kind = .dependencyMissing
                recoverable = true
            case .transportFailure:
                kind = .transport
                recoverable = true
            case .protocolFailure:
                kind = .protocolMismatch
                recoverable = true
            case .malformedResponse:
                kind = .malformedResponse
                recoverable = true
            case .timedOut:
                kind = .timedOut
                recoverable = true
            case .cancelled:
                kind = .transport
                recoverable = true
            }
        } else if let error = error as? UsageRefreshCommitError {
            legacyErrorCode = nil
            switch error {
            case .profileUnavailable:
                kind = .invalidConfiguration
            case .providerMismatch, .providerRevisionMismatch:
                kind = .invalidConfiguration
            case .inputInvalidated:
                kind = .unauthenticated
            case .persistenceRejected:
                kind = .persistence
            }
            recoverable = true
        } else if let appError = error as? AppError {
            legacyErrorCode = appError.code
            switch appError.code {
            case .sessionKeyNotFound, .sessionKeyInvalid,
                    .sessionKeyExpired, .apiUnauthorized:
                kind = .unauthenticated
            case .networkTimeout:
                kind = .timedOut
            case .apiInvalidResponse, .apiParsingFailed:
                kind = .malformedResponse
            default:
                kind = .transport
            }
            recoverable = appError.isRecoverable
        } else if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                kind = .timedOut
                legacyErrorCode = .networkTimeout
            case .notConnectedToInternet, .networkConnectionLost,
                    .cannotConnectToHost, .cannotFindHost,
                    .dnsLookupFailed:
                kind = .transport
                legacyErrorCode = .networkUnavailable
            default:
                kind = .transport
                legacyErrorCode = .networkGenericError
            }
            recoverable = true
        } else {
            kind = .unknown
            recoverable = true
            legacyErrorCode = nil
        }
        return ProviderRefreshFailure(
            kind: kind,
            occurredAt: now(),
            isRecoverable: recoverable,
            consecutiveCount: count,
            legacyErrorCode: legacyErrorCode
        )
    }

    private func enqueueStatus(
        for context: UsagePresentationContext,
        invocationOrder: UInt64
    ) async {
        guard invocationOrder
                >= latestStatusInvocationOrder else {
            return
        }
        latestStatusInvocationOrder = invocationOrder
        await presentationStore.registerClaudeStatusInvocation(
            invocationOrder
        )
        guard invocationOrder
                == latestStatusInvocationOrder else {
            return
        }
        let request = StatusRequest(
            id: UUID(),
            context: context,
            invocationOrder: invocationOrder
        )
        if let running = statusRunning {
            if invocationOrder > running.0.invocationOrder {
                if running.0.context == context {
                    statusRunning = (
                        StatusRequest(
                            id: running.0.id,
                            context: context,
                            invocationOrder: invocationOrder
                        ),
                        running.1
                    )
                    if (statusPending?.invocationOrder ?? 0)
                        < invocationOrder {
                        statusPending = nil
                    }
                    await presentationStore.beginClaudeStatus(
                        expected: context,
                        invocationOrder: invocationOrder
                    )
                } else {
                    statusPending = request
                }
            }
            return
        }
        await startStatus(request)
    }

    private func startStatus(_ request: StatusRequest) async {
        let task = Task { [weak self, statusFetch] in
            do {
                let status = try await statusFetch()
                await self?.statusCompleted(
                    request,
                    result: .success(status)
                )
            } catch {
                await self?.statusCompleted(
                    request,
                    result: .failure(error)
                )
            }
        }
        statusRunning = (request, task)
        await presentationStore.beginClaudeStatus(
            expected: request.context,
            invocationOrder: request.invocationOrder
        )
    }

    private func statusCompleted(
        _ request: StatusRequest,
        result: Result<ClaudeStatus, Error>
    ) async {
        guard let authoritativeRequest = statusRunning?.0,
              authoritativeRequest.id == request.id else {
            return
        }
        statusRunning = nil
        if authoritativeRequest.invocationOrder
                < latestStatusInvocationOrder,
           let pending = statusPending {
            statusPending = nil
            await startStatus(pending)
            return
        }
        switch result {
        case .success(let status):
            await presentationStore.publishClaudeStatus(
                status,
                expected: authoritativeRequest.context,
                invocationOrder:
                    authoritativeRequest.invocationOrder
            )
        case .failure(let error):
            await presentationStore.failClaudeStatus(
                with: failure(for: error, count: 1),
                expected: authoritativeRequest.context,
                invocationOrder:
                    authoritativeRequest.invocationOrder
            )
        }
        if let pending = statusPending {
            statusPending = nil
            await startStatus(pending)
        }
    }
}
