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

    func testFileDomainQueriesOmitDataProtectionKeychain() {
        let service = "service"
        let account = "account"
        let item = SecurityProfileKeychainBackend.itemQuery(
            service: service,
            account: account,
            domain: .file
        )
        let add = SecurityProfileKeychainBackend.addQuery(
            data: Data("value".utf8),
            service: service,
            account: account,
            domain: .file
        )
        let read = SecurityProfileKeychainBackend.readQuery(
            service: service,
            account: account,
            domain: .file
        )

        XCTAssertNil(item[kSecUseDataProtectionKeychain as String])
        XCTAssertNil(add[kSecUseDataProtectionKeychain as String])
        XCTAssertNil(read[kSecUseDataProtectionKeychain as String])
        // Data-protection accessibility classes do not apply to the file
        // Keychain and must not be sent to it.
        XCTAssertNil(add[kSecAttrAccessible as String])
        XCTAssertEqual(add[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(read[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(item[kSecAttrService as String] as? String, service)
        XCTAssertEqual(item[kSecAttrAccount as String] as? String, account)
    }

    private func makeLocator(_ field: ProfileSecretField) -> ProfileSecretLocator {
        ProfileSecretLocator(profileID: profileID, field: field)
    }

    private func account(_ field: ProfileSecretField) -> String {
        "\(profileID.uuidString).\(field.rawValue)"
    }
}

/// A build without a Keychain access group — an ad-hoc signed or re-signed
/// copy — is refused by the data-protection Keychain on every write *and* on
/// every delete, which is what made the failure unrecoverable rather than
/// merely unsuccessful.
final class ProfileKeychainDomainResolverTests: XCTestCase {
    func testMissingEntitlementResolvesToTheFileKeychain() {
        let resolver = ProfileKeychainDomainResolver {
            errSecMissingEntitlement
        }

        XCTAssertEqual(resolver.domain, .file)
    }

    func testSuccessfulProbeKeepsTheDataProtectionKeychain() {
        let resolver = ProfileKeychainDomainResolver { errSecSuccess }

        XCTAssertEqual(resolver.domain, .dataProtection)
    }

    func testUnrelatedProbeFailureDoesNotMoveCredentials() {
        // A locked Keychain is a transient condition. Moving the credentials
        // to a different Keychain because of it would strand them.
        let resolver = ProfileKeychainDomainResolver {
            errSecInteractionNotAllowed
        }

        XCTAssertEqual(resolver.domain, .dataProtection)
    }

    func testDomainIsProbedOnlyOnce() {
        var probeCount = 0
        let resolver = ProfileKeychainDomainResolver {
            probeCount += 1
            return errSecSuccess
        }

        _ = resolver.domain
        _ = resolver.domain
        _ = resolver.domain

        XCTAssertEqual(probeCount, 1)
    }

    func testLiveRejectionDowngradesPermanently() {
        let resolver = ProfileKeychainDomainResolver { errSecSuccess }
        XCTAssertEqual(resolver.domain, .dataProtection)

        resolver.downgradeToFileKeychain()

        XCTAssertEqual(resolver.domain, .file)
    }

    func testDowngradeBeforeFirstProbeSurvivesTheProbe() {
        let resolver = ProfileKeychainDomainResolver { errSecSuccess }

        resolver.downgradeToFileKeychain()

        XCTAssertEqual(resolver.domain, .file)
    }

    func testMissingEntitlementIsDistinguishedFromOtherFailures() {
        XCTAssertTrue(
            KeychainError.saveFailed(status: errSecMissingEntitlement)
                .isMissingEntitlement
        )
        XCTAssertTrue(
            KeychainError.deleteFailed(status: errSecMissingEntitlement)
                .isMissingEntitlement
        )
        XCTAssertFalse(
            KeychainError.saveFailed(status: errSecItemNotFound)
                .isMissingEntitlement
        )
        XCTAssertFalse(KeychainError.invalidData.isMissingEntitlement)
    }

    func testKeychainErrorsExplainTheStatus() {
        let description = KeychainError.saveFailed(
            status: errSecMissingEntitlement
        ).localizedDescription

        XCTAssertTrue(description.contains("\(errSecMissingEntitlement)"))
        XCTAssertTrue(description.contains("errSecMissingEntitlement"))
    }
}

/// Covers the case the probe cannot predict: it said the data-protection
/// Keychain was fine, and a real operation later disagreed.
final class EntitlementFallbackTests: XCTestCase {
    private let service = "service"
    private let account = "account"

    private func makeBackend(
        _ operations: SpyKeychainItemOperations,
        probe: @escaping () -> OSStatus = { errSecSuccess }
    ) -> (SecurityProfileKeychainBackend, ProfileKeychainDomainResolver) {
        let resolver = ProfileKeychainDomainResolver(probe: probe)
        let backend = SecurityProfileKeychainBackend(
            resolver: resolver,
            operations: operations,
            // A fresh ledger per test: recovery is once per credential per
            // process, and tests must not inherit another test's process.
            recoveryLedger: ProfileKeychainRecoveryLedger()
        )
        return (backend, resolver)
    }

    func testLiveRejectionRetriesAgainstTheFileKeychain() throws {
        let operations = SpyKeychainItemOperations()
        operations.refuseDataProtection = true
        let (backend, resolver) = makeBackend(operations)

        try backend.upsert(
            Data("secret".utf8),
            service: service,
            account: account
        )

        XCTAssertEqual(operations.attemptedDomains.first, .dataProtection)
        XCTAssertTrue(
            operations.attemptedDomains.dropFirst().allSatisfy {
                $0 == .file
            },
            "Once refused, nothing else may go to the data-protection Keychain"
        )
        XCTAssertEqual(
            operations.value(
                domain: .file,
                service: service,
                account: account
            ),
            Data("secret".utf8),
            "The credential must actually land in the fallback Keychain"
        )
        XCTAssertEqual(resolver.domain, .file)
    }

    func testDowngradeSticksForSubsequentOperations() throws {
        let operations = SpyKeychainItemOperations()
        operations.refuseDataProtection = true
        let (backend, _) = makeBackend(operations)

        try backend.upsert(
            Data("secret".utf8),
            service: service,
            account: account
        )
        operations.attemptedDomains.removeAll()
        _ = try backend.read(service: service, account: account)
        try backend.remove(service: service, account: account)

        XCTAssertEqual(
            operations.attemptedDomains,
            [.file, .file],
            "Later operations must not re-try the rejected Keychain"
        )
    }

    func testUnrelatedFailuresAreNotRetried() {
        let operations = SpyKeychainItemOperations()
        operations.forcedStatus = errSecAuthFailed
        let (backend, _) = makeBackend(operations)

        XCTAssertThrowsError(
            try backend.upsert(
                Data("secret".utf8),
                service: service,
                account: account
            )
        )
        XCTAssertEqual(operations.attemptedDomains, [.dataProtection])
    }

    /// The upgrade path off an ad-hoc signed build: the credential was only
    /// ever writable to the file Keychain, and must not look deleted once a
    /// properly signed release can reach the data-protection Keychain.
    func testCredentialLeftInTheFileKeychainIsRecovered() throws {
        let operations = SpyKeychainItemOperations()
        operations.store(Data("stranded".utf8), domain: .file,
                         service: service, account: account)
        let (backend, _) = makeBackend(operations)

        XCTAssertEqual(
            try backend.read(service: service, account: account),
            Data("stranded".utf8)
        )
    }

    func testRecoveredCredentialIsMovedIntoTheDataProtectionKeychain() throws {
        let operations = SpyKeychainItemOperations()
        operations.store(Data("stranded".utf8), domain: .file,
                         service: service, account: account)
        let (backend, _) = makeBackend(operations)

        _ = try backend.read(service: service, account: account)

        XCTAssertEqual(
            operations.value(domain: .dataProtection,
                             service: service, account: account),
            Data("stranded".utf8)
        )
        XCTAssertNil(
            operations.value(domain: .file,
                             service: service, account: account),
            "The old copy must not be left behind once it has been moved"
        )
    }

    func testAFailedMigrationLeavesTheOriginalInPlace() throws {
        let operations = SpyKeychainItemOperations()
        operations.store(Data("stranded".utf8), domain: .file,
                         service: service, account: account)
        operations.refuseWrites = true
        let (backend, _) = makeBackend(operations)

        XCTAssertEqual(
            try backend.read(service: service, account: account),
            Data("stranded".utf8),
            "The caller still gets its credential"
        )
        XCTAssertEqual(
            operations.value(domain: .file,
                             service: service, account: account),
            Data("stranded".utf8),
            "Losing the only copy would be worse than not migrating"
        )
    }

    /// The recovery is bounded: one extra lookup per credential, then never
    /// again. A general search of both Keychains on every read would prompt
    /// for access repeatedly.
    func testRecoveryIsAttemptedOnlyOncePerCredential() throws {
        let operations = SpyKeychainItemOperations()
        let (backend, _) = makeBackend(operations)

        _ = try backend.read(service: service, account: account)
        XCTAssertEqual(
            operations.attemptedDomains,
            [.dataProtection, .file]
        )

        operations.attemptedDomains.removeAll()
        _ = try backend.read(service: service, account: account)
        _ = try backend.read(service: service, account: account)

        XCTAssertEqual(
            operations.attemptedDomains,
            [.dataProtection, .dataProtection],
            "A credential that was already looked for is not looked for again"
        )
    }

    func testRecoveryIsScopedToTheCredentialThatMissed() throws {
        let operations = SpyKeychainItemOperations()
        let (backend, _) = makeBackend(operations)

        _ = try backend.read(service: service, account: account)
        operations.attemptedDomains.removeAll()
        _ = try backend.read(service: service, account: "other-profile")

        XCTAssertEqual(
            operations.attemptedDomains,
            [.dataProtection, .file],
            "A miss on one credential says nothing about another"
        )
    }

    func testNoRecoveryOnceTheFileKeychainIsTheOneInUse() throws {
        let operations = SpyKeychainItemOperations()
        let (backend, _) = makeBackend(
            operations,
            probe: { errSecMissingEntitlement }
        )

        _ = try backend.read(service: service, account: account)

        XCTAssertEqual(
            operations.attemptedDomains,
            [.file],
            "There is no second Keychain to recover from"
        )
    }

    /// A delete must not be undoable by the recovery path. Reachable after an
    /// interrupted profile deletion: profiles flagged `deletionInProgress`
    /// skip the launch warm-up read, so the ledger is cold on the retry and
    /// the verification read is the first thing to look for that credential.
    func testDeletingACredentialCannotResurrectItFromTheOtherKeychain() throws {
        let operations = SpyKeychainItemOperations()
        operations.store(Data("stranded".utf8), domain: .file,
                         service: service, account: account)
        let (backend, _) = makeBackend(operations)

        try backend.remove(service: service, account: account)

        XCTAssertNil(
            operations.value(domain: .file,
                             service: service, account: account),
            "The copy in the other Keychain must be removed too"
        )
        XCTAssertNil(
            operations.value(domain: .dataProtection,
                             service: service, account: account),
            "It must certainly not have been migrated back in"
        )
        XCTAssertNil(
            try backend.readIgnoringRecovery(
                service: service,
                account: account
            )
        )
    }

    func testDeleteVerificationDoesNotTriggerRecovery() throws {
        let operations = SpyKeychainItemOperations()
        operations.store(Data("stranded".utf8), domain: .file,
                         service: service, account: account)
        let (backend, _) = makeBackend(operations)

        _ = try backend.readIgnoringRecovery(
            service: service,
            account: account
        )

        XCTAssertEqual(
            operations.value(domain: .file,
                             service: service, account: account),
            Data("stranded".utf8),
            "A recovery-free read must not move anything"
        )
        XCTAssertNil(
            operations.value(domain: .dataProtection,
                             service: service, account: account)
        )
    }

    /// An unentitled build could never have written to the data-protection
    /// Keychain, so being refused there must not fail the delete.
    func testDeleteSucceedsWhenTheOtherKeychainIsUnreachable() throws {
        let operations = SpyKeychainItemOperations()
        operations.refuseDataProtection = true
        let (backend, _) = makeBackend(
            operations,
            probe: { errSecMissingEntitlement }
        )
        try backend.upsert(
            Data("secret".utf8),
            service: service,
            account: account
        )

        XCTAssertNoThrow(
            try backend.remove(service: service, account: account)
        )
        XCTAssertNil(
            operations.value(domain: .file,
                             service: service, account: account)
        )
    }

    func testReadsFollowAWriteTriggeredDowngrade() throws {
        let operations = SpyKeychainItemOperations()
        operations.refuseDataProtection = true
        let (backend, _) = makeBackend(operations)

        try backend.upsert(
            Data("secret".utf8),
            service: service,
            account: account
        )
        operations.attemptedDomains.removeAll()
        _ = try backend.read(service: service, account: account)

        XCTAssertEqual(operations.attemptedDomains, [.file])
    }
}

/// Records which Keychain each call was aimed at, and can refuse the
/// data-protection one the way an ad-hoc signed binary is refused.
private final class SpyKeychainItemOperations: KeychainItemOperations {
    private struct ItemKey: Hashable {
        let domain: ProfileKeychainDomain
        let service: String
        let account: String
    }

    var refuseDataProtection = false
    /// Refuses every write, to exercise a migration that cannot complete.
    var refuseWrites = false
    /// Applied to every call regardless of domain.
    var forcedStatus: OSStatus?
    var attemptedDomains: [ProfileKeychainDomain] = []

    private var items: [ItemKey: Data] = [:]

    func store(
        _ data: Data,
        domain: ProfileKeychainDomain,
        service: String,
        account: String
    ) {
        items[ItemKey(domain: domain, service: service, account: account)] =
            data
    }

    func value(
        domain: ProfileKeychainDomain,
        service: String,
        account: String
    ) -> Data? {
        items[ItemKey(domain: domain, service: service, account: account)]
    }

    private func domain(of query: [String: Any]) -> ProfileKeychainDomain {
        query[kSecUseDataProtectionKeychain as String] as? Bool == true
            ? .dataProtection
            : .file
    }

    private func key(_ query: [String: Any]) -> ItemKey {
        ItemKey(
            domain: domain(of: query),
            service: query[kSecAttrService as String] as? String ?? "",
            account: query[kSecAttrAccount as String] as? String ?? ""
        )
    }

    private func status(for query: [String: Any]) -> OSStatus? {
        let domain = domain(of: query)
        attemptedDomains.append(domain)
        if let forcedStatus {
            return forcedStatus
        }
        if refuseDataProtection && domain == .dataProtection {
            return errSecMissingEntitlement
        }
        return nil
    }

    /// Mirrors the measured behaviour of a build with no Keychain access
    /// group: writes and deletes are refused outright, reads are told the
    /// item simply is not there.
    ///
    ///     add=-34018  read=-25300  delete=-34018
    private func readStatus(for query: [String: Any]) -> OSStatus? {
        let domain = domain(of: query)
        attemptedDomains.append(domain)
        if let forcedStatus {
            return forcedStatus
        }
        if refuseDataProtection && domain == .dataProtection {
            return errSecItemNotFound
        }
        return nil
    }

    func add(_ query: [String: Any]) -> OSStatus {
        if let status = status(for: query) {
            return status
        }
        if refuseWrites {
            return errSecAuthFailed
        }
        items[key(query)] = query[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func update(
        _ query: [String: Any],
        attributes: [String: Any]
    ) -> OSStatus {
        if let status = status(for: query) {
            return status
        }
        if refuseWrites {
            return errSecAuthFailed
        }
        guard items[key(query)] != nil else {
            return errSecItemNotFound
        }
        items[key(query)] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        if let status = status(for: query) {
            return status
        }
        guard items.removeValue(forKey: key(query)) != nil else {
            return errSecItemNotFound
        }
        return errSecSuccess
    }

    func copyMatching(
        _ query: [String: Any],
        into result: inout AnyObject?
    ) -> OSStatus {
        if let status = readStatus(for: query) {
            return status
        }
        guard let data = items[key(query)] else {
            result = nil
            return errSecItemNotFound
        }
        result = data as AnyObject
        return errSecSuccess
    }
}

/// Exercises the real Security framework in whatever security context this
/// build happens to run in.
///
/// The test host is ad-hoc signed and carries no Keychain access group, which
/// is exactly the situation a locally built or re-signed copy of the app is in
/// — and the situation in which every data-protection write and delete used to
/// fail with `errSecMissingEntitlement`.
final class ProfileKeychainBackendIntegrationTests: XCTestCase {
    private let service = "com.claudeusagetracker.tests.profile-credentials"
    private let account = "round-trip"
    private let backend = SecurityProfileKeychainBackend()

    override func tearDown() {
        try? backend.remove(service: service, account: account)
        super.tearDown()
    }

    func testResolvedDomainMatchesWhatSecurityActuallyAllows() {
        let probeStatus =
            ProfileKeychainDomainResolver.probeDataProtectionKeychain()
        let expected: ProfileKeychainDomain =
            probeStatus == errSecMissingEntitlement ? .file : .dataProtection

        XCTAssertEqual(ProfileKeychainDomainResolver().domain, expected)
    }

    func testCredentialRoundTripSucceedsInThisBuildsSecurityContext() throws {
        let secret = Data("integration-secret".utf8)

        do {
            try backend.upsert(secret, service: service, account: account)
        } catch let error as KeychainError where error.status
            == errSecInteractionNotAllowed || error.status == errSecNotAvailable {
            throw XCTSkip(
                "No usable Keychain in this environment: "
                    + error.localizedDescription
            )
        }

        XCTAssertEqual(
            try backend.read(service: service, account: account),
            secret
        )

        let updated = Data("rotated-secret".utf8)
        try backend.upsert(updated, service: service, account: account)
        XCTAssertEqual(
            try backend.read(service: service, account: account),
            updated
        )

        // The rollback path the setup wizard depends on: a delete has to be
        // able to undo a write, in the same Keychain the write landed in.
        try backend.remove(service: service, account: account)
        XCTAssertNil(try backend.read(service: service, account: account))
    }
}

/// Credential storage failures used to reach the setup wizard as `E9999` with
/// the internal transaction wording and no recovery advice.
final class CredentialStorageErrorMappingTests: XCTestCase {
    private let locator = ProfileSecretLocator(
        profileID: UUID(),
        field: .claudeSessionKey
    )

    func testMissingEntitlementMapsToAnActionableCode() {
        let error = AppError.wrap(
            KeychainError.saveFailed(status: errSecMissingEntitlement)
        )

        XCTAssertEqual(error.code, .credentialStorageUnavailable)
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertFalse(error.isRecoverable)
        // dataStorage gets no auto-injected action from ErrorPresenter, so
        // an alert would otherwise offer nothing to act on.
        XCTAssertEqual(error.recoveryActions, [.openSettings])
    }

    func testOtherKeychainFailuresAreRecoverable() {
        let error = AppError.wrap(
            KeychainError.loadFailed(status: errSecInteractionNotAllowed)
        )

        XCTAssertEqual(error.code, .credentialStorageFailed)
        XCTAssertTrue(error.isRecoverable)
        XCTAssertEqual(error.recoveryActions, [.openSettings])
    }

    func testRollbackFailureIsNoLongerUnknown() {
        let error = AppError.wrap(
            ProfileStoreError.credentialRollbackFailed(
                UUID(),
                [.claudeSessionKey],
                metadata: false
            )
        )

        XCTAssertEqual(error.code, .credentialStorageFailed)
        XCTAssertNotEqual(error.code, .unknown)
        XCTAssertNotNil(error.recoverySuggestion)
    }

    func testVerificationFailureIsCategorisedAsCredentialStorage() {
        let error = AppError.wrap(
            ProfileSecretStoreError.writeVerificationFailed(locator)
        )

        XCTAssertEqual(error.code, .credentialStorageFailed)
        XCTAssertEqual(error.code.category, .dataStorage)
    }

    func testUnrelatedProfileStoreErrorsAreLeftAlone() {
        let error = AppError.wrap(
            ProfileStoreError.profileWriteVerificationFailed
        )

        XCTAssertEqual(error.code, .unknown)
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
