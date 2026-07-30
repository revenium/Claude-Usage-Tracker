import Foundation
import UsageCore
import XCTest
@testable import Claude_Usage

@MainActor
final class UsageProviderRegistryTests: XCTestCase {
    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) {
            self.value = value
        }

        func withValue<Result>(
            _ body: (inout Value) -> Result
        ) -> Result {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }

        func snapshot() -> Value {
            withValue { $0 }
        }
    }

    private let now = Date(timeIntervalSinceReferenceDate: 50_000)

    func testProductionAvailabilityKeepsCodexDisabled() {
        XCTAssertFalse(
            UsageProviderFeatureAvailability.production.codexRefreshEnabled
        )
    }

    func testDisabledCodexFailsBeforeResolverOrFactory() throws {
        let resolverCalls = Locked(0)
        let factoryCalls = Locked(0)
        let registry = makeRegistry(
            availability: .production,
            resolverCalls: resolverCalls,
            factoryCalls: factoryCalls
        )

        XCTAssertThrowsError(
            try registry.capture(
                profile: try makeLinkedCodexProfile(),
                context: makeContext()
            )
        ) { error in
            XCTAssertEqual(
                error as? UsageProviderCaptureError,
                .featureDisabled(.codex)
            )
        }
        XCTAssertEqual(resolverCalls.snapshot(), 0)
        XCTAssertEqual(factoryCalls.snapshot(), 0)
    }

    func testUnlinkedCodexFailsWithoutResolvingOrLaunching() {
        let resolverCalls = Locked(0)
        let factoryCalls = Locked(0)
        let registry = makeRegistry(
            resolverCalls: resolverCalls,
            factoryCalls: factoryCalls
        )
        let profile = Profile(
            name: "Unlinked",
            providerConfiguration: .codex(.init())
        )

        XCTAssertThrowsError(
            try registry.capture(
                profile: profile,
                context: makeContext()
            )
        ) { error in
            XCTAssertEqual(
                error as? UsageProviderCaptureError,
                .codexHomeUnlinked
            )
        }
        XCTAssertEqual(resolverCalls.snapshot(), 0)
        XCTAssertEqual(factoryCalls.snapshot(), 0)
    }

    func testUnavailableCodexHomeFailsWithoutResolvingOrLaunching() throws {
        let resolverCalls = Locked(0)
        let factoryCalls = Locked(0)
        let registry = makeRegistry(
            codexHomeValidator: { _ in false },
            resolverCalls: resolverCalls,
            factoryCalls: factoryCalls
        )

        XCTAssertThrowsError(
            try registry.capture(
                profile: try makeLinkedCodexProfile(),
                context: makeContext()
            )
        ) { error in
            XCTAssertEqual(
                error as? UsageProviderCaptureError,
                .codexHomeUnavailable
            )
        }
        XCTAssertEqual(resolverCalls.snapshot(), 0)
        XCTAssertEqual(factoryCalls.snapshot(), 0)
    }

    func testMissingExecutableFailsWithoutConstructingProvider() throws {
        let resolverCalls = Locked(0)
        let factoryCalls = Locked(0)
        let registry = makeRegistry(
            executableValidator: { _ in false },
            resolverCalls: resolverCalls,
            factoryCalls: factoryCalls
        )

        XCTAssertThrowsError(
            try registry.capture(
                profile: try makeLinkedCodexProfile(),
                context: makeContext()
            )
        ) { error in
            XCTAssertEqual(
                error as? UsageProviderCaptureError,
                .codexExecutableMissing
            )
        }
        XCTAssertEqual(resolverCalls.snapshot(), 1)
        XCTAssertEqual(factoryCalls.snapshot(), 0)
    }

    func testCodexFactoryCreatesFreshRequestScopedFetchForEveryCapture()
        async throws
    {
        let factoryCalls = Locked(0)
        let registry = UsageProviderRegistry(
            featureAvailability: .testing(),
            claudeRequestCapture: { _ in
                throw TestError.unexpected
            },
            codexHomeValidator: { _ in true },
            codexExecutableResolver: {
                URL(fileURLWithPath: "/usr/bin/true")
            },
            codexExecutableValidator: { _ in true },
            codexFetchFactory: { _ in
                let generation = factoryCalls.withValue {
                    $0 += 1
                    return $0
                }
                return {
                    try Self.makeCodexReport(generation: generation)
                }
            },
            now: { self.now }
        )
        let profile = try makeLinkedCodexProfile()

        let first = try registry.capture(
            profile: profile,
            context: makeContext()
        )
        let second = try registry.capture(
            profile: profile,
            context: makeContext()
        )

        XCTAssertEqual(factoryCalls.snapshot(), 2)
        let firstResult = try await first.coreFetch()
        let secondResult = try await second.coreFetch()
        XCTAssertEqual(firstResult.report.account?.displayName, "request-1")
        XCTAssertEqual(secondResult.report.account?.displayName, "request-2")
        XCTAssertEqual(
            firstResult.report.staleAt,
            firstResult.report.fetchedAt.addingTimeInterval(300)
        )
        XCTAssertNil(firstResult.claudeUsage)
        XCTAssertNil(first.apiFetch)
        XCTAssertEqual(first.identity.providerID, .codex)
        XCTAssertEqual(first.capabilities[.usageLimits], .available)
    }

    func testCodexInvalidRefreshIntervalUsesFiveMinuteFreshness()
        async throws
    {
        let registry = UsageProviderRegistry(
            featureAvailability: .testing(),
            claudeRequestCapture: { _ in
                throw TestError.unexpected
            },
            codexHomeValidator: { _ in true },
            codexExecutableResolver: {
                URL(fileURLWithPath: "/usr/bin/true")
            },
            codexExecutableValidator: { _ in true },
            codexFetchFactory: { _ in
                {
                    try Self.makeCodexReport(generation: 1)
                }
            }
        )
        let profile = try makeLinkedCodexProfile(
            refreshInterval: .infinity
        )
        let job = try registry.capture(
            profile: profile,
            context: makeContext()
        )

        let result = try await job.coreFetch()

        XCTAssertEqual(job.refreshInterval, 300)
        XCTAssertEqual(
            result.report.staleAt,
            result.report.fetchedAt.addingTimeInterval(300)
        )
    }

    func testCodexRejectsFactoryResultForWrongProvider() async throws {
        let registry = UsageProviderRegistry(
            featureAvailability: .testing(),
            claudeRequestCapture: { _ in
                throw TestError.unexpected
            },
            codexHomeValidator: { _ in true },
            codexExecutableResolver: {
                URL(fileURLWithPath: "/usr/bin/true")
            },
            codexExecutableValidator: { _ in true },
            codexFetchFactory: { _ in
                {
                    try Self.makeClaudeReport()
                }
            },
            now: { self.now }
        )
        let job = try registry.capture(
            profile: try makeLinkedCodexProfile(),
            context: makeContext()
        )

        do {
            _ = try await job.coreFetch()
            XCTFail("Expected provider identity mismatch")
        } catch {
            XCTAssertEqual(
                error as? UsageProviderFetchError,
                .providerIdentityMismatch(
                    expected: .codex,
                    received: .claude
                )
            )
        }
    }

    @MainActor
    func testClaudeCredentialsAreCapturedSynchronouslyAndCannotDrift()
        async throws
    {
        let liveCredential = Locked(11)
        let captureCalls = Locked(0)
        let registry = UsageProviderRegistry(
            featureAvailability: .production,
            claudeRequestCapture: { _ in
                captureCalls.withValue { $0 += 1 }
                let capturedCredential = liveCredential.snapshot()
                return CapturedClaudeProviderRequest(
                    coreFetch: {
                        Self.makeClaudeUsage(
                            sessionTokensUsed: capturedCredential
                        )
                    },
                    apiFetch: {
                        Self.makeAPIUsage(
                            currentSpendCents: capturedCredential
                        )
                    }
                )
            },
            codexHomeValidator: { _ in
                XCTFail("Codex home must not be consulted for Claude")
                return false
            },
            codexExecutableResolver: {
                XCTFail("Codex executable must not be resolved for Claude")
                throw TestError.unexpected
            },
            codexExecutableValidator: { _ in false },
            codexFetchFactory: { _ in
                XCTFail("Codex provider must not be constructed for Claude")
                throw TestError.unexpected
            },
            now: { self.now }
        )
        let profile = Profile(
            name: "Claude",
            providerRevision: 4,
            refreshInterval: 20
        )

        let job = try registry.capture(
            profile: profile,
            context: makeContext()
        )
        XCTAssertEqual(captureCalls.snapshot(), 1)
        liveCredential.withValue { $0 = 99 }

        let result = try await job.coreFetch()
        let apiUsage = try await XCTUnwrap(job.apiFetch)()

        XCTAssertEqual(result.claudeUsage?.sessionTokensUsed, 11)
        XCTAssertEqual(apiUsage.currentSpendCents, 11)
        XCTAssertEqual(result.report.providerID, .claude)
        XCTAssertEqual(result.report.fetchedAt, now)
        XCTAssertEqual(
            result.report.staleAt,
            now.addingTimeInterval(300)
        )
        XCTAssertEqual(job.identity.profileID, profile.id)
        XCTAssertEqual(job.identity.providerRevision, 4)
        XCTAssertEqual(job.requestContext.trigger, .manual)
    }

    func testClaudeCaptureFailureIsTypedAndDoesNotExposeUnderlyingError() {
        let registry = UsageProviderRegistry(
            claudeRequestCapture: { _ in
                throw TestError.secretBearingFailure
            },
            codexExecutableResolver: {
                throw TestError.unexpected
            },
            codexFetchFactory: { _ in
                throw TestError.unexpected
            }
        )

        XCTAssertThrowsError(
            try registry.capture(
                profile: Profile(name: "Claude"),
                context: makeContext()
            )
        ) { error in
            XCTAssertEqual(
                error as? UsageProviderCaptureError,
                .claudeCredentialsUnavailable
            )
            XCTAssertFalse(
                String(describing: error).contains("secret-bearing")
            )
        }
    }

    func testDeletedProfileFailsBeforeAnyProviderDependencyRuns() {
        let captureCalls = Locked(0)
        let resolverCalls = Locked(0)
        let factoryCalls = Locked(0)
        let registry = makeRegistry(
            claudeRequestCapture: { _ in
                captureCalls.withValue { $0 += 1 }
                throw TestError.unexpected
            },
            resolverCalls: resolverCalls,
            factoryCalls: factoryCalls
        )
        let profile = Profile(name: "Deleting", deletionInProgress: true)

        XCTAssertThrowsError(
            try registry.capture(
                profile: profile,
                context: makeContext()
            )
        ) { error in
            XCTAssertEqual(
                error as? UsageProviderCaptureError,
                .profileDeletionInProgress
            )
        }
        XCTAssertEqual(captureCalls.snapshot(), 0)
        XCTAssertEqual(resolverCalls.snapshot(), 0)
        XCTAssertEqual(factoryCalls.snapshot(), 0)
    }

    private func makeRegistry(
        availability: UsageProviderFeatureAvailability = .testing(),
        codexHomeValidator: @escaping
            UsageProviderRegistry.CodexHomeValidator = { _ in true },
        executableValidator: @escaping
            UsageProviderRegistry.ExecutableValidator = { _ in true },
        claudeRequestCapture: @escaping ClaudeProviderRequestCapture = { _ in
            throw TestError.unexpected
        },
        resolverCalls: Locked<Int>,
        factoryCalls: Locked<Int>
    ) -> UsageProviderRegistry {
        UsageProviderRegistry(
            featureAvailability: availability,
            claudeRequestCapture: claudeRequestCapture,
            codexHomeValidator: codexHomeValidator,
            codexExecutableResolver: {
                resolverCalls.withValue { $0 += 1 }
                return URL(fileURLWithPath: "/usr/bin/true")
            },
            codexExecutableValidator: executableValidator,
            codexFetchFactory: { _ in
                factoryCalls.withValue { $0 += 1 }
                return {
                    try Self.makeCodexReport(generation: 1)
                }
            },
            now: { self.now }
        )
    }

    private func makeLinkedCodexProfile(
        refreshInterval: TimeInterval = 30
    ) throws -> Profile {
        let home = try CodexHomeCanonicalizer().canonicalize(
            FileManager.default.temporaryDirectory.path
        )
        return Profile(
            name: "Codex",
            providerConfiguration: .codex(.init(linkedHome: home)),
            providerRevision: 7,
            refreshInterval: refreshInterval
        )
    }

    private func makeContext() -> UsageRefreshRequestContext {
        UsageRefreshRequestContext(
            trigger: .manual,
            requestedAt: now.addingTimeInterval(-1),
            presentationEpoch: 3
        )
    }

    nonisolated private static func makeCodexReport(
        generation: Int
    ) throws -> UsageReport {
        try UsageReport(
            providerID: .codex,
            account: ProviderAccount(
                displayName: "request-\(generation)"
            ),
            health: ProviderHealth(
                status: .healthy,
                checkedAt: Date(timeIntervalSinceReferenceDate: 50_000)
            ),
            limitGroups: [],
            fetchedAt: Date(timeIntervalSinceReferenceDate: 50_000)
        )
    }

    nonisolated private static func makeClaudeReport()
        throws -> UsageReport {
        try UsageReport(
            providerID: .claude,
            health: ProviderHealth(
                status: .healthy,
                checkedAt: Date(timeIntervalSinceReferenceDate: 50_000)
            ),
            limitGroups: [],
            fetchedAt: Date(timeIntervalSinceReferenceDate: 50_000)
        )
    }

    nonisolated private static func makeClaudeUsage(
        sessionTokensUsed: Int
    ) -> ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: sessionTokensUsed,
            sessionLimit: 100,
            sessionPercentage: Double(sessionTokensUsed),
            sessionResetTime: Date(timeIntervalSinceReferenceDate: 60_000),
            weeklyTokensUsed: 20,
            weeklyLimit: 100,
            weeklyPercentage: 20,
            weeklyResetTime: Date(timeIntervalSinceReferenceDate: 70_000),
            opusWeeklyTokensUsed: 0,
            opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0,
            sonnetWeeklyPercentage: 0,
            sonnetWeeklyResetTime: nil,
            fableWeeklyTokensUsed: 0,
            fableWeeklyPercentage: 0,
            fableWeeklyResetTime: nil,
            costUsed: nil,
            costLimit: nil,
            costCurrency: nil,
            lastUpdated: Date(timeIntervalSinceReferenceDate: 50_000),
            userTimezone: TimeZone(secondsFromGMT: 0)!
        )
    }

    nonisolated private static func makeAPIUsage(
        currentSpendCents: Int
    ) -> APIUsage {
        APIUsage(
            currentSpendCents: currentSpendCents,
            resetsAt: Date(timeIntervalSinceReferenceDate: 80_000),
            prepaidCreditsCents: 100,
            currency: "USD",
            apiTokenCostCents: nil,
            apiCostByModel: nil,
            costBySource: nil,
            dailyCostCents: nil
        )
    }

    private enum TestError: Error {
        case unexpected
        case secretBearingFailure
    }
}
