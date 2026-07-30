import Darwin
import Foundation
import UsageCore
import XCTest
@testable import CodexUsageProvider

final class CodexUsageProviderTests: XCTestCase {
    func testCurrentContractMapsDynamicLimitsCreditsAndUsageSummary()
        async throws
    {
        let fake = try FakeCodexAppServer(scenario: "provider_current")
        let provider = CodexUsageProvider(client: fake.client)

        let report = try await provider.fetchUsage()

        XCTAssertEqual(report.providerID, .codex)
        XCTAssertEqual(report.health.status, .healthy)
        XCTAssertEqual(report.account?.displayName, "person@example.com")
        XCTAssertEqual(report.account?.planName, "pro")
        XCTAssertEqual(report.limitGroups.count, 2)

        let codex = try XCTUnwrap(
            report.limitGroups.first { $0.displayName == "Codex" }
        )
        XCTAssertEqual(codex.id.rawValue, "codex.limit.codex")
        XCTAssertEqual(codex.windows.count, 2)
        XCTAssertEqual(codex.windows[0].usedPercentage, 25)
        XCTAssertEqual(codex.windows[0].duration, 18_000)
        XCTAssertEqual(
            codex.windows[0].resetsAt,
            Date(timeIntervalSince1970: 1_785_380_400)
        )
        XCTAssertEqual(
            codex.windows[0].startedAt,
            Date(timeIntervalSince1970: 1_785_362_400)
        )
        XCTAssertEqual(codex.windows[1].usedPercentage, 40)

        let ordinaryCredits = try XCTUnwrap(
            report.credits.first {
                $0.id.rawValue == "codex.limit.codex.credits"
            }
        )
        XCTAssertEqual(ordinaryCredits.balance, 75.5)
        XCTAssertEqual(ordinaryCredits.unit, .count)
        let resetCredits = try XCTUnwrap(
            report.credits.first {
                $0.id.rawValue == "codex.rate-limit-reset-credits"
            }
        )
        XCTAssertEqual(resetCredits.balance, 2)
        XCTAssertEqual(
            resetCredits.resetsAt,
            Date(timeIntervalSince1970: 1_786_000_000)
        )

        let summary = try XCTUnwrap(report.usageSummary)
        XCTAssertEqual(
            metric("codex.lifetime-tokens", in: summary)?.value,
            1_234_567
        )
        XCTAssertEqual(
            metric("codex.reported-daily-bucket-tokens", in: summary)?.value,
            35_801
        )
        XCTAssertEqual(
            metric("codex.reported-daily-buckets", in: summary)?.value,
            2
        )
        XCTAssertEqual(
            metric("codex.longest-running-turn-seconds", in: summary)?
                .unit.rawValue,
            "seconds"
        )
        XCTAssertNotNil(summary.periodStartedAt)
        XCTAssertNotNil(summary.periodEndsAt)

        XCTAssertEqual(provider.capabilities[.account], .available)
        XCTAssertEqual(provider.capabilities[.usageSummary], .unknown)
        XCTAssertEqual(provider.capabilities[.resetCredits], .available)
        XCTAssertEqual(
            provider.capabilities,
            CodexUsageProvider.supportedCapabilities
        )
        XCTAssertEqual(
            provider.capabilities[.statusLineIntegration],
            .unavailable
        )

        let requests = try fake.recordedRequests()
        XCTAssertEqual(
            requests.map(\.method),
            [.accountRead, .accountRateLimitsRead, .accountUsageRead]
        )
        XCTAssertEqual(
            requests[0].params,
            .object(["refreshToken": .bool(false)])
        )
        XCTAssertNil(requests[1].params)
        XCTAssertNil(requests[2].params)
        XCTAssertFalse(requests.map(\.method).contains(.accountLogout))
        XCTAssertEqual(
            requests.map(\.id),
            [.integer(2), .integer(3), .integer(4)]
        )
        let initializations = try fake.recordedInitializations()
        XCTAssertEqual(initializations.map(\.method), [.initialize])
        XCTAssertEqual(initializations.map(\.id), [.integer(1)])
        XCTAssertEqual(try fake.launchedProcessIdentifiers().count, 1)
        try await fake.assertAllProcessesExited()
    }

