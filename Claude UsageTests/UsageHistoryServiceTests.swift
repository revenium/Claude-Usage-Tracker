import Foundation
import XCTest
@testable import Claude_Usage

final class UsageHistoryServiceTests: XCTestCase {
    func testMigratesLegacyHistoryOnlyAfterVerifiedFileRoundTrip() async throws {
        try await MainActor.run {
            try testMigratesLegacyHistoryOnlyAfterVerifiedFileRoundTripOnMainActor()
        }
    }

    @MainActor
    private func testMigratesLegacyHistoryOnlyAfterVerifiedFileRoundTripOnMainActor() throws {
        let environment = try makeEnvironment()
        let profileID = UUID()
        let history = makeHistory(percentage: 42)
        let key = "usageHistory_\(profileID.uuidString)"
        environment.defaults.set(try JSONEncoder().encode(history), forKey: key)

        let store = ProfileUsageFileStore(
            baseURL: environment.rootURL,
            now: { Date(timeIntervalSince1970: 500) }
        )
        let service = UsageHistoryService(
            defaults: environment.defaults,
            fileStore: store,
            now: { Date(timeIntervalSince1970: 500) }
        )

        XCTAssertNil(environment.defaults.data(forKey: key))
        XCTAssertEqual(service.loadHistory(for: profileID), history)
        XCTAssertEqual(
            try store.load(
                UsageHistoryData.self,
                for: profileID,
                providerID: "claude",
                kind: .history
            ),
            history
        )

        let fileURL = try store.fileURL(for: profileID, kind: .history)
        let envelope = try JSONDecoder().decode(
            ProfileUsageFileEnvelope<UsageHistoryData>.self,
            from: Data(contentsOf: fileURL)
        )
        XCTAssertEqual(envelope.recordKind, .history)
        XCTAssertEqual(envelope.providerID, "claude")
        XCTAssertEqual(envelope.profileID, profileID)
        XCTAssertEqual(envelope.writtenAt, Date(timeIntervalSince1970: 500))
    }

    func testMigrationIsFailureSafePerLegacyKey() async throws {
        try await MainActor.run {
            try testMigrationIsFailureSafePerLegacyKeyOnMainActor()
        }
    }

    @MainActor
    private func testMigrationIsFailureSafePerLegacyKeyOnMainActor() throws {
        let environment = try makeEnvironment()
        let validProfileID = UUID()
        let invalidProfileID = UUID()
        let validKey = "usageHistory_\(validProfileID.uuidString)"
        let invalidKey = "usageHistory_\(invalidProfileID.uuidString)"
        let history = makeHistory(percentage: 25)
        environment.defaults.set(try JSONEncoder().encode(history), forKey: validKey)
        environment.defaults.set(Data("not-json".utf8), forKey: invalidKey)

        let service = UsageHistoryService(
            defaults: environment.defaults,
            fileStore: ProfileUsageFileStore(baseURL: environment.rootURL)
        )

        XCTAssertNil(environment.defaults.data(forKey: validKey))
        XCTAssertNotNil(environment.defaults.data(forKey: invalidKey))
        XCTAssertEqual(service.loadHistory(for: validProfileID), history)
        XCTAssertTrue(service.loadHistory(for: invalidProfileID).isEmpty)
    }

    func testFailedFileMigrationRetainsLegacyDataAndLoadsFallback() async throws {
        try await MainActor.run {
            try testFailedFileMigrationRetainsLegacyDataAndLoadsFallbackOnMainActor()
        }
    }

    @MainActor
    private func testFailedFileMigrationRetainsLegacyDataAndLoadsFallbackOnMainActor() throws {
        let environment = try makeEnvironment()
        let profileID = UUID()
        let key = "usageHistory_\(profileID.uuidString)"
        let history = makeHistory(percentage: 70)
        environment.defaults.set(try JSONEncoder().encode(history), forKey: key)

        // A regular file cannot contain the per-profile directory, forcing the
        // durable write to fail without relying on process permissions.
        let blockedRootURL = environment.rootURL.appendingPathComponent("blocked")
        try Data("blocking-file".utf8).write(to: blockedRootURL)
        let service = UsageHistoryService(
            defaults: environment.defaults,
            fileStore: ProfileUsageFileStore(baseURL: blockedRootURL)
        )

        XCTAssertNotNil(environment.defaults.data(forKey: key))
        XCTAssertEqual(service.loadHistory(for: profileID), history)
    }

