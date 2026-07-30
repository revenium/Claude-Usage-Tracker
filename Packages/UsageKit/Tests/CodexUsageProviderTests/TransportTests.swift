import CodexUsageProvider
import Foundation
import XCTest

final class TransportTests: XCTestCase {
    func testHandshakeCompletesBeforeAccountRequest() async throws {
        let fake = try FakeCodexAppServer(scenario: "happy")

        let result = try await fake.client.request(
            .accountRead,
            params: .object(["refreshToken": .bool(false)])
        )
        let identifier = try await fake.processIdentifier()

        XCTAssertEqual(result, .object(["ok": .bool(true)]))
        try await fake.assertProcessExited(identifier)
    }

    func testFragmentedInitializeAndResponseFramesAreReassembled() async throws {
        for _ in 0..<5 {
            let fragmentedInitialize = try FakeCodexAppServer(
                scenario: "fragmented_initialize"
            )
            let initializeResult = try await fragmentedInitialize.client.request(
                .accountRateLimitsRead
            )
            XCTAssertEqual(
                initializeResult,
                .object(["ok": .bool(true)])
            )

            let fragmentedResponse = try FakeCodexAppServer(
                scenario: "fragmented_response"
            )
            let responseResult = try await fragmentedResponse.client.request(
                .accountUsageRead
            )
            XCTAssertEqual(
                responseResult,
                .object(["ok": .bool(true)])
            )
        }
    }

    func testInterleavedNotificationsAreRetained() async throws {
        let fake = try FakeCodexAppServer(scenario: "interleaved_notifications")
        let session = try await fake.client.openSession()
        let identifier = try await fake.processIdentifier()

        let requestResult = try await session.request(.accountRateLimitsRead)
        XCTAssertEqual(
            requestResult,
            .object(["ok": .bool(true)])
        )
        let rateLimitNotification = try await session.nextNotification(
            matching: .accountRateLimitsUpdated
        )
        XCTAssertEqual(rateLimitNotification.method, .accountRateLimitsUpdated)
        let accountNotification = try await session.nextNotification(
            matching: .accountUpdated
        )
        XCTAssertEqual(accountNotification.method, .accountUpdated)
        try await session.close()
        try await fake.assertProcessExited(identifier)
    }

    func testMultipleRequestsUseStrictlyIncreasingUniqueIDs() async throws {
        let fake = try FakeCodexAppServer(scenario: "two_requests")
        let session = try await fake.client.openSession()

        let firstResult = try await session.request(
            .accountRead,
            params: .object([:])
        )
        XCTAssertEqual(
            firstResult,
            .object(["sequence": .integer(1)])
        )
        let secondResult = try await session.request(.accountUsageRead)
        XCTAssertEqual(
            secondResult,
            .object(["sequence": .integer(2)])
        )
        try await session.close()
    }

    func testDuplicateResponseCannotSatisfyANewerRequest() async throws {
        let fake = try FakeCodexAppServer(scenario: "duplicate_response")
        let session = try await fake.client.openSession()
        let firstResult = try await session.request(
            .accountRead,
            params: .object([:])
        )
        XCTAssertEqual(
            firstResult,
            .object(["sequence": .integer(1)])
        )

        await XCTAssertThrowsCodexError(
            try await session.request(.accountUsageRead)
        ) { error in
            guard case let .requestIDMismatch(expected, received) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(expected, 3)
            XCTAssertEqual(received, .integer)
        }
    }

    func testIntegerAndStringIDMismatchesAreRejectedAndRedacted() async throws {
        let integerFake = try FakeCodexAppServer(scenario: "mismatched_integer_id")
        await XCTAssertThrowsCodexError(
            try await integerFake.client.request(.accountUsageRead)
        ) { error in
            guard case let .requestIDMismatch(expected, received) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(expected, 2)
            XCTAssertEqual(received, .integer)
        }

        let stringFake = try FakeCodexAppServer(scenario: "mismatched_string_id")
        await XCTAssertThrowsCodexError(
            try await stringFake.client.request(.accountUsageRead)
        ) { error in
            XCTAssertFalse(error.description.contains("super-secret"))
            guard case let .requestIDMismatch(_, received) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(received, .string)
        }
    }

    func testMalformedAndOversizedFramesFailDeterministically() async throws {
        let malformed = try FakeCodexAppServer(scenario: "malformed")
        await XCTAssertThrowsCodexError(
            try await malformed.client.request(.accountRateLimitsRead)
        ) { error in
            XCTAssertEqual(error, .malformedFrame)
        }

        let limits = try compactLimits()
        let oversized = try FakeCodexAppServer(
            scenario: "oversized_line",
            limits: limits
        )
        await XCTAssertThrowsCodexError(
            try await oversized.client.request(.accountRateLimitsRead)
        ) { error in
            XCTAssertEqual(error, .lineLimitExceeded)
        }
    }

