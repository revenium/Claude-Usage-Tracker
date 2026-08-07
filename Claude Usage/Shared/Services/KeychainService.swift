//
//  KeychainService.swift
//  Claude Usage
//
//  Created by Claude Code on 2025-12-28.
//

import Foundation
import Security

/// Low-level data-protection Keychain operations. Kept injectable so profile
/// secret failure paths can be tested without touching the user's Keychain.
nonisolated protocol ProfileKeychainBackend {
    func upsert(_ data: Data, service: String, account: String) throws
    func read(service: String, account: String) throws -> Data?
    func remove(service: String, account: String) throws

    /// Reads without the upgrade-path recovery.
    ///
    /// Deletion verification must use this: a plain `read` may pull a copy out
    /// of the other Keychain and put it back, which would let a delete
    /// resurrect the credential it was asked to destroy.
    func readIgnoringRecovery(service: String, account: String) throws -> Data?
}

extension ProfileKeychainBackend {
    func readIgnoringRecovery(
        service: String,
        account: String
    ) throws -> Data? {
        try read(service: service, account: account)
    }
}

/// Direct, domain-scoped Keychain access used only by the one-time batch
/// migration in `ProfileKeychainDomainMigrationService`.
///
/// Everything else in this file goes through `ProfileKeychainBackend`, which
/// resolves a single domain for the process and layers in lazy recovery. The
/// batch migration is different: it must address the legacy file Keychain and
/// the data-protection Keychain explicitly, in the same pass, regardless of
/// which one the resolver has cached — so it is kept on its own narrow
/// protocol rather than widening the one every other caller depends on.
nonisolated protocol ProfileKeychainDomainAccess {
    func read(
        service: String,
        account: String,
        domain: ProfileKeychainDomain
    ) throws -> Data?

    func write(
        _ data: Data,
        service: String,
        account: String,
        domain: ProfileKeychainDomain
    ) throws
}

/// Which macOS Keychain implementation profile credentials live in.
///
/// The data-protection Keychain is preferred, but macOS only grants a process
/// access to it when the running binary carries a Keychain access group. That
/// group comes from the App Sandbox, a `keychain-access-groups` entitlement,
/// or an `application-identifier` entitlement injected by a provisioning
/// profile — none of which an ad-hoc signed build has. Such a build gets
/// `errSecMissingEntitlement` (-34018) on every write *and* on every delete,
/// while reads merely report "not found", so a failed credential write cannot
/// even be rolled back. The file-based (login) Keychain has no such
/// requirement and is the correct destination in that environment.
nonisolated enum ProfileKeychainDomain: String {
    case dataProtection
    case file
}

/// Decides once per process which Keychain the profile credentials belong in.
///
/// Resolution is a real probe rather than an entitlement inspection: it writes
/// and removes a valueless sentinel item, which is the only way to observe the
/// access-group decision the Security framework actually makes for this
/// binary.
nonisolated final class ProfileKeychainDomainResolver: @unchecked Sendable {
    static let shared = ProfileKeychainDomainResolver()

    /// Namespace for the availability sentinel. Never holds credential data.
    static let probeService = "com.claudeusagetracker.keychain-probe.v1"
    static let probeAccount = "availability"

    private let probe: () -> OSStatus
    private let lock = NSLock()
    private var cached: ProfileKeychainDomain?

    init(
        probe: @escaping () -> OSStatus =
            ProfileKeychainDomainResolver.probeDataProtectionKeychain
    ) {
        self.probe = probe
    }

    /// The Keychain every profile secret operation must use.
    var domain: ProfileKeychainDomain {
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let status = probe()
        let resolved: ProfileKeychainDomain =
            status == errSecMissingEntitlement ? .file : .dataProtection

        lock.lock()
        // A concurrent probe or a live downgrade wins: never widen access back
        // to a Keychain that has already rejected a real operation.
        let winner = cached ?? resolved
        cached = winner
        lock.unlock()

        if winner == .file {
            LoggingService.shared.log(
                "Keychain: data-protection Keychain unavailable "
                    + "(status \(status)); using the login Keychain for "
                    + "profile credentials"
            )
        }
        return winner
    }

    /// Records that a live data-protection operation was rejected for lack of
    /// an entitlement. Subsequent operations use the file Keychain.
    func downgradeToFileKeychain() {
        lock.lock()
        let alreadyDowngraded = cached == .file
        cached = .file
        lock.unlock()

        if !alreadyDowngraded {
            LoggingService.shared.log(
                "Keychain: data-protection Keychain rejected a live "
                    + "operation; falling back to the login Keychain"
            )
        }
    }

    /// Writes and removes a sentinel item. The status of the write is the only
    /// reliable way to observe the access-group decision the Security
    /// framework makes for this binary.
    static func probeDataProtectionKeychain() -> OSStatus {
        let query = SecurityProfileKeychainBackend.addQuery(
            data: Data("probe".utf8),
            service: probeService,
            account: probeAccount,
            domain: .dataProtection
        )

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess || status == errSecDuplicateItem {
            _ = SecItemDelete(
                SecurityProfileKeychainBackend.itemQuery(
                    service: probeService,
                    account: probeAccount,
                    domain: .dataProtection
                ) as CFDictionary
            )
        }
        return status
    }
}