    func testAccountReadAlwaysSendsRequiredRefreshTokenParameter()
        async throws
    {
        let fake = try FakeCodexAppServer(scenario: "provider_current")
        let provider = CodexUsageProvider(client: fake.client)

        let account = try await provider.readAccount(refreshToken: true)

        XCTAssertEqual(account.planName, "pro")
        let requests = try fake.recordedRequests()
        XCTAssertEqual(requests.map(\.method), [.accountRead])
        XCTAssertEqual(
            requests[0].params,
            .object(["refreshToken": .bool(true)])
        )
    }

    func testMissingOptionalUsageMethodAndEmptyUsageDegradeGracefully()
        async throws
    {
        for scenario in ["provider_usage_unavailable", "provider_usage_empty"] {
            let fake = try FakeCodexAppServer(scenario: scenario)
            let provider = CodexUsageProvider(client: fake.client)

            let report = try await provider.fetchUsage()

            XCTAssertEqual(report.health.status, .degraded)
            XCTAssertEqual(
                report.health.issue,
                .optionalUsageUnavailable
            )
            XCTAssertNil(report.usageSummary)
            XCTAssertEqual(report.limitGroups.count, 1)
            XCTAssertEqual(
                provider.capabilities[.usageSummary],
                .unknown
            )
            XCTAssertEqual(
                try fake.recordedRequests().map(\.method),
                [.accountRead, .accountRateLimitsRead, .accountUsageRead]
            )
        }
    }

    func testMalformedOptionalUsagePreservesAccountAndRateLimits()
        async throws
    {
        let fake = try FakeCodexAppServer(
            scenario: "provider_usage_malformed"
        )
        let provider = CodexUsageProvider(client: fake.client)

        let report = try await provider.fetchUsage()

        XCTAssertEqual(report.account?.planName, "plus")
        XCTAssertEqual(report.health.status, .degraded)
        XCTAssertEqual(report.health.issue, .optionalUsageUnavailable)
        XCTAssertNil(report.usageSummary)
        XCTAssertEqual(report.limitGroups.count, 1)
        XCTAssertEqual(
            report.limitGroups[0].id.rawValue,
            "codex.limit.codex"
        )
        XCTAssertEqual(
            report.limitGroups[0].windows[0].usedPercentage,
            37
        )
        XCTAssertEqual(
            try fake.recordedRequests().map(\.method),
            [.accountRead, .accountRateLimitsRead, .accountUsageRead]
        )
        XCTAssertEqual(try fake.launchedProcessIdentifiers().count, 1)
        try await fake.assertAllProcessesExited()
    }

    func testCreditAvailabilityFlagsGateFiniteBalances() async throws {
        let fake = try FakeCodexAppServer(scenario: "provider_credit_matrix")

        let report = try await CodexUsageProvider(
            client: fake.client
        ).fetchUsage()

        XCTAssertEqual(
            report.credits.map(\.id.rawValue),
            ["codex.limit.finite.credits"]
        )
        XCTAssertEqual(report.credits.first?.balance, 12.5)
    }

    func testDailyPeriodUsesExactUTCDayAcrossHostDST() async throws {
        let previousTimeZone = getenv("TZ").map { String(cString: $0) }
        XCTAssertEqual(setenv("TZ", "America/Denver", 1), 0)
        tzset()
        NSTimeZone.resetSystemTimeZone()
        defer {
            if let previousTimeZone {
                _ = setenv("TZ", previousTimeZone, 1)
            } else {
                _ = unsetenv("TZ")
            }
            tzset()
            NSTimeZone.resetSystemTimeZone()
        }

        let formatter = ISO8601DateFormatter()
        let expectedStart = try XCTUnwrap(
            formatter.date(from: "2026-03-08T00:00:00Z")
        )
        let expectedEnd = try XCTUnwrap(
            formatter.date(from: "2026-03-09T00:00:00Z")
        )
        XCTAssertNotEqual(
            TimeZone.current.secondsFromGMT(for: expectedStart),
            0
        )

        let fake = try FakeCodexAppServer(scenario: "provider_daily_dst")
        let report = try await CodexUsageProvider(
            client: fake.client
        ).fetchUsage()
        let summary = try XCTUnwrap(report.usageSummary)

        XCTAssertEqual(summary.periodStartedAt, expectedStart)
        XCTAssertEqual(summary.periodEndsAt, expectedEnd)
        XCTAssertEqual(
            try XCTUnwrap(summary.periodEndsAt).timeIntervalSince(
                try XCTUnwrap(summary.periodStartedAt)
            ),
            86_400
        )
    }