    func testStdoutAndStderrHaveIndependentBounds() async throws {
        let limits = try compactLimits()
        let stdout = try FakeCodexAppServer(
            scenario: "stdout_overflow",
            limits: limits
        )
        await XCTAssertThrowsCodexError(
            try await stdout.client.request(.accountRateLimitsRead)
        ) { error in
            XCTAssertEqual(error, .outputLimitExceeded(.stdout))
        }

        let stderr = try FakeCodexAppServer(
            scenario: "stderr_overflow",
            limits: limits
        )
        await XCTAssertThrowsCodexError(
            try await stderr.client.request(.accountRateLimitsRead)
        ) { error in
            XCTAssertEqual(error, .outputLimitExceeded(.stderr))
        }
    }

    func testStartupAndRequestTimeoutsAreBounded() async throws {
        let limits = try fastLimits()
        let startup = try FakeCodexAppServer(
            scenario: "startup_timeout",
            limits: limits
        )
        let startupBegan = Date()
        await XCTAssertThrowsCodexError(
            try await startup.client.request(.accountRead)
        ) { error in
            guard case let .timedOut(stage, method, id) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(stage, .startup)
            XCTAssertEqual(method, .initialize)
            XCTAssertEqual(id, 1)
        }
        XCTAssertLessThan(Date().timeIntervalSince(startupBegan), 1)

        let request = try FakeCodexAppServer(
            scenario: "request_timeout",
            limits: limits
        )
        let requestBegan = Date()
        await XCTAssertThrowsCodexError(
            try await request.client.request(.accountUsageRead)
        ) { error in
            guard case let .timedOut(stage, method, id) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(stage, .request)
            XCTAssertEqual(method, .accountUsageRead)
            XCTAssertEqual(id, 2)
        }
        XCTAssertLessThan(Date().timeIntervalSince(requestBegan), 1)
    }

    func testTaskCancellationTerminatesTheRequest() async throws {
        let fake = try FakeCodexAppServer(
            scenario: "cancellation",
            limits: try CodexTransportLimits(
                startupTimeout: 1,
                requestTimeout: 5,
                overallTimeout: 5
            )
        )
        let task = Task {
            try await fake.client.request(.accountUsageRead)
        }
        let identifier = try await fake.processIdentifier()
        try await Task.sleep(nanoseconds: 250_000_000)
        let began = Date()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as CodexTransportError {
            guard case let .cancelled(method, id) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(method, .accountUsageRead)
            XCTAssertTrue(id == nil || id == 2)
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 1)
        try await fake.assertProcessExited(identifier)
    }

    func testCancellationForceTerminatesAnUncooperativeProcess() async throws {
        for _ in 0..<3 {
            let fake = try FakeCodexAppServer(
                scenario: "ignore_termination",
                limits: try CodexTransportLimits(
                    startupTimeout: 1,
                    requestTimeout: 5,
                    overallTimeout: 5,
                    terminationGracePeriod: 0.05
                )
            )
            let task = Task {
                try await fake.client.request(.accountUsageRead)
            }
            let identifier = try await fake.processIdentifier()
            try await Task.sleep(nanoseconds: 250_000_000)
            let began = Date()
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("Expected cancellation")
            } catch let error as CodexTransportError {
                guard case .cancelled = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertLessThan(Date().timeIntervalSince(began), 1)
            try await fake.assertProcessExited(identifier)
        }
    }

    func testOverallTimeoutCapsARequestScopedSession() async throws {
        let fake = try FakeCodexAppServer(
            scenario: "request_timeout",
            limits: try CodexTransportLimits(
                startupTimeout: 1,
                requestTimeout: 2,
                overallTimeout: 0.35,
                terminationGracePeriod: 0.05
            )
        )
        await XCTAssertThrowsCodexError(
            try await fake.client.request(.accountUsageRead)
        ) { error in
            guard case let .timedOut(stage, method, id) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(stage, .overall)
            XCTAssertEqual(method, .accountUsageRead)
            XCTAssertEqual(id, 2)
        }
    }

    func testBlockedStdinWriteIsCoveredByTheRequestTimeout() async throws {
        let fake = try FakeCodexAppServer(
            scenario: "blocked_stdin",
            limits: try CodexTransportLimits(
                maximumLineBytes: 256 * 1_024,
                maximumStdoutBytes: 512 * 1_024,
                maximumStderrBytes: 1_024,
                startupTimeout: 1,
                requestTimeout: 0.1,
                overallTimeout: 2,
                terminationGracePeriod: 0.05
            )
        )
        let largeParams: CodexJSONValue = .object([
            "payload": .string(String(repeating: "x", count: 220 * 1_024))
        ])
        let began = Date()
        let task = Task {
            try await fake.client.request(
                .accountLoginStart,
                params: largeParams
            )
        }
        let identifier = try await fake.processIdentifier()
        await XCTAssertThrowsCodexError(
            try await task.value
        ) { error in
            guard case let .timedOut(stage, method, id) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(stage, .request)
            XCTAssertEqual(method, .accountLoginStart)
            XCTAssertEqual(id, 2)
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 1)
        try await fake.assertProcessExited(identifier)
    }

