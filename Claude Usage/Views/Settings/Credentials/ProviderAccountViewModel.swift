import Foundation
import Combine
import UsageCore
import CodexUsageProvider

struct ProviderAccountSnapshot: Equatable {
    let account: ProviderAccount
    let health: ProviderHealth
}

enum ProviderAccountViewState: Equatable {
    case idle
    case loading
    case linked(ProviderAccountSnapshot)
    case unauthenticated(ProviderHealth)
    case unsupported(ProviderHealth)
    case unavailable(String)
}

enum ProviderLoginViewState: Equatable {
    case idle
    case starting
    case awaiting(ProviderUILoginChallenge)
    case cancelling
    case succeeded
    case failed(String)
}

/// Provider account state for setup and settings.
///
/// Every task is guarded by both a local operation generation and the complete
/// current profile/provider/home identity. Late results from a replaced profile
/// or relinked home are discarded.
@MainActor
final class ProviderAccountViewModel: ObservableObject {
    @Published private(set) var accountState:
        ProviderAccountViewState = .idle
    @Published private(set) var loginState:
        ProviderLoginViewState = .idle
    private(set) var verifiedDraftIdentity:
        ProviderUIRequestIdentity?

    private let dependencies: ProviderUIDependencies
    private var profileID: UUID?
    private var draftRequest: CapturedProviderUIRequest?
    private var operationGeneration: UInt64 = 0
    private var workTask: Task<Void, Never>?
    private var loginWaitTask: Task<Void, Never>?
    private var loginSession: ProviderUILoginSession?

    init(dependencies: ProviderUIDependencies) {
        self.dependencies = dependencies
    }

    deinit {
        workTask?.cancel()
        loginWaitTask?.cancel()
        if let loginSession {
            Task {
                _ = try? await loginSession.cancel()
                try? await loginSession.disconnect()
            }
        }
    }

    func selectProfile(_ profileID: UUID?) {
        guard self.profileID != profileID
                || draftRequest != nil else {
            return
        }
        invalidateAndDisconnect()
        draftRequest = nil
        verifiedDraftIdentity = nil
        self.profileID = profileID
        accountState = .idle
        loginState = .idle
    }

    /// Selects an ephemeral first-run draft. Validation and provider work can
    /// proceed, but no profile UUID or app metadata is created until the
    /// caller explicitly commits setup.
    func selectDraftCodexHome(_ path: String) throws {
        invalidateAndDisconnect()
        profileID = nil
        draftRequest = nil
        verifiedDraftIdentity = nil
        accountState = .idle
        loginState = .idle
        let request = try dependencies.captureCodexDraftRequest(
            homePath: path
        )
        draftRequest = request
        verifiedDraftIdentity = request.identity
    }

    func refresh() {
        switch loginState {
        case .starting, .awaiting, .cancelling:
            // The login-scoped app server remains the sole owner until it
            // reaches a terminal state. A refresh must not supersede its
            // generation and strand the session.
            return
        case .idle, .succeeded, .failed:
            break
        }
        guard let capture = captureOperation() else { return }
        accountState = .loading
        workTask?.cancel()
        workTask = Task {
            do {
                let health = try await capture.request.health()
                let account = try await capture.request.account()
                guard accept(capture) else {
                    rejectChangedIdentity(capture)
                    return
                }
                if let account {
                    accountState = .linked(
                        ProviderAccountSnapshot(
                            account: account,
                            health: health
                        )
                    )
                } else {
                    accountState = .unauthenticated(health)
                }
            } catch {
                guard accept(capture) else {
                    rejectChangedIdentity(capture)
                    return
                }
                accountState = state(
                    for: error,
                    checkedAt: Date()
                )
            }
        }
    }

    func startLogin(_ flow: ProviderUILoginFlow) {
        switch loginState {
        case .starting, .awaiting, .cancelling:
            // A login attempt is a single owned session. Reject overlapping
            // starts so no second task can replace or leak the first session.
            return
        case .idle, .succeeded, .failed:
            break
        }
        guard loginSession == nil else { return }
        guard let capture = captureOperation() else { return }
        workTask?.cancel()
        loginWaitTask?.cancel()
        loginState = .starting
        workTask = Task {
            do {
                let result = try await capture.request.beginLogin(flow)
                guard accept(capture) else {
                    if case .started(let session) = result {
                        _ = try? await session.cancel()
                        try? await session.disconnect()
                    }
                    rejectChangedIdentity(capture)
                    return
                }
                switch result {
                case .alreadyAuthenticated(let account):
                    loginState = .succeeded
                    accountState = .linked(
                        ProviderAccountSnapshot(
                            account: account,
                            health: ProviderHealth(
                                status: .healthy,
                                checkedAt: Date()
                            )
                        )
                    )
                case .started(let session):
                    loginSession = session
                    loginState = .awaiting(session.challenge)
                    waitForLogin(session, capture: capture)
                }
            } catch {
                guard accept(capture) else {
                    rejectChangedIdentity(capture)
                    return
                }
                loginState = .failed(Self.message(for: error))
            }
        }
    }