    func testRefreshSharesOneOverallDeadlineAcrossAllRPCs() async throws {
        let fake = try FakeCodexAppServer(
            scenario: "provider_refresh_overall_timeout",
            limits: try CodexTransportLimits(
                startupTimeout: 5,
                requestTimeout: 10,
                overallTimeout: 4,
                terminationGracePeriod: 0.05
            )
        )
        let began = Date()

        await XCTAssertThrowsProviderError(
            try await CodexUsageProvider(
                client: fake.client
            ).fetchUsage()
        ) {
            XCTAssertEqual($0, .timedOut)
        }

        XCTAssertLessThan(Date().timeIntervalSince(began), 6)
        XCTAssertEqual(
            try fake.recordedRequests().map(\.method),
            [.accountRead, .accountRateLimitsRead, .accountUsageRead]
        )
        XCTAssertEqual(
            try fake.recordedRequests().map(\.id),
            [.integer(2), .integer(3), .integer(4)]
        )
        XCTAssertEqual(try fake.recordedInitializations().count, 1)
        XCTAssertEqual(try fake.launchedProcessIdentifiers().count, 1)
        try await fake.assertAllProcessesExited()
    }

    func testLegacyAndAdditiveShapesRemainCompatible() async throws {
        let fake = try FakeCodexAppServer(
            scenario: "provider_legacy_additive"
        )
        let provider = CodexUsageProvider(client: fake.client)

        let report = try await provider.fetchUsage()

        XCTAssertEqual(report.account?.planName, "future_plan")
        XCTAssertNil(report.account?.displayName)
        XCTAssertEqual(report.limitGroups.count, 1)
        XCTAssertEqual(
            report.limitGroups[0].id.rawValue,
            "codex.limit.legacy~20bucket"
        )
        XCTAssertEqual(report.limitGroups[0].windows[0].usedPercentage, 12.5)
        XCTAssertEqual(report.limitGroups[0].windows[0].duration, 3_600)
        XCTAssertNil(report.usageSummary)
    }

    func testMalformedDynamicBucketIsSkippedWhenAValidBucketExists()
        async throws
    {
        let fake = try FakeCodexAppServer(scenario: "provider_lossy_dynamic")
        let report = try await CodexUsageProvider(
            client: fake.client
        ).fetchUsage()

        XCTAssertEqual(report.limitGroups.count, 1)
        XCTAssertEqual(report.limitGroups[0].id.rawValue, "codex.limit.valid")
        XCTAssertEqual(report.limitGroups[0].windows[0].usedPercentage, 11)
    }

