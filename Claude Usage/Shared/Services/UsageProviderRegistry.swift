import Foundation
import UsageCore

/// Immutable provider identity captured before refresh work is scheduled.
///
/// A completed request is safe to accept only while all three fields still
/// match the live profile.
nonisolated struct ProviderRefreshIdentity: Hashable, Sendable {
    let profileID: UUID
    let providerID: ProviderID
    let providerRevision: UInt64
}

/// Why a refresh was requested. The value is diagnostic context only; it
/// carries no credentials or provider configuration.
nonisolated enum UsageRefreshTrigger:
    String,
    Codable,
    Equatable,
    Sendable
{
    case startup
    case timer
    case manual
    case profileActivation
    case credentialsChanged
    case providerConfigurationChanged
    case networkAvailable
    case wake
    case displayChanged
    case retry
}

/// Request metadata captured with a provider job.
nonisolated struct UsageRefreshRequestContext: Equatable, Sendable {
    let requestID: UUID
    let trigger: UsageRefreshTrigger
    let requestedAt: Date
    let presentationEpoch: UInt64

    init(
        requestID: UUID = UUID(),
        trigger: UsageRefreshTrigger,
        requestedAt: Date,
        presentationEpoch: UInt64
    ) {
        self.requestID = requestID
        self.trigger = trigger
        self.requestedAt = requestedAt
        self.presentationEpoch = presentationEpoch
    }
}

/// Provider-neutral result returned to the refresh engine.
///
/// `claudeUsage` is a temporary compatibility value for existing Claude-only
/// presentation and persistence paths. Codex returns only the normalized
/// report.
nonisolated struct ProviderFetchResult: @unchecked Sendable {
    let report: UsageReport
    let claudeUsage: ClaudeUsage?

    init(report: UsageReport, claudeUsage: ClaudeUsage? = nil) {
        self.report = report
        self.claudeUsage = claudeUsage
    }
}

typealias ProviderCoreFetch =
    @Sendable () async throws -> ProviderFetchResult
typealias ProviderAPIFetch =
    @Sendable () async throws -> APIUsage

/// A complete immutable unit of work consumed by `UsageRefreshEngine`.
///
/// The registry creates a new value for every refresh request. Its closures
/// contain only request-scoped captured inputs and never consult the active
/// profile when they execute.
nonisolated struct CapturedProviderRefreshJob: @unchecked Sendable {
    let identity: ProviderRefreshIdentity
    let profileName: String
    let notificationSettings: NotificationSettings
    let refreshInterval: TimeInterval
    let requestContext: UsageRefreshRequestContext
    let capabilities: ProviderCapabilities
    let coreFetch: ProviderCoreFetch
    let apiFetch: ProviderAPIFetch?
}

/// Request-scoped Claude operations produced synchronously from a profile.
///
/// The capture implementation owns credential resolution. By the time this
/// value is returned, both closures must contain immutable credential values.
nonisolated struct CapturedClaudeProviderRequest: @unchecked Sendable {
    let account: ProviderAccount?
    let coreFetch: @Sendable () async throws -> ClaudeUsage
    let apiFetch: ProviderAPIFetch?

    init(
        account: ProviderAccount? = nil,
        coreFetch: @escaping @Sendable () async throws -> ClaudeUsage,
        apiFetch: ProviderAPIFetch? = nil
    ) {
        self.account = account
        self.coreFetch = coreFetch
        self.apiFetch = apiFetch
    }
}

typealias ClaudeProviderRequestCapture =
    @MainActor @Sendable (Profile) throws
        -> CapturedClaudeProviderRequest

/// Safe, typed failures from synchronous provider-job capture.
///
/// These cases intentionally contain neither raw underlying errors nor paths,
/// credentials, command output, or process arguments.
nonisolated enum UsageProviderCaptureError: Error, Equatable, Sendable {
    case profileDeletionInProgress
    case featureDisabled(ProviderID)
    case claudeCredentialsUnavailable
    case codexHomeUnlinked
    case codexHomeUnavailable
    case codexExecutableMissing
    case providerConstructionFailed(ProviderID)
}

