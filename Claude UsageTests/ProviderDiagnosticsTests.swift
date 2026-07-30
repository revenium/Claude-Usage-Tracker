import CodexUsageProvider
import Darwin
import Foundation
import UsageCore
import XCTest
@testable import Claude_Usage

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

    private let bearer = "sk-ant-p14BearerSecret123456"
    private let session = "sess-p14SessionSecret123456"
    private let cookie = "p14CookieSecret123456"
    private let query = "p14QuerySecret123456"
    private let credential = "p14CredentialSecret123456"
    private let home = "/Users/p14-sensitive/.codex/accounts/work"
    private let rpcSecret = "p14RPCSecret123456"

    private var secretFixtures: [String] {
        [
            bearer,
            session,
            cookie,
            query,
            credential,
            home,
            rpcSecret,
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
                    [.chooseHome, .openSettings, .unlink],
                    true
                ),
                (
                    ProfileProviderConfigurationError
                        .duplicateCodexHome(duplicateID),
                    .duplicateHome,
                    [.chooseHome, .openSettings],
                    true
                ),
                (
                    UsageProviderError.unauthenticated,
                    .loggedOut,
                    [.signIn, .openSettings],
                    true
                ),
                (
                    UsageProviderError.unsupportedAccount,
                    .unsupportedAccount,
                    [.openSettings, .unlink],
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
            [.signIn, .openSettings]
        )

        let claudeError = MenuBarManager.appError(
            for: failure,
            providerID: .claude
        )
        XCTAssertNil(claudeError.providerCategory)
        XCTAssertEqual(claudeError.code, .apiUnauthorized)
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

    func testVersionProbeBoundsOutputScrubsEnvironmentAndReapsTimeout()
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

        let pidFile = root.appendingPathComponent("stubborn.pid")
        let stubbornScript =
            root.appendingPathComponent("stubborn-version")
        try makeExecutableScript(
            at: stubbornScript,
            body:
                "trap '' TERM\n"
                + "printf '%s\\n' \"$$\" > "
                + shellQuoted(pidFile.path)
                + "\nwhile :; do :; done"
        )
        let stubborn = await CodexVersionProbe.readVersion(
            stubbornScript,
            timeout: 0.2,
            terminationGrace: 0.05
        )
        XCTAssertNil(stubborn)
        let pidText = try String(
            contentsOf: pidFile,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidText))
        errno = 0
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
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
