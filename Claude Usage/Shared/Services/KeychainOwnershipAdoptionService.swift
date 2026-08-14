//
//  KeychainOwnershipAdoptionService.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-08-14.
//

import Foundation
import Security

/// Re-owns file-Keychain credential items created by the app's pre-rename
/// identity so macOS stops showing per-item consent dialogs.
///
/// Login-Keychain ("file" domain) generic-password items carry an access
/// control list naming the application that created them. The pre-rename app
/// (`Claude Usage.app`) created every existing profile credential, so the
/// renamed binary's first read of each item makes macOS ask the user for
/// consent — and a plain "Allow" only lasts until the next launch, while
/// "Deny" silently strands that profile's credentials.
///
/// This service runs once after the identity changes: for each item under the
/// profile-credentials service it reads the value (this is the one time the
/// consent dialog appears), writes a backup copy under a sibling service,
/// deletes the foreign-owned original, re-adds it — the new item's ACL names
/// this app, so every future read is silent — verifies the readback, and
/// removes the backup. Any per-item failure (including the user clicking
/// "Deny") leaves that item exactly as it was and is retried on the next
/// launch; the completion marker is recorded only after a launch in which
/// every item was adopted.
///
/// The service targets the file domain explicitly rather than the resolved
/// domain: data-protection items are gated by access groups, not per-app
/// ACLs, so they never prompt and never need adoption.
///
/// `nonisolated` is load-bearing — see `LegacyIdentityMigrationService`.
nonisolated final class KeychainOwnershipAdoptionService {
    static let shared = KeychainOwnershipAdoptionService()

    /// Recorded in the current defaults domain after every item is adopted.
    static let adoptionCompletedKey = "keychainOwnershipAdoptionCompleted_v1"

    /// Suffix of the temporary backup service used mid-swap. A crash between
    /// delete and re-add leaves the value recoverable here; the next launch's
    /// adoption pass restores it.
    static let backupServiceSuffix = ".adoption-backup"

    private let defaults: UserDefaults
    private let store: KeychainAdoptionItemStore
    private let currentBundleIdentifier: String?
    private let legacyBundleIdentifier: String
    private let service: String

    init(
        defaults: UserDefaults = .standard,
        store: KeychainAdoptionItemStore = FileKeychainAdoptionItemStore(),
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        legacyBundleIdentifier: String =
            AppIdentity.legacyBundleIdentifierBase
                + (AppBuildVariant.isUAT ? ".uat" : ""),
        service: String = KeychainService.profileSecretsService
    ) {
        self.defaults = defaults
        self.store = store
        self.currentBundleIdentifier = currentBundleIdentifier
        self.legacyBundleIdentifier = legacyBundleIdentifier
        self.service = service
    }

    func adoptIfNeeded() {
        guard let bundleIdentifier = currentBundleIdentifier,
            bundleIdentifier != legacyBundleIdentifier
        else {
            return
        }
        guard !defaults.bool(forKey: Self.adoptionCompletedKey) else {
            return
        }

        let backupService = service + Self.backupServiceSuffix
        var allAdopted = true

        // Finish any swap a previous launch started: a backup item whose
        // original is missing means the crash window between delete and
        // re-add was hit — restore from the backup before anything else.
        for account in (try? store.accounts(service: backupService)) ?? [] {
            guard let value = try? store.readData(
                service: backupService, account: account
            ) else { continue }
            let original = (try? store.readData(
                service: service, account: account
            )) ?? nil
            if original == nil {
                try? store.add(value, service: service, account: account)
            }
            try? store.delete(service: backupService, account: account)
        }

        let accounts: [String]
        do {
            // Attribute-only enumeration; never triggers the consent dialog.
            accounts = try store.accounts(service: service)
        } catch {
            LoggingService.shared.logError(
                "Keychain ownership adoption could not enumerate items;"
                    + " it will retry on next launch",
                error: error
            )
            return
        }

        for account in accounts {
            do {
                // The one read that can show the consent dialog. "Deny"
                // surfaces as an error and leaves the item untouched.
                guard let value = try store.readData(
                    service: service, account: account
                ) else { continue }

                try store.add(value, service: backupService, account: account)
                try store.delete(service: service, account: account)
                do {
                    try store.add(value, service: service, account: account)
                } catch {
                    // Original is gone; put it back from memory before
                    // rethrowing so no state is lost.
                    try? store.add(value, service: service, account: account)
                    throw error
                }

                guard try store.readData(
                    service: service, account: account
                ) == value else {
                    throw KeychainError.invalidData
                }
                try store.delete(service: backupService, account: account)
            } catch {
                allAdopted = false
                LoggingService.shared.logError(
                    "Keychain ownership adoption failed for one item;"
                        + " it will retry on next launch",
                    error: error
                )
            }
        }

        if allAdopted {
            defaults.set(true, forKey: Self.adoptionCompletedKey)
            LoggingService.shared.logInfo(
                "Keychain ownership adoption completed"
                    + " (\(accounts.count) item(s))"
            )
        }
    }
}

// MARK: - Store seam

/// Minimal file-Keychain surface the adoption pass needs; a protocol so tests
/// can simulate foreign-owned items and consent denials without touching the
/// real Keychain.
protocol KeychainAdoptionItemStore {
    /// Account names under `service`, from an attribute-only query that never
    /// prompts.
    func accounts(service: String) throws -> [String]
    /// Item data, or nil if absent. May show the macOS consent dialog for
    /// items another application created.
    func readData(service: String, account: String) throws -> Data?
    func add(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

/// Real file-domain implementation. Queries deliberately omit
/// `kSecUseDataProtectionKeychain`, mirroring how the pre-rename releases
/// wrote these items.
nonisolated final class FileKeychainAdoptionItemStore: KeychainAdoptionItemStore {
    func accounts(service: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess,
            let items = result as? [[String: Any]]
        else {
            throw KeychainError.loadFailed(status: status)
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    func readData(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.loadFailed(status: status)
        }
        return data
    }

    func add(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrSynchronizable as String: false
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status: status)
        }
    }

    func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status: status)
        }
    }
}
