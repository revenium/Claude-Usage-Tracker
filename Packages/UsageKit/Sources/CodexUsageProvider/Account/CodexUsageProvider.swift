import Foundation
import UsageCore

public struct CodexUsageProvider: UsageProvider, Sendable {
    public let id = ProviderID.codex

    public let capabilities = ProviderCapabilities([
        .account: .available,
        .health: .available,
        .usageLimits: .available,
        .usageSummary: .unknown,
        .credits: .available,
        .resetCredits: .available,
        .interactiveLogin: .available,
        .automaticSessionStart: .unavailable,
        .statusLineIntegration: .unavailable
    ])

    private let client: CodexAppServerClient
    private let now: @Sendable () -> Date

    public init(
        processConfiguration: CodexProcessConfiguration,
        limits: CodexTransportLimits = try! CodexTransportLimits(),
        clientInfo: CodexClientInfo = try! CodexClientInfo(
            name: "claude_usage_tracker",
            title: "Claude Usage",
            version: "1"
        )
    ) {
        client = CodexAppServerClient(
            processConfiguration: processConfiguration,
            limits: limits,
            clientInfo: clientInfo
        )
        now = { Date() }
    }

    public init(client: CodexAppServerClient) {
        self.client = client
        now = { Date() }
    }

    init(
        client: CodexAppServerClient,
        now: @escaping @Sendable () -> Date
    ) {
        self.client = client
        self.now = now
    }

    public func account() async throws -> ProviderAccount? {
        try await readSupportedAccount(refreshToken: false)
    }

    public func readAccount(
        refreshToken: Bool
    ) async throws -> ProviderAccount {
        try await readSupportedAccount(refreshToken: refreshToken)
    }

    public func accountStatus(
        refreshToken: Bool = false
    ) async throws -> CodexAccountStatus {
        try await requestAccountStatus(refreshToken: refreshToken)
    }

    /// Returns an existing supported account without starting another login.
    ///
    /// Logged-out homes proceed through the requested official interactive
    /// flow, while non-subscription account modes remain explicitly
    /// unsupported.
    public func beginLogin(
        _ flow: CodexLoginFlow
    ) async throws -> CodexLoginStartResult {
        switch try await accountStatus() {
        case let .supported(account):
            return .alreadyAuthenticated(account)
        case .unauthenticated:
            return .started(try await startLogin(flow))
        case .unsupported:
            throw UsageProviderError.unsupportedAccount
        }
    }

    public func health() async -> ProviderHealth {
        let checkedAt = now()
        do {
            try await client.withSession { session in
                _ = try await readSupportedAccount(
                    refreshToken: false,
                    session: session
                )
                _ = try await requestRateLimits(session: session)
            }
            return ProviderHealth(
                status: .healthy,
                checkedAt: checkedAt
            )
        } catch {
            return Self.health(
                for: Self.map(error),
                checkedAt: checkedAt
            )
        }
    }

    public func fetchUsage() async throws -> UsageReport {
        let snapshot: RefreshSnapshot
        do {
            snapshot = try await client.withSession { session in
                let account = try await readSupportedAccount(
                    refreshToken: false,
                    session: session
                )
                let rateLimits = try await requestRateLimits(session: session)
                let usage = try await requestOptionalTokenUsage(
                    session: session
                )
                return RefreshSnapshot(
                    account: account,
                    rateLimits: rateLimits,
                    usage: usage
                )
            }
        } catch {
            throw Self.map(error)
        }
        let fetchedAt = now()

        do {
            let mappedLimits = try CodexReportMapper.limitGroups(
                from: snapshot.rateLimits
            )
            let mappedCredits = try CodexReportMapper.credits(
                from: snapshot.rateLimits
            )
            let summaryResult = Self.mapOptionalUsage(snapshot.usage)
            let mappedSummary: UsageSummary?
            let health: ProviderHealth
            switch summaryResult {
            case let .available(summary):
                mappedSummary = summary
                health = ProviderHealth(
                    status: .healthy,
                    checkedAt: fetchedAt
                )
            case .unavailable:
                mappedSummary = nil
                health = ProviderHealth(
                    status: .degraded,
                    checkedAt: fetchedAt,
                    issue: .optionalUsageUnavailable
                )
            }
            return try UsageReport(
                providerID: .codex,
                account: snapshot.account,
                health: health,
                limitGroups: mappedLimits,
                usageSummary: mappedSummary,
                credits: mappedCredits,
                fetchedAt: fetchedAt
            )
        } catch is UsageCoreValidationError {
            throw UsageProviderError.malformedResponse
        } catch let error as UsageProviderError {
            throw error
        } catch {
            throw UsageProviderError.malformedResponse
        }
    }