    func testDynamicLimitsCoverSecondaryOnlyBoundariesAndResetTimes()
        throws
    {
        let referenceDate = Date(timeIntervalSince1970: 2_000)
        let response = try CodexDomainDecoder.decode(
            CodexRateLimitsResponse.self,
            from: .object([
                "rateLimitsByLimitId": .object([
                    "secondary-only": .object([
                        "limitId": .string("secondary-only"),
                        "limitName": .string("Secondary only"),
                        "secondary": .object([
                            "usedPercent": .number(42),
                            "windowDurationMins": .integer(60),
                            "resetsAt": .integer(3_000)
                        ])
                    ]),
                    "boundary": .object([
                        "limitId": .string("boundary"),
                        "primary": .object([
                            "usedPercent": .number(0),
                            "windowDurationMins": .integer(5),
                            "resetsAt": .integer(1_000)
                        ]),
                        "secondary": .object([
                            "usedPercent": .number(100),
                            "windowDurationMins": .integer(10),
                            "resetsAt": .integer(3_000)
                        ])
                    ])
                ])
            ])
        )

        let groups = try CodexReportMapper.limitGroups(from: response)
        let secondaryOnly = try XCTUnwrap(
            groups.first { $0.id.rawValue == "codex.limit.secondary-only" }
        )
        XCTAssertEqual(secondaryOnly.windows.count, 1)
        XCTAssertEqual(
            secondaryOnly.windows[0].id.rawValue,
            "codex.limit.secondary-only.secondary"
        )
        XCTAssertEqual(secondaryOnly.windows[0].usedPercentage, 42)

        let boundary = try XCTUnwrap(
            groups.first { $0.id.rawValue == "codex.limit.boundary" }
        )
        XCTAssertEqual(
            boundary.windows.compactMap(\.usedPercentage),
            [0, 100]
        )
        let expiredReset = try XCTUnwrap(boundary.windows[0].resetsAt)
        let futureReset = try XCTUnwrap(boundary.windows[1].resetsAt)
        XCTAssertLessThan(expiredReset, referenceDate)
        XCTAssertGreaterThan(futureReset, referenceDate)
        XCTAssertEqual(
            boundary.windows[0].startedAt,
            expiredReset.addingTimeInterval(-300)
        )
        XCTAssertEqual(
            boundary.windows[1].startedAt,
            futureReset.addingTimeInterval(-600)
        )
    }

    func testMalformedRequiredAccountAndRateShapesFailClosed() async throws {
        let malformedAccount = try FakeCodexAppServer(
            scenario: "provider_malformed_account"
        )
        await XCTAssertThrowsProviderError(
            try await CodexUsageProvider(
                client: malformedAccount.client
            ).account()
        ) {
            XCTAssertEqual($0, .malformedResponse)
        }

        let malformedRate = try FakeCodexAppServer(
            scenario: "provider_malformed_rate"
        )
        await XCTAssertThrowsProviderError(
            try await CodexUsageProvider(
                client: malformedRate.client
            ).fetchUsage()
        ) {
            XCTAssertEqual($0, .malformedResponse)
        }
    }

    func testUnsupportedAndUnauthenticatedAccountsAreExplicit()
        async throws
    {
        for (scenario, expectedKind) in [
            ("provider_api_key", CodexUnsupportedAccountKind.apiKey),
            ("provider_bedrock", .amazonBedrock),
            ("provider_unknown_account", .other),
            ("provider_no_openai_account", .noOpenAIAccount)
        ] {
            let fake = try FakeCodexAppServer(scenario: scenario)
            let provider = CodexUsageProvider(client: fake.client)
            let status = try await provider.accountStatus()
            XCTAssertEqual(status, .unsupported(expectedKind))
            await XCTAssertThrowsProviderError(try await provider.account()) {
                XCTAssertEqual($0, .unsupportedAccount)
            }
            let health = await provider.health()
            XCTAssertEqual(health.status, .unsupported)
            XCTAssertEqual(health.issue, .accountUnsupported)
        }

        let unauthenticated = try FakeCodexAppServer(
            scenario: "provider_unauthenticated"
        )
        let provider = CodexUsageProvider(client: unauthenticated.client)
        let accountStatus = try await provider.accountStatus()
        XCTAssertEqual(accountStatus, .unauthenticated)
        await XCTAssertThrowsProviderError(try await provider.account()) {
            XCTAssertEqual($0, .unauthenticated)
        }
        let health = await provider.health()
        XCTAssertEqual(health.status, .unauthenticated)
        XCTAssertEqual(health.issue, .authenticationRequired)
    }