    func cancelLogin() {
        operationGeneration &+= 1
        let cancellationGeneration = operationGeneration
        workTask?.cancel()
        loginWaitTask?.cancel()
        guard let session = loginSession else {
            loginState = .idle
            return
        }
        loginSession = nil
        loginState = .cancelling
        Task {
            _ = try? await session.cancel()
            try? await session.disconnect()
            guard self.operationGeneration == cancellationGeneration,
                  self.loginSession == nil else {
                return
            }
            self.loginState = .idle
        }
    }

    func dismiss() {
        invalidateAndDisconnect()
        draftRequest = nil
        verifiedDraftIdentity = nil
        accountState = .idle
        loginState = .idle
    }

    func invalidateDraft() {
        guard draftRequest != nil else { return }
        invalidateAndDisconnect()
        draftRequest = nil
        verifiedDraftIdentity = nil
        accountState = .idle
        loginState = .idle
    }

    private func waitForLogin(
        _ session: ProviderUILoginSession,
        capture: OperationCapture
    ) {
        loginWaitTask = Task {
            do {
                let outcome = try await session.waitForCompletion()
                try await session.disconnect()
                guard accept(capture) else {
                    if capture.generation == operationGeneration {
                        loginSession = nil
                    }
                    rejectChangedIdentity(capture)
                    return
                }
                loginSession = nil
                switch outcome {
                case .succeeded:
                    loginState = .succeeded
                    refresh()
                case .failed:
                    loginState = .failed(
                        ProviderUILocalization.text(
                            "codex.login.failed",
                            fallback:
                                "Codex did not complete sign-in. Try again."
                        )
                    )
                }
            } catch {
                try? await session.disconnect()
                guard accept(capture) else {
                    if capture.generation == operationGeneration {
                        loginSession = nil
                    }
                    rejectChangedIdentity(capture)
                    return
                }
                loginSession = nil
                loginState = .failed(Self.message(for: error))
            }
        }
    }

    private struct OperationCapture {
        let generation: UInt64
        let request: CapturedProviderUIRequest
    }

    private func captureOperation() -> OperationCapture? {
        operationGeneration &+= 1
        if let draftRequest {
            return OperationCapture(
                generation: operationGeneration,
                request: draftRequest
            )
        }
        guard let profileID,
              let profile = dependencies.profile(id: profileID) else {
            accountState = .unavailable(
                ProviderUILocalization.text(
                    "provider.profile_unavailable",
                    fallback: "This profile is no longer available."
                )
            )
            return nil
        }
        do {
            return OperationCapture(
                generation: operationGeneration,
                request: try dependencies.captureRequest(for: profile)
            )
        } catch {
            accountState = .unavailable(Self.message(for: error))
            return nil
        }
    }

    private func accept(_ capture: OperationCapture) -> Bool {
        guard capture.generation == operationGeneration else {
            return false
        }
        if let draftRequest {
            return draftRequest.identity == capture.request.identity
                && dependencies.hasCurrentProviderIdentity(
                    capture.request.identity
                )
        }
        guard let current = dependencies.identity(
            for: capture.request.identity.profileID
        ) else {
            return false
        }
        return current == capture.request.identity
            && dependencies.hasCurrentProviderIdentity(
                capture.request.identity
            )
    }

    private func rejectChangedIdentity(
        _ capture: OperationCapture
    ) {
        // A newer operation owns the presentation state and must never be
        // overwritten by an older completion.
        guard capture.generation == operationGeneration else {
            return
        }
        let message = ProviderUILocalization.text(
            "provider.profile_changed",
            fallback:
                "The profile or linked home changed. Review the current profile and try again."
        )
        if draftRequest?.identity == capture.request.identity {
            draftRequest = nil
            verifiedDraftIdentity = nil
        }
        accountState = .unavailable(message)
        switch loginState {
        case .starting, .awaiting, .cancelling:
            loginState = .failed(message)
        case .idle, .succeeded, .failed:
            break
        }
    }

