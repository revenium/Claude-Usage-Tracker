//
//  ProfileStore.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation

protocol ProfileDefaultsStore: AnyObject {
    func data(forKey defaultName: String) -> Data?
    func string(forKey defaultName: String) -> String?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: ProfileDefaultsStore {}

enum ProfileStoreError: Error, LocalizedError {
    case profileNotFound(UUID)
    case credentialReadUnresolved(ProfileSecretLocator)
    case credentialTransactionFailed(UUID, [ProfileSecretField])
    case credentialRollbackFailed(UUID, [ProfileSecretField], metadata: Bool)
    case profileWriteVerificationFailed
    case profileRestoreVerificationFailed

    var errorDescription: String? {
        switch self {
        case .profileNotFound(let id):
            return "Profile \(id.uuidString.prefix(8)) was not found."
        case .credentialReadUnresolved(let locator):
            return "Secure credential state is unresolved for \(locator.safeDescription)."
        case .credentialTransactionFailed(let profileID, let fields):
            let fieldNames = fields.map(\.rawValue).joined(separator: ", ")
            return "Credential update failed for profile \(profileID.uuidString.prefix(8))"
                + (fieldNames.isEmpty ? "." : " (\(fieldNames)).")
        case .credentialRollbackFailed(let profileID, let fields, let metadata):
            let fieldNames = fields.map(\.rawValue).joined(separator: ", ")
            let secureDescription = fieldNames.isEmpty
                ? "none"
                : fieldNames
            return "Credential rollback is unresolved for profile \(profileID.uuidString.prefix(8)); "
                + "secure fields: \(secureDescription), metadata: \(metadata ? "unresolved" : "restored")."
        case .profileWriteVerificationFailed:
            return "The profile record could not be verified after writing."
        case .profileRestoreVerificationFailed:
            return "The previous profile record could not be restored after a failed write."
        }
    }
}

/// Manages profile metadata in preferences and credentials in app-owned,
/// per-profile secure storage.
class ProfileStore {
    static let shared = ProfileStore()

    private let defaults: any ProfileDefaultsStore
    private let secretStore: any ProfileSecretStore
    private let usageFileStore: any ProfileCurrentUsageFileStoring
    private var credentialBaselines: [ProfileSecretLocator: ProfileSecretReadResult] = [:]
    private var unresolvedLocators: Set<ProfileSecretLocator> = []
    private var unresolvedUsageProfileIDs: Set<UUID> = []

    private enum Keys {
        static let profiles = "profiles_v3"
        static let activeProfileId = "activeProfileId"
        static let displayMode = "profileDisplayMode"
        static let multiProfileConfig = "multiProfileDisplayConfig"
    }

    init(
        defaults: (any ProfileDefaultsStore)? = nil,
        secretStore: (any ProfileSecretStore)? = nil,
        usageFileStore: (any ProfileCurrentUsageFileStoring)? = nil
    ) {
        self.defaults = defaults ?? UserDefaults.standard
        self.secretStore = secretStore ?? KeychainService.shared
        self.usageFileStore = usageFileStore ?? ProfileUsageFileStore()
        LoggingService.shared.log("ProfileStore: Using profile metadata and verified secure storage")
    }

    // MARK: - Profile Management

    /// Compatibility entry point for existing metadata/usage call sites.
    ///
    /// Nil credential properties are intentionally neutral here. Credential
    /// deletion belongs to explicit credential APIs, never an ordinary profile
    /// save whose input may have been hydrated during a Keychain read failure.
    func saveProfiles(_ profiles: [Profile]) {
        do {
            try saveProfilesThrowing(profiles)
        } catch {
            LoggingService.shared.logStorageError("saveProfiles", error: error)
        }
    }

    func saveProfilesThrowing(_ profiles: [Profile]) throws {
        let storedProfiles = try decodeStoredProfiles()
        let storedByID = Dictionary(uniqueKeysWithValues: storedProfiles.map { ($0.id, $0) })
        var prepared: [Profile] = []
        prepared.reserveCapacity(profiles.count)

        for profile in profiles {
            prepared.append(
                try prepareForOrdinarySave(profile, stored: storedByID[profile.id])
            )
        }

        try persistProfiles(prepared)
        LoggingService.shared.log("ProfileStore: Saved \(profiles.count) profile metadata record(s)")
    }