    func testHealthIncludesRequiredRateLimitEndpoint() async throws {
        let rpcFailure = try FakeCodexAppServer(
            scenario: "provider_health_rate_rpc_failure"
        )
        let rpcHealth = await CodexUsageProvider(
            client: rpcFailure.client
        ).health()
        XCTAssertEqual(rpcHealth.status, .degraded)
        XCTAssertEqual(rpcHealth.issue, .protocolMismatch)
        XCTAssertEqual(
            try rpcFailure.recordedRequests().map(\.method),
            [.accountRead, .accountRateLimitsRead]
        )
        XCTAssertEqual(
            try rpcFailure.recordedRequests().map(\.id),
            [.integer(2), .integer(3)]
        )
        XCTAssertEqual(try rpcFailure.launchedProcessIdentifiers().count, 1)
        try await rpcFailure.assertAllProcessesExited()

        let malformed = try FakeCodexAppServer(
            scenario: "provider_health_rate_malformed"
        )
        let malformedHealth = await CodexUsageProvider(
            client: malformed.client
        ).health()
        XCTAssertEqual(malformedHealth.status, .degraded)
        XCTAssertEqual(malformedHealth.issue, .responseInvalid)
        XCTAssertEqual(
            try malformed.recordedRequests().map(\.method),
            [.accountRead, .accountRateLimitsRead]
        )
        XCTAssertEqual(try malformed.launchedProcessIdentifiers().count, 1)
        try await malformed.assertAllProcessesExited()
    }

    func testBrowserAndDeviceLoginUseOfficialScopedFlows() async throws {
        let browserFake = try FakeCodexAppServer(
            scenario: "provider_login_browser"
        )
        let browserProvider = CodexUsageProvider(client: browserFake.client)
        let browserAttempt = try await browserProvider.startLogin(
            .browser(
                useHostedSuccessPage: true,
                appBrand: .chatgpt
            )
        )
        guard case let .browser(loginID, authorizationURL) =
            browserAttempt.challenge
        else {
            return XCTFail("Expected browser challenge")
        }
        XCTAssertEqual(loginID, "browser-login-id")
        XCTAssertEqual(authorizationURL.host, "chatgpt.com")
        XCTAssertEqual(
            String(describing: browserAttempt.challenge),
            "CodexLoginChallenge.browser(<redacted>)"
        )
        let browserOutcome = try await browserAttempt.waitForCompletion()
        XCTAssertEqual(browserOutcome, .succeeded)
        try await browserAttempt.disconnect()
        let repeatedBrowserOutcome =
            try await browserAttempt.waitForCompletion()
        let lateBrowserCancellation = try await browserAttempt.cancel()
        XCTAssertEqual(repeatedBrowserOutcome, .succeeded)
        XCTAssertEqual(lateBrowserCancellation, .notFound)
        let browserRequests = try browserFake.recordedRequests()
        XCTAssertEqual(browserRequests.map(\.method), [.accountLoginStart])
        XCTAssertEqual(
            browserRequests[0].params,
            .object([
                "type": .string("chatgpt"),
                "useHostedLoginSuccessPage": .bool(true),
                "appBrand": .string("chatgpt")
            ])
        )

        let deviceFake = try FakeCodexAppServer(
            scenario: "provider_login_device"
        )
        let deviceAttempt = try await CodexUsageProvider(
            client: deviceFake.client
        ).startLogin(.deviceCode)
        guard case let .deviceCode(loginID, verificationURL, userCode) =
            deviceAttempt.challenge
        else {
            return XCTFail("Expected device-code challenge")
        }
        XCTAssertEqual(loginID, "device-login-id")
        XCTAssertEqual(verificationURL.host, "auth.openai.com")
        XCTAssertEqual(userCode, "ABCD-1234")
        let deviceOutcome = try await deviceAttempt.waitForCompletion()
        XCTAssertEqual(deviceOutcome, .succeeded)
        let deviceRequests = try deviceFake.recordedRequests()
        XCTAssertEqual(deviceRequests.map(\.method), [.accountLoginStart])
        XCTAssertEqual(
            deviceRequests[0].params,
            .object(["type": .string("chatgptDeviceCode")])
        )
    }

