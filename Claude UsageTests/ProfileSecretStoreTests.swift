import Security
import XCTest
@testable import Claude_Usage

final class ProfileSecretStoreTests: XCTestCase {
    private let profileID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    func testWriteReadsBackExactValue() throws {
        let backend = MockProfileKeychainBackend()
        let store = KeychainService(profileBackend: backend)
        let locator = makeLocator(.claudeSessionKey)

        try store.write("top-secret", to: locator)

        XCTAssertEqual(try store.read(locator), .value("top-secret"))
        XCTAssertTrue(try store.profileSecretMatches("top-secret", at: locator))
        XCTAssertFalse(try store.profileSecretMatches("different", at: locator))
    }

    func testPhantomWriteFailsVerificationWithoutLeakingValue() {
        let backend = MockProfileKeychainBackend()
        backend.persistsWrites = false
        let store = KeychainService(profileBackend: backend)
        let locator = makeLocator(.apiSessionKey)
        let secret = "must-not-appear-in-errors"

        XCTAssertThrowsError(try store.write(secret, to: locator)) { error in
            guard case ProfileSecretStoreError.writeVerificationFailed(let failedLocator) = error else {
                return XCTFail("Expected writeVerificationFailed, got \(error)")
            }
            XCTAssertEqual(failedLocator, locator)
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }
    }

    func testMismatchedWriteFailsVerification() {
        let backend = MockProfileKeychainBackend()
        backend.replacementWriteData = Data("different".utf8)
        let store = KeychainService(profileBackend: backend)
        let locator = makeLocator(.cliCredentialsJSON)

        XCTAssertThrowsError(try store.write("expected", to: locator)) { error in
            guard case ProfileSecretStoreError.writeVerificationFailed(let failedLocator) = error else {
                return XCTFail("Expected writeVerificationFailed, got \(error)")
            }
            XCTAssertEqual(failedLocator, locator)
        }
    }

    func testWriteVerificationComparesUTF8BytesNotCanonicalStrings() {
        let backend = MockProfileKeychainBackend()
        backend.replacementWriteData = Data("e\u{301}".utf8)
        let store = KeychainService(profileBackend: backend)
        let locator = makeLocator(.cliCredentialsJSON)

        XCTAssertThrowsError(try store.write("\u{E9}", to: locator)) { error in
            guard case ProfileSecretStoreError.writeVerificationFailed(let failedLocator) = error else {
                return XCTFail("Expected writeVerificationFailed, got \(error)")
            }
            XCTAssertEqual(failedLocator, locator)
        }
    }

    func testReadErrorIsNotReportedAsAbsent() {
        let backend = MockProfileKeychainBackend()
        backend.readError = KeychainError.loadFailed(status: errSecInteractionNotAllowed)
        let store = KeychainService(profileBackend: backend)

        XCTAssertThrowsError(try store.read(makeLocator(.claudeSessionKey))) { error in
            guard case KeychainError.loadFailed(let status) = error else {
                return XCTFail("Expected a Keychain load error, got \(error)")
            }
            XCTAssertEqual(status, errSecInteractionNotAllowed)
        }
    }

    func testMissingItemIsExplicitlyAbsent() throws {
        let store = KeychainService(profileBackend: MockProfileKeychainBackend())

        XCTAssertEqual(try store.read(makeLocator(.claudeSessionKey)), .absent)
    }

    func testInvalidUTF8IsAReadError() {
        let backend = MockProfileKeychainBackend()
        backend.items[backend.key(
            service: KeychainService.profileSecretsService,
            account: account(.claudeSessionKey)
        )] = Data([0xFF])
        let store = KeychainService(profileBackend: backend)

        XCTAssertThrowsError(try store.read(makeLocator(.claudeSessionKey))) { error in
            guard case KeychainError.invalidData = error else {
                return XCTFail("Expected invalidData, got \(error)")
            }
        }
    }

    func testDeleteReadsBackAndConfirmsAbsence() throws {
        let backend = MockProfileKeychainBackend()
        let store = KeychainService(profileBackend: backend)
        let locator = makeLocator(.claudeSessionKey)
        try store.write("value", to: locator)

        try store.delete(locator)

        XCTAssertEqual(try store.read(locator), .absent)
    }

    func testDeletingMissingItemIsSuccessful() {
        let store = KeychainService(profileBackend: MockProfileKeychainBackend())

        XCTAssertNoThrow(try store.delete(makeLocator(.apiSessionKey)))
    }

