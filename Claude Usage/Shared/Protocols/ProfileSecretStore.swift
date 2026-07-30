//
//  ProfileSecretStore.swift
//  Claude Usage
//
//  Per-profile secret persistence contracts.
//

import Foundation

/// Credential values that must not be serialized in a profile record.
///
/// Raw values are part of the persisted Keychain account namespace. Do not
/// change them without a migration.
nonisolated enum ProfileSecretField: String, CaseIterable {
    case claudeSessionKey = "claude-session-key"
    case apiSessionKey = "api-session-key"
    case cliCredentialsJSON = "cli-credentials"
}

/// Identifies one independently persisted credential value.
nonisolated struct ProfileSecretLocator: Hashable {
    let profileID: UUID
    let field: ProfileSecretField
}

/// A successful read distinguishes a missing item from a storage failure.
///
/// Implementations throw when the underlying store is unavailable or cannot
/// be read. Callers must never interpret an error as `.absent`.
nonisolated enum ProfileSecretReadResult: Equatable {
    case value(String)
    case absent
}

/// Secure storage for profile credentials.
///
/// `write` and `delete` are verified operations: they return only after a
/// direct read confirms the requested state.
nonisolated protocol ProfileSecretStore {
    func read(_ locator: ProfileSecretLocator) throws -> ProfileSecretReadResult
    func write(_ value: String, to locator: ProfileSecretLocator) throws
    func delete(_ locator: ProfileSecretLocator) throws
}

/// Verification failures intentionally contain only non-secret identifiers.
nonisolated enum ProfileSecretStoreError: Error, LocalizedError {
    case writeVerificationFailed(ProfileSecretLocator)
    case deletionVerificationFailed(ProfileSecretLocator)

    var errorDescription: String? {
        switch self {
        case .writeVerificationFailed(let locator):
            return "Keychain write verification failed for \(locator.safeDescription)"
        case .deletionVerificationFailed(let locator):
            return "Keychain deletion verification failed for \(locator.safeDescription)"
        }
    }
}

extension ProfileSecretLocator {
    /// Safe for diagnostics: contains no credential material or profile name.
    nonisolated var safeDescription: String {
        "profile \(profileID.uuidString.prefix(8)), field \(field.rawValue)"
    }
}