    private func invalidateAndDisconnect() {
        operationGeneration &+= 1
        workTask?.cancel()
        workTask = nil
        loginWaitTask?.cancel()
        loginWaitTask = nil
        if let session = loginSession {
            loginSession = nil
            Task {
                _ = try? await session.cancel()
                try? await session.disconnect()
            }
        }
    }

    private func state(
        for error: Error,
        checkedAt: Date
    ) -> ProviderAccountViewState {
        if let providerError = error as? UsageProviderError {
            switch providerError {
            case .unauthenticated:
                return .unauthenticated(
                    ProviderHealth(
                        status: .unauthenticated,
                        checkedAt: checkedAt,
                        issue: .authenticationRequired
                    )
                )
            case .unsupportedAccount:
                return .unsupported(
                    ProviderHealth(
                        status: .unsupported,
                        checkedAt: checkedAt,
                        issue: .accountUnsupported
                    )
                )
            default:
                break
            }
        }
        return .unavailable(Self.message(for: error))
    }

    static func message(for error: Error) -> String {
        if let factoryError = error as? CodexProviderFactoryError {
            switch factoryError {
            case .featureDisabled:
                return ProviderUILocalization.text(
                    "codex.feature_unavailable",
                    fallback: "Codex support is not available in this build."
                )
            case .homeUnlinked:
                return ProviderUILocalization.text(
                    "codex.home.unlinked",
                    fallback: "Link a Codex home to continue."
                )
            case .homeUnavailable:
                return ProviderUILocalization.text(
                    "codex.home.unavailable",
                    fallback:
                        "The linked Codex home is missing or was replaced. Relink it to continue."
                )
            case .executableMissing:
                return ProviderUILocalization.text(
                    "codex.cli.missing",
                    fallback:
                        "The Codex CLI is unavailable. Install Codex or make its executable available in PATH."
                )
            case .providerConstructionFailed:
                return ProviderUILocalization.text(
                    "codex.server.unavailable",
                    fallback:
                        "The Codex app server could not be started. Check the Codex installation and try again."
                )
            }
        }
        if let canonicalizationError =
            error as? CodexHomeCanonicalizationError {
            return canonicalizationError.errorDescription
                ?? ProviderUILocalization.text(
                    "codex.home.invalid",
                    fallback: "The Codex home could not be linked."
                )
        }
        if let configurationError =
            error as? ProfileProviderConfigurationError {
            return configurationError.errorDescription
                ?? ProviderUILocalization.text(
                    "codex.profile.invalid",
                    fallback: "The Codex profile could not be updated."
                )
        }
        if let providerError = error as? UsageProviderError {
            switch providerError {
            case .unauthenticated:
                return ProviderUILocalization.text(
                    "codex.account.sign_in_required",
                    fallback: "Sign in with Codex to continue."
                )
            case .unsupportedAccount:
                return ProviderUILocalization.text(
                    "codex.account.unsupported",
                    fallback:
                        "This Codex account does not expose ChatGPT subscription usage."
                )
            case .dependencyMissing:
                return ProviderUILocalization.text(
                    "codex.cli.missing",
                    fallback: "The Codex CLI is unavailable."
                )
            case .timedOut:
                return ProviderUILocalization.text(
                    "codex.operation.timeout",
                    fallback: "Codex did not respond in time. Try again."
                )
            case .cancelled:
                return ProviderUILocalization.text(
                    "codex.operation.cancelled",
                    fallback: "The Codex operation was canceled."
                )
            case .transportFailure:
                return ProviderUILocalization.text(
                    "codex.transport.failed",
                    fallback:
                        "The Codex app server disconnected. Try again."
                )
            case .protocolFailure, .malformedResponse:
                return ProviderUILocalization.text(
                    "codex.response.invalid",
                    fallback:
                        "Codex returned an unsupported response. Update Codex and try again."
                )
            case .capabilityUnavailable, .invalidConfiguration:
                return ProviderUILocalization.text(
                    "codex.operation.unavailable",
                    fallback: "This operation is not available."
                )
            }
        }
        return ProviderUILocalization.text(
            "provider.operation.failed",
            fallback: "The provider operation failed safely. Try again."
        )
    }
}