/// Remembers which credentials have already been looked for in the file
/// Keychain, so the one-time recovery below stays one-time.
///
/// Scoped per credential rather than per process: a miss on one profile's
/// session key says nothing about another profile's.
nonisolated final class ProfileKeychainRecoveryLedger: @unchecked Sendable {
    static let shared = ProfileKeychainRecoveryLedger()

    private let lock = NSLock()
    private var checked: Set<String> = []

    /// Returns true the first time it is asked about a credential, false
    /// every time after.
    func shouldAttemptRecovery(service: String, account: String) -> Bool {
        let key = "\(service)\u{0}\(account)"
        lock.lock()
        defer { lock.unlock() }
        return checked.insert(key).inserted
    }
}

/// The four `SecItem*` entry points, behind a seam.
///
/// Without it the entitlement fallback below could only be exercised on a
/// machine whose Keychain happens to refuse the operation, which is the one
/// case no test can arrange.
nonisolated protocol KeychainItemOperations {
    func add(_ query: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
    func copyMatching(
        _ query: [String: Any],
        into result: inout AnyObject?
    ) -> OSStatus
}

nonisolated struct SecurityKeychainItemOperations: KeychainItemOperations {
    func add(_ query: [String: Any]) -> OSStatus {
        SecItemAdd(query as CFDictionary, nil)
    }

    func update(
        _ query: [String: Any],
        attributes: [String: Any]
    ) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }

    func copyMatching(
        _ query: [String: Any],
        into result: inout AnyObject?
    ) -> OSStatus {
        SecItemCopyMatching(query as CFDictionary, &result)
    }
}