    public func startLogin(
        _ flow: CodexLoginFlow
    ) async throws -> CodexLoginAttempt {
        let session: CodexAppServerSession
        do {
            session = try await client.openSession()
        } catch {
            throw Self.map(error)
        }

        do {
            let params: CodexJSONValue
            switch flow {
            case let .browser(useHostedSuccessPage, appBrand):
                params = .object([
                    "type": .string("chatgpt"),
                    "useHostedLoginSuccessPage": .bool(useHostedSuccessPage),
                    "appBrand": .string(appBrand.rawValue)
                ])
            case .deviceCode:
                params = .object([
                    "type": .string("chatgptDeviceCode")
                ])
            }

            let rawResponse = try await session.request(
                .accountLoginStart,
                params: params
            )
            let response = try CodexDomainDecoder.decode(
                CodexLoginStartResponse.self,
                from: rawResponse
            )
            let challenge = try Self.loginChallenge(
                from: response,
                expectedFlow: flow
            )
            return CodexLoginAttempt(
                challenge: challenge,
                session: session
            )
        } catch let operationError {
            do {
                try await session.close()
            } catch {
                throw Self.map(error)
            }
            if let providerError = operationError as? UsageProviderError {
                throw providerError
            }
            throw Self.map(operationError)
        }
    }

    /// Disconnecting unlinks this provider instance only.
    ///
    /// It intentionally does not invoke `account/logout` and never mutates the
    /// linked CODEX_HOME. The app owns removal of the profile reference.
    public func disconnect() async {}

    private func readSupportedAccount(
        refreshToken: Bool,
        session: CodexAppServerSession? = nil
    ) async throws -> ProviderAccount {
        switch try await requestAccountStatus(
            refreshToken: refreshToken,
            session: session
        ) {
        case let .supported(account):
            return account
        case .unauthenticated:
            throw UsageProviderError.unauthenticated
        case .unsupported:
            throw UsageProviderError.unsupportedAccount
        }
    }

    private func requestAccountStatus(
        refreshToken: Bool,
        session: CodexAppServerSession? = nil
    ) async throws -> CodexAccountStatus {
        let rawResponse: CodexJSONValue
        do {
            rawResponse = try await request(
                .accountRead,
                params: .object(["refreshToken": .bool(refreshToken)]),
                session: session
            )
        } catch {
            throw Self.map(error)
        }

        let response = try CodexDomainDecoder.decode(
            CodexAccountReadResponse.self,
            from: rawResponse
        )
        guard let account = response.account else {
            if response.requiresOpenaiAuth {
                return .unauthenticated
            }
            return .unsupported(.noOpenAIAccount)
        }

        switch account.type {
        case "chatgpt":
            return .supported(
                ProviderAccount(
                    displayName: Self.safeDisplayValue(account.email),
                    planName: Self.safeDisplayValue(account.planType)
                )
            )
        case "apiKey":
            return .unsupported(.apiKey)
        case "amazonBedrock":
            return .unsupported(.amazonBedrock)
        default:
            return .unsupported(.other)
        }
    }

    private func requestRateLimits(
        session: CodexAppServerSession? = nil
    ) async throws -> CodexRateLimitsResponse {
        let rawResponse: CodexJSONValue
        do {
            rawResponse = try await request(
                .accountRateLimitsRead,
                session: session
            )
        } catch {
            throw Self.map(error)
        }

        let decoded = try CodexDomainDecoder.decode(
            CodexRateLimitsResponse.self,
            from: rawResponse
        )
        guard decoded.rateLimits != nil
                || !decoded.rateLimitsByLimitID.isEmpty
        else {
            throw UsageProviderError.malformedResponse
        }
        return decoded
    }

