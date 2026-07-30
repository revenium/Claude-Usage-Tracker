import Foundation
import XCTest
@testable import Claude_Usage

final class ProfileCurrentUsageIntegrationTests: XCTestCase {
    private static var processLifetimeServices: [AnyObject] = []

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "ClaudeUsageTests.CurrentUsage.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testLegacyUsageMigratesToVerifiedFileAndScrubsProfileJSON() throws {
        let profileID = UUID()
        let claude = makeClaudeUsage(tokens: 41)
        let api = makeAPIUsage(spend: 205)
        seedLegacyUsageProfile(id: profileID, claude: claude, api: api)
        let usageFiles = MockCurrentUsageFileStore()
        let store = retain(makeStore(usageFiles: usageFiles))

        let loaded = try store.loadProfilesWithVerifiedMigration()

        XCTAssertEqual(loaded.first?.claudeUsage, claude)
        XCTAssertEqual(loaded.first?.apiUsage, api)
        XCTAssertEqual(
            usageFiles.values[profileID],
            ProfileCurrentUsage(claudeUsage: claude, apiUsage: api)
        )
        let persisted = try persistedProfileText()
        XCTAssertFalse(persisted.contains("\"claudeUsage\""))
        XCTAssertFalse(persisted.contains("\"apiUsage\""))
        XCTAssertFalse(persisted.contains("currentUsageMigrationRetry"))
        XCTAssertFalse(persisted.contains("claudeSessionKey"))