/// Production backend for app-owned per-profile credentials.
nonisolated struct SecurityProfileKeychainBackend: ProfileKeychainBackend {
    private let resolver: ProfileKeychainDomainResolver
    private let operations: any KeychainItemOperations
    private let recoveryLedger: ProfileKeychainRecoveryLedger

    init(
        resolver: ProfileKeychainDomainResolver = .shared,
        operations: any KeychainItemOperations =
            SecurityKeychainItemOperations(),
        recoveryLedger: ProfileKeychainRecoveryLedger = .shared
    ) {
        self.resolver = resolver
        self.operations = operations
        self.recoveryLedger = recoveryLedger
    }

    func upsert(_ data: Data, service: String, account: String) throws {
        try withEntitlementFallback {
            try upsert(data, service: service, account: account, domain: $0)
        }
    }

    func read(service: String, account: String) throws -> Data? {
        let found = try withEntitlementFallback {
            try read(service: service, account: account, domain: $0)
        }
        if let found {
            return found
        }
        return try recoverFromFileKeychain(service: service, account: account)
    }

    /// Looks once in the file Keychain for a credential the data-protection
    /// Keychain does not have, and moves it across if it is there.
    ///
    /// This is the upgrade path off an ad-hoc signed build: that build could
    /// only ever write to the file Keychain, so after installing a properly
    /// signed release the credential would otherwise look deleted and the
    /// user would be sent back through setup.
    ///
    /// It is deliberately not a general search of both Keychains. It runs
    /// only when the data-protection Keychain is in use and the lookup
    /// missed, and only once per credential — so an install that never had a
    /// file-Keychain copy pays a single extra miss, with no access prompt,
    /// because a Keychain with no such item has no ACL to consult.
    private func recoverFromFileKeychain(
        service: String,
        account: String
    ) throws -> Data? {
        guard resolver.domain == .dataProtection,
              recoveryLedger.shouldAttemptRecovery(
                  service: service,
                  account: account
              ) else {
            return nil
        }

        // A failure here means "nothing to recover", never "the read
        // failed" — the caller already has its answer from the Keychain
        // that is actually in use.
        guard let recovered = try? read(
            service: service,
            account: account,
            domain: .file
        ) else {
            return nil
        }

        do {
            try upsert(
                recovered,
                service: service,
                account: account,
                domain: .dataProtection
            )
            // Only drop the old copy once the new one is definitely in place.
            try remove(service: service, account: account, domain: .file)
            LoggingService.shared.log(
                "Keychain: recovered a profile credential from the login "
                    + "Keychain into the data-protection Keychain"
            )
        } catch {
            // Leave the file copy alone and try again next launch.
            LoggingService.shared.log(
                "Keychain: could not migrate a recovered credential; "
                    + "leaving it in the login Keychain"
            )
        }
        return recovered
    }

    func remove(service: String, account: String) throws {
        try withEntitlementFallback {
            try remove(service: service, account: account, domain: $0)
        }

        // Delete means gone from anywhere this app could have put it: a
        // credential left in the file Keychain by an earlier ad-hoc signed
        // install is exactly what the recovery path would find again.
        //
        // Only in this direction. Resolving to `.file` means the
        // data-protection Keychain refused this binary outright, so it can
        // hold nothing to sweep.
        guard resolver.domain == .dataProtection else {
            return
        }
        try remove(service: service, account: account, domain: .file)
    }

    func readIgnoringRecovery(
        service: String,
        account: String
    ) throws -> Data? {
        try withEntitlementFallback {
            try read(service: service, account: account, domain: $0)
        }
    }

    /// Runs an operation against the resolved Keychain and retries it once
    /// against the file Keychain when the data-protection Keychain turns out
    /// to be off limits after all. Without this, a probe that succeeded in a
    /// different security context would leave writes permanently broken.
    ///
    /// Only writes and deletes can trigger this. A refused *read* reports
    /// `errSecItemNotFound` rather than `errSecMissingEntitlement`, so it is
    /// indistinguishable from a genuinely absent item and cannot be retried on
    /// that signal. Reads are covered instead by the resolved domain plus the
    /// bounded recovery in `recoverFromFileKeychain`. The retry stays wired up
    /// for reads as a no-cost guard in case a future macOS starts reporting
    /// the entitlement failure directly.
    private func withEntitlementFallback<T>(
        _ operation: (ProfileKeychainDomain) throws -> T
    ) throws -> T {
        let domain = resolver.domain
        do {
            return try operation(domain)
        } catch let error as KeychainError
            where domain == .dataProtection && error.isMissingEntitlement {
            resolver.downgradeToFileKeychain()
            return try operation(.file)
        }
    }

    /// Not `private`: `ProfileKeychainDomainAccess` conformance below needs
    /// it, and the batch domain migration needs to address a specific
    /// Keychain directly rather than through the resolver's cached decision.
    func upsert(
        _ data: Data,
        service: String,
        account: String,
        domain: ProfileKeychainDomain
    ) throws {
        let updateStatus = operations.update(
            Self.itemQuery(
                service: service,
                account: account,
                domain: domain
            ),
            attributes: [kSecValueData as String: data]
        )

        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.saveFailed(status: updateStatus)
        }

        let addStatus = operations.add(
            Self.addQuery(
                data: data,
                service: service,
                account: account,
                domain: domain
            )
        )
        if addStatus == errSecSuccess {
            return
        }

        // Another writer may have inserted the item between update and add.
        if addStatus == errSecDuplicateItem {
            let retryStatus = operations.update(
                Self.itemQuery(
                    service: service,
                    account: account,
                    domain: domain
                ),
                attributes: [kSecValueData as String: data]
            )
            guard retryStatus == errSecSuccess else {
                throw KeychainError.saveFailed(status: retryStatus)
            }
            return
        }

        throw KeychainError.saveFailed(status: addStatus)
    }

    /// Not `private`: see `upsert(_:service:account:domain:)` above.
    func read(
        service: String,
        account: String,
        domain: ProfileKeychainDomain
    ) throws -> Data? {
        var result: AnyObject?
        let status = operations.copyMatching(
            Self.readQuery(
                service: service,
                account: account,
                domain: domain
            ),
            into: &result
        )

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.loadFailed(status: status)
        }
        guard let data = result as? Data else {
            throw KeychainError.invalidData
        }
        return data
    }

    private func remove(
        service: String,
        account: String,
        domain: ProfileKeychainDomain
    ) throws {
        let status = operations.delete(
            Self.itemQuery(
                service: service,
                account: account,
                domain: domain
            )
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status: status)
        }
    }

    /// Base query shared by update and delete operations.
    static func itemQuery(
        service: String,
        account: String,
        domain: ProfileKeychainDomain = .dataProtection
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if domain == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    static func addQuery(
        data: Data,
        service: String,
        account: String,
        domain: ProfileKeychainDomain = .dataProtection
    ) -> [String: Any] {
        var query = itemQuery(
            service: service,
            account: account,
            domain: domain
        )
        query[kSecValueData as String] = data
        query[kSecAttrSynchronizable as String] = false
        // Data-protection classes are meaningless to the file Keychain, which
        // rejects unknown attributes on some macOS releases.
        if domain == .dataProtection {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }
        return query
    }

    static func readQuery(
        service: String,
        account: String,
        domain: ProfileKeychainDomain = .dataProtection
    ) -> [String: Any] {
        var query = itemQuery(
            service: service,
            account: account,
            domain: domain
        )
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }
}