    private func requestOptionalTokenUsage(
        session: CodexAppServerSession? = nil
    )
        async throws -> OptionalTokenUsageSnapshot
    {
        do {
            let rawResponse = try await request(
                .accountUsageRead,
                session: session
            )
            let decoded = try CodexDomainDecoder.decode(
                CodexAccountTokenUsageResponse.self,
                from: rawResponse
            )
            guard decoded.containsRecognizedUsageSurface else {
                return .unavailable
            }
            return .available(decoded)
        } catch let error as CodexTransportError {
            if case let .rpcFailure(code, method, _) = error,
               code == -32601,
               method == .accountUsageRead
            {
                return .unavailable
            }
            throw Self.map(error)
        } catch let error as UsageProviderError {
            if error == .malformedResponse {
                return .unavailable
            }
            throw error
        } catch {
            return .unavailable
        }
    }

    private func request(
        _ method: CodexMethod,
        params: CodexJSONValue? = nil,
        session: CodexAppServerSession?
    ) async throws -> CodexJSONValue {
        if let session {
            return try await session.request(method, params: params)
        }
        return try await client.request(method, params: params)
    }

    private static func loginChallenge(
        from response: CodexLoginStartResponse,
        expectedFlow: CodexLoginFlow
    ) throws -> CodexLoginChallenge {
        guard let loginID = safeOpaqueValue(response.loginID) else {
            throw UsageProviderError.malformedResponse
        }

        switch expectedFlow {
        case .browser:
            guard response.type == "chatgpt",
                  let authorizationURL = safeWebURL(
                      response.authorizationURL
                  )
            else {
                throw UsageProviderError.malformedResponse
            }
            return .browser(
                loginID: loginID,
                authorizationURL: authorizationURL
            )
        case .deviceCode:
            guard response.type == "chatgptDeviceCode",
                  let verificationURL = safeWebURL(
                      response.verificationURL
                  ),
                  let userCode = safeOpaqueValue(response.userCode)
            else {
                throw UsageProviderError.malformedResponse
            }
            return .deviceCode(
                loginID: loginID,
                verificationURL: verificationURL,
                userCode: userCode
            )
        }
    }

    private static func mapOptionalUsage(
        _ usage: OptionalTokenUsageSnapshot
    ) -> OptionalUsageMapping {
        switch usage {
        case let .available(response):
            do {
                return .available(
                    try CodexReportMapper.usageSummary(from: response)
                )
            } catch {
                return .unavailable
            }
        case .unavailable:
            return .unavailable
        }
    }

    static func map(_ error: Error) -> UsageProviderError {
        if error is CancellationError {
            return .cancelled
        }
        guard let transportError = error as? CodexTransportError else {
            if let providerError = error as? UsageProviderError {
                return providerError
            }
            return .transportFailure
        }

        switch transportError {
        case let .invalidConfiguration(field):
            return field == .executable
                ? .dependencyMissing
                : .invalidConfiguration
        case let .rpcFailure(code, _, _):
            return code == 401 || code == 403
                ? .unauthenticated
                : .protocolFailure
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        case .malformedFrame,
             .lineLimitExceeded,
             .requestIDMismatch,
             .requestIDExhausted,
             .unsupportedServerRequest,
             .unexpectedResponse:
            return .protocolFailure
        case .launchFailed,
             .writeFailed,
             .outputLimitExceeded,
             .processExited,
             .unexpectedEOF:
            return .transportFailure
        }
    }

    private static func health(
        for error: UsageProviderError,
        checkedAt: Date
    ) -> ProviderHealth {
        switch error {
        case .unauthenticated:
            ProviderHealth(
                status: .unauthenticated,
                checkedAt: checkedAt,
                issue: .authenticationRequired
            )
        case .unsupportedAccount:
            ProviderHealth(
                status: .unsupported,
                checkedAt: checkedAt,
                issue: .accountUnsupported
            )
        case .dependencyMissing:
            ProviderHealth(
                status: .unavailable,
                checkedAt: checkedAt,
                issue: .dependencyMissing
            )
        case .invalidConfiguration:
            ProviderHealth(
                status: .unavailable,
                checkedAt: checkedAt,
                issue: .configurationInvalid
            )
        case .malformedResponse:
            ProviderHealth(
                status: .degraded,
                checkedAt: checkedAt,
                issue: .responseInvalid
            )
        case .protocolFailure:
            ProviderHealth(
                status: .degraded,
                checkedAt: checkedAt,
                issue: .protocolMismatch
            )
        case .transportFailure, .timedOut, .cancelled:
            ProviderHealth(
                status: .unavailable,
                checkedAt: checkedAt,
                issue: .transportUnavailable
            )
        case .capabilityUnavailable:
            ProviderHealth(
                status: .degraded,
                checkedAt: checkedAt,
                issue: .unknown
            )
        }
    }