    func loadProfiles() -> [Profile] {
        do {
            return try loadProfilesWithVerifiedMigration()
        } catch {
            LoggingService.shared.logStorageError("loadProfiles", error: error)

            // A failed migration rewrite must not make an existing installation
            // look like a first launch. The previous bytes were restored, so
            // return their backward-compatible decode and retry next load.
            do {
                return try decodeStoredProfiles()
            } catch {
                LoggingService.shared.logStorageError("decodeRestoredProfiles", error: error)
                return []
            }
        }
    }

    /// Loads, hydrates, and verifies any per-field plaintext migration rewrite.
    /// Migration coordinators use the throwing form before marking completion.
    func loadProfilesWithVerifiedMigration() throws -> [Profile] {
        var profiles = try decodeStoredProfiles()
        guard !profiles.isEmpty else {
            LoggingService.shared.log("ProfileStore: No profiles found in storage")
            return []
        }

        var needsRewrite = false

        for profileIndex in profiles.indices {
            for field in ProfileSecretField.allCases {
                let locator = ProfileSecretLocator(
                    profileID: profiles[profileIndex].id,
                    field: field
                )

                if let retryValue = profiles[profileIndex].credentialMigrationRetry.value(for: field) {
                    needsRewrite = true
                    do {
                        try secretStore.write(retryValue, to: locator)
                        profiles[profileIndex].credentialMigrationRetry.setValue(nil, for: field)
                        profiles[profileIndex].setSecretValue(retryValue, for: field)
                        credentialBaselines[locator] = .value(retryValue)
                        unresolvedLocators.remove(locator)
                    } catch {
                        // Preserve this field only. Other independently verified
                        // fields can still be scrubbed from the same profile.
                        profiles[profileIndex].setSecretValue(retryValue, for: field)
                        credentialBaselines[locator] = .value(retryValue)
                        unresolvedLocators.remove(locator)
                        LoggingService.shared.logError(
                            "ProfileStore: Secure migration remains retryable for \(locator.safeDescription)",
                            error: error
                        )
                    }
                    continue
                }

                do {
                    let result = try secretStore.read(locator)
                    credentialBaselines[locator] = result
                    unresolvedLocators.remove(locator)
                    profiles[profileIndex].setSecretValue(result.value, for: field)
                } catch {
                    // Unresolved is neither absent nor permission to delete.
                    credentialBaselines.removeValue(forKey: locator)
                    unresolvedLocators.insert(locator)
                    profiles[profileIndex].setSecretValue(nil, for: field)
                    LoggingService.shared.logError(
                        "ProfileStore: Secure read unresolved for \(locator.safeDescription)",
                        error: error
                    )
                }
            }

            if let retryUsage = profiles[profileIndex].currentUsageMigrationRetry {
                needsRewrite = true
                do {
                    let profileID = profiles[profileIndex].id
                    let authoritativeUsage: ProfileCurrentUsage
                    if let existingUsage = try usageFileStore.loadCurrentUsage(for: profileID) {
                        // A previous migration may have installed the file and
                        // terminated before scrubbing preferences. A later
                        // refresh can make that file newer than this retry.
                        authoritativeUsage = existingUsage
                    } else {
                        try usageFileStore.saveCurrentUsage(retryUsage, for: profileID)
                        authoritativeUsage = retryUsage
                    }
                    profiles[profileIndex].currentUsageMigrationRetry = nil
                    profiles[profileIndex].claudeUsage = authoritativeUsage.claudeUsage
                    profiles[profileIndex].apiUsage = authoritativeUsage.apiUsage
                    unresolvedUsageProfileIDs.remove(profileID)
                } catch {
                    // The explicit retry envelope remains authoritative until
                    // an exact file readback succeeds.
                    profiles[profileIndex].claudeUsage = retryUsage.claudeUsage
                    profiles[profileIndex].apiUsage = retryUsage.apiUsage
                    unresolvedUsageProfileIDs.insert(profiles[profileIndex].id)
                    LoggingService.shared.logError(
                        "ProfileStore: Current-usage migration remains retryable for profile \(profiles[profileIndex].id.uuidString.prefix(8))",
                        error: error
                    )
                }
                continue
            }

            do {
                let currentUsage = try usageFileStore.loadCurrentUsage(
                    for: profiles[profileIndex].id
                )
                profiles[profileIndex].claudeUsage = currentUsage?.claudeUsage
                profiles[profileIndex].apiUsage = currentUsage?.apiUsage
                unresolvedUsageProfileIDs.remove(profiles[profileIndex].id)
            } catch {
                // A read failure is unresolved state, not proof of absence.
                profiles[profileIndex].claudeUsage = nil
                profiles[profileIndex].apiUsage = nil
                unresolvedUsageProfileIDs.insert(profiles[profileIndex].id)
                LoggingService.shared.logError(
                    "ProfileStore: Current usage read is unresolved for profile \(profiles[profileIndex].id.uuidString.prefix(8))",
                    error: error
                )
            }
        }

        if needsRewrite {
            try persistProfiles(profiles)
            LoggingService.shared.log("ProfileStore: Verified profile credential migration rewrite")
        }

        LoggingService.shared.log("ProfileStore: Loaded \(profiles.count) profile(s)")
        return profiles
    }

