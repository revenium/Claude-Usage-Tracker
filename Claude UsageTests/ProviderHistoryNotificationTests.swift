import Foundation
import UsageCore
import UserNotifications
import XCTest
@testable import Claude_Usage

@MainActor
final class ProviderHistoryNotificationTests: HostedAppTestCase {
    func testLegacyHistoryDecodesWithoutNormalizedFieldAndRoundTrips() throws {
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let legacy = UsageHistoryData(
            snapshots: [
                UsageSnapshot(
                    timestamp: date,
                    resetType: .sessionReset,
                    sessionTokensUsed: 10,
                    sessionPercentage: 25,
                    triggeringResetTime: date
                )
            ]
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(legacy)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "normalizedSnapshots")
        let fixture = try JSONSerialization.data(
            withJSONObject: object
        )

        let decoded = try JSONDecoder().decode(
            UsageHistoryData.self,
            from: fixture
        )
        XCTAssertEqual(decoded, legacy)
        XCTAssertTrue(decoded.normalizedSnapshots.isEmpty)
        XCTAssertEqual(
            try JSONDecoder().decode(
                UsageHistoryData.self,
                from: JSONEncoder().encode(decoded)
            ),
            legacy
        )
    }

    func testCodexHistoryPreservesArbitraryGroupsWindowsAndNewCycles()
        throws
    {
        let environment = try makeEnvironment()
        let profileID = UUID()
        let firstDate = Date(timeIntervalSinceReferenceDate: 2_000)
        let service = retain(UsageHistoryService(
            defaults: environment.defaults,
            fileStore: ProfileUsageFileStore(
                baseURL: environment.rootURL
            ),
            now: { firstDate }
        ))
        let first = try report(
            providerID: .codex,
            fetchedAt: firstDate,
            windows: [
                ("future.group", "primary", 41, 3_000),
                ("future.group", "secondary", 72, 4_000),
                ("another.group", "rolling", 13, 5_000)
            ]
        )
        service.recordNormalizedReport(
            first,
            for: profileID,
            providerID: .codex,
            recordedAt: firstDate
        )

        // Same cycles inside the sampling interval are not duplicated.
        let nearby = try report(
            providerID: .codex,
            fetchedAt: firstDate.addingTimeInterval(30),
            windows: [
                ("future.group", "primary", 42, 3_000),
                ("future.group", "secondary", 73, 4_000),
                ("another.group", "rolling", 14, 5_000)
            ]
        )
        service.recordNormalizedReport(
            nearby,
            for: profileID,
            providerID: .codex,
            recordedAt: firstDate.addingTimeInterval(30)
        )

        // A cycle change records immediately even inside that interval.
        let reset = try report(
            providerID: .codex,
            fetchedAt: firstDate.addingTimeInterval(60),
            windows: [
                ("future.group", "primary", 1, 6_000),
                ("future.group", "secondary", 73, 4_000),
                ("another.group", "rolling", 14, 5_000)
            ]
        )
        service.recordNormalizedReport(
            reset,
            for: profileID,
            providerID: .codex,
            recordedAt: firstDate.addingTimeInterval(60)
        )

        let history = service.loadHistory(
            for: profileID,
            providerID: .codex
        )
        XCTAssertEqual(history.normalizedSnapshots.count, 4)
        XCTAssertEqual(
            Set(history.normalizedSnapshots.map(\.groupID.rawValue)),
            ["future.group", "another.group"]
        )
        XCTAssertEqual(
            Set(history.normalizedSnapshots.map(\.windowID.rawValue)),
            ["primary", "secondary", "rolling"]
        )
        XCTAssertEqual(
            history.normalizedSnapshots.filter {
                $0.windowID.rawValue == "primary"
            }.map(\.cycleID).count,
            2
        )
        XCTAssertTrue(history.snapshots.isEmpty)
    }

    func testNormalizedSnapshotRoundTripPreservesQuantityAndResetMetadata()
        throws
    {
        let profileID = UUID()
        let fetchedAt = Date(
            timeIntervalSinceReferenceDate: 7_000
        )
        let startedAt = fetchedAt.addingTimeInterval(-300)
        let resetsAt = fetchedAt.addingTimeInterval(300)
        let window = try UsageWindow(
            id: UsageWindowID("requests"),
            displayName: "Requests",
            quantity: UsageQuantity(
                used: 12,
                limit: 50,
                unit: .requests
            ),
            startedAt: startedAt,
            resetsAt: resetsAt,
            duration: 600
        )
        let group = try UsageLimitGroup(
            id: UsageLimitGroupID("future-quota"),
            displayName: "Future quota",
            windows: [window]
        )
        let report = try UsageReport(
            providerID: .codex,
            health: ProviderHealth(
                status: .healthy,
                checkedAt: fetchedAt
            ),
            limitGroups: [group],
            sourceUpdatedAt:
                fetchedAt.addingTimeInterval(-1),
            fetchedAt: fetchedAt,
            staleAt: fetchedAt.addingTimeInterval(300)
        )
        let snapshot = NormalizedUsageSnapshot(
            profileID: profileID,
            report: report,
            group: group,
            window: window
        )
        let decoded = try JSONDecoder().decode(
            NormalizedUsageSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.quantity?.used, 12)
        XCTAssertEqual(decoded.quantity?.limit, 50)
        XCTAssertEqual(decoded.quantity?.unit, .requests)
        XCTAssertEqual(decoded.usedPercentage, 24)
        XCTAssertEqual(decoded.startedAt, startedAt)
        XCTAssertEqual(decoded.resetsAt, resetsAt)
        XCTAssertEqual(decoded.duration, 600)
        XCTAssertEqual(
            decoded.sourceUpdatedAt,
            fetchedAt.addingTimeInterval(-1)
        )
        XCTAssertEqual(decoded.identity.profileID, profileID)
        XCTAssertEqual(decoded.identity.providerID, .codex)
        XCTAssertEqual(
            decoded.identity.groupID.rawValue,
            "future-quota"
        )
        XCTAssertEqual(
            decoded.identity.windowID.rawValue,
            "requests"
        )
    }

