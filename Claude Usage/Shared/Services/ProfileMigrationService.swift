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
        var profiles = try profileStore.loadProfilesWithVerifiedMigration()

        if defaults.bool(forKey: migrationKey), !profiles.isEmpty {
            // Existing v3 installations can predate profile-keyed secure
            // storage. Retry both profile-blob and global/file source migration
            // even though the earlier multi-profile marker is already set.
            let targetID = profileStore.loadActiveProfileId()
                .flatMap { activeID in
                    profiles.first(where: { $0.id == activeID })?.id
                } ?? profiles[0].id
            try credentialMigration.migrateIfNeeded(
                to: targetID,
                profileStore: profileStore
            )
            return
        }

        let targetProfile: Profile

        if let activeID = profileStore.loadActiveProfileId(),
           let active = profiles.first(where: { $0.id == activeID }) {
            targetProfile = active
        } else if let existing = profiles.first {
            targetProfile = existing
        } else {
            targetProfile = createFirstProfileFromLegacy()
            try profileStore.saveProfilesThrowing([targetProfile])
            profiles = try profileStore.loadProfilesWithVerifiedMigration()
            guard profiles.contains(where: { $0.id == targetProfile.id }) else {
                throw ProfileStoreError.profileWriteVerificationFailed
            }
        }

        // Organization identifiers are metadata, not secrets. Populate them
        // only when the target does not already contain a newer selection.
        if let index = profiles.firstIndex(where: { $0.id == targetProfile.id }) {
            if profiles[index].organizationId == nil {
                profiles[index].organizationId = legacySettings.loadOrganizationId()
            }
            if profiles[index].apiOrganizationId == nil {
                profiles[index].apiOrganizationId = legacySettings.loadAPIOrganizationId()
            }
            try profileStore.saveProfilesThrowing(profiles)
        }

        try credentialMigration.migrateIfNeeded(
            to: targetProfile.id,
            profileStore: profileStore
        )

        let verifiedProfiles = try profileStore.loadProfilesWithVerifiedMigration()
        guard verifiedProfiles.contains(where: { $0.id == targetProfile.id }) else {
            throw ProfileStoreError.profileWriteVerificationFailed
        }

        profileStore.saveActiveProfileId(targetProfile.id)
        profileStore.saveDisplayMode(.single)
        defaults.set(true, forKey: migrationKey)
        guard defaults.bool(forKey: migrationKey) else {
            throw ProfileStoreError.profileWriteVerificationFailed
        }

        LoggingService.shared.log("Profile migration completed and verified")
    }

    private func createFirstProfileFromLegacy() -> Profile {
        Profile(
            id: UUID(),
            name: FunnyNameGenerator.getRandomName(excluding: []),
            hasCliAccount: false,
            cliAccountSyncedAt: nil,
            iconConfig: legacySettings.loadMenuBarIconConfiguration(),
            refreshInterval: legacySettings.loadRefreshInterval(),
            autoStartSessionEnabled: legacySettings.loadAutoStartSessionEnabled(),
            notificationSettings: NotificationSettings(
                enabled: legacySettings.loadNotificationsEnabled(),
                threshold75Enabled: true,
                threshold90Enabled: true,
                threshold95Enabled: true
            ),
            isSelectedForDisplay: true,
            createdAt: Date(),
            lastUsedAt: Date()
        )
    }

    func resetMigration() {
        defaults.removeObject(forKey: migrationKey)
        credentialMigration.resetMigrationForTesting()
    }
}
