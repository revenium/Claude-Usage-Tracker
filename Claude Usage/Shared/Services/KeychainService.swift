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
}

/// Production backend for app-owned per-profile credentials.
nonisolated struct SecurityProfileKeychainBackend: ProfileKeychainBackend {
    func upsert(_ data: Data, service: String, account: String) throws {
        let updateStatus = SecItemUpdate(
            Self.itemQuery(service: service, account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.saveFailed(status: updateStatus)
        }

        let addStatus = SecItemAdd(
            Self.addQuery(data: data, service: service, account: account) as CFDictionary,
            nil
        )
        if addStatus == errSecSuccess {
            return
        }

        // Another writer may have inserted the item between update and add.
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                Self.itemQuery(service: service, account: account) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard retryStatus == errSecSuccess else {
                throw KeychainError.saveFailed(status: retryStatus)
            }
            return
        }

        throw KeychainError.saveFailed(status: addStatus)
    }

    func read(service: String, account: String) throws -> Data? {
        var result: AnyObject?
        let status = SecItemCopyMatching(
            Self.readQuery(service: service, account: account) as CFDictionary,
            &result
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

    func remove(service: String, account: String) throws {
        let status = SecItemDelete(
            Self.itemQuery(service: service, account: account) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status: status)
        }
    }

    /// Base query shared by update and delete operations.
    static func itemQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    static func addQuery(data: Data, service: String, account: String) -> [String: Any] {
        var query = itemQuery(service: service, account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        query[kSecAttrSynchronizable as String] = false
        return query
    }

    static func readQuery(service: String, account: String) -> [String: Any] {
        var query = itemQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
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

        guard try read(locator) == .absent else {
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

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Invalid data format for Keychain storage"
        case .saveFailed(let status):
            return "Failed to save to Keychain (status: \(status))"
        case .loadFailed(let status):
            return "Failed to load from Keychain (status: \(status))"
        case .deleteFailed(let status):
            return "Failed to delete from Keychain (status: \(status))"
        }
    }
}