        let relaunched = retain(makeStore(usageFiles: usageFiles))
            .loadProfiles()
        XCTAssertEqual(relaunched.first?.claudeUsage, claude)
        XCTAssertEqual(relaunched.first?.apiUsage, api)
    }

    @MainActor
    func testFailedLegacyMigrationRetainsExplicitRetryUntilReadbackSucceeds() throws {
        let profileID = UUID()
        let claude = makeClaudeUsage(tokens: 72)
        let api = makeAPIUsage(spend: 900)
        seedLegacyUsageProfile(id: profileID, claude: claude, api: api)
        let usageFiles = MockCurrentUsageFileStore()
        usageFiles.saveError = TestFailure.expected
        let store = retain(makeStore(usageFiles: usageFiles))

        let firstLoad = try store.loadProfilesWithVerifiedMigration()

        XCTAssertEqual(firstLoad.first?.claudeUsage, claude)
        XCTAssertEqual(firstLoad.first?.apiUsage, api)
        XCTAssertTrue(try persistedProfileText().contains("currentUsageMigrationRetry"))

        usageFiles.saveError = nil
        let secondLoad = try store.loadProfilesWithVerifiedMigration()
        XCTAssertEqual(secondLoad.first?.claudeUsage, claude)
        XCTAssertEqual(secondLoad.first?.apiUsage, api)
        XCTAssertFalse(try persistedProfileText().contains("currentUsageMigrationRetry"))
        XCTAssertEqual(usageFiles.values[profileID]?.claudeUsage, claude)
    }

    @MainActor
    func testValidCurrentFileWinsOverStaleMigrationRetryEnvelope() throws {
        let profileID = UUID()
        let staleUsage = ProfileCurrentUsage(
            claudeUsage: makeClaudeUsage(tokens: 10),
            apiUsage: makeAPIUsage(spend: 10)
        )
        let currentUsage = ProfileCurrentUsage(
            claudeUsage: makeClaudeUsage(tokens: 90),
            apiUsage: makeAPIUsage(spend: 90)
        )
        let retryProfile = Profile(
            id: profileID,
            name: "Interrupted Migration",
            claudeUsage: staleUsage.claudeUsage,
            apiUsage: staleUsage.apiUsage,
            currentUsageMigrationRetry: staleUsage
        )
        defaults.set(
            try JSONEncoder().encode([retryProfile]),
            forKey: "profiles_v3"
        )
        let usageFiles = MockCurrentUsageFileStore()
        usageFiles.values[profileID] = currentUsage
        let store = retain(makeStore(usageFiles: usageFiles))

        let loaded = try store.loadProfilesWithVerifiedMigration()

        XCTAssertEqual(loaded.first?.claudeUsage, currentUsage.claudeUsage)
        XCTAssertEqual(loaded.first?.apiUsage, currentUsage.apiUsage)
        XCTAssertEqual(usageFiles.values[profileID], currentUsage)
        XCTAssertEqual(usageFiles.saveCount, 0)
        XCTAssertFalse(try persistedProfileText().contains("currentUsageMigrationRetry"))
    }

    @MainActor
    func testReadErrorStaysUnresolvedAndMetadataSaveIsUsageNeutral() throws {
        let profileID = UUID()
        let existing = ProfileCurrentUsage(
            claudeUsage: makeClaudeUsage(tokens: 19),
            apiUsage: makeAPIUsage(spend: 88)
        )
        let usageFiles = MockCurrentUsageFileStore()
        usageFiles.values[profileID] = existing
        let setupStore = retain(makeStore(usageFiles: usageFiles))
        try setupStore.saveProfilesThrowing([Profile(id: profileID, name: "Before")])

        usageFiles.loadErrors[profileID] = TestFailure.expected
        let store = retain(makeStore(usageFiles: usageFiles))
        var profiles = store.loadProfiles()
        XCTAssertNil(profiles.first?.claudeUsage)
        profiles[0].name = "After"

        try store.saveProfilesThrowing(profiles)

        XCTAssertEqual(usageFiles.values[profileID], existing)
        XCTAssertEqual(usageFiles.updateCount, 0)
        XCTAssertEqual(usageFiles.deleteAllCount, 0)
        XCTAssertThrowsError(try store.loadClaudeUsage(for: profileID))
        XCTAssertEqual(store.loadProfiles().first?.name, "After")
    }

    @MainActor
    func testCorruptCurrentFileCannotBecomeImplicitAbsenceAfterQuarantine() throws {
        let profileID = UUID()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CurrentUsageCorruption-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let usageFiles = ProfileUsageFileStore(baseURL: rootURL)
        let oldUsage = ProfileCurrentUsage(
            claudeUsage: makeClaudeUsage(tokens: 44)
        )
        try usageFiles.saveCurrentUsage(oldUsage, for: profileID)
        let currentURL = try usageFiles.fileURL(for: profileID, kind: .currentUsage)
        try Data("not-json".utf8).write(to: currentURL)
        let store = retain(
            ProfileStore(
                defaults: defaults,
                secretStore: MockSecretStore(),
                usageFileStore: usageFiles
            )
        )
        try store.saveProfilesThrowing([Profile(id: profileID, name: "Before")])

        var loaded = store.loadProfiles()
        XCTAssertNil(loaded.first?.claudeUsage)
        loaded[0].name = "After"
        try store.saveProfilesThrowing(loaded)

        XCTAssertThrowsError(
            try store.saveClaudeUsage(makeClaudeUsage(tokens: 99), for: profileID)
        ) { error in
            guard case ProfileUsageFileStoreError.currentUsageReadUnresolved = error else {
                return XCTFail("Expected unresolved current usage, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentURL.path))
        XCTAssertEqual(store.loadProfiles().first?.name, "After")
    }

    @MainActor
    func testExplicitComponentUpdatesPreserveOtherComponentAndProfileIsolation() throws {
        let firstID = UUID()
        let secondID = UUID()
        let firstClaude = makeClaudeUsage(tokens: 11)
        let firstAPI = makeAPIUsage(spend: 22)
        let secondAPI = makeAPIUsage(spend: 33)
        let usageFiles = MockCurrentUsageFileStore()
        let store = retain(makeStore(usageFiles: usageFiles))
        try store.saveProfilesThrowing([
            Profile(id: firstID, name: "First"),
            Profile(id: secondID, name: "Second")
        ])

        try store.saveClaudeUsage(firstClaude, for: firstID)
        try store.saveAPIUsage(firstAPI, for: firstID)
        try store.saveAPIUsage(secondAPI, for: secondID)

        XCTAssertEqual(try store.loadClaudeUsage(for: firstID), firstClaude)
        XCTAssertEqual(try store.loadAPIUsage(for: firstID), firstAPI)
        XCTAssertEqual(try store.loadAPIUsage(for: secondID), secondAPI)
        XCTAssertNil(try store.loadClaudeUsage(for: secondID))

        try store.clearClaudeUsage(for: firstID)
        XCTAssertNil(try store.loadClaudeUsage(for: firstID))
        XCTAssertEqual(try store.loadAPIUsage(for: firstID), firstAPI)
        XCTAssertEqual(try store.loadAPIUsage(for: secondID), secondAPI)
        XCTAssertFalse(try persistedProfileText().contains("\"apiUsage\""))
    }

    @MainActor
    func testManagerPublishesUsageOnlyAfterVerifiedPersistence() throws {
        let profileID = UUID()
        let oldUsage = makeClaudeUsage(tokens: 1)
        let newUsage = makeClaudeUsage(tokens: 2)
        let usageFiles = MockCurrentUsageFileStore()
        usageFiles.values[profileID] = ProfileCurrentUsage(claudeUsage: oldUsage)
        let store = retain(makeStore(usageFiles: usageFiles))
        try store.saveProfilesThrowing([Profile(id: profileID, name: "Profile")])
        let history = retain(MockHistoryDeleter())
        let manager = retain(
            ProfileManager(profileStore: store, historyService: history)
        )
        manager.profiles = [
            Profile(id: profileID, name: "Profile", claudeUsage: oldUsage)
        ]
        manager.activeProfile = manager.profiles[0]
        usageFiles.updateError = TestFailure.expected

        manager.saveClaudeUsage(newUsage, for: profileID)

        XCTAssertEqual(manager.profiles.first?.claudeUsage, oldUsage)
        XCTAssertEqual(manager.activeProfile?.claudeUsage, oldUsage)
        XCTAssertEqual(usageFiles.values[profileID]?.claudeUsage, oldUsage)
    }

    @MainActor
    func testCredentialRemovalFailureDoesNotPublishCredentialOrUsageChanges() throws {
        let profileID = UUID()
        let usage = makeClaudeUsage(tokens: 54)
        let secrets = MockSecretStore()
        secrets.values[ProfileSecretLocator(
            profileID: profileID,
            field: .claudeSessionKey
        )] = "session"
        let usageFiles = MockCurrentUsageFileStore()
        usageFiles.values[profileID] = ProfileCurrentUsage(claudeUsage: usage)
        let store = retain(
            ProfileStore(
                defaults: defaults,
                secretStore: secrets,
                usageFileStore: usageFiles
            )
        )
        try store.saveProfilesThrowing([
            Profile(
                id: profileID,
                name: "Profile",
                organizationId: "org"
            )
        ])
        let manager = retain(
            ProfileManager(
                profileStore: store,
                historyService: retain(MockHistoryDeleter())
            )
        )
        manager.profiles = [
            Profile(
                id: profileID,
                name: "Profile",
                claudeSessionKey: "session",
                organizationId: "org",
                claudeUsage: usage
            )
        ]
        manager.activeProfile = manager.profiles[0]
        usageFiles.updateError = TestFailure.expected

        XCTAssertThrowsError(
            try manager.removeClaudeAICredentials(for: profileID)
        )

        XCTAssertEqual(manager.profiles.first?.claudeSessionKey, "session")
        XCTAssertEqual(manager.profiles.first?.organizationId, "org")
        XCTAssertEqual(manager.profiles.first?.claudeUsage, usage)
        XCTAssertEqual(
            secrets.values[ProfileSecretLocator(
                profileID: profileID,
                field: .claudeSessionKey
            )],
            "session"
        )
    }

    @MainActor
    func testProfileDeletionFailureRetainsIdentityAndSuccessRemovesAllData() throws {
        let deletedID = UUID()
        let retainedID = UUID()
        let claudeUsage = makeClaudeUsage(tokens: 80)
        let apiUsage = makeAPIUsage(spend: 80)
        let secrets = MockSecretStore()
        let usageFiles = MockCurrentUsageFileStore()
        usageFiles.values[deletedID] = ProfileCurrentUsage(
            claudeUsage: claudeUsage,
            apiUsage: apiUsage
        )
        let store = retain(makeStore(usageFiles: usageFiles, secrets: secrets))
        let initialProfiles = [
            Profile(
                id: deletedID,
                name: "Delete",
                claudeSessionKey: "claude-secret",
                apiSessionKey: "api-secret",
                cliCredentialsJSON: "cli-secret",
                claudeUsage: claudeUsage,
                apiUsage: apiUsage
            ),
            Profile(id: retainedID, name: "Keep")
        ]
        try store.saveProfilesThrowing(initialProfiles)
        let history = retain(MockHistoryDeleter())
        let manager = retain(
            ProfileManager(profileStore: store, historyService: history)
        )
        manager.profiles = initialProfiles
        manager.activeProfile = initialProfiles[0]
        usageFiles.deleteError = TestFailure.expected

        XCTAssertThrowsError(try manager.deleteProfile(deletedID))
        XCTAssertEqual(manager.profiles.map(\.id), initialProfiles.map(\.id))
        XCTAssertEqual(try persistedProfileIDs(), initialProfiles.map(\.id))
        XCTAssertNil(manager.profiles[0].claudeSessionKey)
        XCTAssertNil(manager.profiles[0].apiSessionKey)
        XCTAssertNil(manager.profiles[0].cliCredentialsJSON)
        XCTAssertNil(manager.activeProfile?.claudeSessionKey)
        XCTAssertEqual(manager.profiles[0].claudeUsage, claudeUsage)
        XCTAssertEqual(manager.profiles[0].apiUsage, apiUsage)
        XCTAssertNotNil(usageFiles.values[deletedID])

        usageFiles.deleteError = nil
        try manager.deleteProfile(deletedID)

        XCTAssertEqual(manager.profiles.map(\.id), [retainedID])
        XCTAssertEqual(try persistedProfileIDs(), [retainedID])
        XCTAssertNil(usageFiles.values[deletedID])
        XCTAssertTrue(history.deletedProfileIDs.contains(deletedID))
    }

    @MainActor
    func testHistoryDeletionFailureRetainsIdentityWithSecretsScrubbed() throws {
        let deletedID = UUID()
        let retainedID = UUID()
        let usage = makeClaudeUsage(tokens: 61)
        let secrets = MockSecretStore()
        let usageFiles = MockCurrentUsageFileStore()
        usageFiles.values[deletedID] = ProfileCurrentUsage(claudeUsage: usage)
        let store = retain(makeStore(usageFiles: usageFiles, secrets: secrets))
        let initialProfiles = [
            Profile(
                id: deletedID,
                name: "Delete",
                claudeSessionKey: "claude-secret",
                apiSessionKey: "api-secret",
                cliCredentialsJSON: "cli-secret",
                claudeUsage: usage
            ),
            Profile(id: retainedID, name: "Keep")
        ]
        try store.saveProfilesThrowing(initialProfiles)
        let history = retain(MockHistoryDeleter())
        history.deleteError = TestFailure.expected
        let manager = retain(
            ProfileManager(profileStore: store, historyService: history)
        )
        manager.profiles = initialProfiles
        manager.activeProfile = initialProfiles[0]

        XCTAssertThrowsError(try manager.deleteProfile(deletedID))

        XCTAssertEqual(manager.profiles.map(\.id), initialProfiles.map(\.id))
        XCTAssertNil(manager.profiles[0].claudeSessionKey)
        XCTAssertNil(manager.profiles[0].apiSessionKey)
        XCTAssertNil(manager.profiles[0].cliCredentialsJSON)
        XCTAssertNil(manager.activeProfile?.claudeSessionKey)
        XCTAssertEqual(manager.profiles[0].claudeUsage, usage)
        XCTAssertEqual(usageFiles.values[deletedID]?.claudeUsage, usage)
        XCTAssertEqual(usageFiles.deleteAllCount, 0)
        for field in ProfileSecretField.allCases {
            XCTAssertNil(
                secrets.values[ProfileSecretLocator(
                    profileID: deletedID,
                    field: field
                )]
            )
        }
    }

    @MainActor
    func testMetadataRemovalFailureRetainsIdentityWithUsageAndSecretsScrubbed() throws {
        let deletedID = UUID()
        let retainedID = UUID()
        let usage = makeClaudeUsage(tokens: 71)
        let backing = FaultingCurrentUsageDefaults()
        let secrets = MockSecretStore()
        let usageFiles = MockCurrentUsageFileStore()
        usageFiles.values[deletedID] = ProfileCurrentUsage(claudeUsage: usage)
        let store = retain(
            ProfileStore(
                defaults: backing,
                secretStore: secrets,
                usageFileStore: usageFiles
            )
        )
        let initialProfiles = [
            Profile(
                id: deletedID,
                name: "Delete",
                claudeSessionKey: "claude-secret",
                apiSessionKey: "api-secret",
                cliCredentialsJSON: "cli-secret",
                claudeUsage: usage
            ),
            Profile(id: retainedID, name: "Keep")
        ]
        try store.saveProfilesThrowing(initialProfiles)
        let history = retain(MockHistoryDeleter())
        let manager = retain(
            ProfileManager(profileStore: store, historyService: history)
        )
        manager.profiles = initialProfiles
        manager.activeProfile = initialProfiles[0]
        backing.corruptNextProfileWrite = true

        XCTAssertThrowsError(try manager.deleteProfile(deletedID))

        XCTAssertEqual(manager.profiles.map(\.id), initialProfiles.map(\.id))
        XCTAssertNil(manager.profiles[0].claudeSessionKey)
        XCTAssertNil(manager.profiles[0].apiSessionKey)
        XCTAssertNil(manager.profiles[0].cliCredentialsJSON)
        XCTAssertNil(manager.profiles[0].claudeUsage)
        XCTAssertNil(manager.profiles[0].apiUsage)
        XCTAssertNil(manager.activeProfile?.claudeUsage)
        XCTAssertNil(usageFiles.values[deletedID])
        let persistedData = try XCTUnwrap(backing.data(forKey: "profiles_v3"))
        XCTAssertEqual(
            try JSONDecoder().decode([Profile].self, from: persistedData).map(\.id),
            initialProfiles.map(\.id)
        )
    }

    @MainActor
    private func makeStore(
        usageFiles: MockCurrentUsageFileStore,
        secrets: MockSecretStore = MockSecretStore()
    ) -> ProfileStore {
        ProfileStore(
            defaults: defaults,
            secretStore: secrets,
            usageFileStore: usageFiles
        )
    }

    @MainActor
    private func seedLegacyUsageProfile(
        id: UUID,
        claude: ClaudeUsage,
        api: APIUsage
    ) {
        let legacy = LegacyUsageProfile(
            id: id,
            name: "Legacy",
            claudeUsage: claude,
            apiUsage: api
        )
        defaults.set(try! JSONEncoder().encode([legacy]), forKey: "profiles_v3")
    }

    private func persistedProfileText() throws -> String {
        let data = try XCTUnwrap(defaults.data(forKey: "profiles_v3"))
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func persistedProfileIDs() throws -> [UUID] {
        let data = try XCTUnwrap(defaults.data(forKey: "profiles_v3"))
        return try JSONDecoder().decode([Profile].self, from: data).map(\.id)
    }

    private func makeClaudeUsage(tokens: Int) -> ClaudeUsage {
        var usage = ClaudeUsage.empty
        usage.sessionTokensUsed = tokens
        usage.sessionPercentage = Double(tokens)
        usage.lastUpdated = Date(timeIntervalSinceReferenceDate: Double(tokens))
        return usage
    }

    private func makeAPIUsage(spend: Int) -> APIUsage {
        APIUsage(
            currentSpendCents: spend,
            resetsAt: Date(timeIntervalSinceReferenceDate: 500),
            prepaidCreditsCents: 1_000,
            currency: "USD",
            apiTokenCostCents: nil,
            apiCostByModel: nil,
            costBySource: nil,
            dailyCostCents: nil
        )
    }

    private func retain<T: AnyObject>(_ service: T) -> T {
        Self.processLifetimeServices.append(service)
        return service
    }
}

private struct LegacyUsageProfile: Encodable {
    let id: UUID
    let name: String
    let claudeUsage: ClaudeUsage
    let apiUsage: APIUsage
}

private enum TestFailure: Error {
    case expected
}

private final class MockCurrentUsageFileStore: ProfileCurrentUsageFileStoring {
    var values: [UUID: ProfileCurrentUsage] = [:]
    var loadErrors: [UUID: Error] = [:]
    var saveError: Error?
    var updateError: Error?
    var deleteError: Error?
    var updateCount = 0
    var deleteAllCount = 0
    var saveCount = 0

    func loadCurrentUsage(for profileID: UUID) throws -> ProfileCurrentUsage? {
        if let error = loadErrors[profileID] {
            throw error
        }
        return values[profileID]
    }

    func saveCurrentUsage(_ usage: ProfileCurrentUsage, for profileID: UUID) throws {
        saveCount += 1
        if let saveError {
            throw saveError
        }
        values[profileID] = usage
        guard try loadCurrentUsage(for: profileID) == usage else {
            throw TestFailure.expected
        }
    }

    @discardableResult
    func updateCurrentUsage(
        for profileID: UUID,
        transform: (inout ProfileCurrentUsage) throws -> Void
    ) throws -> ProfileCurrentUsage {
        updateCount += 1
        if let updateError {
            throw updateError
        }
        var usage = try loadCurrentUsage(for: profileID) ?? ProfileCurrentUsage()
        try transform(&usage)
        values[profileID] = usage
        return usage
    }

    func deleteAllData(for profileID: UUID) throws {
        deleteAllCount += 1
        if let deleteError {
            throw deleteError
        }
        values.removeValue(forKey: profileID)
    }
}

private final class MockSecretStore: ProfileSecretStore {
    var values: [ProfileSecretLocator: String] = [:]

    func read(_ locator: ProfileSecretLocator) throws -> ProfileSecretReadResult {
        values[locator].map(ProfileSecretReadResult.value) ?? .absent
    }

    func write(_ value: String, to locator: ProfileSecretLocator) throws {
        values[locator] = value
    }

    func delete(_ locator: ProfileSecretLocator) throws {
        values.removeValue(forKey: locator)
    }
}

private final class FaultingCurrentUsageDefaults: ProfileDefaultsStore {
    var storage: [String: Any] = [:]
    var corruptNextProfileWrite = false

    func data(forKey defaultName: String) -> Data? {
        storage[defaultName] as? Data
    }

    func string(forKey defaultName: String) -> String? {
        storage[defaultName] as? String
    }

    func set(_ value: Any?, forKey defaultName: String) {
        if corruptNextProfileWrite, defaultName == "profiles_v3" {
            corruptNextProfileWrite = false
            storage[defaultName] = Data("corrupt".utf8)
        } else {
            storage[defaultName] = value
        }
    }

    func removeObject(forKey defaultName: String) {
        storage.removeValue(forKey: defaultName)
    }
}

@MainActor
private final class MockHistoryDeleter: ProfileHistoryDeleting {
    var deleteError: Error?
    var deletedProfileIDs: [UUID] = []

    func deleteHistoryThrowing(for profileId: UUID) throws {
        if let deleteError {
            throw deleteError
        }
        deletedProfileIDs.append(profileId)
    }
}
