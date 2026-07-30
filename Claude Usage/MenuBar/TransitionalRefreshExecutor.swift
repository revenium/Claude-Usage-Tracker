import Foundation

/// Request-scoped refresh ownership used while provider refresh moves to the
/// P09 coordinator. P09 replaces this seam with the provider-aware actor.
@MainActor
final class TransitionalRefreshExecutor {
    enum Mode {
        case single
        case multi
    }

    struct PresentationIdentity: Equatable {
        let profileID: UUID
        let generation: UInt64
    }

    struct Plan {
        let mode: Mode
        let profileID: UUID
        let presentationIdentity: PresentationIdentity
        let profileName: String
        let notificationSettings: NotificationSettings
        let previousClaudeUsage: ClaudeUsage?
        let previousAPIUsage: APIUsage?
        let claudeRequest:
            Result<ClaudeAPIService.CapturedUsageRequest, Error>
        let apiRequest: ClaudeAPIService.CapturedAPIUsageRequest?

        static func capture(
            profile: Profile,
            mode: Mode,
            presentationGeneration: UInt64,
            apiService: ClaudeAPIService
        ) -> Plan {
            // This method is intentionally synchronous. All mutable/profile-
            // global credential state must be resolved before a Task exists.
            let claudeRequest:
                Result<ClaudeAPIService.CapturedUsageRequest, Error> = Result {
                    try apiService.captureUsageRequest(for: profile)
                }

            return Plan(
                mode: mode,
                profileID: profile.id,
                presentationIdentity: PresentationIdentity(
                    profileID: profile.id,
                    generation: presentationGeneration
                ),
                profileName: profile.name,
                notificationSettings: profile.notificationSettings,
                previousClaudeUsage: profile.claudeUsage,
                previousAPIUsage: profile.apiUsage,
                claudeRequest: claudeRequest,
                apiRequest: apiService.captureAPIUsageRequest(for: profile)
            )
        }
    }

    enum ComponentOutcome: Equatable {
        case success
        case failure
        case superseded
        case profileUnavailable
        case notRequested
    }

    struct PlanOutcome {
        let plan: Plan
        let claude: ComponentOutcome
        let api: ComponentOutcome
    }

    struct BatchResult {
        let generation: UInt64
        let outcomes: [PlanOutcome]

        /// A Claude usage success is the freshness signal. Console API usage
        /// is auxiliary, so its failure never turns a core success into a
        /// failed batch.
        var hasCoreSuccess: Bool {
            outcomes.contains { $0.claude == .success }
        }
    }

    struct Hooks {
        let currentPresentationIdentity: () -> PresentationIdentity?
        let isProfileWritable: (UUID) -> Bool
        let setLoading: (Bool) -> Void
        let fetchClaude:
            (ClaudeAPIService.CapturedUsageRequest) async throws -> ClaudeUsage
        let fetchAPI:
            (ClaudeAPIService.CapturedAPIUsageRequest) async throws -> APIUsage
        let fetchStatus: () async throws -> ClaudeStatus
        let commitClaude: (Plan, ClaudeUsage, Bool) -> Bool
        let presentClaude: (Plan, ClaudeUsage) -> Void
        let commitAPI: (Plan, APIUsage, Bool) -> Bool
        let presentAPI: (Plan, APIUsage) -> Void
        let claudeFailed: (Plan, Error, Bool) -> Void
        let apiFailed: (Plan, Error, Bool) -> Void
        let presentStatus: (ClaudeStatus) -> Void
        let statusFailed: (Error) -> Void
        let batchFinished: (BatchResult) -> Void
    }

    private struct Execution {
        let plan: Plan
        let profileGeneration: UInt64
    }

    private struct BatchHandle {
        let generation: UInt64
        let presentationIdentity: PresentationIdentity?
    }

    private struct StatusHandle {
        let generation: UInt64
        let batchGeneration: UInt64
        let presentationIdentity: PresentationIdentity?
    }

    private let hooks: Hooks
    private var profileGenerations: [UUID: UInt64] = [:]
    private var batchGeneration: UInt64 = 0
    private var statusGeneration: UInt64 = 0
    private var loadingBatchGeneration: UInt64?
    private var loadingIdentity: PresentationIdentity?
    private var currentBatchProfileIDs: Set<UUID> = []