    func testPhantomDeleteFailsVerification() throws {
        let backend = MockProfileKeychainBackend()
        let store = KeychainService(profileBackend: backend)
        let locator = makeLocator(.cliCredentialsJSON)
        try store.write("value", to: locator)
        backend.persistsDeletes = false

        XCTAssertThrowsError(try store.delete(locator)) { error in
            guard case ProfileSecretStoreError.deletionVerificationFailed(let failedLocator) = error else {
                return XCTFail("Expected deletionVerificationFailed, got \(error)")
            }
            XCTAssertEqual(failedLocator, locator)
        }
    }

    func testDeleteReadbackErrorIsNotReportedAsSuccess() throws {
        let backend = MockProfileKeychainBackend()
        let store = KeychainService(profileBackend: backend)
        let locator = makeLocator(.claudeSessionKey)
        try store.write("value", to: locator)
        backend.readError = KeychainError.loadFailed(status: errSecNotAvailable)

        XCTAssertThrowsError(try store.delete(locator)) { error in
            guard case KeychainError.loadFailed(let status) = error else {
                return XCTFail("Expected a Keychain load error, got \(error)")
            }
            XCTAssertEqual(status, errSecNotAvailable)
        }
    }

    func testProfilesAndFieldsAreIsolated() throws {
        let backend = MockProfileKeychainBackend()
        let store = KeychainService(profileBackend: backend)
        let otherProfileID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let claude = makeLocator(.claudeSessionKey)
        let api = makeLocator(.apiSessionKey)
        let other = ProfileSecretLocator(profileID: otherProfileID, field: .claudeSessionKey)

        try store.write("claude", to: claude)
        try store.write("api", to: api)
        try store.write("other", to: other)
        try store.delete(claude)

        XCTAssertEqual(try store.read(claude), .absent)
        XCTAssertEqual(try store.read(api), .value("api"))
        XCTAssertEqual(try store.read(other), .value("other"))
    }

    func testStableServiceAndAccountNamespace() throws {
        let backend = MockProfileKeychainBackend()
        let store = KeychainService(profileBackend: backend)

        try store.write("value", to: makeLocator(.cliCredentialsJSON))

        XCTAssertEqual(backend.lastService, "com.claudeusagetracker.profile-credentials.v1")
        XCTAssertEqual(
            backend.lastAccount,
            "\(profileID.uuidString).cli-credentials"
        )
    }

    func testProductionQueriesUseDataProtectionKeychain() {
        let service = "service"
        let account = "account"
        let item = SecurityProfileKeychainBackend.itemQuery(service: service, account: account)
        let add = SecurityProfileKeychainBackend.addQuery(
            data: Data("value".utf8),
            service: service,
            account: account
        )
        let read = SecurityProfileKeychainBackend.readQuery(service: service, account: account)

        XCTAssertEqual(item[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(add[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(add[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(
            add[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlock as String
        )
        XCTAssertEqual(read[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(read[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(
            read[kSecMatchLimit as String] as? String,
            kSecMatchLimitOne as String
        )
    }

    private func makeLocator(_ field: ProfileSecretField) -> ProfileSecretLocator {
        ProfileSecretLocator(profileID: profileID, field: field)
    }

    private func account(_ field: ProfileSecretField) -> String {
        "\(profileID.uuidString).\(field.rawValue)"
    }
}

private final class MockProfileKeychainBackend: ProfileKeychainBackend {
    struct ItemKey: Hashable {
        let service: String
        let account: String
    }

    var items: [ItemKey: Data] = [:]
    var persistsWrites = true
    var persistsDeletes = true
    var replacementWriteData: Data?
    var writeError: Error?
    var readError: Error?
    var deleteError: Error?
    var lastService: String?
    var lastAccount: String?

    func key(service: String, account: String) -> ItemKey {
        ItemKey(service: service, account: account)
    }

    func upsert(_ data: Data, service: String, account: String) throws {
        lastService = service
        lastAccount = account
        if let writeError {
            throw writeError
        }
        if persistsWrites {
            items[key(service: service, account: account)] = replacementWriteData ?? data
        }
    }

    func read(service: String, account: String) throws -> Data? {
        lastService = service
        lastAccount = account
        if let readError {
            throw readError
        }
        return items[key(service: service, account: account)]
    }

    func remove(service: String, account: String) throws {
        lastService = service
        lastAccount = account
        if let deleteError {
            throw deleteError
        }
        if persistsDeletes {
            items.removeValue(forKey: key(service: service, account: account))
        }
    }
}