extension SecurityProfileKeychainBackend: ProfileKeychainDomainAccess {
    func write(
        _ data: Data,
        service: String,
        account: String,
        domain: ProfileKeychainDomain
    ) throws {
        try upsert(data, service: service, account: account, domain: domain)
    }
}

/// Service for secure storage and retrieval of sensitive data using macOS Keychain
nonisolated final class KeychainService {
    static let shared = KeychainService()

    /// Stable versioned namespace for this fork's profile credentials.
    /// Changing it would strand credentials saved by compatible releases.
    static let profileSecretsService = "com.claudeusagetracker.profile-credentials.v1"

    private let profileBackend: ProfileKeychainBackend

    private convenience init() {
        self.init(profileBackend: SecurityProfileKeychainBackend())
    }

    /// Internal for deterministic tests; production uses `shared`.
    init(profileBackend: ProfileKeychainBackend) {
        self.profileBackend = profileBackend
    }

    /// Keychain item identifiers
    enum KeychainKey: String {
        case apiSessionKey = "com.claudeusagetracker.api-session-key"
        case claudeSessionKey = "com.claudeusagetracker.claude-session-key"

        var service: String {
            return rawValue
        }

        var account: String {
            return "session-key"
        }
    }

    // MARK: - Public Methods

    /// Saves a string value to the Keychain
    /// - Parameters:
    ///   - value: The string value to save
    ///   - key: The keychain key identifier
    /// - Throws: KeychainError if save fails
    @MainActor
    func save(_ value: String, for key: KeychainKey) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        // First, try to update existing item
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            LoggingService.shared.log("Keychain: Updated \(key.service)")
            return
        }

        // If update fails because item doesn't exist, add new item
        if updateStatus == errSecItemNotFound {
            // Create access control that doesn't require password
            var accessControlError: Unmanaged<CFError>?
            guard let accessControl = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleWhenUnlocked,
                [],
                &accessControlError
            ) else {
                if let error = accessControlError?.takeRetainedValue() {
                    LoggingService.shared.log("Failed to create access control: \(error)")
                }
                throw KeychainError.saveFailed(status: errSecParam)
            }

            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: key.service,
                kSecAttrAccount as String: key.account,
                kSecValueData as String: data,
                kSecAttrAccessControl as String: accessControl,
                kSecAttrSynchronizable as String: false
            ]

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

            if addStatus == errSecSuccess {
                LoggingService.shared.log("Keychain: Added \(key.service)")
                return
            } else {
                throw KeychainError.saveFailed(status: addStatus)
            }
        } else {
            throw KeychainError.saveFailed(status: updateStatus)
        }
    }

    /// Loads a string value from the Keychain
    /// - Parameter key: The keychain key identifier
    /// - Returns: The stored string value, or nil if not found
    /// - Throws: KeychainError if load fails (other than item not found)
    @MainActor
    func load(for key: KeychainKey) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess {
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData
            }
            LoggingService.shared.log("Keychain: Loaded \(key.service)")
            return value
        } else if status == errSecItemNotFound {
            LoggingService.shared.log("Keychain: Item not found \(key.service)")
            return nil
        } else {
            throw KeychainError.loadFailed(status: status)
        }
    }

    /// Deletes a value from the Keychain
    /// - Parameter key: The keychain key identifier
    /// - Throws: KeychainError if delete fails (ignores item not found)
    @MainActor
    func delete(for key: KeychainKey) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account
        ]

        let status = SecItemDelete(query as CFDictionary)

        if status == errSecSuccess {
            LoggingService.shared.log("Keychain: Deleted \(key.service)")
        } else if status == errSecItemNotFound {
            // Item not found is not an error for delete
            LoggingService.shared.log("Keychain: Item not found for deletion \(key.service)")
        } else {
            throw KeychainError.deleteFailed(status: status)
        }
    }

    /// Checks if a value exists in the Keychain
    /// - Parameter key: The keychain key identifier
    /// - Returns: true if the item exists, false otherwise
    @MainActor
    func exists(for key: KeychainKey) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account,
            kSecReturnData as String: false
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - Per-Profile Credential Storage

    /// Reads one profile credential. Missing and unreadable are intentionally
    /// different outcomes: only `errSecItemNotFound` becomes `.absent`.
    func read(_ locator: ProfileSecretLocator) throws -> ProfileSecretReadResult {
        guard let data = try profileBackend.read(
            service: Self.profileSecretsService,
            account: account(for: locator)
        ) else {
            return .absent
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return .value(value)
    }

    /// Writes and directly reads back a profile credential before returning.
    /// The requested value is never included in errors or logs.
    func write(_ value: String, to locator: ProfileSecretLocator) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        try profileBackend.upsert(
            data,
            service: Self.profileSecretsService,
            account: account(for: locator)
        )

        guard try profileSecretMatches(value, at: locator) else {
            throw ProfileSecretStoreError.writeVerificationFailed(locator)
        }
    }

    /// Deletes and directly confirms absence before returning.
    func delete(_ locator: ProfileSecretLocator) throws {
        try profileBackend.remove(
            service: Self.profileSecretsService,
            account: account(for: locator)
        )

        // Deliberately not `read(_:)`: that one can recover a copy from the
        // other Keychain, which would turn this verification into a
        // resurrection of the credential just deleted.
        guard try profileBackend.readIgnoringRecovery(
            service: Self.profileSecretsService,
            account: account(for: locator)
        ) == nil else {
            throw ProfileSecretStoreError.deletionVerificationFailed(locator)
        }
    }

    /// Direct readback helper used by migration code and `write`.
    ///
    /// There is deliberately no in-memory cache on this path.
    func profileSecretMatches(_ expected: String, at locator: ProfileSecretLocator) throws -> Bool {
        guard let expectedData = expected.data(using: .utf8) else {
            throw KeychainError.invalidData
        }
        let storedData = try profileBackend.read(
            service: Self.profileSecretsService,
            account: account(for: locator)
        )
        return storedData == expectedData
    }

    private func account(for locator: ProfileSecretLocator) -> String {
        "\(locator.profileID.uuidString).\(locator.field.rawValue)"
    }

}

