import CodexUsageProvider
import Darwin
import Foundation
import UsageCore
import XCTest
@testable import Claude_Usage

private actor ProviderDiagnosticsTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
final class ProviderDiagnosticsTests: HostedAppTestCase {
    private struct FixtureError: LocalizedError {
        let payload: String
        var errorDescription: String? { payload }
    }

    private struct UnsafeLegacyNetworkLog: Codable {
        let id: UUID
        let timestamp: Date
        let url: String
        let method: String
        let statusCode: Int?
        let duration: TimeInterval?
        let requestBody: String?
        let responsePreview: String?
        let fullResponseSize: Int?
        let errorMessage: String?
    }

    private struct UnsafeLegacyNetworkSession: Codable {
        let isActive: Bool
        let startTime: Date?
        let endTime: Date?
        let duration: TimeInterval
        let logs: [UnsafeLegacyNetworkLog]
    }

    private let bearer = "sk-ant-p14BearerSecret123456"
    private let session = "sess-p14SessionSecret123456"
    private let cookie = "p14CookieSecret123456"
    private let query = "p14QuerySecret123456"
    private let credential = "p14CredentialSecret123456"
    private let home = "/Users/p14-sensitive/.codex/accounts/work"
    private let rpcSecret = "p14RPCSecret123456"
    private let environmentSecret =
        "p14EnvironmentSecret123456"
    private let customHome = "/custom/private/location"
    private let bareCustomHome =
        "/srv/p14-private/codex/accounts/default"
    private let jwt =
        "eyJhbGciOiJIUzI1NiJ9."
        + "eyJzdWIiOiJwMTRKd1RTZWNyZXQifQ."
        + "p14JWTSignatureSecret123456789"

    private var secretFixtures: [String] {
        [
            bearer,
            session,
            cookie,
            query,
            credential,
            home,
            rpcSecret,
            environmentSecret,
            customHome,
            bareCustomHome,
            jwt,
            "p14-sensitive"
        ]
    }

    func testTableDrivenRedactorRemovesSensitiveClasses() {
        let cases: [(name: String, value: String, marker: String)] = [
            (
                "query",
                "https://example.test/usage?token=\(query)&mode=full#\(credential)",
                SensitiveDataRedactor.redactedQuery
            ),
            (
                "authorization",
                "Authorization: Bearer \(bearer)",
                SensitiveDataRedactor.redactedValue
            ),
            (
                "cookie",
                "Cookie: session=\(cookie); theme=dark",
                SensitiveDataRedactor.redactedValue
            ),
            (
                "credential-json",
                #"{"accessToken":"\#(credential)","nested":{"sessionKey":"\#(session)"},"ok":true}"#,
                SensitiveDataRedactor.redactedValue
            ),
            (
                "embedded-credential-json",
                #"prefix {"refreshToken":"\#(credential)"} suffix"#,
                SensitiveDataRedactor.redactedValue
            ),
            (
                "nested-cookie",
                #"{"message":"Cookie: \#(cookie)"}"#,
                SensitiveDataRedactor.redactedValue
            ),
            (
                "session-token",
                "session_key=\(session)",
                SensitiveDataRedactor.redactedValue
            ),
            (
                "home-path",
                "CODEX_HOME=\(home)",
                SensitiveDataRedactor.redactedPath
            ),
            (
                "generic-secret-environment",
                "AWS_SECRET_ACCESS_KEY=\(environmentSecret)",
                SensitiveDataRedactor.redactedValue
            ),
            (
                "generic-token-environment",
                "GITHUB_TOKEN=\(environmentSecret)",
                SensitiveDataRedactor.redactedValue
            ),
            (
                "id-token-environment",
                "id_token=\(environmentSecret)",
                SensitiveDataRedactor.redactedValue
            ),
            (
                "custom-home-environment",
                "CUSTOM_HOME=\(customHome)",
                SensitiveDataRedactor.redactedPath
            ),
            (
                "bare-custom-home",
                "Provider home \(bareCustomHome)",
                SensitiveDataRedactor.redactedPath
            ),
            (
                "bare-custom-home-after-colon",
                "Provider home:\(bareCustomHome)",
                SensitiveDataRedactor.redactedPath
            ),
            (
                "bare-custom-home-after-equals",
                "provider_root=\(bareCustomHome)",
                SensitiveDataRedactor.redactedPath
            ),
            (
                "standalone-jwt",
                "Probe returned \(jwt)",
                SensitiveDataRedactor.redactedValue
            ),
            (
                "custom-auth-file",
                "Credential file: /custom/private/auth.json",
                SensitiveDataRedactor.redactedPath
            ),
            (
                "volume-path",
                "Executable: /Volumes/PrivateDisk/bin/codex",
                SensitiveDataRedactor.redactedPath
            ),
            (
                "rpc",
                #"{"id":1,"method":"account/read","params":{"token":"\#(rpcSecret)"}}"#,
                SensitiveDataRedactor.redactedRPC
            )
        ]

        for fixture in cases {
            let result = SensitiveDataRedactor.redact(fixture.value)
            XCTAssertTrue(
                result.contains(fixture.marker),
                fixture.name
            )
            assertNoSecrets(result, context: fixture.name)
        }
    }