    init(hooks: Hooks) {
        self.hooks = hooks
    }

    @discardableResult
    func start(_ plan: Plan) -> Task<Void, Never> {
        start([plan], loadingIdentity: plan.presentationIdentity)
    }

    @discardableResult
    func start(
        _ plans: [Plan],
        loadingIdentity: PresentationIdentity?
    ) -> Task<Void, Never> {
        batchGeneration &+= 1
        let batch = BatchHandle(
            generation: batchGeneration,
            presentationIdentity: loadingIdentity
        )
        currentBatchProfileIDs = Set(plans.map(\.profileID))
        let executions = plans.map { plan in
            let generation =
                (profileGenerations[plan.profileID] ?? 0) &+ 1
            profileGenerations[plan.profileID] = generation
            return Execution(
                plan: plan,
                profileGeneration: generation
            )
        }

        statusGeneration &+= 1
        let status = StatusHandle(
            generation: statusGeneration,
            batchGeneration: batch.generation,
            presentationIdentity: loadingIdentity
        )

        let wasLoading = loadingBatchGeneration != nil
        loadingBatchGeneration = batch.generation
        self.loadingIdentity = loadingIdentity
        if !wasLoading {
            hooks.setLoading(true)
        }

        // Every plan and token is fully captured before these Tasks exist.
        let planTasks = executions.map { execution in
            Task { [weak self] in
                await self?.execute(execution)
            }
        }
        let statusTask = Task { [weak self] in
            await self?.executeStatus(status)
        }

        return Task { [weak self] in
            guard let self else { return }
            var outcomes: [PlanOutcome] = []
            for task in planTasks {
                if let outcome = await task.value {
                    outcomes.append(outcome)
                }
            }

            self.finishLoading(batch)
            if self.isBatchCurrent(batch) {
                self.hooks.batchFinished(
                    BatchResult(
                        generation: batch.generation,
                        outcomes: outcomes
                    )
                )
            }
            await statusTask.value
        }
    }

    /// An identity transition ends only the old presentation/loading epoch.
    /// Per-profile execution generations remain valid so a completed A request
    /// may still persist to A after the user activates B.
    func presentationIdentityDidChange(
        to identity: PresentationIdentity?
    ) {
        guard loadingBatchGeneration != nil,
              identity != loadingIdentity else {
            return
        }
        loadingBatchGeneration = nil
        loadingIdentity = nil
        hooks.setLoading(false)
    }

    /// Supersedes captured credentials for one profile. If that profile is
    /// part of the current batch, its batch/status/final hooks are invalidated
    /// as well; unrelated in-flight profiles retain persistence ownership.
    func invalidate(profileID: UUID) {
        profileGenerations[profileID] =
            (profileGenerations[profileID] ?? 0) &+ 1
        guard currentBatchProfileIDs.contains(profileID) else { return }
        invalidateCurrentBatch()
    }

    /// Legacy credential notifications do not identify the changed profile.
    /// Conservatively supersede every captured profile and current batch.
    func invalidateAllCapturedProfiles() {
        for profileID in Array(profileGenerations.keys) {
            profileGenerations[profileID] =
                (profileGenerations[profileID] ?? 0) &+ 1
        }
        invalidateCurrentBatch()
    }

    private func execute(_ execution: Execution) async -> PlanOutcome {
        let claudeTask = Task { [weak self] in
            await self?.executeClaude(execution)
                ?? .superseded
        }
        let apiTask = execution.plan.apiRequest.map { request in
            Task { [weak self] in
                await self?.executeAPI(execution, request: request)
                    ?? .superseded
            }
        }

        let claude = await claudeTask.value
        let api: ComponentOutcome
        if let apiTask {
            api = await apiTask.value
        } else {
            api = .notRequested
        }
        return PlanOutcome(
            plan: execution.plan,
            claude: claude,
            api: api
        )
    }

