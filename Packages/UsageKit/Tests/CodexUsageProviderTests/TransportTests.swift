import Foundation
import UsageCore
import XCTest
@testable import CodexUsageProvider

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

    func testConcurrentRequestsCorrelateOutOfOrderNumericAndStringIDs()
        async throws
    {
        let fake = try FakeCodexAppServer(
            scenario: "multi_inflight_out_of_order"
        )
        let session = try await fake.client.openSession()

        async let accountResult = session.request(
            .accountRead,
            params: .object([:])
        )
        async let usageResult = session.request(.accountUsageRead)
        let (account, usage) = try await (accountResult, usageResult)

        XCTAssertEqual(
            account,
            .object(["request": .string("account")])
        )
        XCTAssertEqual(
            usage,
            .object(["request": .string("usage")])
        )
        let accountNotification = try await session.nextNotification(
            matching: .accountUpdated
        )
        let rateLimitNotification = try await session.nextNotification(
            matching: .accountRateLimitsUpdated
        )
        XCTAssertEqual(accountNotification.method, .accountUpdated)
        XCTAssertEqual(
            rateLimitNotification.method,
            .accountRateLimitsUpdated
        )
        let requests = try fake.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(Set(requests.map(\.id)).count, 2)
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
            guard case let .unexpectedResponse(received) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
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
        let startup = try FakeCodexAppServer(
            scenario: "startup_timeout",
            limits: try CodexTransportLimits(
                startupTimeout: 0.5,
                requestTimeout: 1,
                overallTimeout: 5,
                terminationGracePeriod: 0.1
            )
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
        XCTAssertLessThan(Date().timeIntervalSince(startupBegan), 2)

        let request = try FakeCodexAppServer(
            scenario: "request_timeout",
            limits: try requestTimeoutLimits()
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
        XCTAssertLessThan(Date().timeIntervalSince(requestBegan), 2)
    }

    func testTaskCancellationTerminatesTheRequest() async throws {
        let fake = try FakeCodexAppServer(
            scenario: "cancellation",
            limits: try CodexTransportLimits(
                startupTimeout: 5,
                requestTimeout: 5,
                overallTimeout: 10
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
        XCTAssertLessThan(Date().timeIntervalSince(began), 2)
        try await fake.assertProcessExited(identifier)
    }

    func testCancellationBeforeRequestStartNeverLaunchesProcess()
        async throws
    {
        let fixture = try PrelaunchFixture()
        defer { fixture.cleanup() }
        let gate = PrelaunchGate()
        let task = Task {
            await gate.wait()
            return try await fixture.client.request(.accountRead)
        }
        await gate.waitUntilStarted()

        task.cancel()
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as CodexTransportError {
            XCTAssertEqual(
                error,
                .cancelled(method: .accountRead, id: nil)
            )
        }
        XCTAssertFalse(fixture.wasLaunched)
    }

    func testCancellationBeforeWithSessionStartNeverLaunchesProcess()
        async throws
    {
        let fixture = try PrelaunchFixture()
        defer { fixture.cleanup() }
        let gate = PrelaunchGate()
        let task = Task {
            await gate.wait()
            return try await fixture.client.withSession { _ in
                true
            }
        }
        await gate.waitUntilStarted()

        task.cancel()
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as CodexTransportError {
            XCTAssertEqual(
                error,
                .cancelled(method: nil, id: nil)
            )
        }
        XCTAssertFalse(fixture.wasLaunched)
    }

    func testCancellationBeforeProviderFetchNeverLaunchesProcess()
        async throws
    {
        let fixture = try PrelaunchFixture()
        defer { fixture.cleanup() }
        let provider = CodexUsageProvider(client: fixture.client)
        let gate = PrelaunchGate()
        let task = Task {
            await gate.wait()
            return try await provider.fetchUsage()
        }
        await gate.waitUntilStarted()

        task.cancel()
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertFalse(fixture.wasLaunched)
    }

    func testCancellationBeforeProviderLoginNeverLaunchesProcess()
        async throws
    {
        let fixture = try PrelaunchFixture()
        defer { fixture.cleanup() }
        let provider = CodexUsageProvider(client: fixture.client)
        let gate = PrelaunchGate()
        let task = Task {
            await gate.wait()
            return try await provider.startLogin(.deviceCode)
        }
        await gate.waitUntilStarted()

        task.cancel()
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertFalse(fixture.wasLaunched)
    }

    func testCancellationForceTerminatesAnUncooperativeProcess() async throws {
        for _ in 0..<3 {
            let fake = try FakeCodexAppServer(
                scenario: "ignore_termination",
                limits: try CodexTransportLimits(
                    startupTimeout: 5,
                    requestTimeout: 5,
                    overallTimeout: 10,
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
            XCTAssertLessThan(Date().timeIntervalSince(began), 2)
            try await fake.assertProcessExited(identifier)
        }
    }

    func testCancellationTerminatesChildAndGrandchildProcesses()
        async throws
    {
        let fake = try descendantTreeServer(requestTimeout: 5)
        let childFile = fake.directoryURL.appendingPathComponent(
            "child.pid"
        )
        let grandchildFile = fake.directoryURL.appendingPathComponent(
            "grandchild.pid"
        )
        let task = Task {
            try await fake.client.request(.accountUsageRead)
        }
        let root = try await fake.processIdentifier()
        let child = try await processIdentifier(at: childFile)
        let grandchild = try await processIdentifier(
            at: grandchildFile
        )

        task.cancel()
        await XCTAssertThrowsCodexError(try await task.value) { error in
            guard case .cancelled = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        try await fake.assertProcessExited(root)
        try await fake.assertProcessExited(child)
        try await fake.assertProcessExited(grandchild)
    }

    func testTimeoutTerminatesChildAndGrandchildProcesses()
        async throws
    {
        let fake = try descendantTreeServer(requestTimeout: 0.4)
        let childFile = fake.directoryURL.appendingPathComponent(
            "child.pid"
        )
        let grandchildFile = fake.directoryURL.appendingPathComponent(
            "grandchild.pid"
        )
        let task = Task {
            try await fake.client.request(.accountUsageRead)
        }
        let root = try await fake.processIdentifier()
        let child = try await processIdentifier(at: childFile)
        let grandchild = try await processIdentifier(
            at: grandchildFile
        )

        await XCTAssertThrowsCodexError(try await task.value) { error in
            guard case let .timedOut(stage, method, id) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(stage, .request)
            XCTAssertEqual(method, .accountUsageRead)
            XCTAssertEqual(id, 2)
        }

        try await fake.assertProcessExited(root)
        try await fake.assertProcessExited(child)
        try await fake.assertProcessExited(grandchild)
    }

    func testEscalationRecensusesRetainedChildAfterRootExit()
        async throws
    {
        let fake = try FakeCodexAppServer(
            scenario: "descendant_after_root_exit",
            limits: CodexTransportLimits(
                startupTimeout: 5,
                requestTimeout: 5,
                overallTimeout: 8,
                terminationGracePeriod: 0.2
            ),
            additionalEnvironment: [
                "CHILD_PID_FILE": "child.pid",
                "LATE_DESCENDANT_PID_FILE": "late-descendant.pid"
            ]
        )
        let childFile = fake.directoryURL.appendingPathComponent(
            "child.pid"
        )
        let lateDescendantFile = fake.directoryURL.appendingPathComponent(
            "late-descendant.pid"
        )
        let task = Task {
            try await fake.client.request(.accountUsageRead)
        }
        let root = try await fake.processIdentifier()
        let child = try await processIdentifier(at: childFile)

        task.cancel()
        await XCTAssertThrowsCodexError(try await task.value) { error in
            guard case .cancelled = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let lateDescendant = try await processIdentifier(
            at: lateDescendantFile
        )

        try await fake.assertProcessExited(root)
        try await fake.assertProcessExited(child)
        try await fake.assertProcessExited(lateDescendant)
    }

    func testOwnedProcessPolicyTreatsZombiesAndPIDReuseAsExited() {
        let expected = CodexOwnedProcessIdentity(
            identifier: 4_242,
            startSeconds: 100,
            startMicroseconds: 200
        )
        let liveMatch = CodexProcessObservation(
            identity: expected,
            parentIdentifier: 101,
            isZombie: false
        )
        XCTAssertTrue(
            CodexOwnedProcessPolicy.isLiveMatch(
                expected,
                observation: liveMatch
            )
        )

        let zombie = CodexProcessObservation(
            identity: expected,
            parentIdentifier: 101,
            isZombie: true
        )
        XCTAssertFalse(
            CodexOwnedProcessPolicy.isLiveMatch(
                expected,
                observation: zombie
            )
        )

        let reusedPID = CodexProcessObservation(
            identity: CodexOwnedProcessIdentity(
                identifier: expected.identifier,
                startSeconds: expected.startSeconds + 1,
                startMicroseconds: expected.startMicroseconds
            ),
            parentIdentifier: 101,
            isZombie: false
        )
        XCTAssertFalse(
            CodexOwnedProcessPolicy.isLiveMatch(
                expected,
                observation: reusedPID
            )
        )
        XCTAssertFalse(
            CodexOwnedProcessPolicy.isLiveMatch(
                expected,
                observation: nil
            )
        )
    }

    func testOwnedProcessPolicyRequiresLiveRootParent() {
        let root = CodexProcessObservation(
            identity: CodexOwnedProcessIdentity(
                identifier: 4_242,
                startSeconds: 100,
                startMicroseconds: 200
            ),
            parentIdentifier: 101,
            isZombie: false
        )
        XCTAssertTrue(
            CodexOwnedProcessPolicy.isLiveRootProcess(
                root,
                parentIdentifier: 101
            )
        )
        XCTAssertFalse(
            CodexOwnedProcessPolicy.isLiveRootProcess(
                root,
                parentIdentifier: 102
            )
        )
        XCTAssertFalse(
            CodexOwnedProcessPolicy.isLiveRootProcess(
                CodexProcessObservation(
                    identity: root.identity,
                    parentIdentifier: 101,
                    isZombie: true
                ),
                parentIdentifier: 101
            )
        )
        XCTAssertFalse(
            CodexOwnedProcessPolicy.isLiveRootProcess(
                nil,
                parentIdentifier: 101
            )
        )
    }

    func testOwnedProcessPolicyRequiresALiveDirectChild() {
        let parent = CodexOwnedProcessIdentity(
            identifier: 100,
            startSeconds: 10,
            startMicroseconds: 20
        )
        let child = CodexProcessObservation(
            identity: CodexOwnedProcessIdentity(
                identifier: 101,
                startSeconds: 11,
                startMicroseconds: 21
            ),
            parentIdentifier: parent.identifier,
            isZombie: false
        )
        XCTAssertTrue(
            CodexOwnedProcessPolicy.isLiveDirectChild(
                child,
                of: parent,
                parentObservation: CodexProcessObservation(
                    identity: parent,
                    parentIdentifier: 99,
                    isZombie: false
                )
            )
        )

        let unrelated = CodexProcessObservation(
            identity: child.identity,
            parentIdentifier: parent.identifier + 1,
            isZombie: false
        )
        XCTAssertFalse(
            CodexOwnedProcessPolicy.isLiveDirectChild(
                unrelated,
                of: parent,
                parentObservation: CodexProcessObservation(
                    identity: parent,
                    parentIdentifier: 99,
                    isZombie: false
                )
            )
        )

        let zombie = CodexProcessObservation(
            identity: child.identity,
            parentIdentifier: parent.identifier,
            isZombie: true
        )
        XCTAssertFalse(
            CodexOwnedProcessPolicy.isLiveDirectChild(
                zombie,
                of: parent,
                parentObservation: CodexProcessObservation(
                    identity: parent,
                    parentIdentifier: 99,
                    isZombie: false
                )
            )
        )

        let reusedParent = CodexProcessObservation(
            identity: CodexOwnedProcessIdentity(
                identifier: parent.identifier,
                startSeconds: parent.startSeconds + 1,
                startMicroseconds: parent.startMicroseconds
            ),
            parentIdentifier: 99,
            isZombie: false
        )
        XCTAssertFalse(
            CodexOwnedProcessPolicy.isLiveDirectChild(
                child,
                of: parent,
                parentObservation: reusedParent
            )
        )

        let zombieParent = CodexProcessObservation(
            identity: parent,
            parentIdentifier: 99,
            isZombie: true
        )
        XCTAssertFalse(
            CodexOwnedProcessPolicy.isLiveDirectChild(
                child,
                of: parent,
                parentObservation: zombieParent
            )
        )
    }

    func testOverallTimeoutCapsARequestScopedSession() async throws {
        let fake = try FakeCodexAppServer(
            scenario: "request_timeout",
            limits: try CodexTransportLimits(
                startupTimeout: 5,
                requestTimeout: 5,
                overallTimeout: 3,
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
                startupTimeout: 5,
                requestTimeout: 0.2,
                overallTimeout: 8,
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
        XCTAssertLessThan(Date().timeIntervalSince(began), 2)
        try await fake.assertProcessExited(identifier)
    }

    func testBlockedStdinCancellationAlwaysSurfacesCancellation()
        async throws
    {
        for _ in 0..<10 {
            let fake = try FakeCodexAppServer(
                scenario: "blocked_stdin",
                limits: try CodexTransportLimits(
                    maximumLineBytes: 256 * 1_024,
                    maximumStdoutBytes: 512 * 1_024,
                    maximumStderrBytes: 1_024,
                    startupTimeout: 5,
                    requestTimeout: 5,
                    overallTimeout: 8,
                    terminationGracePeriod: 0.05
                ),
                additionalEnvironment: [
                    "BLOCKED_STDIN_READY_FILE": "blocked-stdin-ready"
                ]
            )
            let readyFile = fake.directoryURL.appendingPathComponent(
                "blocked-stdin-ready"
            )
            let largeParams: CodexJSONValue = .object([
                "payload": .string(
                    String(repeating: "x", count: 220 * 1_024)
                )
            ])
            let task = Task {
                try await fake.client.request(
                    .accountLoginStart,
                    params: largeParams
                )
            }
            let identifier = try await fake.processIdentifier()
            try await waitForFile(at: readyFile)
            try await Task.sleep(nanoseconds: 50_000_000)

            task.cancel()
            await XCTAssertThrowsCodexError(
                try await task.value
            ) { error in
                XCTAssertEqual(
                    error,
                    .cancelled(
                        method: .accountLoginStart,
                        id: 2
                    )
                )
            }
            try await fake.assertProcessExited(identifier)
        }
    }

    func testCloseFailureStillReleasesHandlersAndIOResources()
        async throws
    {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodexCloseFailure-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        var retainedProcesses: [BoundedProcess] = []
        let warmup = try forcedCloseFailureProcess(
            in: directoryURL
        )
        try await assertForcedCloseReleasesHandlers(warmup)
        retainedProcesses.append(warmup)
        let baselineDescriptorCount = openFileDescriptorCount()

        for _ in 0..<12 {
            let process = try forcedCloseFailureProcess(
                in: directoryURL
            )
            try await assertForcedCloseReleasesHandlers(process)
            retainedProcesses.append(process)
        }

        let retainedDescriptorCount = withExtendedLifetime(
            retainedProcesses
        ) {
            openFileDescriptorCount()
        }
        XCTAssertLessThanOrEqual(
            retainedDescriptorCount,
            // XCTest and the concurrency runtime can briefly churn unrelated
            // process-wide descriptors. A five-descriptor allowance remains
            // far below the per-instance leak this regression detects.
            baselineDescriptorCount + 5,
            """
            Forced-close cleanup leaked file descriptors: baseline \
            \(baselineDescriptorCount), retained \(retainedDescriptorCount)
            """
        )
    }

    func testExplicitCloseDiscardsQueuedNotificationsBeforeTeardown()
        async throws
    {
        let fake = try FakeCodexAppServer(
            scenario: "queued_notification_wait_for_close",
            limits: try CodexTransportLimits(
                startupTimeout: 5,
                requestTimeout: 5,
                overallTimeout: 8,
                terminationGracePeriod: 0.05
            )
        )
        let session = try await fake.client.openSession()
        let identifier = try await fake.processIdentifier()
        let result = try await session.request(.accountRead)
        XCTAssertEqual(result, .object(["ok": .bool(true)]))
        let pendingRequestID = try await session.sendRequestForTesting(
            .accountUsageRead
        )

        await session.enableProcessClosePauseForTesting()
        let closeTask = Task {
            try await session.close()
        }
        await session.waitForProcessClosePausedForTesting()

        await XCTAssertThrowsCodexError(
            try await session.nextNotification(
                matching: .accountUpdated
            )
        ) { error in
            XCTAssertEqual(
                error,
                .writeFailed(method: .accountUpdated)
            )
        }
        await XCTAssertThrowsCodexError(
            try await session.responseForTesting(
                id: pendingRequestID,
                method: .accountUsageRead
            )
        ) { error in
            XCTAssertEqual(
                error,
                .cancelled(
                    method: .accountUsageRead,
                    id: pendingRequestID
                )
            )
        }

        await session.releaseProcessClosePauseForTesting()
        try await closeTask.value
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

    func testRoutedFramesDrainAfterTerminalInput() async throws {
        let fake = try FakeCodexAppServer(
            scenario: "exit_after_buffered_frames"
        )
        let session = try await fake.client.openSession()
        let requestID = try await session.sendRequestForTesting(
            .accountRead
        )

        let terminal = await session.waitForTerminalForTesting()
        XCTAssertEqual(terminal, .processExited(status: 0))

        let response = try await session.responseForTesting(
            id: requestID,
            method: .accountRead
        )
        XCTAssertEqual(
            response,
            .object(["buffered": .bool(true)])
        )
        await XCTAssertThrowsCodexError(
            try await session.request(.accountUsageRead)
        ) { error in
            XCTAssertEqual(error, .processExited(status: 0))
        }

        let rateLimits = try await session.nextNotification(
            matching: .accountRateLimitsUpdated
        )
        XCTAssertEqual(
            rateLimits.params,
            .object(["sequence": .integer(2)])
        )
        let account = try await session.nextNotification()
        XCTAssertEqual(account.method, .accountUpdated)
        XCTAssertEqual(
            account.params,
            .object(["sequence": .integer(1)])
        )

        await XCTAssertThrowsCodexError(
            try await session.nextNotification(
                matching: .accountLoginCompleted
            )
        ) { error in
            XCTAssertEqual(error, .processExited(status: 0))
        }
        try await session.close()
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

    func testCodexHomeRepointedAfterConfigurationFailsBeforeLaunch()
        async throws
    {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "CodexLaunchBoundary-\(UUID().uuidString)",
            isDirectory: true
        )
        let configuredHome = root.appendingPathComponent(
            "configured",
            isDirectory: true
        )
        let replacementHome = root.appendingPathComponent(
            "replacement",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: configuredHome,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: replacementHome,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: root) }
        let configuration = try CodexProcessConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            codexHomeURL: configuredHome
        )
        let client = CodexAppServerClient(
            processConfiguration: configuration
        )

        try fileManager.removeItem(at: configuredHome)
        try fileManager.createSymbolicLink(
            at: configuredHome,
            withDestinationURL: replacementHome
        )

        await XCTAssertThrowsCodexError(
            try await client.request(.accountRead)
        ) { error in
            XCTAssertEqual(
                error,
                .invalidConfiguration(.codexHome)
            )
        }
    }

    func testCodexHomeReplacedAtSamePathAfterConfigurationFailsBeforeLaunch()
        async throws
    {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "CodexLaunchIdentity-\(UUID().uuidString)",
            isDirectory: true
        )
        let configuredHome = root.appendingPathComponent(
            "configured",
            isDirectory: true
        )
        let retainedOriginal = root.appendingPathComponent(
            "retained-original",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: configuredHome,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: root) }
        let configuration = try CodexProcessConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            codexHomeURL: configuredHome
        )
        let client = CodexAppServerClient(
            processConfiguration: configuration
        )

        try fileManager.moveItem(
            at: configuredHome,
            to: retainedOriginal
        )
        try fileManager.createDirectory(
            at: configuredHome,
            withIntermediateDirectories: false
        )

        await XCTAssertThrowsCodexError(
            try await client.request(.accountRead)
        ) { error in
            XCTAssertEqual(
                error,
                .invalidConfiguration(.codexHome)
            )
        }
    }

    func testExpectedCodexHomeIdentityRejectsReplacementAtConstruction()
        throws
    {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "CodexExpectedIdentity-\(UUID().uuidString)",
            isDirectory: true
        )
        let configuredHome = root.appendingPathComponent(
            "configured",
            isDirectory: true
        )
        let retainedOriginal = root.appendingPathComponent(
            "retained-original",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: configuredHome,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let attributes = try fileManager.attributesOfItem(
            atPath: configuredHome.path
        )
        let device = try XCTUnwrap(
            attributes[.systemNumber] as? NSNumber
        )
        let file = try XCTUnwrap(
            attributes[.systemFileNumber] as? NSNumber
        )
        let expectedIdentity = CodexHomeIdentity(
            deviceID: device.uint64Value,
            fileID: file.uint64Value
        )

        try fileManager.moveItem(
            at: configuredHome,
            to: retainedOriginal
        )
        try fileManager.createDirectory(
            at: configuredHome,
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(
            try CodexProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                codexHomeURL: configuredHome,
                expectedCodexHomeIdentity: expectedIdentity
            )
        ) { error in
            XCTAssertEqual(
                error as? CodexTransportError,
                .invalidConfiguration(.codexHome)
            )
        }

        try fileManager.removeItem(at: configuredHome)
        try fileManager.moveItem(
            at: retainedOriginal,
            to: configuredHome
        )
        XCTAssertNoThrow(
            try CodexProcessConfiguration(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                codexHomeURL: configuredHome,
                expectedCodexHomeIdentity: expectedIdentity
            )
        )
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

    func testFixtureProvenanceAndSensitiveDataPolicy() throws {
        let provenanceURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "schema-provenance",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        let provenance = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: provenanceURL)
            ) as? [String: Any]
        )
        XCTAssertEqual(
            provenance["source"] as? String,
            "Official locally installed Codex CLI generated JSON schemas"
        )
        XCTAssertEqual(
            provenance["generatorVersion"] as? String,
            "codex-cli 0.145.0"
        )
        XCTAssertEqual(provenance["syntheticDataOnly"] as? Bool, true)
        XCTAssertEqual(
            Set(provenance["fixtureProtocolMethods"] as? [String] ?? []),
            Set([
                "initialize",
                "initialized",
                "account/read",
                "account/updated",
                "account/rateLimits/read",
                "account/rateLimits/updated",
                "account/usage/read",
                "account/login/start",
                "account/login/completed",
                "account/login/cancel"
            ])
        )

        let fixtureDirectory = provenanceURL.deletingLastPathComponent()
        let fixtureURLs = try XCTUnwrap(
            FileManager.default.enumerator(
                at: fixtureDirectory,
                includingPropertiesForKeys: [.isRegularFileKey]
            )?.allObjects as? [URL]
        ).filter {
            ["json", "jsonl", "sh"].contains($0.pathExtension)
        }
        XCTAssertFalse(fixtureURLs.isEmpty)

        let forbiddenLiteralFragments = [
            "auth.json",
            "\"access_token\"",
            "\"refresh_token\"",
            "\"id_token\"",
            "/users/",
            "/home/",
            "c:\\users\\"
        ]
        let forbiddenPatterns = [
            #"\bsk-[A-Za-z0-9_-]{12,}\b"#,
            #"\b(?:acct|org|user)_[A-Za-z0-9]{8,}\b"#,
            #"\beyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{8,}"#
        ]
        let emailPattern = try NSRegularExpression(
            pattern:
                #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            options: [.caseInsensitive]
        )

        for url in fixtureURLs {
            let contents = try String(
                contentsOf: url,
                encoding: .utf8
            )
            let lowercased = contents.lowercased()
            for fragment in forbiddenLiteralFragments {
                XCTAssertFalse(
                    lowercased.contains(fragment),
                    "\(url.lastPathComponent) contains \(fragment)"
                )
            }
            for pattern in forbiddenPatterns {
                XCTAssertNil(
                    contents.range(
                        of: pattern,
                        options: .regularExpression
                    ),
                    "\(url.lastPathComponent) contains sensitive-shaped data"
                )
            }
            let range = NSRange(
                contents.startIndex..<contents.endIndex,
                in: contents
            )
            for match in emailPattern.matches(
                in: contents,
                range: range
            ) {
                let email = (contents as NSString).substring(
                    with: match.range
                )
                XCTAssertTrue(
                    email.lowercased().hasSuffix("@example.com"),
                    "\(url.lastPathComponent) contains a non-example account identifier"
                )
            }
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

    private func forcedCloseFailureProcess(
        in directoryURL: URL
    ) throws -> BoundedProcess {
        let configuration = try CodexProcessConfiguration(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            codexHomeURL: directoryURL,
            workingDirectoryURL: directoryURL
        )
        return BoundedProcess(
            configuration: configuration,
            limits: try CodexTransportLimits(
                terminationGracePeriod: 0.05
            ),
            terminationOutcomeValidator: { _, _ in false }
        )
    }

    private func assertForcedCloseReleasesHandlers(
        _ process: BoundedProcess
    ) async throws {
        try process.start()
        XCTAssertTrue(process.hasReadabilityHandlersForTesting())
        XCTAssertTrue(process.hasTerminationHandlerForTesting())

        do {
            try await process.close()
            XCTFail("Expected termination timeout")
        } catch let error as CodexTransportError {
            XCTAssertEqual(
                error,
                .timedOut(
                    stage: .termination,
                    method: nil,
                    id: nil
                )
            )
        }

        XCTAssertFalse(process.hasReadabilityHandlersForTesting())
        XCTAssertFalse(process.hasTerminationHandlerForTesting())
    }

    private func openFileDescriptorCount() -> Int {
        var count = 0
        for descriptor in 0..<getdtablesize() {
            errno = 0
            if fcntl(descriptor, F_GETFD) != -1 || errno != EBADF {
                count += 1
            }
        }
        return count
    }

    private func requestTimeoutLimits() throws -> CodexTransportLimits {
        try CodexTransportLimits(
            startupTimeout: 5,
            requestTimeout: 0.2,
            overallTimeout: 8,
            terminationGracePeriod: 0.1
        )
    }

    private func compactLimits() throws -> CodexTransportLimits {
        try CodexTransportLimits(
            maximumLineBytes: 128,
            maximumStdoutBytes: 512,
            maximumStderrBytes: 128,
            startupTimeout: 5,
            requestTimeout: 1,
            overallTimeout: 8,
            terminationGracePeriod: 0.1
        )
    }

    private func descendantTreeServer(
        requestTimeout: TimeInterval
    ) throws -> FakeCodexAppServer {
        return try FakeCodexAppServer(
            scenario: "descendant_tree",
            limits: CodexTransportLimits(
                startupTimeout: 5,
                requestTimeout: requestTimeout,
                overallTimeout: 8,
                terminationGracePeriod: 0.05
            ),
            additionalEnvironment: [
                "CHILD_PID_FILE": "child.pid",
                "GRANDCHILD_PID_FILE": "grandchild.pid"
            ]
        )
    }

    private func processIdentifier(
        at url: URL,
        timeout: TimeInterval = 5
    ) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let value = String(data: data, encoding: .utf8)?
                   .trimmingCharacters(
                       in: .whitespacesAndNewlines
                   ),
               let identifier = Int32(value),
               identifier > 0
            {
                return identifier
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw FixtureProcessError.identifierObservationTimedOut
    }

    private func waitForFile(
        at url: URL,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw FixtureProcessError.fileObservationTimedOut
    }

    private enum FixtureProcessError: Error {
        case identifierObservationTimedOut
        case fileObservationTimedOut
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

private actor PrelaunchGate {
    private var started = false
    private var releaseContinuation:
        CheckedContinuation<Void, Never>?
    private var startContinuations:
        [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started = true
        let startContinuations = self.startContinuations
        self.startContinuations.removeAll()
        for continuation in startContinuations {
            continuation.resume()
        }
        await withCheckedContinuation {
            releaseContinuation = $0
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation {
            startContinuations.append($0)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class PrelaunchFixture {
    let client: CodexAppServerClient
    private let root: URL
    private let marker: URL

    var wasLaunched: Bool {
        FileManager.default.fileExists(atPath: marker.path)
    }

    init() throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory.appendingPathComponent(
            "CodexPrecancelledLaunch-\(UUID().uuidString)",
            isDirectory: true
        )
        let codexHome = root.appendingPathComponent(
            "home",
            isDirectory: true
        )
        let executable = root.appendingPathComponent("fake-codex")
        marker = root.appendingPathComponent("launched")
        try fileManager.createDirectory(
            at: codexHome,
            withIntermediateDirectories: true
        )
        try Data(
            """
            #!/bin/sh
            /usr/bin/touch "$MARKER_PATH"
            exit 1
            """.utf8
        ).write(to: executable)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        client = CodexAppServerClient(
            processConfiguration: try CodexProcessConfiguration(
                executableURL: executable,
                environment: ["MARKER_PATH": marker.path],
                codexHomeURL: codexHome
            )
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