    func testBeginLoginReturnsAlreadyAuthenticatedWithoutStartingLogin()
        async throws
    {
        let fake = try FakeCodexAppServer(
            scenario: "provider_login_already_authenticated"
        )
        let provider = CodexUsageProvider(client: fake.client)

        let result = try await provider.beginLogin(.browser())
        guard case let .alreadyAuthenticated(account) = result else {
            return XCTFail("Expected existing authenticated account")
        }

        XCTAssertEqual(account.displayName, "already@example.com")
        XCTAssertEqual(account.planName, "plus")
        XCTAssertEqual(
            try fake.recordedRequests().map(\.method),
            [.accountRead]
        )
        XCTAssertEqual(try fake.launchedProcessIdentifiers().count, 1)
        try await fake.assertAllProcessesExited()
    }

    func testLoginServerErrorIsTypedAndClosesScopedSession()
        async throws
    {
        let fake = try FakeCodexAppServer(
            scenario: "provider_login_server_error"
        )
        let provider = CodexUsageProvider(client: fake.client)

        await XCTAssertThrowsProviderError(
            try await provider.startLogin(.browser())
        ) {
            XCTAssertEqual($0, .protocolFailure)
        }

        XCTAssertEqual(
            try fake.recordedRequests().map(\.method),
            [.accountLoginStart]
        )
        XCTAssertEqual(try fake.launchedProcessIdentifiers().count, 1)
        try await fake.assertAllProcessesExited()
    }

    func testLoginCancelUsesLoginIDAndClosesScopedSession() async throws {
        let fake = try FakeCodexAppServer(scenario: "provider_login_cancel")
        let attempt = try await CodexUsageProvider(
            client: fake.client
        ).startLogin(.browser())

        let firstWaitTask = Task {
            try await attempt.waitForCompletion()
        }
        let secondWaitTask = Task {
            try await attempt.waitForCompletion()
        }
        guard await waitUntilCompletionIsRegistered(attempt) else {
            return XCTFail("Completion wait did not register")
        }
        let firstCancelTask = Task {
            try await attempt.cancel()
        }
        let secondCancelTask = Task {
            try await attempt.cancel()
        }
        let firstCancellationOutcome = try await firstCancelTask.value
        let secondCancellationOutcome = try await secondCancelTask.value
        let firstCompletionOutcome = try await firstWaitTask.value
        let secondCompletionOutcome = try await secondWaitTask.value
        let repeatedCancellationOutcome = try await attempt.cancel()
        let repeatedCompletionOutcome =
            try await attempt.waitForCompletion()
        XCTAssertEqual(firstCancellationOutcome, .canceled)
        XCTAssertEqual(secondCancellationOutcome, .canceled)
        XCTAssertEqual(firstCompletionOutcome, .failed)
        XCTAssertEqual(secondCompletionOutcome, .failed)
        XCTAssertEqual(repeatedCancellationOutcome, .canceled)
        XCTAssertEqual(repeatedCompletionOutcome, .failed)
        let requests = try fake.recordedRequests()
        XCTAssertEqual(
            requests.map(\.method),
            [.accountLoginStart, .accountLoginCancel]
        )
        XCTAssertEqual(
            requests[1].params,
            .object(["loginId": .string("cancel-login-id")])
        )
        XCTAssertFalse(requests.map(\.method).contains(.accountLogout))
        XCTAssertEqual(try fake.launchedProcessIdentifiers().count, 1)
        try await fake.assertAllProcessesExited()
    }

    func testCompletionWinsWhenItPrecedesNotFoundResponse() async throws {
        let fake = try FakeCodexAppServer(
            scenario: "provider_login_completion_before_not_found"
        )
        let attempt = try await CodexUsageProvider(
            client: fake.client
        ).startLogin(.browser())

        let waitTask = Task {
            try await attempt.waitForCompletion()
        }
        guard await waitUntilCompletionIsRegistered(attempt) else {
            return XCTFail("Completion wait did not register")
        }
        let cancellationOutcome = try await attempt.cancel()
        let completionOutcome = try await waitTask.value

        XCTAssertEqual(completionOutcome, .succeeded)
        XCTAssertEqual(cancellationOutcome, .notFound)
        XCTAssertEqual(
            try fake.recordedRequests().map(\.method),
            [.accountLoginStart, .accountLoginCancel]
        )
        XCTAssertEqual(try fake.launchedProcessIdentifiers().count, 1)
        try await fake.assertAllProcessesExited()
    }

