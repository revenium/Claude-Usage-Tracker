import XCTest
@testable import Claude_Usage

final class ProfileSecurityIntegrationTests: XCTestCase {
    // The app target uses main-actor default isolation. On the current macOS
    // XCTest runtime, releasing injected actor-isolated app services from the
    // Objective-C test thunk triggers a runtime allocator bug. Production uses
    // process-lifetime singletons; mirror that lifetime for injected services.
    private static var processLifetimeServices: [AnyObject] = []

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "ClaudeUsageTests.ProfileSecurity.\(UUID().uuidString)"
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
    func testProfileEncodingOmitsLegacySecretKeysAndPreservesMetadata() throws {
        let expiry = Date(timeIntervalSinceReferenceDate: 123_456)
        let profile = Profile(
            name: "Metadata",
            claudeSessionKey: "CLAUDE_FIXTURE_SECRET",
            organizationId: "org",
            apiSessionKey: "API_FIXTURE_SECRET",
            apiOrganizationId: "api-org",
            apiSessionKeyExpiry: expiry,
            cliCredentialsJSON: "CLI_FIXTURE_SECRET",
            hasCliAccount: true,
            cliAccountSyncedAt: expiry,
            cliAccountName: "linked-account"
        )

        let data = try JSONEncoder().encode(profile)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertNil(object["claudeSessionKey"])
        XCTAssertNil(object["apiSessionKey"])
        XCTAssertNil(object["cliCredentialsJSON"])
        XCTAssertNil(object["credentialMigrationRetry"])
        XCTAssertEqual(object["cliAccountName"] as? String, "linked-account")

        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        XCTAssertEqual(decoded.apiSessionKeyExpiry, expiry)
        XCTAssertEqual(decoded.cliAccountName, "linked-account")
    }

    func testHostedUnitTestLaunchGuardIsActive() {
        XCTAssertTrue(AppDelegate.isRunningHostedUnitTests)
    }

    @MainActor
    func testLegacyProfileDecodesAndReencodesAsExplicitRetryEnvelope() throws {
        let id = UUID()
        let legacyObject: [[String: Any]] = [[
            "id": id.uuidString,
            "name": "Legacy",
            "claudeSessionKey": "LEGACY_CLAUDE_FIXTURE",
            "apiSessionKey": "LEGACY_API_FIXTURE",
            "cliCredentialsJSON": "LEGACY_CLI_FIXTURE",
            "cliAccountName": "legacy-link",
            "apiSessionKeyExpiry": 99.0
        ]]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)

        let decoded = try JSONDecoder().decode([Profile].self, from: legacyData)
        XCTAssertEqual(decoded.first?.claudeSessionKey, "LEGACY_CLAUDE_FIXTURE")
        XCTAssertEqual(decoded.first?.apiSessionKey, "LEGACY_API_FIXTURE")
        XCTAssertEqual(decoded.first?.cliCredentialsJSON, "LEGACY_CLI_FIXTURE")