    func testRedactorPreservesBenignVersionsAndPublicURLs() {
        let version = "codex-cli 1.2.3"
        let publicURL =
            "https://example.test/releases/codex-cli/1.2.3"

        XCTAssertEqual(
            SensitiveDataRedactor.redact(version),
            version
        )
        XCTAssertEqual(
            SensitiveDataRedactor.redact(publicURL),
            publicURL
        )
        XCTAssertFalse(
            SensitiveDataRedactor.redact(
                "home: \(bareCustomHome)"
            ).contains(bareCustomHome)
        )
        XCTAssertFalse(
            SensitiveDataRedactor.redact(
                "token: \(jwt)"
            ).contains(jwt)
        )
    }

    func testEveryLoggingEntryPointUsesCentralRedactionBoundary() {
        var output: [String] = []
        let logger = retain(
            LoggingService {
                output.append($0)
            }
        )
        let hostileURL =
            "https://example.test/path?token=\(query)"
        let hostileError = FixtureError(
            payload:
                "Authorization: Bearer \(bearer)\n"
                + "CODEX_HOME=\(home)"
        )
        let hostileJSON =
            #"{"refreshToken":"\#(credential)"}"#

        logger.logAPIRequest(hostileURL)
        logger.logAPIResponse(hostileURL, statusCode: 200)
        logger.logAPIError(hostileURL, error: hostileError)
        logger.logStorageSave(hostileJSON)
        logger.logStorageLoad(hostileJSON, success: false)
        logger.logStorageError(hostileJSON, error: hostileError)
        logger.logNotificationSent(
            "Cookie: session=\(cookie)"
        )
        logger.logNotificationError(hostileError)
        logger.logNotificationPermission(true)
        logger.logUIEvent("CODEX_HOME=\(home)")
        logger.logWindowEvent("session_key=\(session)")
        logger.log(hostileJSON)
        logger.logError(hostileURL, error: hostileError)
        logger.logWarning("Bearer \(bearer)")
        logger.logInfo("Cookie: \(cookie)")
        logger.logDebug(
            #"{"id":9,"result":{"token":"\#(rpcSecret)"}}"#
        )

        XCTAssertEqual(output.count, 16)
        assertNoSecrets(
            output.joined(separator: "\n"),
            context: "LoggingService"
        )
        XCTAssertTrue(
            output.contains {
                $0.contains(
                    SensitiveDataRedactor.redactedRPC
                )
            }
        )
    }

    func testAppErrorAndErrorLoggerNeverRetainRawDetails() {
        let raw = "Authorization: Bearer \(bearer)\n"
            + "Cookie: \(cookie)\nCODEX_HOME=\(home)"
        let appError = AppError(
            code: .unknown,
            message: raw,
            technicalDetails:
                #"{"apiKey":"\#(credential)"}"#,
            underlyingError: FixtureError(
                payload: "session_key=\(session)"
            ),
            recoverySuggestion:
                "Open \(home)?token=\(query)",
            file: home + "/SensitiveSource.swift",
            function: "operation(\(bearer))"
        )

        let fields = [
            appError.message,
            appError.technicalDetails ?? "",
            appError.underlyingError?.localizedDescription ?? "",
            appError.recoverySuggestion ?? "",
            appError.description,
            appError.supportReport,
            appError.context?.file ?? "",
            appError.context?.function ?? ""
        ].joined(separator: "\n")
        assertNoSecrets(fields, context: "AppError")

        let errorLogger = retain(ErrorLogger())
        errorLogger.log(appError)
        let exported = errorLogger.exportLog()
        assertNoSecrets(exported, context: "ErrorLogger")
    }

    func testNetworkModelSanitizesNewAndLegacyRecords() throws {
        let hostileURL =
            "https://example.test/usage?token=\(query)"
        let hostileBody =
            #"{"sessionKey":"\#(session)","credential":"\#(credential)"}"#
        let hostileResponse =
            #"{"id":1,"result":{"token":"\#(rpcSecret)"}}"#
        let hostileError =
            "Cookie: session=\(cookie)\nCODEX_HOME=\(home)"

        let newLog = NetworkRequestLog(
            timestamp: Date(),
            url: hostileURL,
            method: "POST",
            requestBody: hostileBody,
            responsePreview: hostileResponse,
            errorMessage: hostileError
        )
        assertSafeNetworkLog(newLog, context: "new")

        let legacy = UnsafeLegacyNetworkLog(
            id: UUID(),
            timestamp: Date(),
            url: hostileURL,
            method: "POST",
            statusCode: 500,
            duration: 0.2,
            requestBody: hostileBody,
            responsePreview: hostileResponse,
            fullResponseSize: 4_096,
            errorMessage: hostileError
        )
        let legacyData = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(
            NetworkRequestLog.self,
            from: legacyData
        )
        assertSafeNetworkLog(decoded, context: "legacy")
        assertNoSecrets(
            String(
                data: try JSONEncoder().encode(decoded),
                encoding: .utf8
            ) ?? "",
            context: "encoded legacy"
        )
    }

