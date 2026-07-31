import CodexUsageProvider
import Foundation
import UsageCore

enum ProviderErrorCategory: String, Codable, CaseIterable, Sendable {
    case missingExecutable
    case launchFailure
    case timeout
    case cancellation
    case incompatibleAppServer
    case malformedResponse
    case invalidHome
    case duplicateHome
    case loggedOut
    case unsupportedAccount
    case partialUsage
    case transientFailure
}

enum ProviderRecoveryAction: String, Codable, CaseIterable, Sendable {
    case retry
    case installOrUpdateCodex
    case openSettings

    nonisolated var title: String {
        switch self {
        case .retry:
            ProviderUILocalization.text(
                "provider.recovery.retry",
                fallback: "Try Again"
            )
        case .installOrUpdateCodex:
            ProviderUILocalization.text(
                "provider.recovery.install_or_update_codex",
                fallback: "Codex Installation Help"
            )
        case .openSettings:
            ProviderUILocalization.text(
                "provider.recovery.open_settings",
                fallback: "Open Settings"
            )
        }
    }
}

struct ProviderErrorPresentation: Equatable, Sendable {
    let category: ProviderErrorCategory
    let titleKey: String
    let explanationKey: String
    let fallbackTitle: String
    let fallbackExplanation: String
    let isRecoverable: Bool
    let actions: [ProviderRecoveryAction]

    nonisolated var title: String {
        ProviderUILocalization.text(titleKey, fallback: fallbackTitle)
    }

    nonisolated var explanation: String {
        ProviderUILocalization.text(
            explanationKey,
            fallback: fallbackExplanation
        )
    }

    nonisolated static func make(
        _ category: ProviderErrorCategory
    ) -> ProviderErrorPresentation {
        switch category {
        case .missingExecutable:
            ProviderErrorPresentation(
                category: category,
                titleKey: "provider.error.codex_missing.title",
                explanationKey:
                    "provider.error.codex_missing.explanation",
                fallbackTitle: "Codex CLI Not Found",
                fallbackExplanation:
                    "Install Codex or make the Codex executable available in PATH, then try again.",
                isRecoverable: true,
                actions: [.installOrUpdateCodex, .openSettings]
            )
        case .launchFailure:
            ProviderErrorPresentation(
                category: category,
                titleKey: "provider.error.codex_launch.title",
                explanationKey:
                    "provider.error.codex_launch.explanation",
                fallbackTitle: "Codex Could Not Start",
                fallbackExplanation:
                    "The Codex app server could not be launched. Check the Codex installation and try again.",
                isRecoverable: true,
                actions: [
                    .retry,
                    .installOrUpdateCodex,
                    .openSettings
                ]
            )
        case .timeout:
            ProviderErrorPresentation(
                category: category,
                titleKey: "provider.error.timeout.title",
                explanationKey: "provider.error.timeout.explanation",
                fallbackTitle: "Codex Timed Out",
                fallbackExplanation:
                    "Codex did not respond within the safety timeout. Try again.",
                isRecoverable: true,
                actions: [.retry]
            )
        case .cancellation:
            ProviderErrorPresentation(
                category: category,
                titleKey: "provider.error.cancelled.title",
                explanationKey:
                    "provider.error.cancelled.explanation",
                fallbackTitle: "Codex Operation Canceled",
                fallbackExplanation:
                    "The operation ended without changing your Codex account or credentials.",
                isRecoverable: true,
                actions: [.retry]
            )
        case .incompatibleAppServer:
            ProviderErrorPresentation(
                category: category,
                titleKey:
                    "provider.error.incompatible_app_server.title",
                explanationKey:
                    "provider.error.incompatible_app_server.explanation",
                fallbackTitle: "Codex Update Required",
                fallbackExplanation:
                    "This Codex app server does not support the protocol required for subscription usage.",
                isRecoverable: true,
                actions: [
                    .installOrUpdateCodex,
                    .retry,
                    .openSettings
                ]
            )
        case .malformedResponse:
            ProviderErrorPresentation(
                category: category,
                titleKey: "provider.error.malformed_response.title",
                explanationKey:
                    "provider.error.malformed_response.explanation",
                fallbackTitle: "Codex Returned Invalid Data",
                fallbackExplanation:
                    "Codex returned a response that could not be safely interpreted. Update Codex and try again.",
                isRecoverable: true,
                actions: [
                    .retry,
                    .installOrUpdateCodex,
                    .openSettings
                ]
            )
        case .invalidHome:
            ProviderErrorPresentation(
                category: category,
                titleKey: "provider.error.invalid_home.title",
                explanationKey:
                    "provider.error.invalid_home.explanation",
                fallbackTitle: "Codex Home Is Unavailable",
                fallbackExplanation:
                    "The linked Codex home is missing, invalid, or changed after verification.",
                isRecoverable: true,
                actions: [.openSettings]
            )
        case .duplicateHome:
            ProviderErrorPresentation(
                category: category,
                titleKey: "provider.error.duplicate_home.title",
                explanationKey:
                    "provider.error.duplicate_home.explanation",
                fallbackTitle: "Codex Home Already Linked",
                fallbackExplanation:
                    "Each Codex home can be linked to only one profile. Choose another home.",
                isRecoverable: true,
                actions: [.openSettings]
            )
        case .loggedOut:
            ProviderErrorPresentation(
                category: category,
                titleKey: "provider.error.logged_out.title",
                explanationKey:
                    "provider.error.logged_out.explanation",
                fallbackTitle: "Sign In with Codex",
                fallbackExplanation:
                    "The linked Codex home is not signed in to a supported ChatGPT subscription.",
                isRecoverable: true,
                actions: [.openSettings]
            )
        case .unsupportedAccount:
            ProviderErrorPresentation(
                category: category,
                titleKey: "provider.error.unsupported_account.title",
                explanationKey:
                    "provider.error.unsupported_account.explanation",
                fallbackTitle: "Codex Account Is Unsupported",
                fallbackExplanation:
                    "This Codex account mode does not expose ChatGPT subscription usage.",
                isRecoverable: false,
                actions: [.openSettings]
            )
        case .partialUsage:
            ProviderErrorPresentation(
                category: category,
                titleKey: "provider.error.partial_usage.title",
                explanationKey:
                    "provider.error.partial_usage.explanation",
                fallbackTitle: "Some Codex Usage Is Unavailable",
                fallbackExplanation:
                    "Rate limits are available, but optional usage details are not supported by this Codex version.",
                isRecoverable: true,
                actions: [.retry, .openSettings]
            )
        case .transientFailure:
            ProviderErrorPresentation(
                category: category,
                titleKey: "provider.error.transient.title",
                explanationKey:
                    "provider.error.transient.explanation",
                fallbackTitle: "Codex Is Temporarily Unavailable",
                fallbackExplanation:
                    "The Codex app server disconnected or failed before the request completed. Try again.",
                isRecoverable: true,
                actions: [.retry, .openSettings]
            )
        }
    }
}

