import CodexUsageProvider
import Foundation
import UsageCore
import XCTest

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

            XCTAssertEqual(report.health.status, .healthy)
            XCTAssertNil(report.usageSummary)
            XCTAssertEqual(report.limitGroups.count, 1)
            XCTAssertEqual(
                try fake.recordedRequests().map(\.method),
                [.accountRead, .accountRateLimitsRead, .accountUsageRead]
            )
        }
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

    func testLoginCancelUsesLoginIDAndClosesScopedSession() async throws {
        let fake = try FakeCodexAppServer(scenario: "provider_login_cancel")
        let attempt = try await CodexUsageProvider(
            client: fake.client
        ).startLogin(.browser())

        let cancellationOutcome = try await attempt.cancel()
        XCTAssertEqual(cancellationOutcome, .canceled)
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
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
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
        try await attempt.disconnect()

        let requests = try loginFake.recordedRequests()
        XCTAssertEqual(requests.map(\.method), [.accountLoginStart])
        XCTAssertFalse(requests.map(\.method).contains(.accountLogout))
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

    private func metric(
        _ id: String,
        in summary: UsageSummary
    ) -> UsageMetric? {
        summary.metrics.first { $0.id.rawValue == id }
    }

    private func fastLimits() throws -> CodexTransportLimits {
        try CodexTransportLimits(
            startupTimeout: 1,
            requestTimeout: 0.1,
            overallTimeout: 1.5,
            terminationGracePeriod: 0.05
        )
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