    func testNotFoundPreservesCompletionForAnActiveWaiter() async throws {
        let fake = try FakeCodexAppServer(
            scenario: "provider_login_not_found_before_completion"
        )
        let attempt = try await CodexUsageProvider(
            client: fake.client
        ).startLogin(.browser())

        let waitTask = Task {
            try await attempt.waitForCompletion()
        }
        guard await waitUntilCompletionIsRegistered(attempt) else {
            return XCTFail("Completion wait did not register")
        }
        let cancellationOutcome = try await attempt.cancel()
        let completionOutcome = try await waitTask.value
        let repeatedCancellationOutcome = try await attempt.cancel()
        let repeatedCompletionOutcome =
            try await attempt.waitForCompletion()

        XCTAssertEqual(cancellationOutcome, .notFound)
        XCTAssertEqual(completionOutcome, .succeeded)
        XCTAssertEqual(repeatedCancellationOutcome, .notFound)
        XCTAssertEqual(repeatedCompletionOutcome, .succeeded)
        XCTAssertEqual(
            try fake.recordedRequests().map(\.method),
            [.accountLoginStart, .accountLoginCancel]
        )
        XCTAssertEqual(try fake.launchedProcessIdentifiers().count, 1)
        try await fake.assertAllProcessesExited()
    }

    func testStandaloneNotFoundClosesWithoutWaitingForCompletion()
        async throws
    {
        let fake = try FakeCodexAppServer(
            scenario: "provider_login_not_found",
            limits: try fastLimits()
        )
        let attempt = try await CodexUsageProvider(
            client: fake.client
        ).startLogin(.browser())

        let startedAt = Date()
        let cancellationOutcome = try await attempt.cancel()

        XCTAssertEqual(cancellationOutcome, .notFound)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        await XCTAssertThrowsProviderError(
            try await attempt.waitForCompletion()
        ) {
            XCTAssertEqual($0, .cancelled)
        }
        XCTAssertEqual(
            try fake.recordedRequests().map(\.method),
            [.accountLoginStart, .accountLoginCancel]
        )
        XCTAssertEqual(try fake.launchedProcessIdentifiers().count, 1)
        try await fake.assertAllProcessesExited()
    }