    func saveActiveProfileId(_ id: UUID) {
        defaults.set(id.uuidString, forKey: Keys.activeProfileId)
    }

    func loadActiveProfileId() -> UUID? {
        guard let uuidString = defaults.string(forKey: Keys.activeProfileId) else {
            return nil
        }
        return UUID(uuidString: uuidString)
    }

    func saveDisplayMode(_ mode: ProfileDisplayMode) {
        defaults.set(mode.rawValue, forKey: Keys.displayMode)
    }

    func loadDisplayMode() -> ProfileDisplayMode {
        guard let rawValue = defaults.string(forKey: Keys.displayMode),
              let mode = ProfileDisplayMode(rawValue: rawValue) else {
            return .single
        }
        return mode
    }

    // MARK: - Multi-Profile Display Config

    func saveMultiProfileConfig(_ config: MultiProfileDisplayConfig) {
        do {
            let data = try JSONEncoder().encode(config)
            defaults.set(data, forKey: Keys.multiProfileConfig)
        } catch {
            LoggingService.shared.logStorageError("saveMultiProfileConfig", error: error)
        }
    }

    func loadMultiProfileConfig() -> MultiProfileDisplayConfig {
        guard let data = defaults.data(forKey: Keys.multiProfileConfig) else {
            return .default
        }
        do {
            return try JSONDecoder().decode(MultiProfileDisplayConfig.self, from: data)
        } catch {
            LoggingService.shared.logStorageError("loadMultiProfileConfig", error: error)
            return .default
        }
    }

    // MARK: - Credential Helpers

    /// Explicitly replaces the complete credential set for a profile.
    ///
    /// A nil secret is a verified deletion here. This is intentionally
    /// different from `saveProfiles`, where nil is credential-neutral.
    func saveProfileCredentials(_ profileId: UUID, credentials: ProfileCredentials) throws {
        var profiles = try loadProfilesWithVerifiedMigration()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            throw ProfileStoreError.profileNotFound(profileId)
        }
        profiles[index].claudeSessionKey = credentials.claudeSessionKey
        profiles[index].organizationId = credentials.organizationId
        profiles[index].apiSessionKey = credentials.apiSessionKey
        profiles[index].apiOrganizationId = credentials.apiOrganizationId
        profiles[index].apiSessionKeyExpiry = credentials.apiSessionKeyExpiry
        profiles[index].cliCredentialsJSON = credentials.cliCredentialsJSON
        profiles[index].credentialMigrationRetry = .init()

        try performCredentialTransaction(
            profileID: profileId,
            mutations: [
                SecretMutation(field: .claudeSessionKey, value: credentials.claudeSessionKey),
                SecretMutation(field: .apiSessionKey, value: credentials.apiSessionKey),
                SecretMutation(field: .cliCredentialsJSON, value: credentials.cliCredentialsJSON)
            ],
            candidateProfiles: profiles
        )
    }

