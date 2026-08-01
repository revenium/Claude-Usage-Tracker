//
//  ProfileStore.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation
import UsageCore

protocol ProfileDefaultsStore: AnyObject {
    func data(forKey defaultName: String) -> Data?
    func string(forKey defaultName: String) -> String?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: ProfileDefaultsStore {}

enum ProfileStoreError: Error, LocalizedError {
    case profileNotFound(UUID)
    case profileDeletionInProgress(UUID)
    case credentialReadUnresolved(ProfileSecretLocator)
    case credentialTransactionFailed(UUID, [ProfileSecretField])
    case credentialRollbackFailed(UUID, [ProfileSecretField], metadata: Bool)
    case credentialUsageUnlinkFailed(UUID)
    case credentialUsageUnlinkRollbackFailed(UUID, credentials: Bool, usage: Bool)
    case credentialUsageUnlinkMarkerVerificationFailed
    case currentUsageCommitRollbackFailed(UUID)
    case profileWriteVerificationFailed
    case profileRestoreVerificationFailed

    var errorDescription: String? {
        switch self {
        case .profileNotFound(let id):
            return "Profile \(id.uuidString.prefix(8)) was not found."
        case .profileDeletionInProgress(let id):
            return "Profile \(id.uuidString.prefix(8)) is pending deletion."
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
        case .credentialUsageUnlinkFailed(let profileID):
            return "Credential unlink failed safely for profile \(profileID.uuidString.prefix(8))."
        case .credentialUsageUnlinkRollbackFailed(
            let profileID,
            let credentials,
            let usage
        ):
            return "Credential unlink rollback is unresolved for profile "
                + "\(profileID.uuidString.prefix(8)); credentials: "
                + "\(credentials ? "unresolved" : "restored"), usage: "
                + "\(usage ? "unresolved" : "restored")."
        case .credentialUsageUnlinkMarkerVerificationFailed:
            return "Credential unlink recovery state could not be verified."
        case .currentUsageCommitRollbackFailed(let profileID):
            return "Current usage rollback is unresolved for profile "
                + "\(profileID.uuidString.prefix(8))."
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
        /// Legacy single-slot active id. Read-only after migration: a fresh
        /// install never writes it again, but it remains the source used to
        /// seed whichever provider owned it the first time per-provider keys
        /// are loaded.
        static let legacyActiveProfileId = "activeProfileId"
        static let activeClaudeProfileId = "activeClaudeProfileId_v1"
        static let activeCodexProfileId = "activeCodexProfileId_v1"
        /// The most recently focused profile across both providers,
        /// independent of the per-provider active slots and of the legacy
        /// single slot (which is deleted after its first read). Written on
        /// every focus change so `loadProfiles()` can restore focus on a
        /// second/later call in the same session, not just the first.
        static let lastFocusedProfileId = "lastFocusedProfileId_v1"
        static let displayMode = "profileDisplayMode"
        static let multiProfileConfig = "multiProfileDisplayConfig"
        static let providerBadgeGlyphEnabled = "providerBadgeGlyphEnabled_v1"
        static let providerBadgeTintEnabled = "providerBadgeTintEnabled_v1"
        static let pendingCredentialUsageUnlinks =
            "profileCredentialUsageUnlinks_v1"
        static let pendingCodexConfigurationMutations =
            "profileCodexConfigurationMutations_v1"
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

    func createInitialProfile(_ profile: Profile) throws {
        try recoverPendingCredentialUsageUnlinks()
        try recoverPendingCodexConfigurationMutations()
        guard try decodeStoredProfiles().isEmpty else {
            throw ProfileProviderConfigurationError
                .initialProfileAlreadyExists
        }
        guard !profile.deletionInProgress else {
            throw ProfileProviderConfigurationError
                .deletionStateChangeRequiresLifecycle(profile.id)
        }
        try profile.validateProviderIsolation()
        try persistProfiles([profile])
    }

    func appendProfile(
        _ profile: Profile,
        expectedExistingIDs: Set<UUID>
    ) throws {
        try recoverPendingCredentialUsageUnlinks()
        try recoverPendingCodexConfigurationMutations()
        let stored = try decodeStoredProfiles()
        try validateProfileSet(stored)
        let storedIDs = Set(stored.map(\.id))
        guard storedIDs == expectedExistingIDs,
              stored.count == expectedExistingIDs.count else {
            throw ProfileProviderConfigurationError.profileSetChanged
        }
        guard !storedIDs.contains(profile.id) else {
            throw ProfileProviderConfigurationError
                .duplicateProfileID(profile.id)
        }
        guard !profile.deletionInProgress else {
            throw ProfileProviderConfigurationError
                .deletionStateChangeRequiresLifecycle(profile.id)
        }
        let prepared = try prepareForOrdinarySave(
            profile,
            stored: nil
        )
        try persistProfiles(stored + [prepared])
    }

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
        // A durable unlink marker is authoritative. Complete or surface its
        // recovery before an ordinary save can replay a stored target retry.
        try recoverPendingCredentialUsageUnlinks()
        try recoverPendingCodexConfigurationMutations()
        try validateProfileSet(profiles)
        let storedProfiles = try decodeStoredProfiles()
        try validateProfileSet(storedProfiles)
        guard profiles.count == storedProfiles.count,
              Set(profiles.map(\.id))
                == Set(storedProfiles.map(\.id)) else {
            throw ProfileProviderConfigurationError.profileSetChanged
        }
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
                return try decodeStoredProfilesMaskingPendingUnlinks()
            } catch {
                LoggingService.shared.logStorageError(
                    "decodeMaskedRestoredProfiles",
                    error: error
                )
                return []
            }
        }
    }