        let rewritten = try JSONEncoder().encode(decoded)
        let text = try XCTUnwrap(String(data: rewritten, encoding: .utf8))
        XCTAssertFalse(text.contains("\"claudeSessionKey\""))
        XCTAssertFalse(text.contains("\"apiSessionKey\""))
        XCTAssertFalse(text.contains("\"cliCredentialsJSON\""))
        XCTAssertTrue(text.contains("\"credentialMigrationRetry\""))
        XCTAssertTrue(text.contains("LEGACY_CLAUDE_FIXTURE"))
    }

    func testSuccessfulLegacyMigrationScrubsAllPlaintext() throws {
        let profileID = UUID()
        seedLegacyProfile(
            id: profileID,
            claude: "SUCCESS_CLAUDE_FIXTURE",
            api: "SUCCESS_API_FIXTURE",
            cli: "SUCCESS_CLI_FIXTURE"
        )
        let secrets = MockProfileSecretStore()
        let store = retain(ProfileStore(defaults: defaults, secretStore: secrets))

        let profiles = try store.loadProfilesWithVerifiedMigration()

        XCTAssertEqual(profiles.first?.claudeSessionKey, "SUCCESS_CLAUDE_FIXTURE")
        XCTAssertEqual(profiles.first?.apiSessionKey, "SUCCESS_API_FIXTURE")
        XCTAssertEqual(profiles.first?.cliCredentialsJSON, "SUCCESS_CLI_FIXTURE")
        let persisted = try persistedProfileText()
        XCTAssertFalse(persisted.contains("SUCCESS_CLAUDE_FIXTURE"))
        XCTAssertFalse(persisted.contains("SUCCESS_API_FIXTURE"))
        XCTAssertFalse(persisted.contains("SUCCESS_CLI_FIXTURE"))
        XCTAssertFalse(persisted.contains("credentialMigrationRetry"))
    }

    func testPartialMigrationKeepsOnlyFailedFieldAsRetryFallback() throws {
        let profileID = UUID()
        seedLegacyProfile(
            id: profileID,
            claude: "PARTIAL_CLAUDE_FIXTURE",
            api: "PARTIAL_API_FIXTURE",
            cli: "PARTIAL_CLI_FIXTURE"
        )
        let secrets = MockProfileSecretStore()
        secrets.writeErrors[.apiSessionKey] = TestError.expected
        let store = retain(ProfileStore(defaults: defaults, secretStore: secrets))

        let profiles = try store.loadProfilesWithVerifiedMigration()

        XCTAssertEqual(profiles.first?.apiSessionKey, "PARTIAL_API_FIXTURE")
        let persisted = try persistedProfileText()
        XCTAssertFalse(persisted.contains("PARTIAL_CLAUDE_FIXTURE"))
        XCTAssertTrue(persisted.contains("PARTIAL_API_FIXTURE"))
        XCTAssertFalse(persisted.contains("PARTIAL_CLI_FIXTURE"))

        secrets.writeErrors.removeValue(forKey: .apiSessionKey)
        _ = try store.loadProfilesWithVerifiedMigration()
        XCTAssertFalse(try persistedProfileText().contains("PARTIAL_API_FIXTURE"))
    }

    func testReadFailureIsUnresolvedAndMetadataSaveDoesNotDeleteSecret() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        secrets.values[locator(profileID, .claudeSessionKey)] = "READ_FAILURE_FIXTURE"
        let setupStore = retain(ProfileStore(defaults: defaults, secretStore: secrets))
        try setupStore.saveProfilesThrowing([Profile(id: profileID, name: "Before")])

        secrets.readErrors[.claudeSessionKey] = TestError.expected
        let store = retain(ProfileStore(defaults: defaults, secretStore: secrets))
        var loaded = store.loadProfiles()
        XCTAssertNil(loaded.first?.claudeSessionKey)
        loaded[0].name = "After"

        try store.saveProfilesThrowing(loaded)

        XCTAssertEqual(
            secrets.values[locator(profileID, .claudeSessionKey)],
            "READ_FAILURE_FIXTURE"
        )
        XCTAssertFalse(secrets.deleted.contains(locator(profileID, .claudeSessionKey)))
        XCTAssertThrowsError(try store.loadProfileCredentials(profileID)) { error in
            guard case ProfileStoreError.credentialReadUnresolved = error else {
                return XCTFail("Expected unresolved read, got \(error)")
            }
        }
    }

    func testExplicitCredentialDeletionFailureRemainsRetryable() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let store = retain(ProfileStore(defaults: defaults, secretStore: secrets))
        try store.saveProfilesThrowing([Profile(id: profileID, name: "Delete")])
        try store.saveCLIProfileCredential("DELETE_FIXTURE", for: profileID)
        secrets.deleteErrors[.cliCredentialsJSON] = TestError.expected

        XCTAssertThrowsError(
            try store.saveCLIProfileCredential(nil, for: profileID)
        )
        XCTAssertEqual(
            secrets.values[locator(profileID, .cliCredentialsJSON)],
            "DELETE_FIXTURE"
        )
        XCTAssertNotNil(store.loadProfiles().first(where: { $0.id == profileID }))
    }

    func testProfileCredentialRoundTripPreservesAPIExpiryAndIsolation() throws {
        let firstID = UUID()
        let secondID = UUID()
        let expiry = Date(timeIntervalSinceReferenceDate: 654_321)
        let secrets = MockProfileSecretStore()
        let store = retain(ProfileStore(defaults: defaults, secretStore: secrets))
        try store.saveProfilesThrowing([
            Profile(id: firstID, name: "First", cliAccountName: "first-link"),
            Profile(id: secondID, name: "Second", cliAccountName: "second-link")
        ])

        try store.saveProfileCredentials(
            firstID,
            credentials: ProfileCredentials(
                claudeSessionKey: "FIRST_CLAUDE_FIXTURE",
                organizationId: "first-org",
                apiSessionKey: "FIRST_API_FIXTURE",
                apiOrganizationId: "first-api-org",
                apiSessionKeyExpiry: expiry,
                cliCredentialsJSON: "FIRST_CLI_FIXTURE"
            )
        )

        let first = try store.loadProfileCredentials(firstID)
        let second = try store.loadProfileCredentials(secondID)
        XCTAssertEqual(first.apiSessionKeyExpiry, expiry)
        XCTAssertEqual(first.apiSessionKey, "FIRST_API_FIXTURE")
        XCTAssertNil(second.claudeSessionKey)
        XCTAssertNil(second.apiSessionKey)
        XCTAssertNil(second.cliCredentialsJSON)
        XCTAssertEqual(store.loadProfiles()[0].cliAccountName, "first-link")
        XCTAssertFalse(try persistedProfileText().contains("FIRST_API_FIXTURE"))
    }

    func testFailedProfileReadbackRestoresPreviousBlob() throws {
        let backing = FaultingProfileDefaults()
        let secrets = MockProfileSecretStore()
        let store = retain(ProfileStore(defaults: backing, secretStore: secrets))
        try store.saveProfilesThrowing([Profile(name: "Before")])
        let previous = backing.data(forKey: "profiles_v3")
        var profile = try XCTUnwrap(store.loadProfiles().first)
        profile.name = "After"
        backing.corruptNextProfileWrite = true

        XCTAssertThrowsError(try store.saveProfilesThrowing([profile]))
        XCTAssertEqual(backing.data(forKey: "profiles_v3"), previous)
        XCTAssertEqual(store.loadProfiles().first?.name, "Before")
    }

    func testLegacySourceCleanupWaitsForVerifiedTargetAndMigrationIsIdempotent() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let store = retain(ProfileStore(defaults: defaults, secretStore: secrets))
        try store.saveProfilesThrowing([Profile(id: profileID, name: "Migration")])

        let source = MockLegacyCredentialSource(
            snapshot: LegacyCredentialSnapshot(
                globalClaudeSessionKey: "MIGRATION_CLAUDE_FIXTURE",
                fileClaudeSessionKey: nil,
                globalAPISessionKey: nil,
                defaultsAPISessionKey: "MIGRATION_API_FIXTURE"
            )
        )
        source.cleanupError = TestError.expected
        let migration = retain(
            KeychainMigrationService(source: source, defaults: defaults)
        )

        XCTAssertThrowsError(try migration.migrateIfNeeded(to: profileID, profileStore: store))
        XCTAssertFalse(source.cleaned)
        XCTAssertEqual(
            try store.loadProfileCredentials(profileID).apiSessionKey,
            "MIGRATION_API_FIXTURE"
        )

        source.cleanupError = nil
        try migration.migrateIfNeeded(to: profileID, profileStore: store)
        XCTAssertTrue(source.cleaned)
        let readsAfterCompletion = source.readCount
        try migration.migrateIfNeeded(to: profileID, profileStore: store)
        XCTAssertEqual(source.readCount, readsAfterCompletion)
    }

    func testExistingV3MarkerStillMigratesFileAndGlobalLegacySources() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let store = retain(ProfileStore(defaults: defaults, secretStore: secrets))
        try store.saveProfilesThrowing([Profile(id: profileID, name: "Existing")])
        store.saveActiveProfileId(profileID)
        defaults.set(true, forKey: "didMigrateToProfilesV3")

        let source = MockLegacyCredentialSource(
            snapshot: LegacyCredentialSnapshot(
                globalClaudeSessionKey: nil,
                fileClaudeSessionKey: "FILE_CLAUDE_FIXTURE",
                globalAPISessionKey: "GLOBAL_API_FIXTURE",
                defaultsAPISessionKey: nil
            )
        )
        let credentialMigration = retain(
            KeychainMigrationService(source: source, defaults: defaults)
        )
        let migration = retain(
            ProfileMigrationService(
                defaults: defaults,
                profileStore: store,
                credentialMigration: credentialMigration,
                legacySettings: MockLegacyProfileSettings()
            )
        )

        try migration.migrateIfNeededThrowing()

        let credentials = try store.loadProfileCredentials(profileID)
        XCTAssertEqual(credentials.claudeSessionKey, "FILE_CLAUDE_FIXTURE")
        XCTAssertEqual(credentials.apiSessionKey, "GLOBAL_API_FIXTURE")
        XCTAssertTrue(source.cleaned)
        let persisted = try persistedProfileText()
        XCTAssertFalse(persisted.contains("FILE_CLAUDE_FIXTURE"))
        XCTAssertFalse(persisted.contains("GLOBAL_API_FIXTURE"))
    }

    func testVerifiedProfileDeletionIsolatedAndStopsOnFailure() throws {
        let firstID = UUID()
        let secondID = UUID()
        let secrets = MockProfileSecretStore()
        for field in ProfileSecretField.allCases {
            secrets.values[locator(firstID, field)] = "FIRST_\(field.rawValue)"
            secrets.values[locator(secondID, field)] = "SECOND_\(field.rawValue)"
        }
        secrets.deleteErrors[.apiSessionKey] = TestError.expected
        let store = retain(ProfileStore(defaults: defaults, secretStore: secrets))

        XCTAssertThrowsError(try store.deleteProfileSecrets(for: firstID))
        XCTAssertNotNil(secrets.values[locator(firstID, .apiSessionKey)])
        for field in ProfileSecretField.allCases {
            XCTAssertNotNil(secrets.values[locator(secondID, field)])
        }
    }

    private func seedLegacyProfile(
        id: UUID,
        claude: String,
        api: String,
        cli: String
    ) {
        let object: [[String: Any]] = [[
            "id": id.uuidString,
            "name": "Legacy",
            "claudeSessionKey": claude,
            "apiSessionKey": api,
            "cliCredentialsJSON": cli,
            "cliAccountName": "preserved-link",
            "apiSessionKeyExpiry": 123.0
        ]]
        defaults.set(
            try! JSONSerialization.data(withJSONObject: object),
            forKey: "profiles_v3"
        )
    }

    private func persistedProfileText() throws -> String {
        let data = try XCTUnwrap(defaults.data(forKey: "profiles_v3"))
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func locator(_ id: UUID, _ field: ProfileSecretField) -> ProfileSecretLocator {
        ProfileSecretLocator(profileID: id, field: field)
    }

    private func retain<T: AnyObject>(_ service: T) -> T {
        Self.processLifetimeServices.append(service)
        return service
    }
}