    static func safeOpaqueValue(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              value.count <= 2_048,
              value == value.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            return nil
        }
        return value
    }

    private static func safeDisplayValue(_ value: String?) -> String? {
        guard let value = safeOpaqueValue(value), value.count <= 512 else {
            return nil
        }
        return value
    }

    private static func safeWebURL(_ value: String?) -> URL? {
        guard let value = safeOpaqueValue(value),
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https"
                || (scheme == "http" && isLoopbackHost(url.host)),
              url.host != nil,
              url.user == nil,
              url.password == nil
        else {
            return nil
        }
        return url
    }

    private static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
            || host == "[::1]"
    }
}

private struct RefreshSnapshot: Sendable {
    var account: ProviderAccount
    var rateLimits: CodexRateLimitsResponse
    var usage: OptionalTokenUsageSnapshot
}

private enum OptionalTokenUsageSnapshot: Sendable {
    case available(CodexAccountTokenUsageResponse)
    case unavailable
}

private enum OptionalUsageMapping {
    case available(UsageSummary?)
    case unavailable
}

public actor CodexLoginAttempt {
    private enum TerminalOperation {
        case idle
        case waitingForCompletion
        case cancelling
        case disconnecting
        case closed
    }

    public nonisolated let challenge: CodexLoginChallenge

    private let session: CodexAppServerSession
    private var terminalOperation = TerminalOperation.idle

    init(
        challenge: CodexLoginChallenge,
        session: CodexAppServerSession
    ) {
        self.challenge = challenge
        self.session = session
    }

    public func waitForCompletion() async throws -> CodexLoginOutcome {
        try begin(.waitingForCompletion)
        do {
            let notification = try await session.nextNotification(
                matching: .accountLoginCompleted
            )
            let completion = try decodeCompletion(notification)
            try await close()
            return completion.success ? .succeeded : .failed
        } catch let operationError {
            do {
                try await close()
            } catch {
                throw CodexUsageProvider.map(error)
            }
            if let providerError = operationError as? UsageProviderError {
                throw providerError
            }
            throw CodexUsageProvider.map(operationError)
        }
    }

    public func cancel() async throws -> CodexLoginCancellationOutcome {
        try begin(.cancelling)
        do {
            let rawResponse = try await session.request(
                .accountLoginCancel,
                params: .object([
                    "loginId": .string(challenge.loginID)
                ])
            )
            let response = try CodexDomainDecoder.decode(
                CodexCancelLoginResponse.self,
                from: rawResponse
            )
            switch response.status {
            case "canceled":
                let notification = try await session.nextNotification(
                    matching: .accountLoginCompleted
                )
                let completion = try decodeCompletion(notification)
                guard !completion.success else {
                    throw UsageProviderError.malformedResponse
                }
                try await close()
                return .canceled
            case "notFound":
                try await close()
                return .notFound
            default:
                throw UsageProviderError.malformedResponse
            }
        } catch let operationError {
            do {
                try await close()
            } catch {
                throw CodexUsageProvider.map(error)
            }
            if let providerError = operationError as? UsageProviderError {
                throw providerError
            }
            throw CodexUsageProvider.map(operationError)
        }
    }

    /// Closes the login-scoped app-server without logging the Codex account out.
    public func disconnect() async throws {
        try begin(.disconnecting)
        try await close()
    }

    private func decodeCompletion(
        _ notification: CodexNotificationFrame
    ) throws -> CodexLoginCompletedNotification {
        guard let params = notification.params else {
            throw UsageProviderError.malformedResponse
        }
        let completion = try CodexDomainDecoder.decode(
            CodexLoginCompletedNotification.self,
            from: params
        )
        guard completion.loginID == challenge.loginID else {
            throw UsageProviderError.malformedResponse
        }
        return completion
    }

    private func begin(_ operation: TerminalOperation) throws {
        guard terminalOperation == .idle else {
            throw UsageProviderError.invalidConfiguration
        }
        terminalOperation = operation
    }

    private func close() async throws {
        guard terminalOperation != .closed else { return }
        terminalOperation = .closed
        try await session.close()
    }
}