    private func executeClaude(
        _ execution: Execution
    ) async -> ComponentOutcome {
        do {
            let usage = try await hooks.fetchClaude(
                execution.plan.claudeRequest.get()
            )
            guard isExecutionCurrent(execution) else {
                return .superseded
            }
            guard hooks.isProfileWritable(execution.plan.profileID) else {
                return .profileUnavailable
            }
            let shouldPresent = isPresentationCurrent(
                for: execution.plan
            )
            guard hooks.commitClaude(
                execution.plan,
                usage,
                shouldPresent
            ) else {
                return .profileUnavailable
            }
            if shouldPresent {
                hooks.presentClaude(execution.plan, usage)
            }
            return .success
        } catch {
            guard isExecutionCurrent(execution) else {
                return .superseded
            }
            guard hooks.isProfileWritable(execution.plan.profileID) else {
                return .profileUnavailable
            }
            hooks.claudeFailed(
                execution.plan,
                error,
                isPresentationCurrent(for: execution.plan)
            )
            return .failure
        }
    }

    private func executeAPI(
        _ execution: Execution,
        request: ClaudeAPIService.CapturedAPIUsageRequest
    ) async -> ComponentOutcome {
        do {
            let usage = try await hooks.fetchAPI(request)
            guard isExecutionCurrent(execution) else {
                return .superseded
            }
            guard hooks.isProfileWritable(execution.plan.profileID) else {
                return .profileUnavailable
            }
            let shouldPresent = isPresentationCurrent(
                for: execution.plan
            )
            guard hooks.commitAPI(
                execution.plan,
                usage,
                shouldPresent
            ) else {
                return .profileUnavailable
            }
            if shouldPresent {
                hooks.presentAPI(execution.plan, usage)
            }
            return .success
        } catch {
            guard isExecutionCurrent(execution) else {
                return .superseded
            }
            guard hooks.isProfileWritable(execution.plan.profileID) else {
                return .profileUnavailable
            }
            hooks.apiFailed(
                execution.plan,
                error,
                isPresentationCurrent(for: execution.plan)
            )
            return .failure
        }
    }

    private func executeStatus(_ handle: StatusHandle) async {
        do {
            let status = try await hooks.fetchStatus()
            guard isStatusCurrent(handle) else { return }
            hooks.presentStatus(status)
        } catch {
            guard isStatusCurrent(handle) else { return }
            hooks.statusFailed(error)
        }
    }

    private func isExecutionCurrent(_ execution: Execution) -> Bool {
        profileGenerations[execution.plan.profileID]
            == execution.profileGeneration
    }

    private func isBatchCurrent(_ handle: BatchHandle) -> Bool {
        batchGeneration == handle.generation
            && hooks.currentPresentationIdentity()
                == handle.presentationIdentity
    }

    private func isStatusCurrent(_ handle: StatusHandle) -> Bool {
        statusGeneration == handle.generation
            && batchGeneration == handle.batchGeneration
            && hooks.currentPresentationIdentity()
                == handle.presentationIdentity
    }

    private func isPresentationCurrent(for plan: Plan) -> Bool {
        hooks.currentPresentationIdentity()
            == plan.presentationIdentity
    }

    private func finishLoading(_ handle: BatchHandle) {
        guard loadingBatchGeneration == handle.generation else {
            return
        }
        loadingBatchGeneration = nil
        loadingIdentity = nil
        hooks.setLoading(false)
    }

    private func invalidateCurrentBatch() {
        batchGeneration &+= 1
        statusGeneration &+= 1
        currentBatchProfileIDs = []
        guard loadingBatchGeneration != nil else { return }
        loadingBatchGeneration = nil
        loadingIdentity = nil
        hooks.setLoading(false)
    }
}