private enum TestError: Error {
    case expected
}

private final class MockProfileSecretStore: ProfileSecretStore {
    var values: [ProfileSecretLocator: String] = [:]
    var writeErrors: [ProfileSecretField: Error] = [:]
    var readErrors: [ProfileSecretField: Error] = [:]
    var deleteErrors: [ProfileSecretField: Error] = [:]
    var deleted: Set<ProfileSecretLocator> = []

    func read(_ locator: ProfileSecretLocator) throws -> ProfileSecretReadResult {
        if let error = readErrors[locator.field] {
            throw error
        }
        return values[locator].map(ProfileSecretReadResult.value) ?? .absent
    }

    func write(_ value: String, to locator: ProfileSecretLocator) throws {
        if let error = writeErrors[locator.field] {
            throw error
        }
        values[locator] = value
    }

    func delete(_ locator: ProfileSecretLocator) throws {
        if let error = deleteErrors[locator.field] {
            throw error
        }
        values.removeValue(forKey: locator)
        deleted.insert(locator)
    }
}

private final class MockLegacyCredentialSource: LegacyCredentialSource {
    let snapshot: LegacyCredentialSnapshot
    var cleanupError: Error?
    var cleaned = false
    var readCount = 0

    init(snapshot: LegacyCredentialSnapshot) {
        self.snapshot = snapshot
    }

    func readSnapshot() throws -> LegacyCredentialSnapshot {
        readCount += 1
        return snapshot
    }

    func removeVerifiedSources(from snapshot: LegacyCredentialSnapshot) throws {
        if let cleanupError {
            throw cleanupError
        }
        cleaned = true
    }
}

private final class FaultingProfileDefaults: ProfileDefaultsStore {
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

private struct MockLegacyProfileSettings: LegacyProfileSettingsSource {
    func loadMenuBarIconConfiguration() -> MenuBarIconConfiguration { .default }
    func loadRefreshInterval() -> TimeInterval { 30 }
    func loadNotificationsEnabled() -> Bool { false }
    func loadAutoStartSessionEnabled() -> Bool { false }
    func loadOrganizationId() -> String? { nil }
    func loadAPIOrganizationId() -> String? { nil }
}