    /// Loads, hydrates, and verifies any per-field plaintext migration rewrite.
    /// Migration coordinators use the throwing form before marking completion.
    func loadProfilesWithVerifiedMigration() throws -> [Profile] {
        try recoverPendingCredentialUsageUnlinks()
        try recoverPendingCodexConfigurationMutations()
        var profiles = try decodeStoredProfiles()
        try validateProfileSet(profiles)
        guard !profiles.isEmpty else {
            LoggingService.shared.log("ProfileStore: No profiles found in storage")
            return []
        }

        var needsRewrite = false

        for profileIndex in profiles.indices {
            if profiles[profileIndex].deletionInProgress {
                // A prior deletion failed after its retained marker was
                // committed. Never let retry envelopes or surviving backing
                // stores rehydrate data into that scrubbed identity.
                let hadRetryData =
                    !profiles[profileIndex].credentialMigrationRetry.isEmpty
                    || profiles[profileIndex].currentUsageMigrationRetry != nil
                profiles[profileIndex].credentialMigrationRetry = .init()
                profiles[profileIndex].currentUsageMigrationRetry = nil
                profiles[profileIndex].claudeSessionKey = nil
                profiles[profileIndex].apiSessionKey = nil
                profiles[profileIndex].cliCredentialsJSON = nil
                profiles[profileIndex].claudeUsage = nil
                profiles[profileIndex].apiUsage = nil
                needsRewrite = needsRewrite || hadRetryData
                continue
            }

            if profiles[profileIndex].providerConfiguration.kind == .codex {
                // A Codex profile owns no Claude credential locators. Merely
                // loading or editing it must never consult secure storage.
                try profiles[profileIndex].validateProviderIsolation()
                do {
                    if let currentUsage = try usageFileStore.loadCurrentUsage(
                        for: profiles[profileIndex].id
                    ) {
                        try currentUsage.validate(
                            expectedProviderID:
                                profiles[profileIndex].providerID,
                            expectedProviderRevision:
                                profiles[profileIndex].providerRevision
                        )
                    }
                    unresolvedUsageProfileIDs.remove(
                        profiles[profileIndex].id
                    )
                } catch {
                    unresolvedUsageProfileIDs.insert(
                        profiles[profileIndex].id
                    )
                    LoggingService.shared.logError(
                        "ProfileStore: Codex current usage read is unresolved "
                            + "for profile "
                            + "\(profiles[profileIndex].id.uuidString.prefix(8))",
                        error: error
                    )
                }
                continue
            }

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
                        try existingUsage.validate(
                            expectedProviderID:
                                profiles[profileIndex].providerID,
                            expectedProviderRevision:
                                profiles[profileIndex].providerRevision
                        )
                        authoritativeUsage = existingUsage
                    } else {
                        try retryUsage.validate(
                            expectedProviderID:
                                profiles[profileIndex].providerID,
                            expectedProviderRevision:
                                profiles[profileIndex].providerRevision
                        )
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
                try currentUsage?.validate(
                    expectedProviderID: profiles[profileIndex].providerID,
                    expectedProviderRevision:
                        profiles[profileIndex].providerRevision
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

        try validateProfileSet(profiles)
        LoggingService.shared.log("ProfileStore: Loaded \(profiles.count) profile(s)")
        return profiles
    }

    /// Persists the active profile id for one provider. Each provider owns an
    /// independent slot so activating a Claude profile never disturbs the
    /// active Codex profile and vice versa.
    func saveActiveProfileId(_ id: UUID, for kind: ProfileProviderKind) {
        defaults.set(id.uuidString, forKey: key(for: kind))
        // A fresh per-provider write supersedes the legacy single slot. It is
        // no longer read once any per-provider key exists (see
        // `loadActiveProfileId(for:)`), but clearing it keeps state legible.
        defaults.removeObject(forKey: Keys.legacyActiveProfileId)
    }

    /// Loads the active profile id explicitly persisted for one provider.
    /// Returns nil if that provider has never had its own slot written —
    /// callers resolve the one-time upgrade migration from
    /// `loadLegacyActiveProfileId()` themselves, since the legacy id is not
    /// scoped to either provider and both providers need a chance to claim
    /// it against their own candidate profiles.
    func loadActiveProfileId(for kind: ProfileProviderKind) -> UUID? {
        guard let uuidString = defaults.string(forKey: key(for: kind)) else {
            return nil
        }
        return UUID(uuidString: uuidString)
    }

    /// The pre-upgrade single active-profile id, if still present. Only used
    /// as a migration seed by `loadActiveProfileId(for:)`.
    func loadLegacyActiveProfileId() -> UUID? {
        guard let uuidString = defaults.string(
            forKey: Keys.legacyActiveProfileId
        ) else {
            return nil
        }
        return UUID(uuidString: uuidString)
    }

    /// Persists the most recently focused profile (independent of the
    /// per-provider active slots). Pass nil to clear it.
    func saveLastFocusedProfileId(_ id: UUID?) {
        if let id {
            defaults.set(id.uuidString, forKey: Keys.lastFocusedProfileId)
        } else {
            defaults.removeObject(forKey: Keys.lastFocusedProfileId)
        }
    }

    /// Loads the most recently focused profile id, if any was persisted.
    func loadLastFocusedProfileId() -> UUID? {
        guard let uuidString = defaults.string(
            forKey: Keys.lastFocusedProfileId
        ) else {
            return nil
        }
        return UUID(uuidString: uuidString)
    }

    private func key(for kind: ProfileProviderKind) -> String {
        switch kind {
        case .claude: return Keys.activeClaudeProfileId
        case .codex: return Keys.activeCodexProfileId
        }
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

    // MARK: - Provider Badge

    /// Two independent toggles, both off by default (unchanged behavior out
    /// of the box). Turning both on is the combined glyph+tint look — there
    /// is no separate stored "combined" option.

    func saveProviderBadgeGlyphEnabled(_ enabled: Bool) {
        defaults.set(String(enabled), forKey: Keys.providerBadgeGlyphEnabled)
    }

    func loadProviderBadgeGlyphEnabled() -> Bool {
        defaults.string(forKey: Keys.providerBadgeGlyphEnabled) == "true"
    }

    func saveProviderBadgeTintEnabled(_ enabled: Bool) {
        defaults.set(String(enabled), forKey: Keys.providerBadgeTintEnabled)
    }

    func loadProviderBadgeTintEnabled() -> Bool {
        defaults.string(forKey: Keys.providerBadgeTintEnabled) == "true"
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
        guard !profiles[index].deletionInProgress else {
            throw ProfileStoreError.profileDeletionInProgress(profileId)
        }
        guard profiles[index].providerConfiguration.kind == .claude else {
            throw ProfileProviderConfigurationError.claudeProfileRequired(profileId)
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

    /// Persists the complete incoming profile metadata and credential set as
    /// one recoverable transaction. Runtime usage and internal migration state
    /// remain owned by their dedicated stores.
    func saveProfileUpdate(_ updatedProfile: Profile) throws {
        var profiles = try loadProfilesWithVerifiedMigration()
        guard let index = profiles.firstIndex(where: { $0.id == updatedProfile.id }) else {
            throw ProfileStoreError.profileNotFound(updatedProfile.id)
        }
        guard !profiles[index].deletionInProgress else {
            throw ProfileStoreError
                .profileDeletionInProgress(updatedProfile.id)
        }
        try validateProviderIdentity(
            candidate: updatedProfile,
            stored: profiles[index]
        )
        try validateDeletionState(
            candidate: updatedProfile,
            stored: profiles[index]
        )

        if profiles[index].providerConfiguration.kind == .codex {
            profiles[index] = updatedProfile
            try saveProfilesThrowing(profiles)
            return
        }

        var candidate = updatedProfile
        candidate.credentialMigrationRetry = profiles[index].credentialMigrationRetry
        candidate.currentUsageMigrationRetry = profiles[index].currentUsageMigrationRetry
        candidate.deletionInProgress = profiles[index].deletionInProgress
        let credentialMutations = [
            SecretMutation(
                field: .claudeSessionKey,
                value: updatedProfile.claudeSessionKey
            ),
            SecretMutation(
                field: .apiSessionKey,
                value: updatedProfile.apiSessionKey
            ),
            SecretMutation(
                field: .cliCredentialsJSON,
                value: updatedProfile.cliCredentialsJSON
            )
        ]
        // This API replaces the complete credential set. Clear stale retry
        // values in the candidate that is committed only after all secure
        // mutations succeed; transaction rollback retains the stored retries.
        for mutation in credentialMutations {
            candidate.credentialMigrationRetry.setValue(
                nil,
                for: mutation.field
            )
        }
        profiles[index] = candidate

        try performCredentialTransaction(
            profileID: updatedProfile.id,
            mutations: credentialMutations,
            candidateProfiles: profiles
        )
    }

    func loadProfileCredentials(_ profileId: UUID) throws -> ProfileCredentials {
        let profiles = try loadProfilesWithVerifiedMigration()
        guard let profile = profiles.first(where: { $0.id == profileId }) else {
            throw ProfileStoreError.profileNotFound(profileId)
        }
        guard !profile.deletionInProgress else {
            throw ProfileStoreError.profileDeletionInProgress(profileId)
        }
        guard profile.providerConfiguration.kind == .claude else {
            throw ProfileProviderConfigurationError
                .claudeProfileRequired(profileId)
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

    /// Removes only the Claude.ai credential pair and its usage component.
    /// A non-secret durable intent lets relaunch recovery finish coherently if
    /// the immediate rollback path cannot restore the prior linked state.
    func unlinkClaudeAI(for profileID: UUID) throws {
        try performCredentialUsageUnlink(
            profileID: profileID,
            component: .claude,
            updateCredentials: { credentials in
                credentials.claudeSessionKey = nil
                credentials.organizationId = nil
            },
            clearUsage: { usage in
                usage.report = nil
                usage.claudeUsage = nil
            }
        )
    }

    /// Removes only the API Console credential pair and its usage component.
    /// The same verified rollback contract as Claude.ai unlink applies.
    func unlinkAPIConsole(for profileID: UUID) throws {
        try performCredentialUsageUnlink(
            profileID: profileID,
            component: .api,
            updateCredentials: { credentials in
                credentials.apiSessionKey = nil
                credentials.apiOrganizationId = nil
                credentials.apiSessionKeyExpiry = nil
            },
            clearUsage: { usage in
                usage.apiUsage = nil
            }
        )
    }

    /// Dedicated provider-identity mutation. Link, relink, and unlink all
    /// invalidate app-owned current usage and advance the request-identity
    /// revision only after the complete transaction succeeds.
    @discardableResult
    func replaceCodexLinkedHome(
        _ linkedHome: CanonicalCodexHome?,
        for profileID: UUID
    ) throws -> Profile {
        try recoverPendingCodexConfigurationMutations()
        let previousProfileData = defaults.data(forKey: Keys.profiles)
        var profiles = try decodeStoredProfiles()
        try validateProfileSet(profiles)
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }
        guard profiles[index].providerConfiguration.kind == .codex else {
            throw ProfileProviderConfigurationError
                .codexProfileRequired(profileID)
        }
        guard !profiles[index].deletionInProgress else {
            throw ProfileStoreError.profileDeletionInProgress(profileID)
        }
        if profiles[index].providerConfiguration.codexConfiguration?
            .linkedHome == linkedHome {
            return profiles[index]
        }
        if let linkedHome,
           let duplicate = profiles.first(where: {
               $0.id != profileID
                   && $0.providerConfiguration.codexConfiguration?
                       .linkedHome == linkedHome
           }) {
            throw ProfileProviderConfigurationError
                .duplicateCodexHome(duplicate.id)
        }
        let previousUsage = try usageFileStore.loadCurrentUsage(for: profileID)
        try previousUsage?.validate(
            expectedProviderID: profiles[index].providerID,
            expectedProviderRevision: profiles[index].providerRevision
        )
        guard profiles[index].providerRevision < UInt64.max else {
            throw ProfileProviderConfigurationError
                .providerRevisionExhausted(profileID)
        }

        let targetRevision = profiles[index].providerRevision + 1
        let marker = PendingCodexConfigurationMutation(
            profileID: profileID,
            linkedHome: linkedHome,
            targetRevision: targetRevision
        )
        try persistPendingCodexConfigurationMutation(marker)

        do {
            try usageFileStore.deleteCurrentUsage(for: profileID)
            unresolvedUsageProfileIDs.remove(profileID)
            profiles[index].providerConfiguration = .codex(
                CodexProfileConfiguration(linkedHome: linkedHome)
            )
            profiles[index].providerRevision = targetRevision
            try persistProfiles(profiles)
            try removePendingCodexConfigurationMutation(for: profileID)
            return profiles[index]
        } catch {
            var metadataRollbackFailed = false
            var usageRollbackFailed = false

            do {
                try restoreProfiles(previousProfileData)
            } catch {
                metadataRollbackFailed = true
            }
            do {
                if let previousUsage {
                    try usageFileStore.saveCurrentUsage(
                        previousUsage,
                        for: profileID
                    )
                } else {
                    try usageFileStore.deleteCurrentUsage(for: profileID)
                }
                unresolvedUsageProfileIDs.remove(profileID)
            } catch {
                usageRollbackFailed = true
                unresolvedUsageProfileIDs.insert(profileID)
            }

            // The durable target intent remains authoritative until both
            // independent prior-state restorations are verified. If either is
            // unresolved, relaunch deterministically completes the target
            // forward instead of preserving a split state.
            if !metadataRollbackFailed && !usageRollbackFailed {
                do {
                    try removePendingCodexConfigurationMutation(
                        for: profileID
                    )
                } catch {
                    metadataRollbackFailed = true
                }
            }

            if metadataRollbackFailed || usageRollbackFailed {
                throw ProfileProviderConfigurationError
                    .codexConfigurationRollbackFailed(
                        profileID,
                        metadata: metadataRollbackFailed,
                        usage: usageRollbackFailed
                    )
            }
            throw ProfileProviderConfigurationError
                .codexConfigurationMutationFailed(profileID)
        }
    }

    /// Activation metadata has a deliberately narrow storage path. In
    /// particular, selecting a Codex profile does not hydrate or migrate any
    /// Claude credentials.
    @discardableResult
    func updateActivationMetadata(
        for profileID: UUID,
        at timestamp: Date
    ) throws -> Profile {
        try recoverPendingCodexConfigurationMutations()
        var profiles = try decodeStoredProfiles()
        try validateProfileSet(profiles)
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }
        guard !profiles[index].deletionInProgress else {
            throw ProfileStoreError.profileDeletionInProgress(profileID)
        }
        profiles[index].lastUsedAt = timestamp
        try persistProfiles(profiles)
        return profiles[index]
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
        guard !profiles[index].deletionInProgress else {
            throw ProfileStoreError.profileDeletionInProgress(profileId)
        }
        guard profiles[index].providerConfiguration.kind == .claude else {
            throw ProfileProviderConfigurationError.claudeProfileRequired(profileId)
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

    /// Atomically persists a CLI-only credential mutation together with its
    /// profile metadata. Unrelated credential fields are never interpreted,
    /// so a read failure represented as nil cannot become an accidental
    /// deletion.
    func saveCLIProfileUpdate(_ updatedProfile: Profile) throws {
        var profiles = try loadProfilesWithVerifiedMigration()
        guard let index = profiles.firstIndex(where: { $0.id == updatedProfile.id }) else {
            throw ProfileStoreError.profileNotFound(updatedProfile.id)
        }
        guard !profiles[index].deletionInProgress else {
            throw ProfileStoreError
                .profileDeletionInProgress(updatedProfile.id)
        }
        guard profiles[index].providerConfiguration.kind == .claude else {
            throw ProfileProviderConfigurationError
                .claudeProfileRequired(updatedProfile.id)
        }
        try validateProviderIdentity(
            candidate: updatedProfile,
            stored: profiles[index]
        )
        try validateDeletionState(
            candidate: updatedProfile,
            stored: profiles[index]
        )

        var candidate = updatedProfile
        candidate.credentialMigrationRetry = profiles[index].credentialMigrationRetry
        candidate.currentUsageMigrationRetry = profiles[index].currentUsageMigrationRetry
        candidate.deletionInProgress = profiles[index].deletionInProgress
        // The explicit CLI mutation supersedes only its stale retry value.
        // This candidate is committed after the secure write succeeds, while
        // transaction rollback retains the previously persisted envelope.
        candidate.credentialMigrationRetry.setValue(
            nil,
            for: .cliCredentialsJSON
        )
        profiles[index] = candidate

        try performCredentialTransaction(
            profileID: updatedProfile.id,
            mutations: [
                SecretMutation(
                    field: .cliCredentialsJSON,
                    value: updatedProfile.cliCredentialsJSON
                )
            ],
            candidateProfiles: profiles
        )
    }

    /// Verifies removal of all app-owned profile credentials. Callers must keep
    /// the profile identity until this method and subsequent file cleanup pass.
    func deleteProfileSecrets(for profileId: UUID) throws {
        try recoverPendingCredentialUsageUnlinks()
        try recoverPendingCodexConfigurationMutations()
        let profiles = try decodeStoredProfiles()
        try validateProfileSet(profiles)
        guard let profile = profiles.first(where: {
            $0.id == profileId
        }) else {
            throw ProfileStoreError.profileNotFound(profileId)
        }
        guard profile.providerConfiguration.kind == .claude else {
            throw ProfileProviderConfigurationError
                .claudeProfileRequired(profileId)
        }
        for field in ProfileSecretField.allCases {
            let locator = ProfileSecretLocator(profileID: profileId, field: field)
            try secretStore.delete(locator)
            credentialBaselines[locator] = .absent
            unresolvedLocators.remove(locator)
        }
    }

    /// Atomically retains a scrubbed deletion marker before any irreversible
    /// cleanup. This prevents persisted migration envelopes from recreating
    /// credentials or usage if deletion later fails and the app relaunches.
    func beginProfileDeletion(_ profileId: UUID) throws -> Profile {
        // Resolve every durable mutation intent before the deletion tombstone
        // is committed. No recovery may recreate profile-owned files after
        // destructive cleanup and before verified identity removal.
        try recoverPendingCredentialUsageUnlinks()
        try recoverPendingCodexConfigurationMutations()
        var profiles = try decodeStoredProfiles()
        try validateProfileSet(profiles)
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            throw ProfileStoreError.profileNotFound(profileId)
        }

        profiles[index].deletionInProgress = true
        profiles[index].claudeSessionKey = nil
        profiles[index].apiSessionKey = nil
        profiles[index].cliCredentialsJSON = nil
        profiles[index].credentialMigrationRetry = .init()
        profiles[index].claudeUsage = nil
        profiles[index].apiUsage = nil
        profiles[index].currentUsageMigrationRetry = nil

        try persistProfiles(profiles)
        return profiles[index]
    }

    /// Removes a previously tombstoned identity using an authoritative
    /// compare-and-swap over the complete remaining profile set.
    func finalizeProfileDeletion(
        _ profileId: UUID,
        expectedRemainingIDs: Set<UUID>
    ) throws {
        try recoverPendingCredentialUsageUnlinks()
        try recoverPendingCodexConfigurationMutations()
        let profiles = try decodeStoredProfiles()
        try validateProfileSet(profiles)
        guard let target = profiles.first(where: {
            $0.id == profileId
        }) else {
            throw ProfileStoreError.profileNotFound(profileId)
        }
        guard target.deletionInProgress else {
            throw ProfileProviderConfigurationError.profileSetChanged
        }
        let remaining = profiles.filter { $0.id != profileId }
        guard remaining.count == expectedRemainingIDs.count,
              Set(remaining.map(\.id)) == expectedRemainingIDs else {
            throw ProfileProviderConfigurationError.profileSetChanged
        }
        try persistProfiles(remaining)
    }

    // MARK: - Current Usage

    func saveClaudeUsage(_ usage: ClaudeUsage, for profileID: UUID) throws {
        let profile = try requireClaudeProfile(profileID)
        var current = try loadCurrentUsageResolvingMigration(
            for: profileID
        )
        current.claudeUsage = usage
        _ = try commitCurrentUsage(
            current,
            for: profileID,
            expectedProviderID: profile.providerID,
            expectedProviderRevision: profile.providerRevision
        )
    }

    func clearClaudeUsage(for profileID: UUID) throws {
        let profile = try requireClaudeProfile(profileID)
        var current = try loadCurrentUsageResolvingMigration(
            for: profileID
        )
        current.report = nil
        current.claudeUsage = nil
        _ = try commitCurrentUsage(
            current,
            for: profileID,
            expectedProviderID: profile.providerID,
            expectedProviderRevision: profile.providerRevision
        )
    }

    func loadClaudeUsage(for profileID: UUID) throws -> ClaudeUsage? {
        try requireClaudeProfile(profileID)
        return try loadCurrentUsageResolvingMigration(for: profileID)
            .claudeUsage
    }

    func saveAPIUsage(_ usage: APIUsage, for profileID: UUID) throws {
        let profile = try requireClaudeProfile(profileID)
        var current = try loadCurrentUsageResolvingMigration(
            for: profileID
        )
        current.apiUsage = usage
        _ = try commitCurrentUsage(
            current,
            for: profileID,
            expectedProviderID: profile.providerID,
            expectedProviderRevision: profile.providerRevision
        )
    }

    func clearAPIUsage(for profileID: UUID) throws {
        let profile = try requireClaudeProfile(profileID)
        var current = try loadCurrentUsageResolvingMigration(
            for: profileID
        )
        current.apiUsage = nil
        _ = try commitCurrentUsage(
            current,
            for: profileID,
            expectedProviderID: profile.providerID,
            expectedProviderRevision: profile.providerRevision
        )
    }

    func loadAPIUsage(for profileID: UUID) throws -> APIUsage? {
        try requireClaudeProfile(profileID)
        return try loadCurrentUsageResolvingMigration(for: profileID)
            .apiUsage
    }

    /// Loads usage only for the exact request identity captured by a refresh.
    /// An existing file for another provider or revision fails closed.
    func loadCurrentUsage(
        for profileID: UUID,
        expectedProviderID: ProviderID,
        expectedProviderRevision: UInt64
    ) throws -> ProfileCurrentUsage? {
        try recoverPendingCredentialUsageUnlinks()
        try recoverPendingCodexConfigurationMutations()
        try validateCurrentUsageFence(
            profileID: profileID,
            expectedProviderID: expectedProviderID,
            expectedProviderRevision: expectedProviderRevision
        )
        _ = try loadCurrentUsageResolvingMigration(for: profileID)
        let usage = try usageFileStore.loadCurrentUsage(for: profileID)
        try usage?.validate(
            expectedProviderID: expectedProviderID,
            expectedProviderRevision: expectedProviderRevision
        )
        return usage
    }

    /// Commits one complete provider result through a provider/revision/
    /// deletion fence. The installed payload and live identity are read back
    /// before success is returned, so callers may publish only after this
    /// method completes.
    @discardableResult
    func commitCurrentUsage(
        _ usage: ProfileCurrentUsage,
        for profileID: UUID,
        expectedProviderID: ProviderID,
        expectedProviderRevision: UInt64
    ) throws -> (
        previous: ProfileCurrentUsage?,
        current: ProfileCurrentUsage
    ) {
        try usage.validate(
            expectedProviderID: expectedProviderID,
            expectedProviderRevision: expectedProviderRevision
        )
        try recoverPendingCredentialUsageUnlinks()
        try recoverPendingCodexConfigurationMutations()
        try validateCurrentUsageFence(
            profileID: profileID,
            expectedProviderID: expectedProviderID,
            expectedProviderRevision: expectedProviderRevision
        )

        // Resolve a legacy retry before capturing the rollback value. A valid
        // installed destination remains authoritative under D031.
        _ = try loadCurrentUsageResolvingMigration(for: profileID)
        let previousUsage = try usageFileStore.loadCurrentUsage(
            for: profileID
        )
        try previousUsage?.validate(
            expectedProviderID: expectedProviderID,
            expectedProviderRevision: expectedProviderRevision
        )

        do {
            let updated = try usageFileStore.updateCurrentUsage(
                for: profileID
            ) { current in
                current = usage
            }
            guard updated == usage else {
                throw ProfileUsageFileStoreError
                    .currentUsageWriteVerificationFailed(profileID)
            }
            let installed = try usageFileStore.loadCurrentUsage(
                for: profileID
            )
            guard installed == usage else {
                throw ProfileUsageFileStoreError
                    .currentUsageWriteVerificationFailed(profileID)
            }
            try validateCurrentUsageFence(
                profileID: profileID,
                expectedProviderID: expectedProviderID,
                expectedProviderRevision: expectedProviderRevision
            )
            unresolvedUsageProfileIDs.remove(profileID)
            return (previous: previousUsage, current: usage)
        } catch {
            let commitError = error
            do {
                let installedAfterFailure =
                    try usageFileStore.loadCurrentUsage(for: profileID)
                if currentUsageFenceMatches(
                    profileID: profileID,
                    expectedProviderID: expectedProviderID,
                    expectedProviderRevision: expectedProviderRevision
                ) {
                    if installedAfterFailure != previousUsage {
                        if let previousUsage {
                            try usageFileStore.saveCurrentUsage(
                                previousUsage,
                                for: profileID
                            )
                        } else {
                            try usageFileStore.deleteCurrentUsage(
                                for: profileID
                            )
                        }
                    }
                    guard try usageFileStore.loadCurrentUsage(
                        for: profileID
                    ) == previousUsage else {
                        throw ProfileUsageFileStoreError
                            .currentUsageWriteVerificationFailed(profileID)
                    }
                } else if installedAfterFailure == usage {
                    // The identity changed after installation. Remove only
                    // the exact stale value installed by this call; never
                    // delete a newer writer's payload.
                    try usageFileStore.deleteCurrentUsage(for: profileID)
                    guard try usageFileStore.loadCurrentUsage(
                        for: profileID
                    ) == nil else {
                        throw ProfileUsageFileStoreError
                            .currentUsageWriteVerificationFailed(profileID)
                    }
                }
            } catch {
                unresolvedUsageProfileIDs.insert(profileID)
                throw ProfileStoreError
                    .currentUsageCommitRollbackFailed(profileID)
            }
            throw commitError
        }
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

    @discardableResult
    private func requireClaudeProfile(_ profileID: UUID) throws -> Profile {
        let profiles = try decodeStoredProfiles()
        try validateProfileSet(profiles)
        guard let profile = profiles.first(where: {
            $0.id == profileID
        }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }
        guard profile.providerConfiguration.kind == .claude else {
            throw ProfileProviderConfigurationError
                .claudeProfileRequired(profileID)
        }
        guard !profile.deletionInProgress else {
            throw ProfileStoreError.profileDeletionInProgress(profileID)
        }
        return profile
    }

    private func validateCurrentUsageFence(
        profileID: UUID,
        expectedProviderID: ProviderID,
        expectedProviderRevision: UInt64
    ) throws {
        let profiles = try decodeStoredProfiles()
        try validateProfileSet(profiles)
        guard let profile = profiles.first(where: {
            $0.id == profileID
        }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }
        guard !profile.deletionInProgress else {
            throw ProfileStoreError.profileDeletionInProgress(profileID)
        }
        guard profile.providerID == expectedProviderID,
              profile.providerRevision == expectedProviderRevision else {
            throw ProfileCurrentUsageValidationError.identityMismatch(
                expectedProviderID: expectedProviderID,
                expectedProviderRevision: expectedProviderRevision,
                foundProviderID: profile.providerID,
                foundProviderRevision: profile.providerRevision
            )
        }
    }

    private func currentUsageFenceMatches(
        profileID: UUID,
        expectedProviderID: ProviderID,
        expectedProviderRevision: UInt64
    ) -> Bool {
        do {
            try validateCurrentUsageFence(
                profileID: profileID,
                expectedProviderID: expectedProviderID,
                expectedProviderRevision: expectedProviderRevision
            )
            return true
        } catch {
            return false
        }
    }

    /// A pending unlink remains authoritative even when its recovery write
    /// fails. Return a fail-closed runtime projection without changing either
    /// the stored retry material or durable marker needed by a later recovery.
    private func decodeStoredProfilesMaskingPendingUnlinks() throws
        -> [Profile] {
        var profiles = try decodeStoredProfiles()

        for marker in try loadPendingCredentialUsageUnlinks() {
            guard let index = profiles.firstIndex(where: {
                $0.id == marker.profileID
            }) else {
                throw ProfileStoreError.profileNotFound(marker.profileID)
            }
            guard profiles[index].providerConfiguration.kind
                    == .claude else {
                throw ProfileProviderConfigurationError
                    .claudeProfileRequired(marker.profileID)
            }
            let field: ProfileSecretField =
                marker.component == .claude
                    ? .claudeSessionKey
                    : .apiSessionKey
            profiles[index].setSecretValue(nil, for: field)
            profiles[index].credentialMigrationRetry.setValue(
                nil,
                for: field
            )

            if marker.component == .claude {
                profiles[index].organizationId = nil
                profiles[index].claudeUsage = nil
            } else {
                profiles[index].apiOrganizationId = nil
                profiles[index].apiSessionKeyExpiry = nil
                profiles[index].apiUsage = nil
            }

            if var usageRetry =
                profiles[index].currentUsageMigrationRetry {
                if marker.component == .claude {
                    usageRetry.report = nil
                    usageRetry.claudeUsage = nil
                } else {
                    usageRetry.apiUsage = nil
                }
                profiles[index].currentUsageMigrationRetry =
                    usageRetry.isEmpty ? nil : usageRetry
            }
        }

        for marker in try loadPendingCodexConfigurationMutations() {
            guard let index = profiles.firstIndex(where: {
                $0.id == marker.profileID
            }) else {
                throw ProfileStoreError.profileNotFound(marker.profileID)
            }
            try validateCodexConfigurationMutationMarker(
                marker,
                against: profiles[index]
            )
            profiles[index].providerConfiguration = .codex(
                CodexProfileConfiguration(linkedHome: marker.linkedHome)
            )
            profiles[index].providerRevision = marker.targetRevision
            profiles[index].claudeUsage = nil
            profiles[index].apiUsage = nil
            profiles[index].currentUsageMigrationRetry = nil
            unresolvedUsageProfileIDs.insert(marker.profileID)
        }

        try validateProfileSet(profiles)
        return profiles
    }

    private func validateProviderIdentity(
        candidate: Profile,
        stored: Profile
    ) throws {
        guard stored.providerConfiguration.kind
                == candidate.providerConfiguration.kind else {
            throw ProfileProviderConfigurationError
                .providerChangeNotAllowed(candidate.id)
        }
        guard stored.providerConfiguration
                == candidate.providerConfiguration else {
            throw ProfileProviderConfigurationError
                .codexHomeChangeRequiresLink(candidate.id)
        }
        guard stored.providerRevision == candidate.providerRevision else {
            throw ProfileProviderConfigurationError
                .providerRevisionChangeNotAllowed(candidate.id)
        }
    }

    private func validateDeletionState(
        candidate: Profile,
        stored: Profile
    ) throws {
        guard candidate.deletionInProgress
                == stored.deletionInProgress else {
            throw ProfileProviderConfigurationError
                .deletionStateChangeRequiresLifecycle(candidate.id)
        }
    }

    private func validateCodexConfigurationMutationMarker(
        _ marker: PendingCodexConfigurationMutation,
        against profile: Profile
    ) throws {
        guard profile.providerConfiguration.kind == .codex else {
            throw ProfileProviderConfigurationError
                .codexProfileRequired(marker.profileID)
        }
        let currentRevision = profile.providerRevision
        if currentRevision == marker.targetRevision {
            guard profile.providerConfiguration.codexConfiguration?
                    .linkedHome == marker.linkedHome else {
                throw ProfileProviderConfigurationError
                    .codexConfigurationMarkerVerificationFailed
            }
            return
        }
        guard currentRevision < UInt64.max,
              marker.targetRevision == currentRevision + 1 else {
            throw ProfileProviderConfigurationError
                .codexConfigurationMarkerVerificationFailed
        }
    }

    private func prepareForOrdinarySave(_ profile: Profile, stored: Profile?) throws -> Profile {
        var prepared = profile
        try profile.validateProviderIsolation()
        if let stored {
            try validateProviderIdentity(
                candidate: profile,
                stored: stored
            )
            try validateDeletionState(
                candidate: profile,
                stored: stored
            )
        }
        if stored?.deletionInProgress == true || profile.deletionInProgress {
            prepared.deletionInProgress = true
            prepared.claudeSessionKey = nil
            prepared.apiSessionKey = nil
            prepared.cliCredentialsJSON = nil
            prepared.credentialMigrationRetry = .init()
            prepared.claudeUsage = nil
            prepared.apiUsage = nil
            prepared.currentUsageMigrationRetry = nil
            return prepared
        }

        prepared.credentialMigrationRetry = stored?.credentialMigrationRetry
            ?? profile.credentialMigrationRetry
        prepared.currentUsageMigrationRetry = stored?.currentUsageMigrationRetry
            ?? profile.currentUsageMigrationRetry

        if profile.providerConfiguration.kind == .codex {
            // Provider isolation guarantees these are already empty. Avoid
            // even constructing Claude secure-storage locators.
            return prepared
        }

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
        try validateProfileSet(profiles)
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }
        guard !profiles[index].deletionInProgress else {
            throw ProfileStoreError.profileDeletionInProgress(profileID)
        }
        let providerID = profiles[index].providerID
        let providerRevision = profiles[index].providerRevision

        if let retryUsage = profiles[index].currentUsageMigrationRetry {
            do {
                try retryUsage.validate(
                    expectedProviderID: providerID,
                    expectedProviderRevision: providerRevision
                )
                let authoritativeUsage: ProfileCurrentUsage
                if let existingUsage = try usageFileStore.loadCurrentUsage(for: profileID) {
                    try existingUsage.validate(
                        expectedProviderID: providerID,
                        expectedProviderRevision: providerRevision
                    )
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
                ?? ProfileCurrentUsage(
                    providerID: providerID,
                    providerRevision: providerRevision
                )
            try usage.validate(
                expectedProviderID: providerID,
                expectedProviderRevision: providerRevision
            )
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

    private func performCredentialUsageUnlink(
        profileID: UUID,
        component: PendingCredentialUsageUnlink.Component,
        updateCredentials: (inout ProfileCredentials) -> Void,
        clearUsage: (inout ProfileCurrentUsage) -> Void
    ) throws {
        let targetField: ProfileSecretField =
            component == .claude ? .claudeSessionKey : .apiSessionKey
        let previousCredentials = try loadProfileCredentials(profileID)
        let previousUsage = try loadCurrentUsageResolvingMigration(for: profileID)
        var unlinkedCredentials = previousCredentials
        updateCredentials(&unlinkedCredentials)
        var profiles = try loadProfilesWithVerifiedMigration()
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }
        if component == .claude {
            profiles[index].claudeSessionKey =
                unlinkedCredentials.claudeSessionKey
            profiles[index].organizationId =
                unlinkedCredentials.organizationId
        } else {
            profiles[index].apiSessionKey =
                unlinkedCredentials.apiSessionKey
            profiles[index].apiOrganizationId =
                unlinkedCredentials.apiOrganizationId
            profiles[index].apiSessionKeyExpiry =
                unlinkedCredentials.apiSessionKeyExpiry
        }
        profiles[index].credentialMigrationRetry.setValue(
            nil,
            for: targetField
        )
        let marker = PendingCredentialUsageUnlink(
            profileID: profileID,
            component: component
        )
        try persistPendingCredentialUsageUnlink(marker)

        do {
            _ = try usageFileStore.updateCurrentUsage(for: profileID) { usage in
                clearUsage(&usage)
            }
            unresolvedUsageProfileIDs.remove(profileID)
            try performCredentialTransaction(
                profileID: profileID,
                mutations: component == .claude
                    ? [
                        SecretMutation(
                            field: .claudeSessionKey,
                            value: unlinkedCredentials.claudeSessionKey
                        )
                    ]
                    : [
                        SecretMutation(
                            field: .apiSessionKey,
                            value: unlinkedCredentials.apiSessionKey
                        )
                    ],
                candidateProfiles: profiles
            )
            try removePendingCredentialUsageUnlink(for: profileID)
        } catch {
            do {
                let resolution = try recoverPendingCredentialUsageUnlink(
                    marker,
                    rollbackCredentials: previousCredentials,
                    rollbackUsage: previousUsage
                )
                if resolution == .unlinked {
                    // The original rollback was not possible, but recovery
                    // completed the unlink coherently and durably.
                    return
                }
            } catch {
                throw ProfileStoreError.credentialUsageUnlinkRollbackFailed(
                    profileID,
                    credentials: true,
                    usage: true
                )
            }
            throw ProfileStoreError.credentialUsageUnlinkFailed(profileID)
        }
    }

    private func recoverPendingCredentialUsageUnlinks() throws {
        for marker in try loadPendingCredentialUsageUnlinks() {
            _ = try recoverPendingCredentialUsageUnlink(
                marker,
                rollbackCredentials: nil,
                rollbackUsage: nil
            )
        }
    }

    private func recoverPendingCodexConfigurationMutations() throws {
        for marker in try loadPendingCodexConfigurationMutations() {
            var profiles = try decodeStoredProfiles()
            try validateProfileSet(profiles)
            guard let index = profiles.firstIndex(where: {
                $0.id == marker.profileID
            }) else {
                throw ProfileStoreError.profileNotFound(marker.profileID)
            }
            try validateCodexConfigurationMutationMarker(
                marker,
                against: profiles[index]
            )

            try usageFileStore.deleteCurrentUsage(for: marker.profileID)
            profiles[index].providerConfiguration = .codex(
                CodexProfileConfiguration(linkedHome: marker.linkedHome)
            )
            profiles[index].providerRevision = marker.targetRevision
            try persistProfiles(profiles)
            unresolvedUsageProfileIDs.remove(marker.profileID)
            try removePendingCodexConfigurationMutation(
                for: marker.profileID
            )
        }
    }

    private func loadPendingCodexConfigurationMutations() throws
        -> [PendingCodexConfigurationMutation] {
        guard let data = defaults.data(
            forKey: Keys.pendingCodexConfigurationMutations
        ) else {
            return []
        }
        return try JSONDecoder().decode(
            [PendingCodexConfigurationMutation].self,
            from: data
        )
    }

    private func persistPendingCodexConfigurationMutation(
        _ marker: PendingCodexConfigurationMutation
    ) throws {
        var markers = try loadPendingCodexConfigurationMutations()
        markers.removeAll { $0.profileID == marker.profileID }
        markers.append(marker)
        try persistPendingCodexConfigurationMutations(markers)
    }

    private func removePendingCodexConfigurationMutation(
        for profileID: UUID
    ) throws {
        var markers = try loadPendingCodexConfigurationMutations()
        markers.removeAll { $0.profileID == profileID }
        try persistPendingCodexConfigurationMutations(markers)
    }

    private func persistPendingCodexConfigurationMutations(
        _ markers: [PendingCodexConfigurationMutation]
    ) throws {
        let data = try JSONEncoder().encode(markers)
        if markers.isEmpty {
            defaults.removeObject(
                forKey: Keys.pendingCodexConfigurationMutations
            )
            guard defaults.data(
                forKey: Keys.pendingCodexConfigurationMutations
            ) == nil else {
                throw ProfileProviderConfigurationError
                    .codexConfigurationMarkerVerificationFailed
            }
        } else {
            defaults.set(
                data,
                forKey: Keys.pendingCodexConfigurationMutations
            )
            guard defaults.data(
                forKey: Keys.pendingCodexConfigurationMutations
            ) == data else {
                throw ProfileProviderConfigurationError
                    .codexConfigurationMarkerVerificationFailed
            }
        }
    }

    private func recoverPendingCredentialUsageUnlink(
        _ marker: PendingCredentialUsageUnlink,
        rollbackCredentials: ProfileCredentials?,
        rollbackUsage: ProfileCurrentUsage?
    ) throws -> CredentialUsageUnlinkResolution {
        var profiles = try decodeStoredProfiles()
        try validateProfileSet(profiles)
        guard let index = profiles.firstIndex(where: {
            $0.id == marker.profileID
        }) else {
            throw ProfileStoreError.profileNotFound(marker.profileID)
        }
        guard profiles[index].providerConfiguration.kind == .claude else {
            throw ProfileProviderConfigurationError
                .claudeProfileRequired(marker.profileID)
        }
        let field: ProfileSecretField =
            marker.component == .claude ? .claudeSessionKey : .apiSessionKey
        let locator = ProfileSecretLocator(
            profileID: marker.profileID,
            field: field
        )
        let secretState: ProfileSecretReadResult
        do {
            secretState = try secretStore.read(locator)
            credentialBaselines[locator] = secretState
            unresolvedLocators.remove(locator)
        } catch {
            credentialBaselines.removeValue(forKey: locator)
            unresolvedLocators.insert(locator)
            throw ProfileStoreError.credentialReadUnresolved(locator)
        }

        let resolution: CredentialUsageUnlinkResolution

        if case .value(let value) = secretState,
           let rollbackCredentials,
           let rollbackUsage {
            profiles[index].setSecretValue(value, for: field)
            if marker.component == .claude {
                profiles[index].organizationId =
                    rollbackCredentials.organizationId
            } else {
                profiles[index].apiOrganizationId =
                    rollbackCredentials.apiOrganizationId
                profiles[index].apiSessionKeyExpiry =
                    rollbackCredentials.apiSessionKeyExpiry
            }
            try usageFileStore.saveCurrentUsage(
                rollbackUsage,
                for: marker.profileID
            )
            resolution = .linked
        } else {
            // A persisted marker is explicit user unlink intent. If the
            // in-process prior-state snapshot is unavailable (relaunch), or
            // secure rollback already left the field absent, complete forward.
            if case .value = secretState {
                try replaceSecret(
                    nil,
                    field: field,
                    profileID: marker.profileID
                )
            }
            profiles[index].setSecretValue(nil, for: field)
            if marker.component == .claude {
                profiles[index].organizationId = nil
            } else {
                profiles[index].apiOrganizationId = nil
                profiles[index].apiSessionKeyExpiry = nil
            }
            // Forward completion is authoritative for this component. Remove
            // only its retry plaintext so the loader cannot replay the
            // unlinked secret; unrelated recovery envelopes remain intact.
            profiles[index].credentialMigrationRetry.setValue(
                nil,
                for: field
            )
            if var usageRetry =
                profiles[index].currentUsageMigrationRetry {
                if marker.component == .claude {
                    usageRetry.report = nil
                    usageRetry.claudeUsage = nil
                } else {
                    usageRetry.apiUsage = nil
                }
                profiles[index].currentUsageMigrationRetry =
                    usageRetry.isEmpty ? nil : usageRetry
            }
            var usage = try usageFileStore.loadCurrentUsage(
                for: marker.profileID
            ) ?? ProfileCurrentUsage(
                providerID: profiles[index].providerID,
                providerRevision: profiles[index].providerRevision
            )
            try usage.validate(
                expectedProviderID: profiles[index].providerID,
                expectedProviderRevision:
                    profiles[index].providerRevision
            )
            if marker.component == .claude {
                usage.report = nil
                usage.claudeUsage = nil
            } else {
                usage.apiUsage = nil
            }
            try usageFileStore.saveCurrentUsage(
                usage,
                for: marker.profileID
            )
            resolution = .unlinked
        }

        try persistProfiles(profiles)
        unresolvedUsageProfileIDs.remove(marker.profileID)
        try removePendingCredentialUsageUnlink(for: marker.profileID)
        return resolution
    }

    private func loadPendingCredentialUsageUnlinks() throws
        -> [PendingCredentialUsageUnlink] {
        guard let data = defaults.data(
            forKey: Keys.pendingCredentialUsageUnlinks
        ) else {
            return []
        }
        return try JSONDecoder().decode(
            [PendingCredentialUsageUnlink].self,
            from: data
        )
    }

    private func persistPendingCredentialUsageUnlink(
        _ marker: PendingCredentialUsageUnlink
    ) throws {
        var markers = try loadPendingCredentialUsageUnlinks()
        markers.removeAll { $0.profileID == marker.profileID }
        markers.append(marker)
        try persistPendingCredentialUsageUnlinks(markers)
    }

    private func removePendingCredentialUsageUnlink(
        for profileID: UUID
    ) throws {
        var markers = try loadPendingCredentialUsageUnlinks()
        markers.removeAll { $0.profileID == profileID }
        try persistPendingCredentialUsageUnlinks(markers)
    }

    private func persistPendingCredentialUsageUnlinks(
        _ markers: [PendingCredentialUsageUnlink]
    ) throws {
        let data = try JSONEncoder().encode(markers)
        if markers.isEmpty {
            defaults.removeObject(
                forKey: Keys.pendingCredentialUsageUnlinks
            )
            guard defaults.data(
                forKey: Keys.pendingCredentialUsageUnlinks
            ) == nil else {
                throw ProfileStoreError
                    .credentialUsageUnlinkMarkerVerificationFailed
            }
        } else {
            defaults.set(
                data,
                forKey: Keys.pendingCredentialUsageUnlinks
            )
            guard defaults.data(
                forKey: Keys.pendingCredentialUsageUnlinks
            ) == data else {
                throw ProfileStoreError
                    .credentialUsageUnlinkMarkerVerificationFailed
            }
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
        try validateProfileSet(profiles)
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

    private func validateProfileSet(_ profiles: [Profile]) throws {
        var profileIDs: Set<UUID> = []
        var codexHomes: [CanonicalCodexHome: UUID] = [:]
        for profile in profiles {
            try profile.validateProviderIsolation()
            guard profileIDs.insert(profile.id).inserted else {
                throw ProfileProviderConfigurationError
                    .duplicateProfileID(profile.id)
            }
            guard let home = profile.providerConfiguration
                    .codexConfiguration?.linkedHome else {
                continue
            }
            if let owner = codexHomes[home] {
                throw ProfileProviderConfigurationError
                    .duplicateCodexHome(owner)
            }
            codexHomes[home] = profile.id
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

private struct PendingCredentialUsageUnlink: Codable {
    enum Component: String, Codable {
        case claude
        case api
    }

    let profileID: UUID
    let component: Component
}

private struct PendingCodexConfigurationMutation: Codable {
    let profileID: UUID
    let linkedHome: CanonicalCodexHome?
    let targetRevision: UInt64
}

private enum CredentialUsageUnlinkResolution {
    case linked
    case unlinked
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