    func testNormalizedHistoryRetentionDropsOldestSnapshots()
        throws
    {
        let environment = try makeEnvironment()
        let profileID = UUID()
        let firstDate = Date(
            timeIntervalSinceReferenceDate: 8_000
        )
        let service = retain(UsageHistoryService(
            defaults: environment.defaults,
            fileStore: ProfileUsageFileStore(
                baseURL: environment.rootURL
            ),
            now: { firstDate },
            maxNormalizedSnapshots: 3
        ))

        for offset in 0..<4 {
            let fetchedAt = firstDate.addingTimeInterval(
                Double(offset)
            )
            service.recordNormalizedReport(
                try report(
                    providerID: .codex,
                    fetchedAt: fetchedAt,
                    windows: [
                        (
                            "group",
                            "window",
                            Double(offset),
                            12_000 + Double(offset)
                        )
                    ]
                ),
                for: profileID,
                providerID: .codex,
                recordedAt: fetchedAt
            )
        }

        let snapshots = service.loadHistory(
            for: profileID,
            providerID: .codex
        ).normalizedSnapshots
        XCTAssertEqual(snapshots.count, 3)
        XCTAssertEqual(
            snapshots.map(\.timestamp).min(),
            firstDate.addingTimeInterval(1)
        )
    }

    func testNormalizedHistoryIsolatedByProfileAndProvider()
        throws
    {
        let environment = try makeEnvironment()
        let firstProfileID = UUID()
        let secondProfileID = UUID()
        let fetchedAt = Date(
            timeIntervalSinceReferenceDate: 8_500
        )
        let service = retain(UsageHistoryService(
            defaults: environment.defaults,
            fileStore: ProfileUsageFileStore(
                baseURL: environment.rootURL
            ),
            now: { fetchedAt }
        ))

        service.recordNormalizedReport(
            try report(
                providerID: .codex,
                fetchedAt: fetchedAt,
                windows: [
                    ("group", "window", 10, 13_000)
                ]
            ),
            for: firstProfileID,
            providerID: .codex,
            recordedAt: fetchedAt
        )
        service.recordNormalizedReport(
            try report(
                providerID: .codex,
                fetchedAt: fetchedAt,
                windows: [
                    ("group", "window", 90, 13_000)
                ]
            ),
            for: secondProfileID,
            providerID: .codex,
            recordedAt: fetchedAt
        )

        let first = service.loadHistory(
            for: firstProfileID,
            providerID: .codex
        )
        let second = service.loadHistory(
            for: secondProfileID,
            providerID: .codex
        )
        XCTAssertEqual(
            first.normalizedSnapshots.map(\.profileID),
            [firstProfileID]
        )
        XCTAssertEqual(
            first.normalizedSnapshots.map(\.usedPercentage),
            [10]
        )
        XCTAssertEqual(
            second.normalizedSnapshots.map(\.profileID),
            [secondProfileID]
        )
        XCTAssertEqual(
            second.normalizedSnapshots.map(\.usedPercentage),
            [90]
        )

        service.recordNormalizedReport(
            try report(
                providerID: .claude,
                fetchedAt: fetchedAt,
                windows: [
                    ("wrong", "provider", 100, 14_000)
                ]
            ),
            for: firstProfileID,
            providerID: .codex,
            recordedAt: fetchedAt
        )
        XCTAssertEqual(
            service.loadHistory(
                for: firstProfileID,
                providerID: .codex
            ).normalizedSnapshots.count,
            1
        )
    }

    func testVersionedMixedExportExcludesSecretsAuthAndCodexHome()
        throws
    {
        let environment = try makeEnvironment()
        let exportedAt = Date(timeIntervalSinceReferenceDate: 9_000)
        let service = retain(UsageHistoryService(
            defaults: environment.defaults,
            fileStore: ProfileUsageFileStore(
                baseURL: environment.rootURL
            ),
            now: { exportedAt }
        ))
        let secret = "EXPORT_SECRET_SENTINEL"
        let authJSON = "{\"tokens\":\"\(secret)\"}"
        let codexHome = "/Users/private/.codex-sensitive"
        let canonicalHome = try JSONDecoder().decode(
            CanonicalCodexHome.self,
            from: Data(
                "{\"path\":\"\(codexHome)\"}".utf8
            )
        )
        var claude = Profile(
            name: "Claude profile",
            claudeSessionKey: secret,
            cliCredentialsJSON: authJSON
        )
        claude.apiSessionKey = "API_\(secret)"
        let codex = Profile(
            name: "Codex profile",
            providerConfiguration: .codex(
                CodexProfileConfiguration(
                    linkedHome: canonicalHome
                )
            )
        )
        service.saveHistory(
            UsageHistoryData(
                snapshots: [
                    UsageSnapshot(
                        resetType: .weeklyReset,
                        weeklyPercentage: 30,
                        triggeringResetTime: exportedAt
                    )
                ]
            ),
            for: claude.id,
            providerID: .claude
        )
        service.recordNormalizedReport(
            try report(
                providerID: .codex,
                fetchedAt: exportedAt,
                windows: [
                    ("dynamic", "primary", 50, 10_000)
                ]
            ),
            for: codex.id,
            providerID: .codex,
            recordedAt: exportedAt
        )

        let json = try XCTUnwrap(
            service.exportContent(
                profiles: [claude, codex],
                exportedAt: exportedAt
            )
        )
        XCTAssertTrue(json.contains("\"schemaVersion\" : 2"))
        XCTAssertTrue(json.contains("\"claude\""))
        XCTAssertTrue(json.contains("\"codex\""))
        XCTAssertTrue(json.contains("\"dynamic\""))
        XCTAssertFalse(json.contains(secret))
        XCTAssertFalse(json.contains("auth.json"))
        XCTAssertFalse(json.contains(authJSON))
        XCTAssertFalse(json.contains(codexHome))
        XCTAssertFalse(json.contains("/Users/"))

        let decoded = try JSONDecoder.iso8601.decode(
            UsageHistoryExportDocument.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.profiles.count, 2)
    }

