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

    func testRecordSessionResetRejectsSnapshotWithFutureTriggeringResetTime() async throws {
        try await MainActor.run {
            try testRecordSessionResetRejectsSnapshotWithFutureTriggeringResetTimeOnMainActor()
        }
    }

    /// Reproduces the false-positive reset mechanism directly: Claude's
    /// session window can advance without an actual reset, so
    /// `checkAndRecordSessionReset` sometimes calls `recordSessionReset` with
    /// a `resetTime` that has not happened yet. Before admission, that
    /// snapshot was written and then hidden forever by the display filter.
    ///
    /// `UsageSnapshot.fromSessionReset` stamps `timestamp` from the real
    /// wall clock (not the service's injectable `now`), so `resetTime` is
    /// anchored to `Date.distantFuture` here rather than an offset from an
    /// injected clock, to stay correct regardless of when the test runs.
    @MainActor
    private func testRecordSessionResetRejectsSnapshotWithFutureTriggeringResetTimeOnMainActor() throws {
        let environment = try makeEnvironment()
        let profileID = UUID()
        let service = UsageHistoryService(
            defaults: environment.defaults,
            fileStore: ProfileUsageFileStore(baseURL: environment.rootURL)
        )
        let usage = makeClaudeUsage(sessionPercentage: 55, sessionResetTime: Date())

        service.recordSessionReset(
            for: profileID,
            previousUsage: usage,
            resetTime: .distantFuture
        )

        let history = service.loadHistory(for: profileID)
        XCTAssertTrue(history.snapshots.isEmpty)
        XCTAssertTrue(history.sessionSnapshots.isEmpty)
    }

    func testNoOpTransformSkipsFileWrite() async throws {
        try await MainActor.run {
            try testNoOpTransformSkipsFileWriteOnMainActor()
        }
    }

    /// `recordSessionReset` with a rejected (future-dated) snapshot is a
    /// no-op transform on the stored history. Confirms `ProfileUsageFileStore
    /// .update` skips the save in that case by asserting the file on disk is
    /// byte-for-byte unchanged, rather than merely asserting the resulting
    /// value is equal.
    @MainActor
    private func testNoOpTransformSkipsFileWriteOnMainActor() throws {
        let environment = try makeEnvironment()
        let profileID = UUID()
        let now = Date(timeIntervalSince1970: 10_000)
        let store = ProfileUsageFileStore(baseURL: environment.rootURL, now: { now })
        let service = UsageHistoryService(
            defaults: environment.defaults,
            fileStore: store,
            now: { now }
        )
        let usage = makeClaudeUsage(sessionPercentage: 30, sessionResetTime: now)
        service.recordSessionReset(
            for: profileID,
            previousUsage: usage,
            resetTime: Date(timeIntervalSince1970: 0)
        )

        let fileURL = try store.fileURL(for: profileID, kind: .history)
        let before = try Data(contentsOf: fileURL)

        // Rejected by admission: mutates nothing, so the transform is a
        // true no-op on the stored payload.
        service.recordSessionReset(
            for: profileID,
            previousUsage: usage,
            resetTime: .distantFuture
        )

        let after = try Data(contentsOf: fileURL)
        XCTAssertEqual(before, after)
    }

    @MainActor
    private func makeClaudeUsage(
        sessionPercentage: Double,
        sessionResetTime: Date
    ) -> ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: 1,
            sessionLimit: 100,
            sessionPercentage: sessionPercentage,
            sessionResetTime: sessionResetTime,
            weeklyTokensUsed: 0,
            weeklyLimit: 100,
            weeklyPercentage: 0,
            weeklyResetTime: sessionResetTime,
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
            lastUpdated: sessionResetTime,
            userTimezone: .current
        )
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
