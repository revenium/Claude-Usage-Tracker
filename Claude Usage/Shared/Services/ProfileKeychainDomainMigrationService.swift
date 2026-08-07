//
//  ProfileKeychainDomainMigrationService.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-08-07.
//

import Foundation

/// One-time, best-effort copy of every profile's credentials from the legacy
/// file Keychain into the data-protection Keychain, now that this build
/// carries a `keychain-access-groups` entitlement.
///
/// This is deliberately additive only: a successful copy never deletes the
/// legacy item. `SecurityProfileKeychainBackend` already retires a legacy
/// item the first time it is *read* after being recovered — that path proved
/// out the "move it and clean up" behaviour. This migration is not that path:
/// it runs eagerly over every profile at launch rather than waiting for each
/// credential to be read on its own, and it follows the more conservative
/// half of this codebase's credential-safety rule on purpose: a credential
/// this process could not confirm copied must never be destroyed. Since a
/// stray legacy item in the file Keychain is otherwise inert once the
/// data-protection Keychain is in use, leaving it behind costs nothing and
/// removes any chance of this pass losing data the per-credential recovery
/// would have handled safely anyway.
final class ProfileKeychainDomainMigrationService {
    static let shared = ProfileKeychainDomainMigrationService()

    private let resolver: ProfileKeychainDomainResolver
    private let domainAccess: any ProfileKeychainDomainAccess
    private let profileStore: ProfileStore
    private let defaults: UserDefaults
    private let migrationCompletedKey =
        "profileCredentialDataProtectionMigrationCompleted_v1"

    init(
        resolver: ProfileKeychainDomainResolver = .shared,
        domainAccess: any ProfileKeychainDomainAccess =
            SecurityProfileKeychainBackend(),
        profileStore: ProfileStore = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.resolver = resolver
        self.domainAccess = domainAccess
        self.profileStore = profileStore
        self.defaults = defaults
    }

    /// Copies every profile's legacy credentials forward. Safe to call on
    /// every launch: it returns immediately once flagged, and the flag is
    /// only ever set after every locator this pass looked at either had
    /// nothing to migrate or was copied and verified.
    func migrateIfNeeded() {
        guard !defaults.bool(forKey: migrationCompletedKey) else {
            return
        }

        // Nothing to migrate to yet. Leave the flag unset so this retries on
        // a future launch — e.g. once a properly signed, entitled build is
        // installed over an ad-hoc one.
        guard resolver.domain == .dataProtection else {
            return
        }

        var allLocatorsSucceeded = true
        for profile in profileStore.loadProfiles() {
            for field in ProfileSecretField.allCases {
                let locator = ProfileSecretLocator(
                    profileID: profile.id,
                    field: field
                )
                if !migrateLocator(locator) {
                    allLocatorsSucceeded = false
                }
            }
        }

        guard allLocatorsSucceeded else {
            return
        }
        defaults.set(true, forKey: migrationCompletedKey)
    }

    /// Returns `false` only when this locator needs another attempt later: an
    /// unreadable legacy item, or a copy that could not be verified. Both
    /// outcomes leave the legacy item exactly as found.
    private func migrateLocator(_ locator: ProfileSecretLocator) -> Bool {
        let service = KeychainService.profileSecretsService
        let account =
            "\(locator.profileID.uuidString).\(locator.field.rawValue)"

        // Never overwrite a value already in the destination: it may be a
        // credential the user re-entered after upgrading, and whatever is
        // behind it in the legacy Keychain is no longer this pass's concern.
        // A failed check here is treated as "not yet migrated" rather than
        // aborting the locator, since the write below is a safe upsert.
        if let existing = try? domainAccess.read(
            service: service,
            account: account,
            domain: .dataProtection
        ), existing != nil {
            return true
        }

        let legacyValue: Data?
        do {
            legacyValue = try domainAccess.read(
                service: service,
                account: account,
                domain: .file
            )
        } catch {
            LoggingService.shared.log(
                "Keychain domain migration: could not read a legacy item "
                    + "for \(locator.safeDescription); leaving it in place"
            )
            return false
        }

        guard let legacyValue else {
            // Nothing to migrate for this locator.
            return true
        }

        do {
            try domainAccess.write(
                legacyValue,
                service: service,
                account: account,
                domain: .dataProtection
            )
        } catch {
            LoggingService.shared.log(
                "Keychain domain migration: could not copy a legacy item "
                    + "for \(locator.safeDescription); leaving it in place"
            )
            return false
        }

        guard let verified = try? domainAccess.read(
            service: service,
            account: account,
            domain: .dataProtection
        ), verified == legacyValue else {
            LoggingService.shared.log(
                "Keychain domain migration: could not verify a copied item "
                    + "for \(locator.safeDescription); leaving the legacy "
                    + "copy in place"
            )
            return false
        }

        // Deliberately not deleted from the file Keychain: see the
        // type-level documentation.
        LoggingService.shared.log(
            "Keychain domain migration: copied a legacy credential for "
                + "\(locator.safeDescription) into the data-protection "
                + "Keychain"
        )
        return true
    }

    func resetMigrationForTesting() {
        defaults.removeObject(forKey: migrationCompletedKey)
    }
}