    func testVersionedCSVPreservesLegacyClaudeAndNormalizedFields()
        throws
    {
        let environment = try makeEnvironment()
        let exportedAt = Date(timeIntervalSinceReferenceDate: 9_500)
        let service = retain(UsageHistoryService(
            defaults: environment.defaults,
            fileStore: ProfileUsageFileStore(
                baseURL: environment.rootURL
            ),
            now: { exportedAt }
        ))
        let dangerousNames = [
            "=HYPERLINK(\"bad\", \"Claude\")",
            "+SUM(1, 1)",
            "-10+20",
            "@SUM(1, 1)",
            "\t=1+1",
            "\r=1+1"
        ]
        let claudeProfiles = dangerousNames.map {
            Profile(name: $0)
        }
        let codex = Profile(
            name: "Codex profile",
            providerConfiguration: .codex(
                CodexProfileConfiguration()
            )
        )
        let legacyHistory = UsageHistoryData(
            snapshots: [
                UsageSnapshot(
                    resetType: .weeklyReset,
                    sessionTokensUsed: 123_456_789,
                    weeklyTokensUsed: 987_654_321,
                    opusWeeklyPercentage: 12.3,
                    sonnetWeeklyPercentage: 45.6,
                    fableWeeklyPercentage: 78.9,
                    apiSpendCents: 12_345,
                    apiPrepaidCreditsCents: 67_890,
                    apiCurrency: "=USD",
                    triggeringResetTime: exportedAt
                )
            ]
        )
        for profile in claudeProfiles {
            service.saveHistory(
                legacyHistory,
                for: profile.id
            )
        }
        service.saveHistory(
            UsageHistoryData(
                normalizedSnapshots: [
                    NormalizedUsageSnapshot(
                        timestamp: exportedAt,
                        profileID: codex.id,
                        providerID: .codex,
                        groupID: try UsageLimitGroupID(
                            "@future-group"
                        ),
                        windowID: try UsageWindowID(
                            "+future-window"
                        ),
                        cycleID: "-future-cycle",
                        usedPercentage: 37,
                        quantity: try UsageQuantity(
                            used: 37,
                            limit: 100,
                            unit: UsageUnit("=units")
                        ),
                        startedAt: nil,
                        resetsAt: exportedAt,
                        duration: nil,
                        sourceUpdatedAt: exportedAt,
                        fetchedAt: exportedAt
                    )
                ]
            ),
            for: codex.id,
            providerID: .codex
        )

        let csv = try XCTUnwrap(
            service.exportContent(
                profiles: claudeProfiles + [codex],
                format: .csv,
                exportedAt: exportedAt
            )
        )
        XCTAssertTrue(csv.contains("Schema Version"))
        XCTAssertTrue(csv.contains("Session Tokens"))
        XCTAssertTrue(csv.contains("API Prepaid Credits"))
        for dangerousName in dangerousNames {
            let neutralized = "'" + dangerousName
            let expected: String
            if neutralized.contains(",")
                || neutralized.contains("\"")
                || neutralized.contains("\n")
                || neutralized.contains("\r") {
                expected = "\""
                    + neutralized.replacingOccurrences(
                        of: "\"",
                        with: "\"\""
                    )
                    + "\""
            } else {
                expected = neutralized
            }
            XCTAssertTrue(
                csv.contains(expected),
                "Missing neutralized CSV value for \(dangerousName.debugDescription)"
            )
            XCTAssertFalse(csv.contains(",\(dangerousName)"))
        }
        XCTAssertTrue(csv.contains("123456789"))
        XCTAssertTrue(csv.contains("987654321"))
        XCTAssertTrue(csv.contains("123.45"))
        XCTAssertTrue(csv.contains("678.9"))
        XCTAssertTrue(csv.contains("'@future-group"))
        XCTAssertTrue(csv.contains("'+future-window"))
        XCTAssertTrue(csv.contains("'-future-cycle"))
        XCTAssertTrue(csv.contains("'=units"))
        XCTAssertTrue(csv.contains("'=USD"))
        XCTAssertTrue(csv.contains(",37.0,"))
        let rows = try parseCSV(csv)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.count == 22 })
        let fields = Set(rows.dropFirst().flatMap { $0 })
        for dangerousName in dangerousNames {
            XCTAssertTrue(fields.contains("'" + dangerousName))
        }
    }

    func testNotificationCrossingDedupAndNewCycleResetRealert()
        throws
    {
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 20_000)
        let settings = NotificationSettings()
        let initial = try report(
            providerID: .codex,
            fetchedAt: now,
            windows: [("group", "primary", 70, 30_000)]
        )

        let baseline = UsageNotificationPolicy.evaluate(
            report: initial,
            profileID: profileID,
            settings: settings,
            now: now,
            previousStates: [:],
            sentIdentities: []
        )
        XCTAssertTrue(baseline.events.isEmpty)

        let low = try report(
            providerID: .codex,
            fetchedAt: now.addingTimeInterval(1),
            windows: [("group", "primary", 70, 30_000)]
        )
        let lowered = UsageNotificationPolicy.evaluate(
            report: low,
            profileID: profileID,
            settings: settings,
            now: now.addingTimeInterval(1),
            previousStates: baseline.states,
            sentIdentities: []
        )
        let crossingReport = try report(
            providerID: .codex,
            fetchedAt: now.addingTimeInterval(2),
            windows: [("group", "primary", 76, 30_000)]
        )
        let crossing = UsageNotificationPolicy.evaluate(
            report: crossingReport,
            profileID: profileID,
            settings: settings,
            now: now.addingTimeInterval(2),
            previousStates: lowered.states,
            sentIdentities: []
        )
        XCTAssertEqual(crossing.events.map(\.threshold), [75])
        let sent = Set(
            crossing.events.map(\.identity.persistenceKey)
        )
        let duplicate = UsageNotificationPolicy.evaluate(
            report: crossingReport,
            profileID: profileID,
            settings: settings,
            now: now.addingTimeInterval(2),
            previousStates: crossing.states,
            sentIdentities: sent
        )
        XCTAssertTrue(duplicate.events.isEmpty)

        let newCycle = try report(
            providerID: .codex,
            fetchedAt: now.addingTimeInterval(3),
            windows: [("group", "primary", 96, 40_000)]
        )
        let reset = UsageNotificationPolicy.evaluate(
            report: newCycle,
            profileID: profileID,
            settings: settings,
            now: now.addingTimeInterval(3),
            previousStates: crossing.states,
            sentIdentities: sent
        )
        XCTAssertEqual(
            reset.events.map(\.identity.kind),
            [.reset, .threshold]
        )
        XCTAssertEqual(reset.events.last?.threshold, 95)
        XCTAssertEqual(
            Set(reset.events.map {
                $0.identity.window.profileID
            }),
            [profileID]
        )
    }

    func testFirstHighObservationMatchesClaudePolicyForEveryProvider()
        throws
    {
        let now = Date(timeIntervalSinceReferenceDate: 40_000)
        for providerID in [ProviderID.claude, .codex] {
            let groupID =
                providerID == .claude ? "subscription" : "group"
            let windowID =
                providerID == .claude ? "session" : "primary"
            let high = try report(
                providerID: providerID,
                fetchedAt: now,
                windows: [(groupID, windowID, 96, 50_000)]
            )
            let result = UsageNotificationPolicy.evaluate(
                report: high,
                profileID: UUID(),
                settings: NotificationSettings(),
                now: now,
                previousStates: [:],
                sentIdentities: []
            )

            XCTAssertEqual(
                result.events.map(\.threshold),
                [95],
                "First-high parity failed for \(providerID.rawValue)"
            )
        }
    }

    func testClaudeNotificationsIgnoreWeeklyModelAndOverageWindows()
        throws
    {
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 45_000)
        let initial = try report(
            providerID: .claude,
            fetchedAt: now,
            windows: [
                ("subscription", "session", 10, 55_000),
                ("subscription", "weekly", 96, 65_000),
                ("opus", "weekly", 96, 65_000),
                ("extra-usage", "current", 96, 75_000)
            ]
        )
        let first = UsageNotificationPolicy.evaluate(
            report: initial,
            profileID: profileID,
            settings: NotificationSettings(),
            now: now,
            previousStates: [:],
            sentIdentities: []
        )
        XCTAssertTrue(first.events.isEmpty)
        XCTAssertEqual(
            Set(first.states.keys.map(\.windowID.rawValue)),
            ["session"]
        )

        let highSession = try report(
            providerID: .claude,
            fetchedAt: now.addingTimeInterval(1),
            windows: [
                ("subscription", "session", 96, 55_000),
                ("subscription", "weekly", 96, 65_000),
                ("opus", "weekly", 96, 65_000),
                ("extra-usage", "current", 96, 75_000)
            ]
        )
        let second = UsageNotificationPolicy.evaluate(
            report: highSession,
            profileID: profileID,
            settings: NotificationSettings(),
            now: now.addingTimeInterval(1),
            previousStates: first.states,
            sentIdentities: []
        )
        XCTAssertEqual(second.events.count, 1)
        XCTAssertEqual(
            second.events.first?.identity.window.groupID.rawValue,
            "subscription"
        )
        XCTAssertEqual(
            second.events.first?.identity.window.windowID.rawValue,
            "session"
        )
        XCTAssertEqual(second.events.first?.threshold, 95)
    }

    func testFailedDeliveryRetriesWithoutLosingSuccessfulIdentity()
        throws
    {
        let environment = try makeEnvironment()
        var requests: [UNNotificationRequest] = []
        var completions: [(Error?) -> Void] = []
        let manager = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: { request, completion in
                requests.append(request)
                completions.append(completion)
            }
        ))
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 47_000)
        let high = try report(
            providerID: .codex,
            fetchedAt: now,
            windows: [
                ("group", "primary", 96, 57_000),
                ("group", "secondary", 96, 67_000)
            ]
        )

        manager.checkAndNotify(
            report: high,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now
        )
        XCTAssertEqual(requests.count, 2)
        let failedIdentifier = requests[0].identifier
        let successfulIdentifier = requests[1].identifier
        completions[0](TestError.expected)
        completions[1](nil)

        manager.checkAndNotify(
            report: high,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.last?.identifier, failedIdentifier)
        XCTAssertNotEqual(requests.last?.identifier, successfulIdentifier)
    }

    func testStaleCycleCannotMutateDeliveredThresholdState()
        throws
    {
        let environment = try makeEnvironment()
        var requests: [UNNotificationRequest] = []
        var completions: [(Error?) -> Void] = []
        let manager = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: { request, completion in
                requests.append(request)
                completions.append(completion)
            }
        ))
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 48_000)
        let cycleA = try report(
            providerID: .codex,
            fetchedAt: now,
            windows: [("group", "primary", 96, 58_000)]
        )

        manager.checkAndNotify(
            report: cycleA,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now
        )
        XCTAssertEqual(requests.count, 1)
        completions.removeFirst()(nil)

        let staleCycleB = try report(
            providerID: .codex,
            fetchedAt: now.addingTimeInterval(1),
            staleAt: now.addingTimeInterval(1.5),
            windows: [("group", "primary", 96, 68_000)]
        )
        manager.checkAndNotify(
            report: staleCycleB,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now.addingTimeInterval(2)
        )
        manager.checkAndNotify(
            report: cycleA,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now.addingTimeInterval(3)
        )

        XCTAssertEqual(requests.count, 1)
    }

    func testFailedResetRetriesAcrossManagerRecreation()
        throws
    {
        let environment = try makeEnvironment()
        var requests: [UNNotificationRequest] = []
        var completions: [(Error?) -> Void] = []
        let capture:
            NotificationManager.NotificationRequestAdder = {
                request,
                completion in
                requests.append(request)
                completions.append(completion)
            }
        let settings = NotificationSettings(
            threshold75Enabled: false,
            threshold90Enabled: false,
            threshold95Enabled: false
        )
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 49_000)
        let cycleA = try report(
            providerID: .codex,
            fetchedAt: now,
            windows: [("group", "primary", 70, 59_000)]
        )
        let cycleB = try report(
            providerID: .codex,
            fetchedAt: now.addingTimeInterval(1),
            windows: [("group", "primary", 0, 69_000)]
        )
        let first = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: capture
        ))
        first.checkAndNotify(
            report: cycleA,
            profileID: profileID,
            profileName: "Codex",
            settings: settings,
            now: now
        )
        first.checkAndNotify(
            report: cycleB,
            profileID: profileID,
            profileName: "Codex",
            settings: settings,
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(requests.count, 1)
        let resetIdentifier = requests[0].identifier
        completions.removeFirst()(TestError.expected)

        let second = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: capture
        ))
        second.checkAndNotify(
            report: cycleB,
            profileID: profileID,
            profileName: "Codex",
            settings: settings,
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].identifier, resetIdentifier)
        completions.removeFirst()(nil)

        let third = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: capture
        ))
        third.checkAndNotify(
            report: cycleB,
            profileID: profileID,
            profileName: "Codex",
            settings: settings,
            now: now.addingTimeInterval(3)
        )
        XCTAssertEqual(requests.count, 2)
    }

    func testInFlightResetIsSubmittedOnlyOnce() throws {
        let environment = try makeEnvironment()
        var requests: [UNNotificationRequest] = []
        var completions: [(Error?) -> Void] = []
        let manager = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: { request, completion in
                requests.append(request)
                completions.append(completion)
            }
        ))
        let settings = NotificationSettings(
            threshold75Enabled: false,
            threshold90Enabled: false,
            threshold95Enabled: false
        )
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 49_500)
        let firstCycle = try report(
            providerID: .codex,
            fetchedAt: now,
            windows: [("group", "primary", 70, 59_500)]
        )
        let nextCycle = try report(
            providerID: .codex,
            fetchedAt: now.addingTimeInterval(1),
            windows: [("group", "primary", 0, 69_500)]
        )
        manager.checkAndNotify(
            report: firstCycle,
            profileID: profileID,
            profileName: "Codex",
            settings: settings,
            now: now
        )
        manager.checkAndNotify(
            report: nextCycle,
            profileID: profileID,
            profileName: "Codex",
            settings: settings,
            now: now.addingTimeInterval(1)
        )
        manager.checkAndNotify(
            report: nextCycle,
            profileID: profileID,
            profileName: "Codex",
            settings: settings,
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(requests.count, 1)
        completions.removeFirst()(TestError.expected)
        manager.checkAndNotify(
            report: nextCycle,
            profileID: profileID,
            profileName: "Codex",
            settings: settings,
            now: now.addingTimeInterval(3)
        )
        XCTAssertEqual(requests.count, 2)
    }

    func testInFlightThresholdIsSubmittedOnlyOnceAndRetriesAfterFailure()
        throws
    {
        let environment = try makeEnvironment()
        var requests: [UNNotificationRequest] = []
        var completions: [(Error?) -> Void] = []
        let manager = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: { request, completion in
                requests.append(request)
                completions.append(completion)
            }
        ))
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 49_700)
        let high = try report(
            providerID: .codex,
            fetchedAt: now,
            windows: [("group", "primary", 96, 59_700)]
        )

        manager.checkAndNotify(
            report: high,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now
        )
        manager.checkAndNotify(
            report: high,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(requests.count, 1)

        completions.removeFirst()(TestError.expected)
        manager.checkAndNotify(
            report: high,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].identifier, requests[1].identifier)
    }

    func testHigherDeliveredThresholdSuppressesLowerBackfill()
        throws
    {
        let environment = try makeEnvironment()
        var requests: [UNNotificationRequest] = []
        var completions: [(Error?) -> Void] = []
        let manager = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: { request, completion in
                requests.append(request)
                completions.append(completion)
            }
        ))
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 49_800)
        for (offset, percentage) in [96.0, 92.0, 80.0]
            .enumerated() {
            let current = try report(
                providerID: .codex,
                fetchedAt:
                    now.addingTimeInterval(
                        TimeInterval(offset)
                    ),
                windows: [
                    ("group", "primary", percentage, 59_800)
                ]
            )
            manager.checkAndNotify(
                report: current,
                profileID: profileID,
                profileName: "Codex",
                settings: NotificationSettings(),
                now:
                    now.addingTimeInterval(
                        TimeInterval(offset)
                    )
            )
            if !completions.isEmpty {
                completions.removeFirst()(nil)
            }
        }

        XCTAssertEqual(requests.count, 1)
    }

    func testMissingWindowRetentionIsBoundedAndExpires()
        throws
    {
        let environment = try makeEnvironment()
        let manager = retain(NotificationManager(
            defaults: environment.defaults,
            missingWindowRetention: 5,
            maximumMissingWindowsPerScope: 2,
            notificationRequestAdder: { _, completion in
                completion(nil)
            }
        ))
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 49_900)
        let observations: [[(
            group: String,
            window: String,
            percentage: Double,
            resetReferenceDate: TimeInterval
        )]] = [
            [
                ("group", "a", 10, 59_900),
                ("group", "b", 10, 59_900),
                ("group", "c", 10, 59_900)
            ],
            [
                ("group", "a", 10, 59_900),
                ("group", "b", 10, 59_900)
            ],
            [("group", "a", 10, 59_900)],
            [("group", "d", 10, 59_900)]
        ]
        for (offset, windows) in observations.enumerated() {
            let time = now.addingTimeInterval(
                TimeInterval(offset)
            )
            manager.checkAndNotify(
                report: try report(
                    providerID: .codex,
                    fetchedAt: time,
                    windows: windows
                ),
                profileID: profileID,
                profileName: "Codex",
                settings: NotificationSettings(),
                now: time
            )
        }
        XCTAssertEqual(
            manager.normalizedNotificationStateCount(
                profileID: profileID,
                providerID: .codex
            ),
            3
        )

        let afterGrace = now.addingTimeInterval(10)
        manager.checkAndNotify(
            report: try report(
                providerID: .codex,
                fetchedAt: afterGrace,
                windows: [("group", "d", 10, 59_900)]
            ),
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: afterGrace
        )
        XCTAssertEqual(
            manager.normalizedNotificationStateCount(
                profileID: profileID,
                providerID: .codex
            ),
            1
        )
    }

    func testProfileClearPersistsAndDoesNotDeleteOtherProfileState()
        throws
    {
        let environment = try makeEnvironment()
        let profileID = UUID()
        let otherProfileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 49_950)
        let settings = NotificationSettings(
            threshold75Enabled: false,
            threshold90Enabled: false,
            threshold95Enabled: false
        )
        let manager = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: { _, completion in
                completion(nil)
            }
        ))
        manager.checkAndNotify(
            report: try report(
                providerID: .codex,
                fetchedAt: now,
                windows: [("group", "primary", 10, 59_950)]
            ),
            profileID: profileID,
            profileName: "Codex",
            settings: settings,
            now: now
        )
        manager.checkAndNotify(
            report: try report(
                providerID: .claude,
                fetchedAt: now,
                windows: [
                    ("subscription", "session", 10, 59_950)
                ]
            ),
            profileID: otherProfileID,
            profileName: "Claude",
            settings: settings,
            now: now
        )

        manager.clearNotificationsForProfile(
            profileID,
            providerID: .codex
        )
        let reloaded = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: { _, completion in
                completion(nil)
            }
        ))
        XCTAssertEqual(
            reloaded.normalizedNotificationStateCount(
                profileID: profileID,
                providerID: .codex
            ),
            0
        )
        XCTAssertEqual(
            reloaded.normalizedNotificationStateCount(
                profileID: profileID,
                providerID: .claude
            ),
            0
        )
        XCTAssertEqual(
            reloaded.normalizedNotificationStateCount(
                profileID: otherProfileID,
                providerID: .claude
            ),
            1
        )
    }

    func testNotificationsRetainMissingWindowStateAndSeparateProfiles()
        throws
    {
        let firstProfile = UUID()
        let secondProfile = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 50_000)
        let initial = try report(
            providerID: .codex,
            fetchedAt: now,
            windows: [
                ("known", "primary", 70, 60_000),
                ("unknown.future", "burst", 20, 70_000)
            ]
        )
        let first = UsageNotificationPolicy.evaluate(
            report: initial,
            profileID: firstProfile,
            settings: NotificationSettings(),
            now: now,
            previousStates: [:],
            sentIdentities: []
        )
        let missingFuture = try report(
            providerID: .codex,
            fetchedAt: now.addingTimeInterval(1),
            windows: [
                ("known", "primary", 76, 60_000)
            ]
        )
        let next = UsageNotificationPolicy.evaluate(
            report: missingFuture,
            profileID: firstProfile,
            settings: NotificationSettings(),
            now: now.addingTimeInterval(1),
            previousStates: first.states,
            sentIdentities: []
        )
        XCTAssertEqual(next.states.count, 2)
        XCTAssertEqual(next.events.map(\.threshold), [75])

        let second = UsageNotificationPolicy.evaluate(
            report: initial,
            profileID: secondProfile,
            settings: NotificationSettings(),
            now: now,
            previousStates: [:],
            sentIdentities: []
        )
        XCTAssertNotEqual(
            Set(first.states.keys.map(\.profileID)),
            Set(second.states.keys.map(\.profileID))
        )
    }

    func testStaleAndUnavailableReportsDoNotNotifyOrAdvanceState()
        throws
    {
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 80_000)
        let key = UsageNotificationWindowKey(
            profileID: profileID,
            providerID: .codex,
            groupID: try UsageLimitGroupID("group"),
            windowID: try UsageWindowID("window")
        )
        let existing = [
            key: UsageNotificationWindowState(
                cycleID: "existing",
                percentage: 70,
                lastSeenAt: now.addingTimeInterval(-1)
            )
        ]
        let stale = try report(
            providerID: .codex,
            fetchedAt: now.addingTimeInterval(-20),
            staleAt: now.addingTimeInterval(-1),
            windows: [("group", "window", 99, 90_000)]
        )
        let staleResult = UsageNotificationPolicy.evaluate(
            report: stale,
            profileID: profileID,
            settings: NotificationSettings(),
            now: now,
            previousStates: existing,
            sentIdentities: []
        )
        XCTAssertTrue(staleResult.events.isEmpty)
        XCTAssertEqual(staleResult.states, existing)

        let unavailable = try report(
            providerID: .codex,
            health: .unavailable,
            fetchedAt: now,
            windows: [("group", "window", 99, 90_000)]
        )
        let unavailableResult =
            UsageNotificationPolicy.evaluate(
                report: unavailable,
                profileID: profileID,
                settings: NotificationSettings(),
                now: now,
                previousStates: existing,
                sentIdentities: []
            )
        XCTAssertTrue(unavailableResult.events.isEmpty)
        XCTAssertEqual(unavailableResult.states, existing)

        let recovered = try report(
            providerID: .codex,
            fetchedAt: now.addingTimeInterval(1),
            windows: [("group", "window", 99, 90_000)]
        )
        let recoveredResult = UsageNotificationPolicy.evaluate(
            report: recovered,
            profileID: profileID,
            settings: NotificationSettings(),
            now: now.addingTimeInterval(1),
            previousStates: unavailableResult.states,
            sentIdentities: []
        )
        XCTAssertEqual(
            recoveredResult.events.compactMap(\.threshold),
            [95]
        )
    }

    func testAutomationCapabilityMatrixIsExplicit() {
        let claude = ClaudeUsageProviderAdapter.capabilities
        let codex = CodexProviderFactory.capabilities
        for capability in [
            ProviderCapability.usageHistory,
            .usageNotifications,
            .automaticSessionStart,
            .automaticProfileSwitch,
            .statusLineIntegration,
            .cliAccountSync,
            .apiBilling
        ] {
            XCTAssertNotEqual(claude[capability], .unknown)
            XCTAssertNotEqual(codex[capability], .unknown)
        }
        let claudePolicy = ProviderFeatureSurfacePolicy(
            capabilities: claude
        )
        let codexPolicy = ProviderFeatureSurfacePolicy(
            capabilities: codex
        )
        let expectations: [
            ProviderFeatureSurface: (claude: Bool, codex: Bool)
        ] = [
            .history: (true, true),
            .notifications: (true, true),
            .automaticSessionStart: (true, false),
            .automaticProfileSwitch: (true, false),
            .statusLine: (true, false),
            .cliAccountSync: (true, false),
            .apiBilling: (true, false),
            .genericRefresh: (true, true),
            .shortcuts: (true, true),
            .launchAtLogin: (true, true)
        ]
        XCTAssertEqual(
            Set(expectations.keys),
            Set(ProviderFeatureSurface.allCases)
        )
        for surface in ProviderFeatureSurface.allCases {
            let expected = expectations[surface]
            XCTAssertEqual(
                claudePolicy.supports(surface),
                expected?.claude,
                "Claude surface policy missing \(surface)"
            )
            XCTAssertEqual(
                codexPolicy.supports(surface),
                expected?.codex,
                "Codex surface policy missing \(surface)"
            )
        }
        XCTAssertEqual(
            Set(ShortcutAction.allCases),
            [.togglePopover, .refresh, .openSettings, .nextProfile]
        )
        XCTAssertTrue(
            AutoStartSessionService.isSupported(
                for: .claude,
                capabilities: claude
            )
        )
        XCTAssertFalse(
            AutoStartSessionService.isSupported(
                for: .codex,
                capabilities: codex
            )
        )
    }

    func testNormalizedHistorySeriesIdentityIncludesProfile() throws {
        let first = NormalizedHistorySeriesIdentity(
            profileID: UUID(),
            providerID: .codex,
            groupID: try UsageLimitGroupID("subscription"),
            windowID: try UsageWindowID("session")
        )
        let second = NormalizedHistorySeriesIdentity(
            profileID: UUID(),
            providerID: .codex,
            groupID: first.groupID,
            windowID: first.windowID
        )

        XCTAssertNotEqual(first, second)
    }

    func testProviderChangeRedirectsCapabilityHiddenSection() {
        let navigation = retain(SettingsNavigationModel())
        navigation.selectedSection = .claudeCode

        navigation.activeProviderDidChange(
            .codex,
            capabilities: CodexProviderFactory.capabilities
        )

        XCTAssertEqual(navigation.selectedSection, .general)
    }

    func testRouterGatesCodexHistoryAndNotificationsByCapabilityAndIdentity()
        throws
    {
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 100_000)
        let context = UsagePresentationContext(
            epoch: 1,
            focusedProfileID: profileID,
            visibleProfileIDs: [profileID]
        )
        let report = try report(
            providerID: .codex,
            fetchedAt: now,
            windows: [("group", "primary", 50, 110_000)]
        )
        var calls: [String] = []
        let router = retain(MenuBarManager.RefreshSideEffectRouter(
            hooks: .init(
                recordNormalized: { _, _ in
                    calls.append("history")
                },
                recordClaude: { _, _ in
                    calls.append("legacy-history")
                },
                writeStatusline: { _, _ in
                    calls.append("statusline")
                },
                notifyNormalized: { _, _ in
                    calls.append("notify")
                },
                autoSwitch: { _, _, _ in
                    calls.append("auto-switch")
                },
                recordAPI: { _, _ in
                    calls.append("api-history")
                },
                finalizeBatch: { _ in },
                recordBatchSuccess: { _ in },
                recordClaudeBatchSuccess: { _ in },
                showBatchSuccess: { _ in },
                autoSwitchBatch: { _, _, _ in },
                logFailure: { _, _ in },
                recordInteractiveFailure: { _, _ in },
                showInteractiveFailure: { _, _ in }
            )
        ))
        let event = acceptedEvent(
            profileID: profileID,
            providerRevision: 2,
            context: context,
            report: report,
            capabilities: ProviderCapabilities([
                .usageHistory: .available,
                .usageNotifications: .available,
                .automaticSessionStart: .unavailable,
                .statusLineIntegration: .unavailable
            ]),
            committedAt: now
        )

        router.committed(event)
        router.presented(
            event,
            currentContext: context,
            activeProfile: Profile(
                id: profileID,
                name: "Codex",
                providerConfiguration: .codex(
                    CodexProfileConfiguration()
                ),
                providerRevision: 2
            )
        )
        XCTAssertEqual(calls, ["history", "notify"])

        calls.removeAll()
        router.presented(
            event,
            currentContext: context,
            activeProfile: Profile(
                id: profileID,
                name: "Changed identity",
                providerConfiguration: .codex(
                    CodexProfileConfiguration()
                ),
                providerRevision: 3
            )
        )
        XCTAssertTrue(calls.isEmpty)

        calls.removeAll()
        let claudeReport = try self.report(
            providerID: .claude,
            fetchedAt: now,
            windows: [("subscription", "session", 50, 110_000)]
        )
        let claude = acceptedEvent(
            profileID: profileID,
            providerRevision: 2,
            context: context,
            report: claudeReport,
            capabilities: ClaudeUsageProviderAdapter.capabilities,
            committedAt: now
        )
        router.committed(claude)
        XCTAssertFalse(
            calls.contains("history"),
            "Claude must not dual-write normalized and legacy history"
        )

        calls.removeAll()
        let unavailable = acceptedEvent(
            profileID: profileID,
            providerRevision: 2,
            context: context,
            report: report,
            capabilities: ProviderCapabilities([
                .usageHistory: .unavailable,
                .usageNotifications: .unavailable
            ]),
            committedAt: now
        )
        router.committed(unavailable)
        router.presented(
            unavailable,
            currentContext: context,
            activeProfile: Profile(
                id: profileID,
                name: "Codex",
                providerConfiguration: .codex(
                    CodexProfileConfiguration()
                ),
                providerRevision: 2
            )
        )
        XCTAssertTrue(calls.isEmpty)
    }

    private func acceptedEvent(
        profileID: UUID,
        providerRevision: UInt64,
        context: UsagePresentationContext,
        report: UsageReport,
        capabilities: ProviderCapabilities,
        committedAt: Date
    ) -> AcceptedUsageRefreshEvent {
        AcceptedUsageRefreshEvent(
            sequence: 1,
            identity: ProviderRefreshIdentity(
                profileID: profileID,
                providerID: report.providerID,
                providerRevision: providerRevision
            ),
            inputGeneration: 0,
            invocationOrder: 1,
            profileName: "Codex",
            notificationSettings: NotificationSettings(),
            trigger: .manual,
            presentationContext: context,
            capabilities: capabilities,
            previousUsage: nil,
            currentUsage: ProfileCurrentUsage(
                providerID: report.providerID,
                providerRevision: providerRevision,
                report: report
            ),
            acceptedComponents: [.providerUsage],
            committedAt: committedAt
        )
    }

    private func report(
        providerID: ProviderID,
        health: ProviderHealthStatus = .healthy,
        fetchedAt: Date,
        staleAt: Date? = nil,
        windows: [
            (
                group: String,
                window: String,
                percentage: Double,
                resetReferenceDate: TimeInterval
            )
        ]
    ) throws -> UsageReport {
        let grouped = Dictionary(grouping: windows, by: \.group)
        let groups = try grouped.map { groupID, members in
            try UsageLimitGroup(
                id: UsageLimitGroupID(groupID),
                displayName: "Display \(groupID)",
                windows: try members.map { member in
                    try UsageWindow(
                        id: UsageWindowID(member.window),
                        displayName: "Display \(member.window)",
                        usedPercentage: member.percentage,
                        resetsAt: Date(
                            timeIntervalSinceReferenceDate:
                                member.resetReferenceDate
                        )
                    )
                }
            )
        }
        return try UsageReport(
            providerID: providerID,
            health: ProviderHealth(
                status: health,
                checkedAt: fetchedAt
            ),
            limitGroups: groups,
            fetchedAt: fetchedAt,
            staleAt:
                staleAt
                ?? fetchedAt.addingTimeInterval(300)
        )
    }

    private enum TestError: Error {
        case expected
        case unterminatedCSVQuote
    }

    private func parseCSV(_ csv: String) throws -> [[String]] {
        let characters = Array(csv)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if inQuotes,
                   index + 1 < characters.count,
                   characters[index + 1] == "\"" {
                    field.append("\"")
                    index += 2
                    continue
                }
                inQuotes.toggle()
            } else if character == ",", !inQuotes {
                row.append(field)
                field = ""
            } else if (character == "\n" || character == "\r"),
                      !inQuotes {
                row.append(field)
                field = ""
                if !row.allSatisfy(\.isEmpty) {
                    rows.append(row)
                }
                row = []
                if character == "\r",
                   index + 1 < characters.count,
                   characters[index + 1] == "\n" {
                    index += 1
                }
            } else {
                field.append(character)
            }
            index += 1
        }

        guard !inQuotes else {
            throw TestError.unterminatedCSVQuote
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    private func makeEnvironment() throws -> (
        defaults: UserDefaults,
        rootURL: URL
    ) {
        let suiteName =
            "ProviderHistoryNotificationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defaults.removePersistentDomain(forName: suiteName)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProviderHistoryNotificationTests-"
                    + UUID().uuidString
            )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: rootURL)
        }
        return (defaults, rootURL)
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