extension MenuBarManager {
    /// Injectable production side-effect boundary for the transitional
    /// executor. Tests drive this exact sequencing while substituting storage,
    /// history, notification, and UI endpoints.
    @MainActor
    final class RefreshSideEffectSink {
        struct Hooks {
            let isProfileWritable: (UUID) -> Bool
            let recordClaude: (TransitionalRefreshExecutor.Plan, ClaudeUsage) -> Void
            let saveClaude:
                (TransitionalRefreshExecutor.Plan, ClaudeUsage, Bool) -> Bool
            let publishClaude:
                (TransitionalRefreshExecutor.Plan, ClaudeUsage) -> Void
            let writeStatusline:
                (TransitionalRefreshExecutor.Plan, ClaudeUsage) -> Void
            let notify:
                (TransitionalRefreshExecutor.Plan, ClaudeUsage) -> Void
            let isAutoSwitchPresentationCurrent:
                (TransitionalRefreshExecutor.Plan) -> Bool
            let autoSwitch:
                (TransitionalRefreshExecutor.Plan, ClaudeUsage) -> Void
            let recordAPI: (TransitionalRefreshExecutor.Plan, APIUsage) -> Void
            let saveAPI:
                (TransitionalRefreshExecutor.Plan, APIUsage, Bool) -> Bool
            let publishAPI:
                (TransitionalRefreshExecutor.Plan, APIUsage) -> Void
            let claudeFailed:
                (TransitionalRefreshExecutor.Plan, Error, Bool) -> Void
            let apiFailed:
                (TransitionalRefreshExecutor.Plan, Error, Bool) -> Void
            let presentStatus: (ClaudeStatus) -> Void
            let statusFailed: (Error) -> Void
            let batchFinalized:
                (TransitionalRefreshExecutor.BatchResult) -> Void
            let batchSucceeded:
                (TransitionalRefreshExecutor.BatchResult) -> Void
        }

        private let hooks: Hooks

        init(hooks: Hooks) {
            self.hooks = hooks
        }

        func isProfileWritable(_ profileID: UUID) -> Bool {
            hooks.isProfileWritable(profileID)
        }

        func commitClaude(
            _ plan: TransitionalRefreshExecutor.Plan,
            usage: ClaudeUsage,
            shouldPresent: Bool
        ) -> Bool {
            guard hooks.isProfileWritable(plan.profileID) else {
                return false
            }
            guard hooks.saveClaude(
                plan,
                usage,
                shouldPresent
            ) else {
                return false
            }
            hooks.recordClaude(plan, usage)
            return true
        }

        func presentClaude(
            _ plan: TransitionalRefreshExecutor.Plan,
            usage: ClaudeUsage
        ) {
            hooks.publishClaude(plan, usage)
            guard case .single = plan.mode else { return }
            hooks.writeStatusline(plan, usage)
            hooks.notify(plan, usage)
            guard hooks.isAutoSwitchPresentationCurrent(plan) else {
                return
            }
            hooks.autoSwitch(plan, usage)
        }

        func commitAPI(
            _ plan: TransitionalRefreshExecutor.Plan,
            usage: APIUsage,
            shouldPresent: Bool
        ) -> Bool {
            guard hooks.isProfileWritable(plan.profileID) else {
                return false
            }
            guard hooks.saveAPI(plan, usage, shouldPresent) else {
                return false
            }
            hooks.recordAPI(plan, usage)
            return true
        }

        func presentAPI(
            _ plan: TransitionalRefreshExecutor.Plan,
            usage: APIUsage
        ) {
            hooks.publishAPI(plan, usage)
        }

        func claudeFailed(
            _ plan: TransitionalRefreshExecutor.Plan,
            error: Error,
            shouldPresent: Bool
        ) {
            guard hooks.isProfileWritable(plan.profileID) else { return }
            hooks.claudeFailed(plan, error, shouldPresent)
        }

        func apiFailed(
            _ plan: TransitionalRefreshExecutor.Plan,
            error: Error,
            shouldPresent: Bool
        ) {
            guard hooks.isProfileWritable(plan.profileID) else { return }
            hooks.apiFailed(plan, error, shouldPresent)
        }

        func presentStatus(_ status: ClaudeStatus) {
            hooks.presentStatus(status)
        }

        func statusFailed(_ error: Error) {
            hooks.statusFailed(error)
        }

        func finishBatch(
            _ result: TransitionalRefreshExecutor.BatchResult
        ) {
            hooks.batchFinalized(result)
            if result.hasCoreSuccess {
                hooks.batchSucceeded(result)
            }
        }
    }
}