extension KeychainService: ProfileSecretStore {}

// MARK: - KeychainError

nonisolated enum KeychainError: Error, LocalizedError {
    case invalidData
    case saveFailed(status: OSStatus)
    case loadFailed(status: OSStatus)
    case deleteFailed(status: OSStatus)

    /// The `OSStatus` behind the failure, when there is one.
    var status: OSStatus? {
        switch self {
        case .invalidData:
            return nil
        case .saveFailed(let status),
             .loadFailed(let status),
             .deleteFailed(let status):
            return status
        }
    }

    /// True when macOS refused the operation because this build carries no
    /// Keychain access group. Callers use it to pick a usable Keychain rather
    /// than surfacing an unrecoverable failure.
    var isMissingEntitlement: Bool {
        status == errSecMissingEntitlement
    }

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Invalid data format for Keychain storage"
        case .saveFailed(let status):
            return "Failed to save to Keychain (\(Self.describe(status)))"
        case .loadFailed(let status):
            return "Failed to load from Keychain (\(Self.describe(status)))"
        case .deleteFailed(let status):
            return "Failed to delete from Keychain (\(Self.describe(status)))"
        }
    }

    /// Renders an `OSStatus` as something a support conversation can act on.
    static func describe(_ status: OSStatus) -> String {
        let name: String
        switch status {
        case errSecMissingEntitlement:
            name = "errSecMissingEntitlement — this build has no Keychain "
                + "access group"
        case errSecInteractionNotAllowed:
            name = "errSecInteractionNotAllowed — the Keychain is locked"
        case errSecAuthFailed:
            name = "errSecAuthFailed — Keychain access was denied"
        case errSecUserCanceled:
            name = "errSecUserCanceled — the Keychain prompt was dismissed"
        case errSecNotAvailable:
            name = "errSecNotAvailable — no Keychain is available"
        case errSecDuplicateItem:
            name = "errSecDuplicateItem"
        case errSecItemNotFound:
            name = "errSecItemNotFound"
        default:
            name = SecCopyErrorMessageString(status, nil) as String?
                ?? "unrecognized Keychain status"
        }
        return "status \(status): \(name)"
    }
}