    func testNetworkLoggerSanitizesBeforeMemoryAndDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL =
            root.appendingPathComponent("network_logs.json")
        let logger = retain(
            NetworkLoggerService(
                session: NetworkLoggingSession(),
                storageURL: storageURL,
                loggingService: LoggingService()
            )
        )
        logger.startLogging(duration: 60)
        logger.logRequest(
            url:
                "https://example.test/usage?token=\(query)",
            method: "POST",
            requestBody: Data(
                #"{"apiKey":"\#(credential)"}"#.utf8
            ),
            responseData: Data(
                #"{"id":1,"result":{"token":"\#(rpcSecret)"}}"#
                    .utf8
            ),
            statusCode: 401,
            duration: 0.5,
            error: FixtureError(
                payload:
                    "Authorization: Bearer \(bearer)\n"
                    + "CODEX_HOME=\(home)"
            )
        )
        logger.stopLogging()

        let logged = try XCTUnwrap(logger.session.logs.first)
        assertSafeNetworkLog(logged, context: "service memory")
        let persisted = try String(
            contentsOf: storageURL,
            encoding: .utf8
        )
        assertNoSecrets(persisted, context: "service disk")
    }

    func testNetworkLoggerRewritesSanitizedLegacySessionToDisk()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL =
            root.appendingPathComponent("network_logs.json")
        let legacy = UnsafeLegacyNetworkSession(
            isActive: false,
            startTime: nil,
            endTime: nil,
            duration: 900,
            logs: [
                UnsafeLegacyNetworkLog(
                    id: UUID(),
                    timestamp: Date(),
                    url:
                        "https://example.test/usage?token=\(query)",
                    method: "POST",
                    statusCode: 200,
                    duration: 0.1,
                    requestBody:
                        "GITHUB_TOKEN=\(environmentSecret)",
                    responsePreview:
                        #"{"id":1,"result":{"credential":"\#(credential)"}}"#,
                    fullResponseSize: 20,
                    errorMessage:
                        "CODEX_HOME=\(home)"
                )
            ]
        )
        try JSONEncoder().encode(legacy).write(
            to: storageURL,
            options: .atomic
        )

        let logger = retain(
            NetworkLoggerService(
                storageURL: storageURL,
                loggingService: LoggingService()
            )
        )

        let loaded = try XCTUnwrap(logger.session.logs.first)
        assertSafeNetworkLog(loaded, context: "loaded legacy")
        let persisted = try String(
            contentsOf: storageURL,
            encoding: .utf8
        )
        assertNoSecrets(
            persisted,
            context: "rewritten legacy disk"
        )
    }

    func testNetworkLoggerDiscardsUndecodableLegacySession()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL =
            root.appendingPathComponent("network_logs.json")
        try Data(
            #"{"GITHUB_TOKEN":"\#(environmentSecret)""#.utf8
        ).write(to: storageURL, options: .atomic)

        let logger = retain(
            NetworkLoggerService(
                storageURL: storageURL,
                loggingService: LoggingService()
            )
        )

        XCTAssertTrue(logger.session.logs.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: storageURL.path
            )
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    func testNetworkLoggerFailsClosedWhenUnsafeLegacyRemovalFails()
        throws
    {
        struct StorageFailure: Error {}

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL =
            root.appendingPathComponent("network_logs.json")
        let legacy = UnsafeLegacyNetworkSession(
            isActive: false,
            startTime: nil,
            endTime: nil,
            duration: 900,
            logs: [
                UnsafeLegacyNetworkLog(
                    id: UUID(),
                    timestamp: Date(),
                    url: "https://example.test",
                    method: "POST",
                    statusCode: 200,
                    duration: 0.1,
                    requestBody: "GITHUB_TOKEN=\(environmentSecret)",
                    responsePreview: nil,
                    fullResponseSize: nil,
                    errorMessage: nil
                )
            ]
        )
        try JSONEncoder().encode(legacy).write(
            to: storageURL,
            options: .atomic
        )
        var logOutput: [String] = []
        let logger = retain(
            NetworkLoggerService(
                storageURL: storageURL,
                loggingService: LoggingService {
                    logOutput.append($0)
                },
                storageOperations: NetworkLogStorageOperations(
                    fileExists: {
                        FileManager.default.fileExists(
                            atPath: $0.path
                        )
                    },
                    read: { try Data(contentsOf: $0) },
                    writeAtomically: { _, _ in
                        throw StorageFailure()
                    },
                    remove: { _ in
                        throw StorageFailure()
                    }
                )
            )
        )

        XCTAssertEqual(
            logger.storageFailure,
            .unsafeLegacyCaptureRetained
        )
        XCTAssertTrue(logger.session.logs.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: storageURL.path
            )
        )
        assertNoSecrets(
            logOutput.joined(separator: "\n"),
            context: "legacy removal failure"
        )
    }

    func testProviderErrorTaxonomyMapsTitlesActionsAndAppErrors() {
        let duplicateID = UUID()
        let cases:
            [
                (
                    error: Error,
                    category: ProviderErrorCategory,
                    actions: [ProviderRecoveryAction],
                    recoverable: Bool
                )
            ] = [
                (
                    CodexProviderFactoryError.executableMissing,
                    .missingExecutable,
                    [.installOrUpdateCodex, .openSettings],
                    true
                ),
                (
                    CodexTransportError.launchFailed,
                    .launchFailure,
                    [
                        .retry,
                        .installOrUpdateCodex,
                        .openSettings
                    ],
                    true
                ),
                (
                    CodexTransportError.timedOut(
                        stage: .request,
                        method: nil,
                        id: nil
                    ),
                    .timeout,
                    [.retry],
                    true
                ),
                (
                    CodexTransportError.cancelled(
                        method: nil,
                        id: nil
                    ),
                    .cancellation,
                    [.retry],
                    true
                ),
                (
                    CodexTransportError.unsupportedServerRequest(
                        method: .initialize
                    ),
                    .incompatibleAppServer,
                    [
                        .installOrUpdateCodex,
                        .retry,
                        .openSettings
                    ],
                    true
                ),
                (
                    CodexTransportError.malformedFrame,
                    .malformedResponse,
                    [
                        .retry,
                        .installOrUpdateCodex,
                        .openSettings
                    ],
                    true
                ),
                (
                    CodexHomeCanonicalizationError.missing,
                    .invalidHome,
                    [.openSettings],
                    true
                ),
                (
                    ProfileProviderConfigurationError
                        .duplicateCodexHome(duplicateID),
                    .duplicateHome,
                    [.openSettings],
                    true
                ),
                (
                    UsageProviderError.unauthenticated,
                    .loggedOut,
                    [.openSettings],
                    true
                ),
                (
                    UsageProviderError.unsupportedAccount,
                    .unsupportedAccount,
                    [.openSettings],
                    false
                ),
                (
                    UsageProviderError.capabilityUnavailable(
                        .usageSummary
                    ),
                    .partialUsage,
                    [.retry, .openSettings],
                    true
                ),
                (
                    UsageProviderError.transportFailure,
                    .transientFailure,
                    [.retry, .openSettings],
                    true
                )
            ]

        XCTAssertEqual(
            Set(cases.map(\.category)),
            Set(ProviderErrorCategory.allCases)
        )
        for fixture in cases {
            let presentation = ProviderErrorMapper.presentation(
                for: fixture.error
            )
            XCTAssertEqual(
                presentation?.category,
                fixture.category
            )
            XCTAssertEqual(
                presentation?.actions,
                fixture.actions
            )
            XCTAssertEqual(
                presentation?.isRecoverable,
                fixture.recoverable
            )
            XCTAssertFalse(presentation?.title.isEmpty ?? true)
            XCTAssertFalse(
                presentation?.explanation.isEmpty ?? true
            )

            let appError = AppError.wrap(fixture.error)
            XCTAssertEqual(
                appError.providerCategory,
                fixture.category
            )
            XCTAssertEqual(
                appError.recoveryActions,
                fixture.actions
            )
            XCTAssertEqual(
                appError.code.category,
                .provider
            )
            assertNoSecrets(
                appError.supportReport,
                context: fixture.category.rawValue
            )
        }
    }

    func testProviderRetryPolicyOnlyRetriesTransientCases() {
        let transient = AppError.wrap(
            UsageProviderError.transportFailure
        )
        let missing = AppError.wrap(
            CodexProviderFactoryError.executableMissing
        )
        let cancelled = AppError.wrap(
            UsageProviderError.cancelled
        )

        if case .retryAfter = ErrorRecovery.shared.shouldRetry(
            transient
        ) {
            // Expected.
        } else {
            XCTFail("Transient provider failure should retry")
        }
        if case .doNotRetry = ErrorRecovery.shared.shouldRetry(
            missing
        ) {
            // Expected.
        } else {
            XCTFail("Missing executable needs explicit action")
        }
        if case .doNotRetry = ErrorRecovery.shared.shouldRetry(
            cancelled
        ) {
            // Expected.
        } else {
            XCTFail("Cancellation must not retry automatically")
        }
    }

    func testProviderRecoveryActionsExecuteOnlyOwnedRoutes() {
        var retryCount = 0
        var settingsCount = 0
        let dispatcher = ProviderRecoveryActionDispatcher(
            retry: { retryCount += 1 },
            openSettings: { settingsCount += 1 }
        )

        XCTAssertTrue(dispatcher.perform(.retry))
        XCTAssertEqual(retryCount, 1)
        XCTAssertEqual(settingsCount, 0)

        XCTAssertTrue(dispatcher.perform(.openSettings))
        XCTAssertEqual(retryCount, 1)
        XCTAssertEqual(settingsCount, 1)

        XCTAssertFalse(
            dispatcher.perform(.installOrUpdateCodex)
        )
        XCTAssertEqual(retryCount, 1)
        XCTAssertEqual(settingsCount, 1)
    }

    func testCodexRefreshFailureUsesProviderPresentation() {
        let failure = ProviderRefreshFailure(
            kind: .unauthenticated,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            isRecoverable: true,
            consecutiveCount: 1
        )

        let codexError = MenuBarManager.appError(
            for: failure,
            providerID: .codex
        )
        XCTAssertEqual(codexError.providerCategory, .loggedOut)
        XCTAssertEqual(codexError.code, .providerLoggedOut)
        XCTAssertEqual(
            codexError.recoveryActions,
            [.openSettings]
        )

        let claudeError = MenuBarManager.appError(
            for: failure,
            providerID: .claude
        )
        XCTAssertNil(claudeError.providerCategory)
        XCTAssertEqual(claudeError.code, .apiUnauthorized)
    }

    func testCodexPersistenceFailureRetainsCanonicalStorageError() {
        let failure = ProviderRefreshFailure(
            kind: .persistence,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            isRecoverable: true,
            consecutiveCount: 1
        )

        XCTAssertNil(
            ProviderErrorMapper.presentation(for: failure)
        )
        let error = MenuBarManager.appError(
            for: failure,
            providerID: .codex
        )
        XCTAssertEqual(error.code, .storageWriteFailed)
        XCTAssertNil(error.providerCategory)
        XCTAssertTrue(error.recoveryActions.isEmpty)
    }

    func testDiagnosticsPresentationRejectsStaleOverlappingResult()
        async
    {
        let gate = ProviderDiagnosticsTestGate()
        let firstStarted = expectation(
            description: "first diagnostics request started"
        )
        let profileID = UUID()
        let firstProfile = Profile(
            id: profileID,
            name: "First",
            providerRevision: 7
        )
        let secondProfile = Profile(
            id: profileID,
            name: "Second",
            providerRevision: 8
        )
        let model = retain(
            ProviderDiagnosticsPresentationModel { profile in
                let revision = profile?.providerRevision ?? 0
                if revision == firstProfile.providerRevision {
                    firstStarted.fulfill()
                    await gate.wait()
                }
                return ProviderDiagnosticSnapshot(
                    generatedAt: Date(
                        timeIntervalSince1970:
                            TimeInterval(revision)
                    ),
                    appVersion: "revision-\(revision)",
                    appBuild: nil,
                    osVersion: "macOS",
                    providerID: "claude",
                    codexExecutableStatus: .notApplicable,
                    codexVersion: nil,
                    appServerCapability: .notApplicable,
                    homeFingerprint: nil,
                    health: nil,
                    requestDurationMilliseconds: nil,
                    recentErrorCategories: []
                )
            }
        )

        let firstTask = Task {
            await model.refresh(for: firstProfile)
        }
        await fulfillment(of: [firstStarted], timeout: 1)
        await model.refresh(for: secondProfile)
        await gate.open()
        await firstTask.value

        XCTAssertEqual(
            model.snapshot?.appVersion,
            "revision-8"
        )
        XCTAssertFalse(model.isRefreshing)
    }

    func testDiagnosticsPresentationRejectsFirstRequestInABAOverlap()
        async
    {
        let firstGate = ProviderDiagnosticsTestGate()
        let firstStarted = expectation(
            description: "first A diagnostics request started"
        )
        let profileID = UUID()
        let profileA = Profile(
            id: profileID,
            name: "A",
            providerRevision: 7
        )
        let profileB = Profile(
            id: profileID,
            name: "B",
            providerRevision: 8
        )
        var invocation = 0
        let model = retain(
            ProviderDiagnosticsPresentationModel { profile in
                invocation += 1
                let call = invocation
                if call == 1 {
                    firstStarted.fulfill()
                    await firstGate.wait()
                }
                return ProviderDiagnosticSnapshot(
                    generatedAt: Date(
                        timeIntervalSince1970:
                            TimeInterval(call)
                    ),
                    appVersion:
                        "call-\(call)-revision-"
                        + "\(profile?.providerRevision ?? 0)",
                    appBuild: nil,
                    osVersion: "macOS",
                    providerID: "claude",
                    codexExecutableStatus: .notApplicable,
                    codexVersion: nil,
                    appServerCapability: .notApplicable,
                    homeFingerprint: nil,
                    health: nil,
                    requestDurationMilliseconds: nil,
                    recentErrorCategories: []
                )
            }
        )

        let firstTask = Task {
            await model.refresh(for: profileA)
        }
        await fulfillment(of: [firstStarted], timeout: 1)
        await model.refresh(for: profileB)
        await model.refresh(for: profileA)
        await firstGate.open()
        await firstTask.value

        XCTAssertEqual(
            model.snapshot?.appVersion,
            "call-3-revision-7"
        )
        XCTAssertFalse(model.isRefreshing)
    }

    func testDiagnosticFixturesCoverEveryHealthClassSafely() {
        let logger = ErrorLogger()
        logger.log(
            AppError.wrap(UsageProviderError.timedOut)
        )
        let service = retain(
            ProviderDiagnosticsService(
                codexProviderFactory: CodexProviderFactory(
                    availability: .production
                ),
                errorLogger: logger,
                versionProbe: { _ in "codex-cli 9.9.9" },
                appVersion: {
                    "1.2.3 Authorization: Bearer "
                        + self.bearer
                },
                appBuild: { "456" },
                osVersion: {
                    "macOS test CODEX_HOME=\(self.home)"
                },
                now: {
                    Date(timeIntervalSince1970: 1_700_000_000)
                }
            )
        )
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let fixtures: [ProviderHealth] = [
            ProviderHealth(
                status: .healthy,
                checkedAt: checkedAt
            ),
            ProviderHealth(
                status: .unavailable,
                checkedAt: checkedAt,
                issue: .dependencyMissing
            ),
            ProviderHealth(
                status: .unavailable,
                checkedAt: checkedAt,
                issue: .configurationInvalid
            ),
            ProviderHealth(
                status: .unauthenticated,
                checkedAt: checkedAt,
                issue: .authenticationRequired
            ),
            ProviderHealth(
                status: .unsupported,
                checkedAt: checkedAt,
                issue: .accountUnsupported
            ),
            ProviderHealth(
                status: .unavailable,
                checkedAt: checkedAt,
                issue: .transportUnavailable
            ),
            ProviderHealth(
                status: .degraded,
                checkedAt: checkedAt,
                issue: .protocolMismatch
            ),
            ProviderHealth(
                status: .degraded,
                checkedAt: checkedAt,
                issue: .responseInvalid
            ),
            ProviderHealth(
                status: .degraded,
                checkedAt: checkedAt,
                issue: .optionalUsageUnavailable
            ),
            ProviderHealth(
                status: .degraded,
                checkedAt: checkedAt,
                issue: .unknown
            )
        ]

        for health in fixtures {
            let snapshot = service.snapshot(
                providerID: .codex,
                health: health,
                codexVersion: "codex-cli 9.9.9",
                homeIdentity: CodexHomeFilesystemIdentity(
                    deviceID: 123,
                    fileID: 456
                ),
                requestDurationMilliseconds: 42
            )
            let report = snapshot.supportText
            XCTAssertTrue(report.contains(health.status.rawValue))
            XCTAssertTrue(
                report.contains(
                    health.issue?.rawValue ?? "none"
                )
            )
            XCTAssertTrue(report.contains("fs-"))
            XCTAssertTrue(report.contains("42 ms"))
            XCTAssertTrue(report.contains("timeout"))
            XCTAssertFalse(report.contains("123:456"))
            assertNoSecrets(
                report,
                context:
                    "health \(health.status.rawValue) "
                    + "\(health.issue?.rawValue ?? "none")"
            )
        }
    }

    func testMissingExecutableDiagnosticIsSafeAndActionable()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let linkedHome =
            try CodexHomeCanonicalizer().canonicalize(root.path)
        let profile = Profile(
            name: "Codex",
            providerConfiguration: .codex(
                CodexProfileConfiguration(
                    linkedHome: linkedHome
                )
            )
        )
        let service = retain(
            ProviderDiagnosticsService(
                codexProviderFactory: CodexProviderFactory(
                    availability: .testing(),
                    executableResolver: {
                        throw CodexProviderFactoryError
                            .executableMissing
                    }
                ),
                errorLogger: ErrorLogger(),
                versionProbe: { _ in
                    XCTFail("Version probe must not run")
                    return nil
                },
                appVersion: { "1.0" },
                appBuild: { "1" },
                osVersion: { "macOS" }
            )
        )

        let snapshot = await service.snapshot(for: profile)

        XCTAssertEqual(snapshot.codexExecutableStatus, .missing)
        XCTAssertEqual(
            snapshot.health?.issue,
            .dependencyMissing
        )
        XCTAssertEqual(
            snapshot.appServerCapability,
            .unavailable
        )
        XCTAssertNotNil(snapshot.homeFingerprint)
        XCTAssertFalse(snapshot.supportText.contains(root.path))
        assertNoSecrets(
            snapshot.supportText,
            context: "missing executable"
        )
    }

    func testVersionProbeBoundsOutputAndScrubsEnvironment()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let environmentFile =
            root.appendingPathComponent("environment.txt")
        let normalScript =
            root.appendingPathComponent("normal-version")
        try makeExecutableScript(
            at: normalScript,
            body:
                "/usr/bin/env > "
                + shellQuoted(environmentFile.path)
                + "\nprintf 'codex-cli 9.9.9\\n'"
        )
        setenv(
            "P14_PARENT_TOKEN",
            credential,
            1
        )
        defer { unsetenv("P14_PARENT_TOKEN") }

        let version = await CodexVersionProbe.readVersion(
            normalScript,
            timeout: 1,
            terminationGrace: 0.1
        )

        XCTAssertEqual(version, "codex-cli 9.9.9")
        let childEnvironment = try String(
            contentsOf: environmentFile,
            encoding: .utf8
        )
        XCTAssertFalse(
            childEnvironment.contains("P14_PARENT_TOKEN")
        )
        XCTAssertFalse(childEnvironment.contains(credential))
        XCTAssertFalse(childEnvironment.contains("CODEX_HOME"))
        XCTAssertTrue(
            childEnvironment.contains("HOME=/var/empty")
        )

        let oversizedScript =
            root.appendingPathComponent("oversized-version")
        try makeExecutableScript(
            at: oversizedScript,
            body:
                "i=0\n"
                + "while [ \"$i\" -lt 5000 ]; do "
                + "printf x; i=$((i + 1)); done"
        )
        let oversized = await CodexVersionProbe.readVersion(
            oversizedScript,
            timeout: 1,
            terminationGrace: 0.1
        )
        XCTAssertNil(oversized)
    }

    func testVersionProbeCleansForkedStdoutWriterWithoutWaitingForEOF()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let childPIDFile =
            root.appendingPathComponent("writer.pid")
        let script =
            root.appendingPathComponent("forked-version")
        try makeExecutableScript(
            at: script,
            body:
                "(trap '' TERM; "
                + "while :; do /bin/sleep 1; done) &\n"
                + "printf '%s\\n' \"$!\" > "
                + shellQuoted(childPIDFile.path)
                + "\nprintf 'codex-cli 9.9.9\\n'\n"
                + "exit 0"
        )
        let startedAt = Date()
        let version = await CodexVersionProbe.readVersion(
            script,
            timeout: 2,
            terminationGrace: 0.05
        )

        XCTAssertEqual(version, "codex-cli 9.9.9")
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            1
        )
        let childPID = try readPID(from: childPIDFile)
        await assertProcessExited(childPID)
    }

    func testVersionProbeContinuousWriterCannotDefeatDeadline()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let rootPIDFile =
            root.appendingPathComponent("writer-root.pid")
        let script =
            root.appendingPathComponent("continuous-writer")
        try makeExecutableScript(
            at: script,
            body:
                "trap '' TERM\n"
                + "printf '%s\\n' \"$$\" > "
                + shellQuoted(rootPIDFile.path)
                + "\nwhile :; do printf x; done"
        )

        let startedAt = Date()
        let result = await CodexVersionProbe.readVersion(
            script,
            timeout: 0.2,
            terminationGrace: 0.05
        )

        XCTAssertNil(result)
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            1.5
        )
        await assertProcessExited(
            try readPID(from: rootPIDFile)
        )
    }

    func testVersionProbeCleansTrackedSetsidDescendant()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let childPIDFile =
            root.appendingPathComponent("setsid-child.pid")
        let script =
            root.appendingPathComponent("setsid-version")
        let perlProgram =
            "POSIX::setsid(); $SIG{TERM}='IGNORE'; "
            + "open(my $f, '>', $ARGV[0]) or die; "
            + "print $f \"$$\\n\"; close($f); "
            + "while (1) { select(undef, undef, undef, 0.1); }"
        try makeExecutableScript(
            at: script,
            body:
                "/usr/bin/perl -MPOSIX -e "
                + shellQuoted(perlProgram)
                + " "
                + shellQuoted(childPIDFile.path)
                + " &\n"
                + "while [ ! -s "
                + shellQuoted(childPIDFile.path)
                + " ]; do /bin/sleep 0.01; done\n"
                // Keep the parent-child relationship observable across more
                // than one probe census. A hostile instant reparent is
                // explicitly outside the trusted-executable contract.
                + "/bin/sleep 0.1\n"
                + "printf 'codex-cli 9.9.9\\n'"
        )

        let version = await CodexVersionProbe.readVersion(
            script,
            timeout: 2,
            terminationGrace: 0.05
        )

        XCTAssertEqual(version, "codex-cli 9.9.9")
        let childPID = try readPID(from: childPIDFile)
        defer { _ = Darwin.kill(childPID, SIGKILL) }
        await assertProcessExited(childPID)
    }

    func testVersionProbeKillsStubbornProcessTreeOnTimeout()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let rootPIDFile =
            root.appendingPathComponent("root.pid")
        let childPIDFile =
            root.appendingPathComponent("child.pid")
        let grandchildPIDFile =
            root.appendingPathComponent("grandchild.pid")
        let grandchildScript =
            root.appendingPathComponent("grandchild")
        let childScript =
            root.appendingPathComponent("child")
        let rootScript =
            root.appendingPathComponent("stubborn-version")
        try makeExecutableScript(
            at: grandchildScript,
            body:
                "trap '' TERM\n"
                + "printf '%s\\n' \"$$\" > "
                + shellQuoted(grandchildPIDFile.path)
                + "\nwhile :; do /bin/sleep 1; done"
        )
        try makeExecutableScript(
            at: childScript,
            body:
                "trap '' TERM\n"
                + "printf '%s\\n' \"$$\" > "
                + shellQuoted(childPIDFile.path)
                + "\n"
                + shellQuoted(grandchildScript.path)
                + " &\nwhile :; do /bin/sleep 1; done"
        )
        try makeExecutableScript(
            at: rootScript,
            body:
                "trap '' TERM\n"
                + "printf '%s\\n' \"$$\" > "
                + shellQuoted(rootPIDFile.path)
                + "\n"
                + shellQuoted(childScript.path)
                + " &\nwhile [ ! -s "
                + shellQuoted(grandchildPIDFile.path)
                + " ]; do /bin/sleep 0.01; done\n"
                + "while :; do /bin/sleep 1; done"
        )

        let startedAt = Date()
        let result = await CodexVersionProbe.readVersion(
            rootScript,
            timeout: 1.5,
            terminationGrace: 0.05
        )

        XCTAssertNil(result)
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            3.5
        )
        let processIdentifiers = try [
            readPID(from: rootPIDFile),
            readPID(from: childPIDFile),
            readPID(from: grandchildPIDFile)
        ]
        for processIdentifier in processIdentifiers {
            await assertProcessExited(processIdentifier)
        }
    }

    func testCodexTransportSourcesContainNoRawProtocolLogging()
        throws
    {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            "Packages/UsageKit/Sources/CodexUsageProvider/Transport/JSONLTransport.swift",
            "Packages/UsageKit/Sources/CodexUsageProvider/Transport/CodexAppServerClient.swift",
            "Packages/UsageKit/Sources/CodexUsageProvider/Transport/BoundedProcess.swift"
        ]
        let forbidden = [
            "print(line",
            "debugPrint(line",
            "dump(frame",
            "log(rawResponse",
            "logRequest(url:",
            "os_log"
        ]

        for relativePath in files {
            let source = try String(
                contentsOf:
                    repositoryRoot.appendingPathComponent(
                        relativePath
                    ),
                encoding: .utf8
            )
            for pattern in forbidden {
                XCTAssertFalse(
                    source.contains(pattern),
                    "\(relativePath) contains \(pattern)"
                )
            }
        }
    }

    private func assertSafeNetworkLog(
        _ log: NetworkRequestLog,
        context: String
    ) {
        let output = [
            log.url,
            log.method,
            log.requestBody ?? "",
            log.responsePreview ?? "",
            log.errorMessage ?? ""
        ].joined(separator: "\n")
        assertNoSecrets(output, context: context)
        XCTAssertTrue(
            log.url.contains(
                SensitiveDataRedactor.redactedQuery
                    .addingPercentEncoding(
                        withAllowedCharacters: .urlQueryAllowed
                    ) ?? SensitiveDataRedactor.redactedQuery
            )
                || log.url.contains(
                    SensitiveDataRedactor.redactedQuery
                ),
            context
        )
        XCTAssertEqual(
            log.responsePreview,
            SensitiveDataRedactor.redactedRPC,
            context
        )
    }

    private func makeExecutableScript(
        at url: URL,
        body: String
    ) throws {
        try ("#!/bin/sh\n" + body + "\n").write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(chmod(url.path, 0o700), 0)
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(
            of: "'",
            with: "'\"'\"'"
        ) + "'"
    }

    private func readPID(from url: URL) throws -> Int32 {
        let value = try String(
            contentsOf: url,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(Int32(value))
    }

    private func assertProcessExited(
        _ processIdentifier: Int32,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            errno = 0
            if Darwin.kill(processIdentifier, 0) == -1,
               errno == ESRCH {
                return
            }
            try? await Task.sleep(
                nanoseconds: 10_000_000
            )
        } while Date() < deadline
        XCTFail(
            "Process \(processIdentifier) survived probe cleanup",
            file: file,
            line: line
        )
    }

    private func assertNoSecrets(
        _ output: String,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for secret in secretFixtures {
            XCTAssertFalse(
                output.contains(secret),
                "\(context) leaked \(secret)",
                file: file,
                line: line
            )
        }
        XCTAssertFalse(
            output.lowercased().contains("auth.json"),
            "\(context) must never name or expose auth.json",
            file: file,
            line: line
        )
    }
}