/// Safe execution failures detected by the registry after a job is captured.
nonisolated enum UsageProviderFetchError: Error, Equatable, Sendable {
    case codexHomeUnavailable
    case providerIdentityMismatch(
        expected: ProviderID,
        received: ProviderID
    )
}

/// Immutable registry that translates a profile into request-scoped provider
/// work. It owns no provider sessions, never reads Codex authentication files,
/// and has no dependency on application singletons.
nonisolated struct UsageProviderRegistry: Sendable {
    typealias CodexHomeValidator =
        CodexProviderFactory.HomeValidator
    typealias ExecutableValidator =
        CodexProviderFactory.ExecutableValidator

    private let claudeRequestCapture: ClaudeProviderRequestCapture
    private let codexProviderFactory: CodexProviderFactory
    private let now: @Sendable () -> Date

    init(
        claudeRequestCapture: @escaping ClaudeProviderRequestCapture,
        codexProviderFactory: CodexProviderFactory =
            CodexProviderFactory(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.claudeRequestCapture = claudeRequestCapture
        self.codexProviderFactory = codexProviderFactory
        self.now = now
    }

    /// Compatibility initializer for focused registry/engine tests. New
    /// product flows should inject a complete `CodexProviderFactory`.
    init(
        featureAvailability: UsageProviderFeatureAvailability = .production,
        claudeRequestCapture: @escaping ClaudeProviderRequestCapture,
        codexHomeValidator: @escaping CodexHomeValidator =
            CodexProviderFactory.defaultHomeValidator,
        codexExecutableResolver: @escaping CodexExecutableResolver,
        codexExecutableValidator: @escaping ExecutableValidator =
            CodexProviderFactory.defaultExecutableValidator,
        codexFetchFactory: @escaping CodexProviderFetchFactory,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.claudeRequestCapture = claudeRequestCapture
        codexProviderFactory = CodexProviderFactory(
            availability: featureAvailability,
            homeValidator: codexHomeValidator,
            executableResolver: codexExecutableResolver,
            executableValidator: codexExecutableValidator,
            fetchFactory: codexFetchFactory
        )
        self.now = now
    }

    func isRefreshEnabled(for providerID: ProviderID) -> Bool {
        switch providerID {
        case .claude:
            return true
        case .codex:
            return codexProviderFactory.isEnabled
        default:
            return false
        }
    }

    @MainActor
    func capabilities(for providerID: ProviderID)
        -> ProviderCapabilities {
        switch providerID {
        case .claude:
            return ClaudeUsageProviderAdapter.capabilities
        case .codex:
            return codexProviderFactory.capabilities
        default:
            return ProviderCapabilities()
        }
    }

    /// Captures all profile- and credential-dependent input synchronously.
    /// Calling either returned fetch closure later cannot drift to another
    /// profile or to credentials changed after this method returns.
    @MainActor
    func capture(
        profile: Profile,
        context: UsageRefreshRequestContext
    ) throws -> CapturedProviderRefreshJob {
        guard !profile.deletionInProgress else {
            throw UsageProviderCaptureError.profileDeletionInProgress
        }

        switch profile.providerConfiguration {
        case .claude:
            return try captureClaude(profile: profile, context: context)
        case .codex(let configuration):
            return try captureCodex(
                profile: profile,
                configuration: configuration,
                context: context
            )
        }
    }

    @MainActor
    private func captureClaude(
        profile: Profile,
        context: UsageRefreshRequestContext
    ) throws -> CapturedProviderRefreshJob {
        let request: CapturedClaudeProviderRequest
        do {
            // This call is intentionally synchronous and occurs before any
            // Task can be created by the refresh engine.
            request = try claudeRequestCapture(profile)
        } catch {
            throw UsageProviderCaptureError.claudeCredentialsUnavailable
        }

        let refreshInterval = Self.sanitizedRefreshInterval(
            profile.refreshInterval
        )
        let freshnessLifetime = Self.freshnessLifetime(
            refreshInterval: profile.refreshInterval
        )
        let now = self.now
        let coreFetch = request.coreFetch
        let account = request.account
        let apiFetch: ProviderAPIFetch?
        if let capturedAPIFetch = request.apiFetch {
            apiFetch = { @Sendable in
                try await capturedAPIFetch()
            }
        } else {
            apiFetch = nil
        }

        return CapturedProviderRefreshJob(
            identity: ProviderRefreshIdentity(
                profileID: profile.id,
                providerID: .claude,
                providerRevision: profile.providerRevision
            ),
            profileName: profile.name,
            notificationSettings: profile.notificationSettings,
            refreshInterval: refreshInterval,
            requestContext: context,
            capabilities: ClaudeUsageProviderAdapter.capabilities,
            coreFetch: {
                let usage = try await coreFetch()
                let fetchedAt = now()
                let report = try await ClaudeUsageProviderAdapter.makeReport(
                    from: usage,
                    context: ClaudeUsageProviderContext(
                        account: account,
                        health: ProviderHealth(
                            status: .healthy,
                            checkedAt: fetchedAt
                        ),
                        fetchedAt: fetchedAt,
                        staleAt: fetchedAt.addingTimeInterval(
                            freshnessLifetime
                        )
                    )
                )
                return ProviderFetchResult(
                    report: report,
                    claudeUsage: usage
                )
            },
            apiFetch: apiFetch
        )
    }

    @MainActor
    private func captureCodex(
        profile: Profile,
        configuration: CodexProfileConfiguration,
        context: UsageRefreshRequestContext
    ) throws -> CapturedProviderRefreshJob {
        let capturedConfiguration: CapturedCodexProviderConfiguration
        do {
            capturedConfiguration = try codexProviderFactory.capture(
                linkedHome: configuration.linkedHome
            )
        } catch let error as CodexProviderFactoryError {
            switch error {
            case .featureDisabled:
                throw UsageProviderCaptureError.featureDisabled(.codex)
            case .homeUnlinked:
                throw UsageProviderCaptureError.codexHomeUnlinked
            case .homeUnavailable:
                throw UsageProviderCaptureError.codexHomeUnavailable
            case .executableMissing:
                throw UsageProviderCaptureError.codexExecutableMissing
            case .providerConstructionFailed:
                throw UsageProviderCaptureError
                    .providerConstructionFailed(.codex)
            }
        } catch {
            throw UsageProviderCaptureError
                .providerConstructionFailed(.codex)
        }

        let fetch: @Sendable () async throws -> UsageReport
        do {
            fetch = try codexProviderFactory.makeFreshFetch(
                capturedConfiguration
            )
        } catch {
            throw UsageProviderCaptureError.providerConstructionFailed(.codex)
        }

        let refreshInterval = Self.sanitizedRefreshInterval(
            profile.refreshInterval
        )
        let freshnessLifetime = Self.freshnessLifetime(
            refreshInterval: profile.refreshInterval
        )

        return CapturedProviderRefreshJob(
            identity: ProviderRefreshIdentity(
                profileID: profile.id,
                providerID: .codex,
                providerRevision: profile.providerRevision
            ),
            profileName: profile.name,
            notificationSettings: profile.notificationSettings,
            refreshInterval: refreshInterval,
            requestContext: context,
            capabilities: codexProviderFactory.capabilities,
            coreFetch: {
                guard codexProviderFactory.isHomeAvailable(
                    capturedConfiguration
                ) else {
                    throw UsageProviderFetchError
                        .codexHomeUnavailable
                }
                var report = try await fetch()
                guard report.providerID == .codex else {
                    throw UsageProviderFetchError.providerIdentityMismatch(
                        expected: .codex,
                        received: report.providerID
                    )
                }
                report.staleAt = report.fetchedAt.addingTimeInterval(
                    freshnessLifetime
                )
                return ProviderFetchResult(report: report)
            },
            apiFetch: nil
        )
    }

    private static func sanitizedRefreshInterval(
        _ interval: TimeInterval
    ) -> TimeInterval {
        guard interval.isFinite, interval > 0 else { return 300 }
        return interval
    }

    private static func freshnessLifetime(
        refreshInterval: TimeInterval
    ) -> TimeInterval {
        guard refreshInterval.isFinite, refreshInterval > 0 else {
            return 300
        }
        return max(300, refreshInterval * 2)
    }
}
