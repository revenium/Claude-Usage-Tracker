//
//  ProfileMigrationService.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation

protocol LegacyProfileSettingsSource {
    func loadMenuBarIconConfiguration() -> MenuBarIconConfiguration
    func loadRefreshInterval() -> TimeInterval
    func loadNotificationsEnabled() -> Bool
    func loadAutoStartSessionEnabled() -> Bool
    func loadOrganizationId() -> String?
    func loadAPIOrganizationId() -> String?
}

extension DataStore: LegacyProfileSettingsSource {}

/// Coordinates the one-time single-profile migration before normal profile
/// loading. Every stage is idempotent and completion is recorded only after
/// profile metadata and profile-keyed credentials pass direct readback.
class ProfileMigrationService {
    static let shared = ProfileMigrationService()

    private let defaults: UserDefaults
    private let profileStore: ProfileStore
    private let credentialMigration: KeychainMigrationService
    private let legacySettings: any LegacyProfileSettingsSource
    private let migrationKey = "didMigrateToProfilesV3"
    private let metadataMigrationKey =
        "profileLegacyMetadataMigrationCompleted_v1"

    init(
        defaults: UserDefaults = .standard,
        profileStore: ProfileStore = .shared,
        credentialMigration: KeychainMigrationService = .shared,
        legacySettings: any LegacyProfileSettingsSource = DataStore.shared
    ) {
        self.defaults = defaults
        self.profileStore = profileStore
        self.credentialMigration = credentialMigration
        self.legacySettings = legacySettings
    }

    func migrateIfNeeded() {
        do {
            try migrateIfNeededThrowing()
        } catch {
            LoggingService.shared.logError("Profile migration failed; it will retry", error: error)
        }
    }

    func migrateIfNeededThrowing() throws {
        let profiles = try profileStore.loadProfilesWithVerifiedMigration()
        let previousActiveID = profileStore.loadLegacyActiveProfileId()
        let activeClaude = previousActiveID
            .flatMap { activeID in
                profiles.first(where: {
                    $0.id == activeID
                        && !$0.deletionInProgress
                        && $0.providerConfiguration.kind == .claude
                })
            }
        guard let targetProfile =
                activeClaude
                ?? profiles.first(where: {
                    !$0.deletionInProgress
                        && $0.providerConfiguration.kind == .claude
                }) else {
            // First run has no provider until the user chooses one. Likewise,
            // a Codex-only installation must not consume or delete Claude
            // legacy sources.
            return
        }

        _ = try migrateClaudeProfileIfNeeded(to: targetProfile.id)

        // Keep a valid explicit provider selection. Only repair missing/stale
        // selection metadata to the migration target.
        if previousActiveID.flatMap({ id in
            profiles.first(where: { $0.id == id })
        }) == nil {
            profileStore.saveActiveProfileId(targetProfile.id, for: .claude)
        }
    }

    /// Explicit seam used immediately after the user creates the first Claude
    /// profile. It preserves zero-profile/provider choice, then applies the
    /// same verified legacy metadata and credential rules to that chosen UUID.
    @discardableResult
    func migrateClaudeProfileIfNeeded(
        to profileID: UUID
    ) throws -> Profile {
        var profiles = try profileStore.loadProfilesWithVerifiedMigration()
        guard let index = profiles.firstIndex(where: {
            $0.id == profileID
        }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }
        guard profiles[index].providerConfiguration.kind == .claude else {
            throw ProfileProviderConfigurationError
                .claudeProfileRequired(profileID)
        }
        guard !profiles[index].deletionInProgress else {
            throw ProfileStoreError.profileDeletionInProgress(profileID)
        }

        // The original all-in-one marker proves legacy metadata was already
        // consumed on established v3 installations. Seed the split marker on
        // upgrade so customized per-profile settings are never overwritten.
        if defaults.bool(forKey: migrationKey),
           !defaults.bool(forKey: metadataMigrationKey) {
            defaults.set(true, forKey: metadataMigrationKey)
            guard defaults.bool(forKey: metadataMigrationKey) else {
                throw ProfileStoreError.profileWriteVerificationFailed
            }
        }

        if !defaults.bool(forKey: metadataMigrationKey) {
            profiles[index].iconConfig =
                legacySettings.loadMenuBarIconConfiguration()
            profiles[index].refreshInterval =
                legacySettings.loadRefreshInterval()
            profiles[index].autoStartSessionEnabled =
                legacySettings.loadAutoStartSessionEnabled()
            profiles[index].notificationSettings = NotificationSettings(
                enabled: legacySettings.loadNotificationsEnabled(),
                threshold75Enabled: true,
                threshold90Enabled: true,
                threshold95Enabled: true
            )
            if profiles[index].organizationId == nil {
                profiles[index].organizationId =
                    legacySettings.loadOrganizationId()
            }
            if profiles[index].apiOrganizationId == nil {
                profiles[index].apiOrganizationId =
                    legacySettings.loadAPIOrganizationId()
            }
            try profileStore.saveProfilesThrowing(profiles)
            defaults.set(true, forKey: metadataMigrationKey)
            guard defaults.bool(forKey: metadataMigrationKey) else {
                throw ProfileStoreError.profileWriteVerificationFailed
            }
        }

        // Existing v3 installations can predate profile-keyed secure storage.
        // The credential service's own verified marker keeps this idempotent.
        try credentialMigration.migrateIfNeeded(
            to: profileID,
            profileStore: profileStore
        )

        let verifiedProfiles =
            try profileStore.loadProfilesWithVerifiedMigration()
        guard let verified = verifiedProfiles.first(where: {
            $0.id == profileID
        }) else {
            throw ProfileStoreError.profileWriteVerificationFailed
        }

        defaults.set(true, forKey: migrationKey)
        guard defaults.bool(forKey: migrationKey) else {
            throw ProfileStoreError.profileWriteVerificationFailed
        }

        LoggingService.shared.log("Profile migration completed and verified")
        return verified
    }

    func resetMigration() {
        defaults.removeObject(forKey: migrationKey)
        defaults.removeObject(forKey: metadataMigrationKey)
        credentialMigration.resetMigrationForTesting()
    }
}