nonisolated enum ProviderErrorMapper {
    static func presentation(
        for error: Error,
        providerID: ProviderID? = nil
    ) -> ProviderErrorPresentation? {
        category(
            for: error,
            providerID: providerID
        ).map(ProviderErrorPresentation.make)
    }

    static func presentation(
        for health: ProviderHealth
    ) -> ProviderErrorPresentation? {
        category(for: health).map(ProviderErrorPresentation.make)
    }

    static func presentation(
        for failure: ProviderRefreshFailure
    ) -> ProviderErrorPresentation? {
        category(for: failure).map(ProviderErrorPresentation.make)
    }

    static func category(
        for error: Error,
        providerID: ProviderID? = nil
    ) -> ProviderErrorCategory? {
        if let transportError = error as? CodexTransportError {
            return categoryForTransportError(transportError)
        }
        if let providerError = error as? UsageProviderError {
            guard providerID == .codex else {
                return nil
            }
            return categoryForUsageProviderError(providerError)
        }
        if let factoryError = error as? CodexProviderFactoryError {
            switch factoryError {
            case .featureDisabled:
                return nil
            case .homeUnlinked, .homeUnavailable:
                return .invalidHome
            case .executableMissing:
                return .missingExecutable
            case .providerConstructionFailed:
                return .launchFailure
            }
        }
        if error is CodexHomeCanonicalizationError {
            return .invalidHome
        }
        if let configurationError =
            error as? ProfileProviderConfigurationError {
            switch configurationError {
            case .duplicateCodexHome:
                return .duplicateHome
            case .invalidCanonicalHome,
                 .codexHomeChangeRequiresLink,
                 .claudeStateOnCodexProfile,
                 .codexProfileRequired,
                 .codexInitialHomeRequiresDedicatedCreation,
                 .codexConfigurationMutationFailed,
                 .codexConfigurationRollbackFailed,
                 .codexConfigurationMarkerVerificationFailed:
                return .invalidHome
            case .claudeProfileRequired:
                return nil
            case .invalidTaggedShape,
                 .providerChangeNotAllowed,
                 .providerRevisionChangeNotAllowed,
                 .providerRevisionExhausted,
                 .initialProfileAlreadyExists,
                 .duplicateProfileID,
                 .profileSetChanged,
                 .deletionStateChangeRequiresLifecycle:
                return providerID == .codex ? .invalidHome : nil
            }
        }
        if let captureError = error as? UsageProviderCaptureError {
            switch captureError {
            case .featureDisabled, .profileDeletionInProgress:
                return nil
            case .codexExecutableMissing:
                return .missingExecutable
            case .codexHomeUnlinked, .codexHomeUnavailable:
                return .invalidHome
            case .providerConstructionFailed(let capturedProviderID):
                return capturedProviderID == .codex
                    ? .launchFailure : nil
            case .claudeCredentialsUnavailable:
                return nil
            }
        }
        return nil
    }

    static func category(
        for error: UsageProviderError
    ) -> ProviderErrorCategory {
        categoryForUsageProviderError(error)
    }

    private static func categoryForUsageProviderError(
        _ error: UsageProviderError
    ) -> ProviderErrorCategory {
        switch error {
        case .capabilityUnavailable:
            return .partialUsage
        case .unauthenticated:
            return .loggedOut
        case .unsupportedAccount:
            return .unsupportedAccount
        case .invalidConfiguration:
            return .invalidHome
        case .dependencyMissing:
            return .missingExecutable
        case .transportFailure:
            return .transientFailure
        case .protocolFailure:
            return .incompatibleAppServer
        case .malformedResponse:
            return .malformedResponse
        case .timedOut:
            return .timeout
        case .cancelled:
            return .cancellation
        }
    }

    static func category(
        for error: CodexTransportError
    ) -> ProviderErrorCategory {
        categoryForTransportError(error)
    }

    private static func categoryForTransportError(
        _ error: CodexTransportError
    ) -> ProviderErrorCategory {
        switch error {
        case let .invalidConfiguration(field):
            return field == .executable
                ? .missingExecutable : .invalidHome
        case .launchFailed:
            return .launchFailure
        case .timedOut:
            return .timeout
        case .cancelled:
            return .cancellation
        case .malformedFrame,
             .lineLimitExceeded,
             .outputLimitExceeded:
            return .malformedResponse
        case .requestIDMismatch,
             .requestIDExhausted,
             .unsupportedServerRequest,
             .unexpectedResponse:
            return .incompatibleAppServer
        case let .rpcFailure(code, _, _):
            if code == 401 || code == 403 {
                return .loggedOut
            }
            if code == -32601 {
                return .incompatibleAppServer
            }
            return .transientFailure
        case .writeFailed,
             .processExited,
             .unexpectedEOF:
            return .transientFailure
        }
    }

    static func category(
        for health: ProviderHealth
    ) -> ProviderErrorCategory? {
        switch health.issue {
        case .dependencyMissing:
            return .missingExecutable
        case .configurationInvalid:
            return .invalidHome
        case .authenticationRequired:
            return .loggedOut
        case .accountUnsupported:
            return .unsupportedAccount
        case .transportUnavailable:
            return .transientFailure
        case .protocolMismatch:
            return .incompatibleAppServer
        case .responseInvalid:
            return .malformedResponse
        case .optionalUsageUnavailable:
            return .partialUsage
        case .unknown:
            return .transientFailure
        case nil:
            switch health.status {
            case .healthy:
                return nil
            case .degraded:
                return .partialUsage
            case .unavailable:
                return .transientFailure
            case .unauthenticated:
                return .loggedOut
            case .unsupported:
                return .unsupportedAccount
            }
        }
    }

    static func category(
        for failure: ProviderRefreshFailure
    ) -> ProviderErrorCategory? {
        switch failure.kind {
        case .disabled:
            return nil
        case .unlinked, .invalidConfiguration:
            return .invalidHome
        case .dependencyMissing:
            return .missingExecutable
        case .unauthenticated:
            return .loggedOut
        case .unsupportedAccount:
            return .unsupportedAccount
        case .persistence:
            return nil
        case .transport, .unknown:
            return .transientFailure
        case .protocolMismatch:
            return .incompatibleAppServer
        case .malformedResponse:
            return .malformedResponse
        case .timedOut:
            return .timeout
        }
    }
}