    func testLoginCompletionTimeoutIsBoundedAndRedacted() async throws {
        let fake = try FakeCodexAppServer(
            scenario: "provider_login_timeout",
            limits: try fastLimits()
        )
        let attempt = try await CodexUsageProvider(
            client: fake.client
        ).startLogin(.browser())

        let startedAt = Date()
        await XCTAssertThrowsProviderError(
            try await attempt.waitForCompletion()
        ) {
            XCTAssertEqual($0, .timedOut)
            XCTAssertFalse(String(describing: $0).contains("pending-login-id"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
        await XCTAssertThrowsProviderError(
            try await attempt.waitForCompletion()
        ) {
            XCTAssertEqual($0, .timedOut)
        }
        XCTAssertEqual(try fake.launchedProcessIdentifiers().count, 1)
        try await fake.assertAllProcessesExited()
    }

    func testCancellingWaitTaskClosesAndReapsTheScopedSession()
        async throws
    {
        let fake = try FakeCodexAppServer(
            scenario: "provider_login_timeout",
            limits: try fastLimits()
        )
        let attempt = try await CodexUsageProvider(
            client: fake.client
        ).startLogin(.browser())

        let waitTask = Task {
            try await attempt.waitForCompletion()
        }
        guard await waitUntilCompletionIsRegistered(attempt) else {
            return XCTFail("Completion wait did not register")
        }
        waitTask.cancel()

        do {
            _ = try await waitTask.value
            XCTFail("Expected typed cancellation")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(
            try fake.recordedRequests().map(\.method),
            [.accountLoginStart]
        )
        XCTAssertEqual(try fake.launchedProcessIdentifiers().count, 1)
        try await fake.assertAllProcessesExited()
    }

    func testDisconnectNeverLogsOutOrMutatesCredentials() async throws {
        let providerOnly = try FakeCodexAppServer(
            scenario: "provider_current"
        )
        let provider = CodexUsageProvider(client: providerOnly.client)
        await provider.disconnect()
        XCTAssertTrue(try providerOnly.recordedRequests().isEmpty)

        let loginFake = try FakeCodexAppServer(
            scenario: "provider_disconnect"
        )
        let attempt = try await CodexUsageProvider(
            client: loginFake.client
        ).startLogin(.browser())
        let waitTask = Task {
            try await attempt.waitForCompletion()
        }
        guard await waitUntilCompletionIsRegistered(attempt) else {
            return XCTFail("Completion wait did not register")
        }
        try await attempt.disconnect()
        try await attempt.disconnect()

        do {
            _ = try await waitTask.value
            XCTFail("Expected disconnect to interrupt the active wait")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let requests = try loginFake.recordedRequests()
        XCTAssertEqual(requests.map(\.method), [.accountLoginStart])
        XCTAssertFalse(requests.map(\.method).contains(.accountLogout))
        XCTAssertEqual(try loginFake.launchedProcessIdentifiers().count, 1)
        try await loginFake.assertAllProcessesExited()
    }

    func testMalformedLoginResponseDoesNotExposeURLsOrSecrets() async throws {
        let fake = try FakeCodexAppServer(
            scenario: "provider_login_redaction"
        )
        do {
            _ = try await CodexUsageProvider(
                client: fake.client
            ).startLogin(.browser())
            XCTFail("Expected malformed response")
        } catch let error as UsageProviderError {
            XCTAssertEqual(error, .malformedResponse)
            let description = String(describing: error)
            XCTAssertFalse(description.contains("super-secret"))
            XCTAssertFalse(
                description.localizedCaseInsensitiveContains("access_token")
            )
        }
    }

    func testLiveAccountAndRateLimitSmokeWhenExplicitlyEnabled()
        async throws
    {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CODEX_USAGE_LIVE_SMOKE"] == "1" else {
            throw XCTSkip(
                "Set CODEX_USAGE_LIVE_SMOKE=1 to enable the live smoke test."
            )
        }
        guard let executablePath =
                environment["CODEX_USAGE_LIVE_EXECUTABLE"],
              let codexHomePath =
                environment["CODEX_USAGE_LIVE_HOME"]
        else {
            return XCTFail(
                "Live smoke requires executable and home environment variables."
            )
        }

        let configuration = try CodexProcessConfiguration(
            executableURL: URL(fileURLWithPath: executablePath),
            codexHomeURL: URL(
                fileURLWithPath: codexHomePath,
                isDirectory: true
            )
        )
        let provider = CodexUsageProvider(
            processConfiguration: configuration
        )

        let account = try await provider.account()
        let report = try await provider.fetchUsage()

        XCTAssertNotNil(account)
        XCTAssertEqual(report.providerID, .codex)
        XCTAssertFalse(report.limitGroups.isEmpty)
    }

    private func metric(
        _ id: String,
        in summary: UsageSummary
    ) -> UsageMetric? {
        summary.metrics.first { $0.id.rawValue == id }
    }

    private func fastLimits() throws -> CodexTransportLimits {
        try CodexTransportLimits(
            startupTimeout: 5,
            requestTimeout: 0.2,
            overallTimeout: 6,
            terminationGracePeriod: 0.05
        )
    }

    private func waitUntilCompletionIsRegistered(
        _ attempt: CodexLoginAttempt
    ) async -> Bool {
        for _ in 0..<1_000 {
            if await attempt.completionWaitIsRegisteredForTesting() {
                return true
            }
            await Task.yield()
        }
        return false
    }
}

private func XCTAssertThrowsProviderError<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    verify: (UsageProviderError) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected UsageProviderError", file: file, line: line)
    } catch let error as UsageProviderError {
        verify(error)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