    func testEarlyExitIsReportedWithoutProcessOutput() async throws {
        let startup = try FakeCodexAppServer(scenario: "early_exit_startup")
        await XCTAssertThrowsCodexError(
            try await startup.client.request(.accountRead)
        ) { error in
            guard case let .processExited(status) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(status, 16)
        }

        let request = try FakeCodexAppServer(scenario: "early_exit_request")
        await XCTAssertThrowsCodexError(
            try await request.client.request(.accountRead)
        ) { error in
            guard case let .processExited(status) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(status, 17)
        }
    }

    func testStdoutEOFIsDistinctFromProcessExit() async throws {
        let fake = try FakeCodexAppServer(scenario: "stdout_eof")
        await XCTAssertThrowsCodexError(
            try await fake.client.request(.accountRead)
        ) { error in
            XCTAssertEqual(error, .unexpectedEOF)
        }
    }

    func testOnlyExplicitEnvironmentAndCanonicalCodexHomeAreInjected() async throws {
        let fileManager = FileManager.default
        let symlinkRoot = fileManager.temporaryDirectory
            .appendingPathComponent("CodexHomeCanonical-\(UUID().uuidString)")
        let realHome = symlinkRoot.appendingPathComponent("real")
        let linkedHome = symlinkRoot.appendingPathComponent("linked")
        try fileManager.createDirectory(
            at: realHome,
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(
            at: linkedHome,
            withDestinationURL: realHome
        )
        defer { try? fileManager.removeItem(at: symlinkRoot) }

        let configured = try FakeCodexAppServer(
            scenario: "environment",
            additionalEnvironment: [
                "SAFE_FLAG": "allowed"
            ],
            codexHomeURL: linkedHome
        )
        let result = try await configured.client.request(.accountRead)
        guard case let .object(values) = result else {
            return XCTFail("Expected object result")
        }
        XCTAssertEqual(values["codexHomeMatches"], .bool(true))
        XCTAssertEqual(values["safeFlagMatches"], .bool(true))
        XCTAssertEqual(values["parentHomeAbsent"], .bool(true))
    }

    func testCallerCannotOverrideCodexHomeAndErrorsDoNotRevealValues() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexConfig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let sensitiveValue = "/private/super-secret-codex-home"

        XCTAssertThrowsError(
            try CodexProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                environment: ["CODEX_HOME": sensitiveValue],
                codexHomeURL: directoryURL
            )
        ) { error in
            guard let transportError = error as? CodexTransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(
                transportError,
                .invalidConfiguration(.environment)
            )
            XCTAssertFalse(transportError.description.contains(sensitiveValue))
        }
    }

    func testRPCAndStderrBodiesAreNeverExposedByErrors() async throws {
        let rpc = try FakeCodexAppServer(scenario: "rpc_error")
        await XCTAssertThrowsCodexError(
            try await rpc.client.request(.accountRead)
        ) { error in
            guard case let .rpcFailure(code, method, id) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(code, 401)
            XCTAssertEqual(method, .accountRead)
            XCTAssertEqual(id, 2)
            XCTAssertFalse(error.description.contains("super-secret"))
            XCTAssertFalse(error.description.localizedCaseInsensitiveContains("token"))
        }

        let stderr = try FakeCodexAppServer(scenario: "stderr_redaction")
        await XCTAssertThrowsCodexError(
            try await stderr.client.request(.accountRead)
        ) { error in
            XCTAssertFalse(error.description.contains("super-secret"))
        }
    }

    func testProtocolFramesRejectInvalidShapesAndRequestIDs() throws {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                CodexInboundFrame.self,
                from: Data(#"{"id":1,"result":{},"error":{"code":1}}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                CodexInboundFrame.self,
                from: Data(#"{"id":1,"error":{"code":1}}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                CodexInboundFrame.self,
                from: Data(#"{"id":1,"method":"account/read","result":{}}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                CodexInboundFrame.self,
                from: Data(#"{"id":" bad ","result":{}}"#.utf8)
            )
        )
        XCTAssertNil(CodexMethod(rawValue: "account/read\nsecret"))
        XCTAssertNil(CodexMethod(rawValue: "account/读取"))
        let unknownMethod = CodexMethod(rawValue: "supersecrettoken")!
        XCTAssertFalse(
            CodexTransportError.unsupportedServerRequest(method: unknownMethod)
                .description
                .contains("supersecret")
        )
    }

    private func fastLimits() throws -> CodexTransportLimits {
        try CodexTransportLimits(
            startupTimeout: 0.5,
            requestTimeout: 0.1,
            overallTimeout: 1.5,
            terminationGracePeriod: 0.1
        )
    }

    private func compactLimits() throws -> CodexTransportLimits {
        try CodexTransportLimits(
            maximumLineBytes: 128,
            maximumStdoutBytes: 512,
            maximumStderrBytes: 128,
            startupTimeout: 1,
            requestTimeout: 1,
            overallTimeout: 2,
            terminationGracePeriod: 0.1
        )
    }
}

private func XCTAssertThrowsCodexError<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    verify: (CodexTransportError) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected CodexTransportError", file: file, line: line)
    } catch let error as CodexTransportError {
        verify(error)
    } catch {
        XCTFail("Unexpected error type: \(error)", file: file, line: line)
    }
}
