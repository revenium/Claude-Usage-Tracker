import AppKit
import XCTest
@testable import Claude_Usage

@MainActor
final class MenuReliabilityTests: HostedAppTestCase {
    private final class MenuTarget: NSObject {
        @objc func refresh() {}
        @objc func settings() {}
        @objc func quit() {}
    }

    private final class ThreadSafeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ value: String) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private final class Deferred<Value> {
        private var continuation: CheckedContinuation<Value, Never>?

        func wait() async -> Value {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func resolve(_ value: Value) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    private final class DeferredThrowing<Value> {
        private var continuation:
            CheckedContinuation<Value, Error>?

        func wait() async throws -> Value {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        }

        func resolve(_ result: Result<Value, Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    private final class RefreshRecorder {
        var loading: [Bool] = []
        var claudeCommits: [(UUID, Double, Bool)] = []
        var apiCommits: [(UUID, Int, Bool)] = []
        var presentations: [String] = []
        var failures: [String] = []
        var statuses: [ClaudeStatus] = []
        var sideEffects: [String] = []
        var batches:
            [TransitionalRefreshExecutor.BatchResult] = []
        var successfulBatches:
            [TransitionalRefreshExecutor.BatchResult] = []
    }

    func testContextMenuContainsExpectedLocalizedActionsAndShortcuts() {
        let target = MenuTarget()
        let menu = MenuBarManager.makeContextMenu(
            target: target,
            refreshAction: #selector(MenuTarget.refresh),
            settingsAction: #selector(MenuTarget.settings),
            quitAction: #selector(MenuTarget.quit)
        )

        XCTAssertEqual(menu.items.count, 4)

        let refresh = menu.items[0]
        XCTAssertEqual(refresh.title, "common.refresh".localized)
        XCTAssertEqual(refresh.action, #selector(MenuTarget.refresh))
        XCTAssertTrue(refresh.target === target)
        XCTAssertEqual(refresh.keyEquivalent, "")

        XCTAssertTrue(menu.items[1].isSeparatorItem)

        let settings = menu.items[2]
        XCTAssertEqual(settings.title, "common.settings".localized)
        XCTAssertEqual(settings.action, #selector(MenuTarget.settings))
        XCTAssertTrue(settings.target === target)
        XCTAssertEqual(settings.keyEquivalent, ",")
        XCTAssertEqual(settings.keyEquivalentModifierMask, .command)

        let quit = menu.items[3]
        XCTAssertEqual(quit.title, "common.quit".localized)
        XCTAssertEqual(quit.action, #selector(MenuTarget.quit))
        XCTAssertTrue(quit.target === target)
        XCTAssertEqual(quit.keyEquivalent, "q")
        XCTAssertEqual(quit.keyEquivalentModifierMask, .command)
    }

    func testPopoverCloseDebounceOnlySuppressesTheSameButtonBriefly() {
        let firstButton = NSObject()
        let secondButton = NSObject()
        let closeDate = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertTrue(
            MenuBarManager.shouldSuppressPopoverOpen(
                button: firstButton,
                lastButton: firstButton,
                lastCloseDate: closeDate,
                now: closeDate.addingTimeInterval(0.1)
            )
        )
        XCTAssertFalse(
            MenuBarManager.shouldSuppressPopoverOpen(
                button: secondButton,
                lastButton: firstButton,
                lastCloseDate: closeDate,
                now: closeDate.addingTimeInterval(0.1)
            )
        )
        XCTAssertFalse(
            MenuBarManager.shouldSuppressPopoverOpen(
                button: firstButton,
                lastButton: firstButton,
                lastCloseDate: closeDate,
                now: closeDate.addingTimeInterval(0.25)
            )
        )
    }

    func testCredentialChangeRoutingRefreshesOnlyAffectedVisibleProfiles() {
        let profileA = UUID()
        let profileB = UUID()

        let inactiveSingle = MenuBarManager.credentialChangeRouting(
            changedProfileID: profileA,
            activeProfileID: profileB,
            selectedProfileIDs: [],
            isMultiProfileMode: false
        )
        XCTAssertEqual(inactiveSingle.invalidation, .profile(profileA))
        XCTAssertFalse(inactiveSingle.shouldRefreshVisibleProfiles)

        let selectedMulti = MenuBarManager.credentialChangeRouting(
            changedProfileID: profileA,
            activeProfileID: profileB,
            selectedProfileIDs: [profileA],
            isMultiProfileMode: true
        )
        XCTAssertEqual(selectedMulti.invalidation, .profile(profileA))
        XCTAssertTrue(selectedMulti.shouldRefreshVisibleProfiles)

        let legacy = MenuBarManager.credentialChangeRouting(
            changedProfileID: nil,
            activeProfileID: profileB,
            selectedProfileIDs: [],
            isMultiProfileMode: false
        )
        XCTAssertEqual(legacy.invalidation, .allCapturedProfiles)
        XCTAssertTrue(legacy.shouldRefreshVisibleProfiles)
    }

    func testDeferredCredentialRefreshRechecksCapturedVisibilityScope() {
        let profileA = UUID()
        let profileB = UUID()
        let routingAtNotification =
            MenuBarManager.credentialChangeRouting(
                changedProfileID: profileA,
                activeProfileID: profileA,
                selectedProfileIDs: [],
                isMultiProfileMode: false
            )
        XCTAssertTrue(routingAtNotification.shouldRefreshVisibleProfiles)

        // The notification was eligible while A was active, but the observer's
        // deferred task must not refresh or mutate B after an intervening switch.
        var visibleRefreshes = 0
        if MenuBarManager.shouldExecuteCredentialRefresh(
            routingAtNotification,
            activeProfileID: profileB,
            selectedProfileIDs: [],
            isMultiProfileMode: false
        ) {
            visibleRefreshes += 1
        }
        XCTAssertEqual(visibleRefreshes, 0)

        let legacy = MenuBarManager.credentialChangeRouting(
            changedProfileID: nil,
            activeProfileID: profileA,
            selectedProfileIDs: [],
            isMultiProfileMode: false
        )
        XCTAssertTrue(
            MenuBarManager.shouldExecuteCredentialRefresh(
                legacy,
                activeProfileID: profileB,
                selectedProfileIDs: [],
                isMultiProfileMode: false
            )
        )
    }

    func testExecutorCapturesInitiatingOverageSettingBeforeAsyncWork()
        async throws {
        var activeIdentity:
            TransitionalRefreshExecutor.PresentationIdentity?
        let profile = Profile(
            name: "Initiating",
            claudeSessionKey: "SESSION_FIXTURE",
            organizationId: "org-fixture",
            checkOverageLimitEnabled: false
        )
        let service = retain(
            ClaudeAPIService(systemCredentialsReader: { nil })
        )
        activeIdentity = .init(profileID: profile.id, generation: 10)
        let plan = TransitionalRefreshExecutor.Plan.capture(
            profile: profile,
            mode: .single,
            presentationGeneration: 10,
            apiService: service
        )

        let fetched = expectation(description: "captured request fetched")
        let recorder = RefreshRecorder()
        let executor = makeRefreshExecutor(
            activeIdentity: { activeIdentity },
            recorder: recorder,
            fetchClaude: { request in
                XCTAssertEqual(
                    request.source,
                    .claudeAI(checkOverage: false)
                )
                fetched.fulfill()
                return self.makeClaudeUsage(12)
            },
            fetchAPI: { _ in self.makeAPIUsage(12) }
        )

        let task = executor.start(plan)
        await fulfillment(of: [fetched], timeout: 1)
        await task.value

        XCTAssertEqual(
            recorder.claudeCommits.map(\.0),
            [profile.id]
        )
    }

    func testExecutorCommitsDelayedResultsToAWithoutPresentingAfterAToB()
        async throws {
        let profileA = makeRefreshProfile(name: "A")
        let profileB = Profile(name: "B")
        var activeIdentity:
            TransitionalRefreshExecutor.PresentationIdentity? =
            .init(profileID: profileA.id, generation: 1)
        let service = retain(
            ClaudeAPIService(systemCredentialsReader: { nil })
        )
        let plan = TransitionalRefreshExecutor.Plan.capture(
            profile: profileA,
            mode: .single,
            presentationGeneration: 1,
            apiService: service
        )
        let claudeStarted = expectation(description: "Claude started")
        let apiStarted = expectation(description: "API started")
        let delayedClaude = Deferred<ClaudeUsage>()
        let delayedAPI = Deferred<APIUsage>()
        let recorder = RefreshRecorder()
        let executor = makeRefreshExecutor(
            activeIdentity: { activeIdentity },
            recorder: recorder,
            fetchClaude: { _ in
                claudeStarted.fulfill()
                return await delayedClaude.wait()
            },
            fetchAPI: { _ in
                apiStarted.fulfill()
                return await delayedAPI.wait()
            }
        )

        let task = executor.start(plan)
        await fulfillment(
            of: [claudeStarted, apiStarted],
            timeout: 1
        )
        activeIdentity = .init(profileID: profileB.id, generation: 2)
        executor.presentationIdentityDidChange(to: activeIdentity)
        delayedClaude.resolve(makeClaudeUsage(21))
        delayedAPI.resolve(makeAPIUsage(210))
        await task.value

        XCTAssertEqual(
            recorder.claudeCommits.map(\.0),
            [profileA.id]
        )
        XCTAssertEqual(recorder.claudeCommits.map(\.2), [false])
        XCTAssertEqual(recorder.apiCommits.map(\.0), [profileA.id])
        XCTAssertEqual(recorder.apiCommits.map(\.2), [false])
        XCTAssertTrue(recorder.presentations.isEmpty)
        XCTAssertEqual(recorder.loading, [true, false])
    }

    func testExecutorRejectsStalePresentationAfterAToBToA()
        async throws {
        let profileA = makeRefreshProfile(
            name: "A",
            includeAPI: false
        )
        let profileB = Profile(name: "B")
        var activeIdentity:
            TransitionalRefreshExecutor.PresentationIdentity? =
            .init(profileID: profileA.id, generation: 4)
        let service = retain(
            ClaudeAPIService(systemCredentialsReader: { nil })
        )
        let plan = TransitionalRefreshExecutor.Plan.capture(
            profile: profileA,
            mode: .single,
            presentationGeneration: 4,
            apiService: service
        )
        let started = expectation(description: "Claude started")
        let delayed = Deferred<ClaudeUsage>()
        let recorder = RefreshRecorder()
        let executor = makeRefreshExecutor(
            activeIdentity: { activeIdentity },
            recorder: recorder,
            fetchClaude: { _ in
                started.fulfill()
                return await delayed.wait()
            },
            fetchAPI: { _ in self.makeAPIUsage(1) }
        )

        let task = executor.start(plan)
        await fulfillment(of: [started], timeout: 1)
        activeIdentity = .init(profileID: profileB.id, generation: 5)
        executor.presentationIdentityDidChange(to: activeIdentity)
        activeIdentity = .init(profileID: profileA.id, generation: 6)
        executor.presentationIdentityDidChange(to: activeIdentity)
        delayed.resolve(makeClaudeUsage(31))
        await task.value

        XCTAssertEqual(
            recorder.claudeCommits.map(\.0),
            [profileA.id]
        )
        XCTAssertEqual(recorder.claudeCommits.map(\.2), [false])
        XCTAssertTrue(recorder.presentations.isEmpty)
    }

    func testExecutorClearsLoadingWhenActiveProfileBecomesNil()
        async throws {
        let profile = makeRefreshProfile(name: "A", includeAPI: false)
        var activeIdentity:
            TransitionalRefreshExecutor.PresentationIdentity? =
            .init(profileID: profile.id, generation: 7)
        let service = retain(
            ClaudeAPIService(systemCredentialsReader: { nil })
        )
        let plan = TransitionalRefreshExecutor.Plan.capture(
            profile: profile,
            mode: .single,
            presentationGeneration: 7,
            apiService: service
        )
        let started = expectation(description: "Claude started")
        let delayed = Deferred<ClaudeUsage>()
        let recorder = RefreshRecorder()
        let executor = makeRefreshExecutor(
            activeIdentity: { activeIdentity },
            recorder: recorder,
            fetchClaude: { _ in
                started.fulfill()
                return await delayed.wait()
            },
            fetchAPI: { _ in self.makeAPIUsage(1) }
        )

        let task = executor.start(plan)
        await fulfillment(of: [started], timeout: 1)
        activeIdentity = nil
        executor.presentationIdentityDidChange(to: nil)

        XCTAssertEqual(recorder.loading, [true, false])

        delayed.resolve(makeClaudeUsage(41))
        await task.value
        XCTAssertEqual(recorder.loading, [true, false])
        XCTAssertTrue(recorder.presentations.isEmpty)
    }

    func testSameIdentityPublicationKeepsValidExecutorCompletion()
        async throws {
        let profile = makeRefreshProfile(name: "A")
        let identity =
            TransitionalRefreshExecutor.PresentationIdentity(
                profileID: profile.id,
                generation: 8
            )
        var activeIdentity:
            TransitionalRefreshExecutor.PresentationIdentity? = identity
        let service = retain(
            ClaudeAPIService(systemCredentialsReader: { nil })
        )
        let plan = TransitionalRefreshExecutor.Plan.capture(
            profile: profile,
            mode: .single,
            presentationGeneration: 8,
            apiService: service
        )
        let started = expectation(description: "Claude started")
        let delayed = Deferred<ClaudeUsage>()
        let recorder = RefreshRecorder()
        let executor = makeRefreshExecutor(
            activeIdentity: { activeIdentity },
            recorder: recorder,
            fetchClaude: { _ in
                started.fulfill()
                return await delayed.wait()
            },
            fetchAPI: { _ in self.makeAPIUsage(510) }
        )

        let task = executor.start(plan)
        await fulfillment(of: [started], timeout: 1)
        activeIdentity = identity
        executor.presentationIdentityDidChange(to: identity)
        XCTAssertEqual(recorder.loading, [true])

        delayed.resolve(makeClaudeUsage(51))
        await task.value

        XCTAssertEqual(recorder.loading, [true, false])
        XCTAssertEqual(
            recorder.presentations.sorted(),
            ["api:A", "claude:A"]
        )
    }

    func testMultiProfileExecutorUsesPreTaskCredentialSnapshotsWithoutCrossAttribution()
        async throws {
        func credentials(_ token: String) -> String {
            """
            {"claudeAiOauth":{"accessToken":"\(token)"}}
            """
        }

        let profileA = makeRefreshProfile(
            name: "A",
            includeClaudeSession: false,
            apiSessionKey: "API_A",
            apiOrganizationID: "ORG_A"
        )
        let profileB = makeRefreshProfile(
            name: "B",
            includeClaudeSession: false,
            apiSessionKey: "API_B",
            apiOrganizationID: "ORG_B"
        )
        var systemCredentials = credentials("SYSTEM_A")
        let service = retain(
            ClaudeAPIService(
                systemCredentialsReader: { systemCredentials }
            )
        )
        let activeIdentity:
            TransitionalRefreshExecutor.PresentationIdentity? =
            .init(profileID: profileA.id, generation: 9)

        let planA = TransitionalRefreshExecutor.Plan.capture(
            profile: profileA,
            mode: .multi,
            presentationGeneration: 9,
            apiService: service
        )
        systemCredentials = credentials("SYSTEM_B")
        let planB = TransitionalRefreshExecutor.Plan.capture(
            profile: profileB,
            mode: .multi,
            presentationGeneration: 9,
            apiService: service
        )
        systemCredentials = credentials("MUTATED_AFTER_CAPTURE")

        let recorder = RefreshRecorder()
        let executor = makeRefreshExecutor(
            activeIdentity: { activeIdentity },
            recorder: recorder,
            fetchClaude: { request in
                if request.capturesOAuthToken("SYSTEM_A") {
                    return self.makeClaudeUsage(61)
                }
                if request.capturesOAuthToken("SYSTEM_B") {
                    return self.makeClaudeUsage(62)
                }
                XCTFail("Executor fetched with uncaptured system token")
                return self.makeClaudeUsage(0)
            },
            fetchAPI: { request in
                if request.capturesCredentials(
                    organizationID: "ORG_A",
                    apiSessionKey: "API_A"
                ) {
                    return self.makeAPIUsage(610)
                }
                if request.capturesCredentials(
                    organizationID: "ORG_B",
                    apiSessionKey: "API_B"
                ) {
                    return self.makeAPIUsage(620)
                }
                XCTFail("Executor fetched with cross-attributed API credentials")
                return self.makeAPIUsage(0)
            }
        )

        let task = executor.start(
            [planA, planB],
            loadingIdentity: activeIdentity
        )
        await task.value

        XCTAssertEqual(
            Dictionary(
                uniqueKeysWithValues:
                    recorder.claudeCommits.map { ($0.0, $0.1) }
            ),
            [profileA.id: 61, profileB.id: 62]
        )
        XCTAssertEqual(
            Dictionary(
                uniqueKeysWithValues:
                    recorder.apiCommits.map { ($0.0, $0.1) }
            ),
            [profileA.id: 610, profileB.id: 620]
        )
        XCTAssertEqual(
            recorder.presentations.sorted(),
            ["claude:A", "api:A"]
                .sorted()
        )
    }

    func testLatestSameProfileRequestWinsWithoutDuplicateLoadingClear()
        async throws {
        let profile = makeRefreshProfile(name: "A", includeAPI: false)
        let identity =
            TransitionalRefreshExecutor.PresentationIdentity(
                profileID: profile.id,
                generation: 40
            )
        let service = retain(
            ClaudeAPIService(systemCredentialsReader: { nil })
        )
        let plan = TransitionalRefreshExecutor.Plan.capture(
            profile: profile,
            mode: .single,
            presentationGeneration: 40,
            apiService: service
        )
        let firstStarted = expectation(description: "A1 started")
        let secondStarted = expectation(description: "A2 started")
        let first = Deferred<ClaudeUsage>()
        let second = Deferred<ClaudeUsage>()
        var fetchCount = 0
        let recorder = RefreshRecorder()
        let executor = makeRefreshExecutor(
            activeIdentity: { identity },
            recorder: recorder,
            fetchClaude: { _ in
                fetchCount += 1
                if fetchCount == 1 {
                    firstStarted.fulfill()
                    return await first.wait()
                }
                secondStarted.fulfill()
                return await second.wait()
            },
            fetchAPI: { _ in self.makeAPIUsage(0) }
        )

        let oldTask = executor.start(plan)
        await fulfillment(of: [firstStarted], timeout: 1)
        let newTask = executor.start(plan)
        await fulfillment(of: [secondStarted], timeout: 1)
        second.resolve(makeClaudeUsage(72))
        await newTask.value
        first.resolve(makeClaudeUsage(71))
        await oldTask.value

        XCTAssertEqual(recorder.claudeCommits.map(\.1), [72])
        XCTAssertEqual(recorder.presentations, ["claude:A"])
        XCTAssertEqual(recorder.loading, [true, false])
        XCTAssertEqual(recorder.batches.count, 1)
        XCTAssertEqual(recorder.successfulBatches.count, 1)
        XCTAssertEqual(
            recorder.sideEffects.filter {
                $0 == "notification:A"
                    || $0 == "auto-switch:A"
                    || $0 == "circuit-success"
            }.sorted(),
            ["auto-switch:A", "circuit-success", "notification:A"]
        )
    }

    func testNewerSuccessSuppressesOlderSameProfileError()
        async throws {
        let profile = makeRefreshProfile(name: "A", includeAPI: false)
        let identity =
            TransitionalRefreshExecutor.PresentationIdentity(
                profileID: profile.id,
                generation: 41
            )
        let service = retain(
            ClaudeAPIService(systemCredentialsReader: { nil })
        )
        let plan = TransitionalRefreshExecutor.Plan.capture(
            profile: profile,
            mode: .single,
            presentationGeneration: 41,
            apiService: service
        )
        let oldStarted = expectation(description: "old A started")
        let oldResult = DeferredThrowing<ClaudeUsage>()
        var fetchCount = 0
        let recorder = RefreshRecorder()
        let executor = makeRefreshExecutor(
            activeIdentity: { identity },
            recorder: recorder,
            fetchClaude: { _ in
                fetchCount += 1
                if fetchCount == 1 {
                    oldStarted.fulfill()
                    return try await oldResult.wait()
                }
                return self.makeClaudeUsage(82)
            },
            fetchAPI: { _ in self.makeAPIUsage(0) }
        )

        let oldTask = executor.start(plan)
        await fulfillment(of: [oldStarted], timeout: 1)
        let newTask = executor.start(plan)
        await newTask.value
        oldResult.resolve(.failure(RefreshHarnessError.expected))
        await oldTask.value

        XCTAssertEqual(recorder.claudeCommits.map(\.1), [82])
        XCTAssertTrue(recorder.failures.isEmpty)
        XCTAssertFalse(
            recorder.sideEffects.contains("circuit-failure:A")
        )
        XCTAssertEqual(recorder.loading, [true, false])
    }

    func testSingleProfileOlderStatusCannotOverwriteNewerStatus()
        async throws {
        let profile = makeRefreshProfile(name: "A", includeAPI: false)
        let identity =
            TransitionalRefreshExecutor.PresentationIdentity(
                profileID: profile.id,
                generation: 42
            )
        let service = retain(
            ClaudeAPIService(systemCredentialsReader: { nil })
        )
        let plan = TransitionalRefreshExecutor.Plan.capture(
            profile: profile,
            mode: .single,
            presentationGeneration: 42,
            apiService: service
        )
        let oldStatusStarted = expectation(description: "old status")
        let oldStatus = Deferred<ClaudeStatus>()
        var statusCount = 0
        let recorder = RefreshRecorder()
        let executor = makeRefreshExecutor(
            activeIdentity: { identity },
            recorder: recorder,
            fetchClaude: { _ in self.makeClaudeUsage(1) },
            fetchAPI: { _ in self.makeAPIUsage(0) },
            fetchStatus: {
                statusCount += 1
                if statusCount == 1 {
                    oldStatusStarted.fulfill()
                    return await oldStatus.wait()
                }
                return .operational
            }
        )

        let oldTask = executor.start(plan)
        await fulfillment(of: [oldStatusStarted], timeout: 1)
        let newTask = executor.start(plan)
        await newTask.value
        oldStatus.resolve(
            ClaudeStatus(indicator: .major, description: "Old")
        )
        await oldTask.value

        XCTAssertEqual(recorder.statuses, [.operational])
    }

    func testMultiProfileOlderStatusCannotOverwriteNewerStatus()
        async throws {
        let profile = makeRefreshProfile(name: "B", includeAPI: false)
        let activeID = UUID()
        let identity =
            TransitionalRefreshExecutor.PresentationIdentity(
                profileID: activeID,
                generation: 43
            )
        let service = retain(
            ClaudeAPIService(systemCredentialsReader: { nil })
        )
        let plan = TransitionalRefreshExecutor.Plan.capture(
            profile: profile,
            mode: .multi,
            presentationGeneration: 43,
            apiService: service
        )
        let oldStatusStarted = expectation(description: "old multi status")
        let oldStatus = Deferred<ClaudeStatus>()
        var statusCount = 0
        let recorder = RefreshRecorder()
        let executor = makeRefreshExecutor(
            activeIdentity: { identity },
            recorder: recorder,
            fetchClaude: { _ in self.makeClaudeUsage(1) },
            fetchAPI: { _ in self.makeAPIUsage(0) },
            fetchStatus: {
                statusCount += 1
                if statusCount == 1 {
                    oldStatusStarted.fulfill()
                    return await oldStatus.wait()
                }
                return .operational
            }
        )

        let oldTask = executor.start(
            [plan],
            loadingIdentity: identity
        )
        await fulfillment(of: [oldStatusStarted], timeout: 1)
        let newTask = executor.start(
            [plan],
            loadingIdentity: identity
        )
        await newTask.value
        oldStatus.resolve(
            ClaudeStatus(indicator: .major, description: "Old")
        )
        await oldTask.value

        XCTAssertEqual(recorder.statuses, [.operational])
    }

    func testMultiBatchFinalizesWhenActiveProfileIsNotSelected()
        async throws {
        let activeID = UUID()
        let identity =
            TransitionalRefreshExecutor.PresentationIdentity(
                profileID: activeID,
                generation: 44
            )
        let profileB = makeRefreshProfile(name: "B", includeAPI: false)
        let profileC = makeRefreshProfile(name: "C", includeAPI: false)
        let service = retain(
            ClaudeAPIService(systemCredentialsReader: { nil })
        )
        let plans = [profileB, profileC].map {
            TransitionalRefreshExecutor.Plan.capture(
                profile: $0,
                mode: .multi,
                presentationGeneration: 44,
                apiService: service
            )
        }
        let recorder = RefreshRecorder()
        let executor = makeRefreshExecutor(
            activeIdentity: { identity },
            recorder: recorder,
            fetchClaude: { _ in self.makeClaudeUsage(91) },
            fetchAPI: { _ in self.makeAPIUsage(0) }
        )

        let task = executor.start(plans, loadingIdentity: identity)
        await task.value

        XCTAssertEqual(
            Set(recorder.claudeCommits.map(\.0)),
            Set([profileB.id, profileC.id])
        )
        XCTAssertTrue(recorder.presentations.isEmpty)
        XCTAssertEqual(recorder.batches.count, 1)
        XCTAssertEqual(recorder.successfulBatches.count, 1)
        XCTAssertFalse(
            recorder.sideEffects.contains {
                $0.hasPrefix("notification:")
                    || $0.hasPrefix("auto-switch:")
                    || $0.hasPrefix("statusline:")
            }
        )
        XCTAssertEqual(recorder.loading, [true, false])
    }

    func testDeletedProfileRejectsClaudeAndAPICommitBeforeHistory()
        async throws {
        let profile = makeRefreshProfile(name: "A")
        let identity =
            TransitionalRefreshExecutor.PresentationIdentity(
                profileID: profile.id,
                generation: 45
            )
        let service = retain(
            ClaudeAPIService(systemCredentialsReader: { nil })
        )
        let plan = TransitionalRefreshExecutor.Plan.capture(
            profile: profile,
            mode: .single,
            presentationGeneration: 45,
            apiService: service
        )
        let claudeStarted = expectation(description: "Claude delayed")
        let apiStarted = expectation(description: "API delayed")
        let claude = Deferred<ClaudeUsage>()
        let api = Deferred<APIUsage>()
        var writable = true
        let recorder = RefreshRecorder()
        let executor = makeRefreshExecutor(
            activeIdentity: { identity },
            recorder: recorder,
            isProfileWritable: { _ in writable },
            fetchClaude: { _ in
                claudeStarted.fulfill()
                return await claude.wait()
            },
            fetchAPI: { _ in
                apiStarted.fulfill()
                return await api.wait()
            }
        )

        let task = executor.start(plan)
        await fulfillment(
            of: [claudeStarted, apiStarted],
            timeout: 1
        )
        writable = false
        claude.resolve(makeClaudeUsage(92))
        api.resolve(makeAPIUsage(920))
        await task.value

        XCTAssertTrue(recorder.claudeCommits.isEmpty)
        XCTAssertTrue(recorder.apiCommits.isEmpty)
        XCTAssertTrue(recorder.presentations.isEmpty)
        XCTAssertTrue(recorder.failures.isEmpty)
        XCTAssertTrue(recorder.successfulBatches.isEmpty)
        XCTAssertFalse(
            recorder.sideEffects.contains {
                $0.contains("history")
                    || $0.contains("save")
                    || $0.contains("notification")
                    || $0.contains("auto-switch")
                    || $0.contains("circuit-success")
                    || $0.contains("circuit-failure")
            }
        )
    }

    func testCredentialNotificationsInvalidateCapturedResultsAndStatus()
        async throws {
        let profile = makeRefreshProfile(name: "A")
        let identity =
            TransitionalRefreshExecutor.PresentationIdentity(
                profileID: profile.id,
                generation: 46
            )
        let service = retain(
            ClaudeAPIService(systemCredentialsReader: { nil })
        )
        let plan = TransitionalRefreshExecutor.Plan.capture(
            profile: profile,
            mode: .single,
            presentationGeneration: 46,
            apiService: service
        )
        let recorder = RefreshRecorder()
        let claude = Deferred<ClaudeUsage>()
        let api = Deferred<APIUsage>()
        let status = Deferred<ClaudeStatus>()
        let started = expectation(description: "all first requests")
        started.expectedFulfillmentCount = 3
        let executor = makeRefreshExecutor(
            activeIdentity: { identity },
            recorder: recorder,
            fetchClaude: { _ in
                started.fulfill()
                return await claude.wait()
            },
            fetchAPI: { _ in
                started.fulfill()
                return await api.wait()
            },
            fetchStatus: {
                started.fulfill()
                return await status.wait()
            }
        )

        let task = executor.start(plan)
        await fulfillment(of: [started], timeout: 1)
        executor.invalidate(profileID: profile.id)
        claude.resolve(makeClaudeUsage(93))
        api.resolve(makeAPIUsage(930))
        status.resolve(.operational)
        await task.value

        XCTAssertEqual(recorder.loading, [true, false])
        XCTAssertTrue(recorder.claudeCommits.isEmpty)
        XCTAssertTrue(recorder.apiCommits.isEmpty)
        XCTAssertTrue(recorder.presentations.isEmpty)
        XCTAssertTrue(recorder.failures.isEmpty)
        XCTAssertTrue(recorder.statuses.isEmpty)
        XCTAssertTrue(recorder.batches.isEmpty)
        XCTAssertTrue(recorder.sideEffects.isEmpty)

        XCTAssertEqual(
            MenuBarManager.credentialChangeProfileID(
                from: Notification(
                    name: .credentialsChanged,
                    object: profile.id,
                    userInfo: nil
                )
            ),
            profile.id
        )
        XCTAssertEqual(
            MenuBarManager.credentialChangeProfileID(
                from: Notification(
                    name: .credentialsChanged,
                    object: nil,
                    userInfo: ["profileID": profile.id]
                )
            ),
            profile.id
        )
        XCTAssertNil(
            MenuBarManager.credentialChangeProfileID(
                from: Notification(name: .credentialsChanged)
            )
        )
    }

    func testLegacyCredentialInvalidationSupersedesAllCapturedProfiles()
        async throws {
        let profile = makeRefreshProfile(
            name: "A",
            includeAPI: false
        )
        let identity =
            TransitionalRefreshExecutor.PresentationIdentity(
                profileID: profile.id,
                generation: 47
            )
        let service = retain(
            ClaudeAPIService(systemCredentialsReader: { nil })
        )
        let plan = TransitionalRefreshExecutor.Plan.capture(
            profile: profile,
            mode: .single,
            presentationGeneration: 47,
            apiService: service
        )
        let started = expectation(description: "legacy refresh")
        let claude = Deferred<ClaudeUsage>()
        let status = Deferred<ClaudeStatus>()
        let statusStarted = expectation(description: "legacy status")
        let recorder = RefreshRecorder()
        let executor = makeRefreshExecutor(
            activeIdentity: { identity },
            recorder: recorder,
            fetchClaude: { _ in
                started.fulfill()
                return await claude.wait()
            },
            fetchAPI: { _ in self.makeAPIUsage(0) },
            fetchStatus: {
                statusStarted.fulfill()
                return await status.wait()
            }
        )

        let task = executor.start(plan)
        await fulfillment(
            of: [started, statusStarted],
            timeout: 1
        )
        executor.invalidateAllCapturedProfiles()
        claude.resolve(makeClaudeUsage(94))
        status.resolve(.operational)
        await task.value

        XCTAssertEqual(recorder.loading, [true, false])
        XCTAssertTrue(recorder.sideEffects.isEmpty)
        XCTAssertTrue(recorder.batches.isEmpty)
    }

    func testBatchFreshnessRequiresAnyCoreSuccessAndIgnoresAPIFailure()
        async throws {
        let identity =
            TransitionalRefreshExecutor.PresentationIdentity(
                profileID: UUID(),
                generation: 48
            )
        let service = retain(
            ClaudeAPIService(systemCredentialsReader: { nil })
        )

        let allFailedRecorder = RefreshRecorder()
        let allFailed = makeRefreshExecutor(
            activeIdentity: { identity },
            recorder: allFailedRecorder,
            fetchClaude: { _ in throw RefreshHarnessError.expected },
            fetchAPI: { _ in throw RefreshHarnessError.expected }
        )
        let failedProfiles = [
            makeRefreshProfile(name: "F1", includeAPI: false),
            makeRefreshProfile(name: "F2", includeAPI: false)
        ]
        let failedPlans = failedProfiles.map {
            TransitionalRefreshExecutor.Plan.capture(
                profile: $0,
                mode: .multi,
                presentationGeneration: 48,
                apiService: service
            )
        }
        await allFailed.start(
            failedPlans,
            loadingIdentity: identity
        ).value

        XCTAssertEqual(allFailedRecorder.batches.count, 1)
        XCTAssertFalse(
            allFailedRecorder.batches[0].hasCoreSuccess
        )
        XCTAssertTrue(allFailedRecorder.successfulBatches.isEmpty)

        let partialRecorder = RefreshRecorder()
        let partial = makeRefreshExecutor(
            activeIdentity: { identity },
            recorder: partialRecorder,
            fetchClaude: { _ in self.makeClaudeUsage(95) },
            fetchAPI: { _ in throw RefreshHarnessError.expected }
        )
        let good = makeRefreshProfile(name: "Good")
        let missingCore = Profile(name: "Missing")
        let partialPlans = [good, missingCore].map {
            TransitionalRefreshExecutor.Plan.capture(
                profile: $0,
                mode: .multi,
                presentationGeneration: 48,
                apiService: service
            )
        }
        await partial.start(
            partialPlans,
            loadingIdentity: identity
        ).value

        XCTAssertEqual(partialRecorder.batches.count, 1)
        XCTAssertTrue(partialRecorder.batches[0].hasCoreSuccess)
        XCTAssertEqual(partialRecorder.successfulBatches.count, 1)
        XCTAssertTrue(
            partialRecorder.failures.contains("api:Good:false")
        )
    }

    func testStartingBDoesNotSupersedeSafeAPersistence()
        async throws {
        let profileA = makeRefreshProfile(name: "A", includeAPI: false)
        let profileB = makeRefreshProfile(name: "B", includeAPI: false)
        var activeIdentity:
            TransitionalRefreshExecutor.PresentationIdentity? =
            .init(profileID: profileA.id, generation: 50)
        let service = retain(
            ClaudeAPIService(systemCredentialsReader: { nil })
        )
        let planA = TransitionalRefreshExecutor.Plan.capture(
            profile: profileA,
            mode: .single,
            presentationGeneration: 50,
            apiService: service
        )
        let planB = TransitionalRefreshExecutor.Plan.capture(
            profile: profileB,
            mode: .single,
            presentationGeneration: 51,
            apiService: service
        )
        let aStarted = expectation(description: "A started")
        let bStarted = expectation(description: "B started")
        let oldStatusStarted = expectation(description: "A status")
        let aUsage = Deferred<ClaudeUsage>()
        let bUsage = Deferred<ClaudeUsage>()
        let aStatus = Deferred<ClaudeStatus>()
        var usageFetchCount = 0
        var statusFetchCount = 0
        let recorder = RefreshRecorder()
        let executor = makeRefreshExecutor(
            activeIdentity: { activeIdentity },
            recorder: recorder,
            fetchClaude: { _ in
                usageFetchCount += 1
                if usageFetchCount == 1 {
                    aStarted.fulfill()
                    return await aUsage.wait()
                }
                bStarted.fulfill()
                return await bUsage.wait()
            },
            fetchAPI: { _ in self.makeAPIUsage(0) },
            fetchStatus: {
                statusFetchCount += 1
                if statusFetchCount == 1 {
                    oldStatusStarted.fulfill()
                    return await aStatus.wait()
                }
                return .operational
            }
        )

        let aTask = executor.start(planA)
        await fulfillment(
            of: [aStarted, oldStatusStarted],
            timeout: 1
        )
        activeIdentity = .init(
            profileID: profileB.id,
            generation: 51
        )
        executor.presentationIdentityDidChange(to: activeIdentity)
        let bTask = executor.start(planB)
        await fulfillment(of: [bStarted], timeout: 1)
        bUsage.resolve(makeClaudeUsage(102))
        await bTask.value

        aUsage.resolve(makeClaudeUsage(101))
        aStatus.resolve(
            ClaudeStatus(indicator: .major, description: "Old A")
        )
        await aTask.value

        XCTAssertEqual(
            Dictionary(
                uniqueKeysWithValues:
                    recorder.claudeCommits.map { ($0.0, $0.1) }
            ),
            [profileA.id: 101, profileB.id: 102]
        )
        XCTAssertEqual(recorder.presentations, ["claude:B"])
        XCTAssertEqual(recorder.batches.count, 1)
        XCTAssertEqual(recorder.successfulBatches.count, 1)
        XCTAssertEqual(recorder.statuses, [.operational])
        XCTAssertEqual(
            recorder.sideEffects.filter {
                $0.hasPrefix("notification:")
                    || $0.hasPrefix("auto-switch:")
                    || $0.hasPrefix("statusline:")
            }.sorted(),
            ["auto-switch:B", "notification:B", "statusline:B"]
        )
        XCTAssertEqual(
            recorder.loading,
            [true, false, true, false]
        )
    }

    func testInvalidatingOneMultiProfileDiscardsOnlyThatProfileButSuppressesBatchHooks()
        async throws {
        func credentials(_ token: String) -> String {
            """
            {"claudeAiOauth":{"accessToken":"\(token)"}}
            """
        }

        let profileA = makeRefreshProfile(
            name: "A",
            includeClaudeSession: false,
            includeAPI: false
        )
        let profileB = makeRefreshProfile(
            name: "B",
            includeClaudeSession: false,
            includeAPI: false
        )
        var systemCredentials = credentials("MULTI_A")
        let service = retain(
            ClaudeAPIService(
                systemCredentialsReader: { systemCredentials }
            )
        )
        let identity =
            TransitionalRefreshExecutor.PresentationIdentity(
                profileID: profileA.id,
                generation: 52
            )
        let planA = TransitionalRefreshExecutor.Plan.capture(
            profile: profileA,
            mode: .multi,
            presentationGeneration: 52,
            apiService: service
        )
        systemCredentials = credentials("MULTI_B")
        let planB = TransitionalRefreshExecutor.Plan.capture(
            profile: profileB,
            mode: .multi,
            presentationGeneration: 52,
            apiService: service
        )
        let aStarted = expectation(description: "multi A started")
        let bStarted = expectation(description: "multi B started")
        let statusStarted = expectation(description: "multi status")
        let aUsage = Deferred<ClaudeUsage>()
        let bUsage = Deferred<ClaudeUsage>()
        let delayedStatus = Deferred<ClaudeStatus>()
        let recorder = RefreshRecorder()
        let executor = makeRefreshExecutor(
            activeIdentity: { identity },
            recorder: recorder,
            fetchClaude: { request in
                if request.capturesOAuthToken("MULTI_A") {
                    aStarted.fulfill()
                    return await aUsage.wait()
                }
                bStarted.fulfill()
                return await bUsage.wait()
            },
            fetchAPI: { _ in self.makeAPIUsage(0) },
            fetchStatus: {
                statusStarted.fulfill()
                return await delayedStatus.wait()
            }
        )

        let task = executor.start(
            [planA, planB],
            loadingIdentity: identity
        )
        await fulfillment(
            of: [aStarted, bStarted, statusStarted],
            timeout: 1
        )
        executor.invalidate(profileID: profileA.id)
        aUsage.resolve(makeClaudeUsage(111))
        bUsage.resolve(makeClaudeUsage(112))
        delayedStatus.resolve(.operational)
        await task.value

        XCTAssertEqual(
            recorder.claudeCommits.map(\.0),
            [profileB.id]
        )
        XCTAssertTrue(recorder.presentations.isEmpty)
        XCTAssertTrue(recorder.statuses.isEmpty)
        XCTAssertTrue(recorder.batches.isEmpty)
        XCTAssertTrue(recorder.successfulBatches.isEmpty)
        XCTAssertEqual(recorder.loading, [true, false])
        XCTAssertTrue(
            recorder.sideEffects.contains("claude-history:B")
        )
        XCTAssertTrue(
            recorder.sideEffects.contains("claude-save:B")
        )
        XCTAssertFalse(
            recorder.sideEffects.contains {
                $0 == "batch-finalized"
                    || $0 == "circuit-success"
                    || $0 == "status"
                    || $0.contains(":A")
            }
        )
    }

    func testProductionSinkPublishesOnlyAfterDurableCommitAcceptance()
        async throws {
        let profile = makeRefreshProfile(name: "A", includeAPI: false)
        let identity =
            TransitionalRefreshExecutor.PresentationIdentity(
                profileID: profile.id,
                generation: 53
            )
        let service = retain(
            ClaudeAPIService(systemCredentialsReader: { nil })
        )
        let plan = TransitionalRefreshExecutor.Plan.capture(
            profile: profile,
            mode: .single,
            presentationGeneration: 53,
            apiService: service
        )

        let rejectedRecorder = RefreshRecorder()
        let rejected = makeRefreshExecutor(
            activeIdentity: { identity },
            recorder: rejectedRecorder,
            acceptClaudeSave: { _ in false },
            fetchClaude: { _ in self.makeClaudeUsage(121) },
            fetchAPI: { _ in self.makeAPIUsage(0) }
        )
        await rejected.start(plan).value

        XCTAssertTrue(rejectedRecorder.claudeCommits.isEmpty)
        XCTAssertFalse(
            rejectedRecorder.sideEffects.contains("claude-history:A")
        )
        XCTAssertTrue(rejectedRecorder.presentations.isEmpty)
        XCTAssertTrue(rejectedRecorder.successfulBatches.isEmpty)
        XCTAssertFalse(
            rejectedRecorder.sideEffects.contains {
                $0 == "notification:A"
                    || $0 == "auto-switch:A"
                    || $0 == "circuit-success"
            }
        )

        let acceptedRecorder = RefreshRecorder()
        let accepted = makeRefreshExecutor(
            activeIdentity: { identity },
            recorder: acceptedRecorder,
            fetchClaude: { _ in self.makeClaudeUsage(122) },
            fetchAPI: { _ in self.makeAPIUsage(0) }
        )
        await accepted.start(plan).value

        XCTAssertEqual(acceptedRecorder.claudeCommits.map(\.1), [122])
        XCTAssertTrue(
            acceptedRecorder.sideEffects.contains("claude-history:A")
        )
        XCTAssertEqual(
            acceptedRecorder.presentations,
            ["claude:A"]
        )
        XCTAssertEqual(acceptedRecorder.successfulBatches.count, 1)
        XCTAssertTrue(
            acceptedRecorder.sideEffects.contains("circuit-success")
        )
    }

    private func makeRefreshExecutor(
        activeIdentity:
            @escaping () ->
                TransitionalRefreshExecutor.PresentationIdentity?,
        recorder: RefreshRecorder,
        isProfileWritable: @escaping (UUID) -> Bool = { _ in true },
        acceptClaudeSave: @escaping (UUID) -> Bool = { _ in true },
        acceptAPISave: @escaping (UUID) -> Bool = { _ in true },
        fetchClaude:
            @escaping (ClaudeAPIService.CapturedUsageRequest)
                async throws -> ClaudeUsage,
        fetchAPI:
            @escaping (ClaudeAPIService.CapturedAPIUsageRequest)
                async throws -> APIUsage,
        fetchStatus:
            @escaping () async throws -> ClaudeStatus = {
                .operational
            }
    ) -> TransitionalRefreshExecutor {
        let sink = retain(
            MenuBarManager.RefreshSideEffectSink(
                hooks: .init(
                    isProfileWritable: isProfileWritable,
                    recordClaude: { plan, _ in
                        recorder.sideEffects.append(
                            "claude-history:\(plan.profileName)"
                        )
                    },
                    saveClaude: { plan, usage, shouldPresent in
                        guard acceptClaudeSave(plan.profileID) else {
                            recorder.sideEffects.append(
                                "claude-save-rejected:\(plan.profileName)"
                            )
                            return false
                        }
                        recorder.claudeCommits.append(
                            (
                                plan.profileID,
                                usage.sessionPercentage,
                                shouldPresent
                            )
                        )
                        recorder.sideEffects.append(
                            "claude-save:\(plan.profileName)"
                        )
                        return true
                    },
                    publishClaude: { plan, _ in
                        recorder.presentations.append(
                            "claude:\(plan.profileName)"
                        )
                    },
                    writeStatusline: { plan, _ in
                        recorder.sideEffects.append(
                            "statusline:\(plan.profileName)"
                        )
                    },
                    notify: { plan, _ in
                        recorder.sideEffects.append(
                            "notification:\(plan.profileName)"
                        )
                    },
                    autoSwitch: { plan, _ in
                        recorder.sideEffects.append(
                            "auto-switch:\(plan.profileName)"
                        )
                    },
                    recordAPI: { plan, _ in
                        recorder.sideEffects.append(
                            "api-history:\(plan.profileName)"
                        )
                    },
                    saveAPI: { plan, usage, shouldPresent in
                        guard acceptAPISave(plan.profileID) else {
                            recorder.sideEffects.append(
                                "api-save-rejected:\(plan.profileName)"
                            )
                            return false
                        }
                        recorder.apiCommits.append(
                            (
                                plan.profileID,
                                usage.currentSpendCents,
                                shouldPresent
                            )
                        )
                        recorder.sideEffects.append(
                            "api-save:\(plan.profileName)"
                        )
                        return true
                    },
                    publishAPI: { plan, _ in
                        recorder.presentations.append(
                            "api:\(plan.profileName)"
                        )
                    },
                    claudeFailed: { plan, _, shouldPresent in
                        recorder.failures.append(
                            "claude:\(plan.profileName):\(shouldPresent)"
                        )
                        recorder.sideEffects.append(
                            "circuit-failure:\(plan.profileName)"
                        )
                    },
                    apiFailed: { plan, _, shouldPresent in
                        recorder.failures.append(
                            "api:\(plan.profileName):\(shouldPresent)"
                        )
                    },
                    presentStatus: {
                        recorder.statuses.append($0)
                        recorder.sideEffects.append("status")
                    },
                    statusFailed: { _ in
                        recorder.failures.append("status")
                    },
                    batchFinalized: {
                        recorder.batches.append($0)
                        recorder.sideEffects.append("batch-finalized")
                    },
                    batchSucceeded: {
                        recorder.successfulBatches.append($0)
                        recorder.sideEffects.append("circuit-success")
                    }
                )
            )
        )
        return TransitionalRefreshExecutor(
            hooks: .init(
                currentPresentationIdentity: activeIdentity,
                isProfileWritable: {
                    sink.isProfileWritable($0)
                },
                setLoading: { recorder.loading.append($0) },
                fetchClaude: fetchClaude,
                fetchAPI: fetchAPI,
                fetchStatus: fetchStatus,
                commitClaude: { plan, usage, shouldPresent in
                    sink.commitClaude(
                        plan,
                        usage: usage,
                        shouldPresent: shouldPresent
                    )
                },
                presentClaude: { plan, usage in
                    sink.presentClaude(
                        plan,
                        usage: usage
                    )
                },
                commitAPI: { plan, usage, shouldPresent in
                    sink.commitAPI(
                        plan,
                        usage: usage,
                        shouldPresent: shouldPresent
                    )
                },
                presentAPI: { plan, usage in
                    sink.presentAPI(
                        plan,
                        usage: usage
                    )
                },
                claudeFailed: { plan, error, shouldPresent in
                    sink.claudeFailed(
                        plan,
                        error: error,
                        shouldPresent: shouldPresent
                    )
                },
                apiFailed: { plan, error, shouldPresent in
                    sink.apiFailed(
                        plan,
                        error: error,
                        shouldPresent: shouldPresent
                    )
                },
                presentStatus: { sink.presentStatus($0) },
                statusFailed: { sink.statusFailed($0) },
                batchFinished: { sink.finishBatch($0) }
            )
        )
    }

    private func makeRefreshProfile(
        name: String,
        includeClaudeSession: Bool = true,
        includeAPI: Bool = true,
        apiSessionKey: String = "API_FIXTURE",
        apiOrganizationID: String = "API_ORG_FIXTURE"
    ) -> Profile {
        Profile(
            name: name,
            claudeSessionKey:
                includeClaudeSession ? "SESSION_\(name)" : nil,
            organizationId:
                includeClaudeSession ? "ORG_\(name)" : nil,
            apiSessionKey: includeAPI ? apiSessionKey : nil,
            apiOrganizationId:
                includeAPI ? apiOrganizationID : nil
        )
    }

    private func makeClaudeUsage(_ percentage: Double) -> ClaudeUsage {
        var usage = ClaudeUsage.empty
        usage.sessionPercentage = percentage
        return usage
    }

    private func makeAPIUsage(_ currentSpendCents: Int) -> APIUsage {
        APIUsage(
            currentSpendCents: currentSpendCents,
            resetsAt: Date(timeIntervalSince1970: 1_900_000_000),
            prepaidCreditsCents: 10_000,
            currency: "USD",
            apiTokenCostCents: nil,
            apiCostByModel: nil,
            costBySource: nil,
            dailyCostCents: nil
        )
    }

    func testImageFingerprintUsesStableCGImageBytes() {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 4, height: 4)).fill()
        image.unlockFocus()

        let first = StatusBarUIManager.imageFingerprint(image)
        let second = StatusBarUIManager.imageFingerprint(image)

        XCTAssertNotNil(first)
        XCTAssertFalse(first?.isEmpty ?? true)
        XCTAssertEqual(first, second)
    }

    func testBorderlessSettingsWindowRecognizesCommandW() {
        XCTAssertTrue(
            BorderlessSettingsWindow.isCloseShortcut(
                modifierFlags: .command,
                charactersIgnoringModifiers: "w"
            )
        )
        XCTAssertTrue(
            BorderlessSettingsWindow.isCloseShortcut(
                modifierFlags: [.command, .shift],
                charactersIgnoringModifiers: "W"
            )
        )
        XCTAssertFalse(
            BorderlessSettingsWindow.isCloseShortcut(
                modifierFlags: [],
                charactersIgnoringModifiers: "w"
            )
        )
        XCTAssertFalse(
            BorderlessSettingsWindow.isCloseShortcut(
                modifierFlags: .command,
                charactersIgnoringModifiers: "q"
            )
        )
    }

    func testMenuBarNotificationIsEnqueuedAfterPendingProfileMutation() {
        let center = NotificationCenter()
        let queue = DispatchQueue(label: "MenuReliabilityTests.notification-order")
        let recorder = ThreadSafeRecorder()
        let notificationName = Notification.Name("MenuReliabilityTests.notification")
        let notificationPosted = expectation(description: "notification posted")

        let observer = center.addObserver(
            forName: notificationName,
            object: nil,
            queue: nil
        ) { _ in
            recorder.append("notification")
            notificationPosted.fulfill()
        }
        defer { center.removeObserver(observer) }

        // ProfileManager enqueues its mutation first. The view helper must enqueue
        // the notification second on the same serial queue.
        queue.async {
            recorder.append("mutation")
        }
        ManageProfilesView.enqueueMenuBarNotification(
            notificationName,
            queue: queue,
            center: center
        )

        wait(for: [notificationPosted], timeout: 1)
        XCTAssertEqual(recorder.snapshot(), ["mutation", "notification"])
    }

    func testProfileDeletionErrorUsesIntentionallyAuthoredLocalizedDescription() {
        let presentation = ProfileDeletionErrorPresentation(
            error: LocalizedDeletionError.expected
        )

        XCTAssertEqual(presentation.message, "Safe deletion failure")
    }

    func testProfileDeletionErrorDoesNotExposeOpaqueErrorPayload() {
        let secret = "DELETE_ERROR_SECRET_FIXTURE"
        let opaqueError = NSError(
            domain: "MenuReliabilityTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: secret]
        )

        let presentation = ProfileDeletionErrorPresentation(error: opaqueError)

        XCTAssertEqual(
            presentation.message,
            ProfileDeletionErrorPresentation.genericMessage
        )
        XCTAssertFalse(presentation.message.contains(secret))
    }
}

private enum LocalizedDeletionError: LocalizedError {
    case expected

    var errorDescription: String? {
        "Safe deletion failure"
    }
}

private enum RefreshHarnessError: Error {
    case expected
}