    func testSaveClearAndThrowingDeleteUseFileStorage() async throws {
        try await MainActor.run {
            try testSaveClearAndThrowingDeleteUseFileStorageOnMainActor()
        }
    }

    @MainActor
    private func testSaveClearAndThrowingDeleteUseFileStorageOnMainActor() throws {
        let environment = try makeEnvironment()
        let profileID = UUID()
        let history = UsageHistoryData(
            snapshots: [
                makeSnapshot(type: .sessionReset, percentage: 10),
                makeSnapshot(type: .weeklyReset, percentage: 20)
            ]
        )
        let store = ProfileUsageFileStore(baseURL: environment.rootURL)
        let service = UsageHistoryService(defaults: environment.defaults, fileStore: store)

        service.saveHistory(history, for: profileID)
        XCTAssertEqual(service.loadHistory(for: profileID), history)
        XCTAssertNil(
            environment.defaults.data(forKey: "usageHistory_\(profileID.uuidString)")
        )

        service.clearHistory(for: profileID, resetType: .sessionReset)
        XCTAssertEqual(service.loadHistory(for: profileID).snapshots.count, 1)
        XCTAssertEqual(service.loadHistory(for: profileID).snapshots.first?.resetType, .weeklyReset)

        let legacyKey = "usageHistory_\(profileID.uuidString)"
        let sessionTimestampKey = "lastSessionRecordTime_\(profileID.uuidString)"
        let weeklyTimestampKey = "lastWeeklyRecordTime_\(profileID.uuidString)"
        environment.defaults.set(try JSONEncoder().encode(history), forKey: legacyKey)
        environment.defaults.set(Date(), forKey: sessionTimestampKey)
        environment.defaults.set(Date(), forKey: weeklyTimestampKey)
        try service.deleteHistoryThrowing(for: profileID)
        XCTAssertTrue(service.loadHistory(for: profileID).isEmpty)
        XCTAssertNil(environment.defaults.object(forKey: legacyKey))
        XCTAssertNil(environment.defaults.object(forKey: sessionTimestampKey))
        XCTAssertNil(environment.defaults.object(forKey: weeklyTimestampKey))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: try store.fileURL(for: profileID, kind: .history).path
            )
        )
    }

    func testVerifiedExistingFileWinsOverStaleLegacyKey() async throws {
        try await MainActor.run {
            try testVerifiedExistingFileWinsOverStaleLegacyKeyOnMainActor()
        }
    }

    @MainActor
    private func testVerifiedExistingFileWinsOverStaleLegacyKeyOnMainActor() throws {
        let environment = try makeEnvironment()
        let profileID = UUID()
        let key = "usageHistory_\(profileID.uuidString)"
        let staleHistory = makeHistory(percentage: 5)
        let currentHistory = makeHistory(percentage: 95)
        environment.defaults.set(try JSONEncoder().encode(staleHistory), forKey: key)

        let store = ProfileUsageFileStore(baseURL: environment.rootURL)
        try store.save(
            currentHistory,
            for: profileID,
            providerID: "claude",
            kind: .history
        )
        let service = UsageHistoryService(defaults: environment.defaults, fileStore: store)

        XCTAssertNil(environment.defaults.data(forKey: key))
        XCTAssertEqual(service.loadHistory(for: profileID), currentHistory)
    }

    @MainActor
    private func makeEnvironment() throws -> (
        defaults: UserDefaults,
        rootURL: URL
    ) {
        let suiteName = "UsageHistoryServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageHistoryServiceTests-\(UUID().uuidString)")
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

    @MainActor
    private func makeHistory(percentage: Double) -> UsageHistoryData {
        UsageHistoryData(
            snapshots: [
                makeSnapshot(type: .sessionReset, percentage: percentage)
            ]
        )
    }

    @MainActor
    private func makeSnapshot(type: ResetType, percentage: Double) -> UsageSnapshot {
        let date = Date(timeIntervalSince1970: 1_000)
        return UsageSnapshot(
            id: UUID(),
            timestamp: date,
            resetType: type,
            sessionTokensUsed: type == .sessionReset ? 100 : nil,
            sessionPercentage: type == .sessionReset ? percentage : nil,
            weeklyTokensUsed: type == .weeklyReset ? 200 : nil,
            weeklyPercentage: type == .weeklyReset ? percentage : nil,
            triggeringResetTime: date
        )
    }
}