    func loadProfileCredentials(_ profileId: UUID) throws -> ProfileCredentials {
        let profiles = try loadProfilesWithVerifiedMigration()
        guard let profile = profiles.first(where: { $0.id == profileId }) else {
            throw ProfileStoreError.profileNotFound(profileId)
        }
        try ensureCredentialReadsResolved(for: profileId)

        return ProfileCredentials(
            claudeSessionKey: profile.claudeSessionKey,
            organizationId: profile.organizationId,
            apiSessionKey: profile.apiSessionKey,
            apiOrganizationId: profile.apiOrganizationId,
            apiSessionKeyExpiry: profile.apiSessionKeyExpiry,
            cliCredentialsJSON: profile.cliCredentialsJSON
        )
    }

    /// Explicit single-field API used by CLI synchronization. It avoids
    /// reinterpreting unrelated secure-read errors as credential deletions.
    func saveCLIProfileCredential(
        _ value: String?,
        for profileId: UUID,
        syncedAt: Date? = nil
    ) throws {
        var profiles = try loadProfilesWithVerifiedMigration()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            throw ProfileStoreError.profileNotFound(profileId)
        }
        profiles[index].cliCredentialsJSON = value
        profiles[index].cliAccountSyncedAt = syncedAt ?? profiles[index].cliAccountSyncedAt
        profiles[index].credentialMigrationRetry.setValue(nil, for: .cliCredentialsJSON)
        try performCredentialTransaction(
            profileID: profileId,
            mutations: [
                SecretMutation(field: .cliCredentialsJSON, value: value)
            ],
            candidateProfiles: profiles
        )
    }

    /// Verifies removal of all app-owned profile credentials. Callers must keep
    /// the profile identity until this method and subsequent file cleanup pass.
    func deleteProfileSecrets(for profileId: UUID) throws {
        for field in ProfileSecretField.allCases {
            let locator = ProfileSecretLocator(profileID: profileId, field: field)
            try secretStore.delete(locator)
            credentialBaselines[locator] = .absent
            unresolvedLocators.remove(locator)
        }
    }

    // MARK: - Current Usage

    func saveClaudeUsage(_ usage: ClaudeUsage, for profileID: UUID) throws {
        _ = try loadCurrentUsageResolvingMigration(for: profileID)
        _ = try usageFileStore.updateCurrentUsage(for: profileID) { current in
            current.claudeUsage = usage
        }
        unresolvedUsageProfileIDs.remove(profileID)
    }

    func clearClaudeUsage(for profileID: UUID) throws {
        _ = try loadCurrentUsageResolvingMigration(for: profileID)
        _ = try usageFileStore.updateCurrentUsage(for: profileID) { current in
            current.claudeUsage = nil
        }
        unresolvedUsageProfileIDs.remove(profileID)
    }

    func loadClaudeUsage(for profileID: UUID) throws -> ClaudeUsage? {
        try loadCurrentUsageResolvingMigration(for: profileID).claudeUsage
    }

    func saveAPIUsage(_ usage: APIUsage, for profileID: UUID) throws {
        _ = try loadCurrentUsageResolvingMigration(for: profileID)
        _ = try usageFileStore.updateCurrentUsage(for: profileID) { current in
            current.apiUsage = usage
        }
        unresolvedUsageProfileIDs.remove(profileID)
    }

    func clearAPIUsage(for profileID: UUID) throws {
        _ = try loadCurrentUsageResolvingMigration(for: profileID)
        _ = try usageFileStore.updateCurrentUsage(for: profileID) { current in
            current.apiUsage = nil
        }
        unresolvedUsageProfileIDs.remove(profileID)
    }

    func loadAPIUsage(for profileID: UUID) throws -> APIUsage? {
        try loadCurrentUsageResolvingMigration(for: profileID).apiUsage
    }

    /// Deletes current usage plus any history/recovery artifacts remaining in
    /// the profile-owned file subtree.
    func deleteProfileUsageData(for profileID: UUID) throws {
        try usageFileStore.deleteAllData(for: profileID)
        unresolvedUsageProfileIDs.remove(profileID)
    }

    // MARK: - Internals

    private func decodeStoredProfiles() throws -> [Profile] {
        guard let data = defaults.data(forKey: Keys.profiles) else {
            return []
        }
        return try JSONDecoder().decode([Profile].self, from: data)
    }

    private func prepareForOrdinarySave(_ profile: Profile, stored: Profile?) throws -> Profile {
        var prepared = profile
        prepared.credentialMigrationRetry = stored?.credentialMigrationRetry
            ?? profile.credentialMigrationRetry
        prepared.currentUsageMigrationRetry = stored?.currentUsageMigrationRetry
            ?? profile.currentUsageMigrationRetry

        for field in ProfileSecretField.allCases {
            let locator = ProfileSecretLocator(profileID: profile.id, field: field)
            let desiredValue = profile.secretValue(for: field)

            if let retryValue = prepared.credentialMigrationRetry.value(for: field) {
                do {
                    try secretStore.write(retryValue, to: locator)
                    prepared.credentialMigrationRetry.setValue(nil, for: field)
                    credentialBaselines[locator] = .value(retryValue)
                } catch {
                    // Legacy plaintext wins until it can be independently
                    // verified in secure storage.
                    prepared.setSecretValue(retryValue, for: field)
                    continue
                }
            }

            if let baseline = credentialBaselines[locator],
               baseline.matches(desiredValue) {
                continue
            }

            // Nil in an ordinary save is never a delete.
            guard let desiredValue else {
                continue
            }

            do {
                try secretStore.write(desiredValue, to: locator)
                prepared.credentialMigrationRetry.setValue(nil, for: field)
                credentialBaselines[locator] = .value(desiredValue)
            } catch {
                // Only the changed/unverified field receives a retry fallback.
                prepared.credentialMigrationRetry.setValue(desiredValue, for: field)
                credentialBaselines[locator] = .value(desiredValue)
                LoggingService.shared.logError(
                    "ProfileStore: Secure update remains retryable for \(locator.safeDescription)",
                    error: error
                )
            }
        }

        return prepared
    }

    private func loadCurrentUsageResolvingMigration(
        for profileID: UUID
    ) throws -> ProfileCurrentUsage {
        var profiles = try decodeStoredProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }

        if let retryUsage = profiles[index].currentUsageMigrationRetry {
            do {
                let authoritativeUsage: ProfileCurrentUsage
                if let existingUsage = try usageFileStore.loadCurrentUsage(for: profileID) {
                    authoritativeUsage = existingUsage
                } else {
                    try usageFileStore.saveCurrentUsage(retryUsage, for: profileID)
                    authoritativeUsage = retryUsage
                }
                profiles[index].currentUsageMigrationRetry = nil
                try persistProfiles(profiles)
                unresolvedUsageProfileIDs.remove(profileID)
                return authoritativeUsage
            } catch {
                unresolvedUsageProfileIDs.insert(profileID)
                throw error
            }
        }

        do {
            let usage = try usageFileStore.loadCurrentUsage(for: profileID)
                ?? ProfileCurrentUsage()
            unresolvedUsageProfileIDs.remove(profileID)
            return usage
        } catch {
            unresolvedUsageProfileIDs.insert(profileID)
            throw error
        }
    }

    private func replaceSecret(
        _ value: String?,
        field: ProfileSecretField,
        profileID: UUID
    ) throws {
        let locator = ProfileSecretLocator(profileID: profileID, field: field)
        if let value {
            try secretStore.write(value, to: locator)
            credentialBaselines[locator] = .value(value)
            unresolvedLocators.remove(locator)
        } else {
            try secretStore.delete(locator)
            credentialBaselines[locator] = .absent
            unresolvedLocators.remove(locator)
        }
    }

    private func performCredentialTransaction(
        profileID: UUID,
        mutations: [SecretMutation],
        candidateProfiles: [Profile]
    ) throws {
        let previousProfileData = defaults.data(forKey: Keys.profiles)
        var previousStates: [ProfileSecretField: ProfileSecretReadResult] = [:]

        for mutation in mutations {
            let locator = ProfileSecretLocator(
                profileID: profileID,
                field: mutation.field
            )
            do {
                let state = try secretStore.read(locator)
                previousStates[mutation.field] = state
                credentialBaselines[locator] = state
                unresolvedLocators.remove(locator)
            } catch {
                credentialBaselines.removeValue(forKey: locator)
                unresolvedLocators.insert(locator)
                throw ProfileStoreError.credentialReadUnresolved(locator)
            }
        }

        let changedMutations = mutations.filter { mutation in
            previousStates[mutation.field]?.matches(mutation.value) == false
        }
        var attemptedFields: [ProfileSecretField] = []

        do {
            for mutation in changedMutations {
                // Include the active field before calling secure storage. A
                // failed verification can still mean the backend mutated.
                attemptedFields.append(mutation.field)
                try replaceSecret(
                    mutation.value,
                    field: mutation.field,
                    profileID: profileID
                )
            }
            try persistProfiles(candidateProfiles)
        } catch {
            var rollbackFailedFields: [ProfileSecretField] = []

            for field in attemptedFields.reversed() {
                guard let previousState = previousStates[field] else {
                    rollbackFailedFields.append(field)
                    continue
                }
                let locator = ProfileSecretLocator(profileID: profileID, field: field)
                do {
                    try restoreSecret(previousState, at: locator)
                    credentialBaselines[locator] = previousState
                    unresolvedLocators.remove(locator)
                } catch {
                    credentialBaselines.removeValue(forKey: locator)
                    unresolvedLocators.insert(locator)
                    rollbackFailedFields.append(field)
                }
            }

            var metadataRollbackFailed = false
            if defaults.data(forKey: Keys.profiles) != previousProfileData {
                do {
                    try restoreProfiles(previousProfileData)
                } catch {
                    metadataRollbackFailed = true
                }
            }

            if !rollbackFailedFields.isEmpty || metadataRollbackFailed {
                throw ProfileStoreError.credentialRollbackFailed(
                    profileID,
                    rollbackFailedFields,
                    metadata: metadataRollbackFailed
                )
            }
            throw ProfileStoreError.credentialTransactionFailed(
                profileID,
                attemptedFields
            )
        }
    }

    private func restoreSecret(
        _ state: ProfileSecretReadResult,
        at locator: ProfileSecretLocator
    ) throws {
        switch state {
        case .value(let value):
            try secretStore.write(value, to: locator)
        case .absent:
            try secretStore.delete(locator)
        }

        guard try secretStore.read(locator) == state else {
            switch state {
            case .value:
                throw ProfileSecretStoreError.writeVerificationFailed(locator)
            case .absent:
                throw ProfileSecretStoreError.deletionVerificationFailed(locator)
            }
        }
    }

    private func ensureCredentialReadsResolved(for profileID: UUID) throws {
        if let locator = unresolvedLocators.first(where: { $0.profileID == profileID }) {
            throw ProfileStoreError.credentialReadUnresolved(locator)
        }
    }

    private func persistProfiles(_ profiles: [Profile]) throws {
        let previousData = defaults.data(forKey: Keys.profiles)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profiles)

        defaults.set(data, forKey: Keys.profiles)
        guard defaults.data(forKey: Keys.profiles) == data else {
            try restoreProfiles(previousData)
            throw ProfileStoreError.profileWriteVerificationFailed
        }
    }

    private func restoreProfiles(_ previousData: Data?) throws {
        if let previousData {
            defaults.set(previousData, forKey: Keys.profiles)
        } else {
            defaults.removeObject(forKey: Keys.profiles)
        }

        guard defaults.data(forKey: Keys.profiles) == previousData else {
            throw ProfileStoreError.profileRestoreVerificationFailed
        }
    }
}

private struct SecretMutation {
    let field: ProfileSecretField
    let value: String?
}

private extension ProfileSecretReadResult {
    var value: String? {
        switch self {
        case .value(let value):
            return value
        case .absent:
            return nil
        }
    }

    func matches(_ candidate: String?) -> Bool {
        value == candidate
    }
}

private extension Profile {
    func secretValue(for field: ProfileSecretField) -> String? {
        switch field {
        case .claudeSessionKey:
            return claudeSessionKey
        case .apiSessionKey:
            return apiSessionKey
        case .cliCredentialsJSON:
            return cliCredentialsJSON
        }
    }

    mutating func setSecretValue(_ value: String?, for field: ProfileSecretField) {
        switch field {
        case .claudeSessionKey:
            claudeSessionKey = value
        case .apiSessionKey:
            apiSessionKey = value
        case .cliCredentialsJSON:
            cliCredentialsJSON = value
        }
    }
}
