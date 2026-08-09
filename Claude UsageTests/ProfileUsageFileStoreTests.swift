import Foundation
import XCTest
@testable import Claude_Usage

final class ProfileUsageFileStoreTests: XCTestCase {
    nonisolated private struct Fixture: Codable, Equatable {
        let value: String
    }

    func testUsesVersionedLayoutAndValidatedProviderNeutralEnvelope() throws {
        let rootURL = try makeTemporaryRoot()
        let profileID = UUID()
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)
        let dates = LockedValues([firstDate, secondDate])
        let store = ProfileUsageFileStore(baseURL: rootURL, now: {
            dates.next()
        })

        try store.save(
            Fixture(value: "first"),
            for: profileID,
            providerID: "codex",
            kind: .history
        )
        try store.save(
            Fixture(value: "second"),
            for: profileID,
            providerID: "codex",
            kind: .history
        )

        let fileURL = try store.fileURL(for: profileID, kind: .history)
        XCTAssertEqual(
            fileURL.path,
            rootURL
                .appendingPathComponent(profileID.uuidString.lowercased())
                .appendingPathComponent("history-v1.json")
                .path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path + ".bak"))

        let data = try Data(contentsOf: fileURL)
        let envelope = try JSONDecoder().decode(
            ProfileUsageFileEnvelope<Fixture>.self,
            from: data
        )
        XCTAssertEqual(envelope.schemaVersion, 1)
        XCTAssertEqual(envelope.profileID, profileID)
        XCTAssertEqual(envelope.providerID, "codex")
        XCTAssertEqual(envelope.recordKind, .history)
        XCTAssertEqual(envelope.writtenAt, firstDate)
        XCTAssertEqual(envelope.updatedAt, secondDate)
        XCTAssertEqual(envelope.payload, Fixture(value: "second"))
    }

    @MainActor
    func testTypedCurrentUsageRoundTripAndComponentUpdate() throws {
        let store = ProfileUsageFileStore(baseURL: try makeTemporaryRoot())
        let profileID = UUID()
        let claude = ClaudeUsage.empty
        let api = APIUsage(
            currentSpendCents: 25,
            resetsAt: Date(timeIntervalSinceReferenceDate: 50),
            prepaidCreditsCents: 100,
            currency: "USD",
            apiTokenCostCents: nil,
            apiCostByModel: nil,
            costBySource: nil,
            dailyCostCents: nil
        )
        let initial = ProfileCurrentUsage(claudeUsage: claude)

        try store.saveCurrentUsage(initial, for: profileID)
        let updated = try store.updateCurrentUsage(for: profileID) { usage in
            usage.apiUsage = api
        }

        XCTAssertEqual(updated.claudeUsage, claude)
        XCTAssertEqual(updated.apiUsage, api)
        XCTAssertEqual(try store.loadCurrentUsage(for: profileID), updated)
    }

    func testValidatesProviderAndRecordKind() throws {
        let rootURL = try makeTemporaryRoot()
        let profileID = UUID()
        let atomicStore = AtomicJSONFileStore(baseURL: rootURL)
        let store = ProfileUsageFileStore(atomicStore: atomicStore)
        let envelope = ProfileUsageFileEnvelope(
            profileID: profileID,
            providerID: "claude",
            recordKind: .currentUsage,
            writtenAt: Date(),
            updatedAt: Date(),
            payload: Fixture(value: "value")
        )
        try atomicStore.write(
            envelope,
            to: "\(profileID.uuidString.lowercased())/history-v1.json"
        )

        XCTAssertThrowsError(
            try store.load(
                Fixture.self,
                for: profileID,
                providerID: "codex",
                kind: .history
            )
        ) { error in
            guard case ProfileUsageFileStoreError.providerMismatch = error else {
                return XCTFail("Expected provider mismatch, got \(error)")
            }
        }

        XCTAssertThrowsError(
            try store.load(
                Fixture.self,
                for: profileID,
                providerID: "claude",
                kind: .history
            )
        ) { error in
            guard case ProfileUsageFileStoreError.recordKindMismatch = error else {
                return XCTFail("Expected record kind mismatch, got \(error)")
            }
        }
    }

    func testValidatesSchemaVersionAndProfileIdentity() throws {
        let rootURL = try makeTemporaryRoot()
        let profileID = UUID()
        let otherProfileID = UUID()
        let atomicStore = AtomicJSONFileStore(baseURL: rootURL)
        let store = ProfileUsageFileStore(atomicStore: atomicStore)
        let path = "\(profileID.uuidString.lowercased())/history-v1.json"

        try atomicStore.write(
            ProfileUsageFileEnvelope(
                profileID: otherProfileID,
                providerID: "claude",
                recordKind: .history,
                writtenAt: Date(),
                updatedAt: Date(),
                payload: Fixture(value: "value")
            ),
            to: path
        )
        XCTAssertThrowsError(
            try store.load(
                Fixture.self,
                for: profileID,
                providerID: "claude",
                kind: .history
            )
        ) { error in
            guard case ProfileUsageFileStoreError.profileMismatch = error else {
                return XCTFail("Expected profile mismatch, got \(error)")
            }
        }

        try atomicStore.write(
            ProfileUsageFileEnvelope(
                schemaVersion: 99,
                profileID: profileID,
                providerID: "claude",
                recordKind: .history,
                writtenAt: Date(),
                updatedAt: Date(),
                payload: Fixture(value: "value")
            ),
            to: path
        )
        XCTAssertThrowsError(
            try store.load(
                Fixture.self,
                for: profileID,
                providerID: "claude",
                kind: .history
            )
        ) { error in
            guard case ProfileUsageFileStoreError.unsupportedSchemaVersion(
                found: 99,
                supported: 1
            ) = error else {
                return XCTFail("Expected schema mismatch, got \(error)")
            }
        }
    }

    func testRejectsReverseTimestampsAndDoesNotOverwriteMismatchedEnvelopeOnSave() throws {
        let rootURL = try makeTemporaryRoot()
        let profileID = UUID()
        let atomicStore = AtomicJSONFileStore(baseURL: rootURL)
        let store = ProfileUsageFileStore(atomicStore: atomicStore)
        let path = "\(profileID.uuidString.lowercased())/history-v1.json"

        try atomicStore.write(
            ProfileUsageFileEnvelope(
                profileID: profileID,
                providerID: "claude",
                recordKind: .history,
                writtenAt: Date(timeIntervalSince1970: 200),
                updatedAt: Date(timeIntervalSince1970: 100),
                payload: Fixture(value: "reverse-time")
            ),
            to: path
        )
        XCTAssertThrowsError(
            try store.load(
                Fixture.self,
                for: profileID,
                providerID: "claude",
                kind: .history
            )
        ) { error in
            guard case ProfileUsageFileStoreError.invalidTimestampChronology = error else {
                return XCTFail("Expected timestamp chronology error, got \(error)")
            }
        }

        let originalEnvelope = ProfileUsageFileEnvelope(
            profileID: profileID,
            providerID: "claude",
            recordKind: .history,
            writtenAt: Date(timeIntervalSince1970: 300),
            updatedAt: Date(timeIntervalSince1970: 300),
            payload: Fixture(value: "preserve-me")
        )
        try atomicStore.write(originalEnvelope, to: path)
        XCTAssertThrowsError(
            try store.save(
                Fixture(value: "do-not-install"),
                for: profileID,
                providerID: "codex",
                kind: .history
            )
        ) { error in
            guard case ProfileUsageFileStoreError.providerMismatch = error else {
                return XCTFail("Expected provider mismatch, got \(error)")
            }
        }

        let preserved = try XCTUnwrap(
            try atomicStore.read(
                ProfileUsageFileEnvelope<Fixture>.self,
                from: path
            )
        )
        XCTAssertEqual(preserved.providerID, "claude")
        XCTAssertEqual(preserved.payload, Fixture(value: "preserve-me"))
    }

    func testClockRollbackDoesNotCreateReverseTimestampChronology() throws {
        let rootURL = try makeTemporaryRoot()
        let profileID = UUID()
        let firstDate = Date(timeIntervalSince1970: 200)
        let earlierDate = Date(timeIntervalSince1970: 100)
        let dates = LockedValues([firstDate, earlierDate])
        let store = ProfileUsageFileStore(baseURL: rootURL, now: {
            dates.next()
        })

        try store.save(
            Fixture(value: "first"),
            for: profileID,
            providerID: "claude",
            kind: .history
        )
        try store.save(
            Fixture(value: "second"),
            for: profileID,
            providerID: "claude",
            kind: .history
        )

        let envelope = try JSONDecoder().decode(
            ProfileUsageFileEnvelope<Fixture>.self,
            from: Data(contentsOf: try store.fileURL(for: profileID, kind: .history))
        )
        XCTAssertEqual(envelope.writtenAt, firstDate)
        XCTAssertEqual(envelope.updatedAt, firstDate)
        XCTAssertEqual(
            try store.load(
                Fixture.self,
                for: profileID,
                providerID: "claude",
                kind: .history
            ),
            Fixture(value: "second")
        )
    }

    func testConcurrentUpdatesDoNotLosePayloadMutations() throws {
        let store = ProfileUsageFileStore(baseURL: try makeTemporaryRoot())
        let profileID = UUID()
        let errors = LockedValues<Error>([])

        DispatchQueue.concurrentPerform(iterations: 40) { index in
            do {
                try store.update(
                    [Int].self,
                    for: profileID,
                    providerID: "codex",
                    kind: .history,
                    initialValue: []
                ) { values in
                    values.append(index)
                }
            } catch {
                errors.append(error)
            }
        }

        XCTAssertTrue(errors.values.isEmpty, "Unexpected errors: \(errors.values)")
        let values = try XCTUnwrap(
            store.load(
                [Int].self,
                for: profileID,
                providerID: "codex",
                kind: .history
            )
        )
        XCTAssertEqual(values.sorted(), Array(0..<40))
    }

    func testDeleteRemovesOwnedRecordArtifactsAndWholeProfileData() throws {
        let rootURL = try makeTemporaryRoot()
        let store = ProfileUsageFileStore(baseURL: rootURL)
        let profileID = UUID()

        try store.save(
            Fixture(value: "history-1"),
            for: profileID,
            providerID: "claude",
            kind: .history
        )
        try store.save(
            Fixture(value: "history-2"),
            for: profileID,
            providerID: "claude",
            kind: .history
        )
        try store.save(
            Fixture(value: "current"),
            for: profileID,
            providerID: "claude",
            kind: .currentUsage
        )
        XCTAssertEqual(
            try store.fileURL(for: profileID, kind: .currentUsage).lastPathComponent,
            "current-v1.json"
        )

        let historyURL = try store.fileURL(for: profileID, kind: .history)
        let quarantineURL = historyURL
            .deletingLastPathComponent()
            .appendingPathComponent("history-v1.json.corrupt-owned")
        let temporaryURL = historyURL
            .deletingLastPathComponent()
            .appendingPathComponent(".history-v1.json.owned.tmp")
        try Data().write(to: quarantineURL)
        try Data().write(to: temporaryURL)

        try store.delete(for: profileID, kind: .history)
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyURL.path + ".bak"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantineURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: try store.fileURL(for: profileID, kind: .currentUsage).path
            )
        )

        try store.deleteAllData(for: profileID)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: historyURL.deletingLastPathComponent().path
            )
        )
    }

    func testArchiveCopiesCurrentPrimaryAndDeleteRemovesIt() throws {
        let rootURL = try makeTemporaryRoot()
        let store = ProfileUsageFileStore(baseURL: rootURL)
        let profileID = UUID()

        XCTAssertNil(
            try store.archive(Fixture.self, for: profileID, kind: .history)
        )

        try store.save(
            Fixture(value: "pre-repair"),
            for: profileID,
            providerID: "claude",
            kind: .history
        )
        let archiveURL = try XCTUnwrap(
            try store.archive(Fixture.self, for: profileID, kind: .history)
        )
        let archivedEnvelope = try JSONDecoder().decode(
            ProfileUsageFileEnvelope<Fixture>.self,
            from: Data(contentsOf: archiveURL)
        )
        XCTAssertEqual(archivedEnvelope.payload, Fixture(value: "pre-repair"))

        try store.delete(for: profileID, kind: .history)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
    }

    func testSweepStaleArtifactsDelegatesAcrossProfiles() throws {
        let rootURL = try makeTemporaryRoot()
        let store = ProfileUsageFileStore(baseURL: rootURL)
        let profileID = UUID()
        try store.save(
            Fixture(value: "current"),
            for: profileID,
            providerID: "claude",
            kind: .history
        )

        let historyURL = try store.fileURL(for: profileID, kind: .history)
        let staleTmp = historyURL
            .deletingLastPathComponent()
            .appendingPathComponent(".history-v1.json.stale.tmp")
        try Data().write(to: staleTmp)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: staleTmp.path
        )

        store.sweepStaleArtifacts(now: Date())

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleTmp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: historyURL.path))
    }

    private func makeTemporaryRoot() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileUsageFileStoreTests-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }
        return rootURL
    }
}

nonisolated private final class LockedValues<Value>: @unchecked Sendable {
    private var storage: [Value]
    private let lock = NSLock()

    init(_ values: [Value]) {
        storage = values
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func next() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return storage.removeFirst()
    }

    func append(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }
}
