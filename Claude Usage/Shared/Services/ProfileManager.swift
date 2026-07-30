//
//  ProfileManager.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation
import Combine
import UsageCore

struct ProfileActivationClaudeEffects {
    var resyncBeforeSwitching: (UUID) throws -> Void
    var applyProfileCredentials: (UUID) throws -> Void
    var switchAccountAndSync: (String) throws -> Void
    var updateStatuslineScripts: () throws -> Void
    var updateStatuslineProfileName: (String) throws -> Void

    static func live(
        cliSyncService: ClaudeCodeSyncService
    ) -> ProfileActivationClaudeEffects {
        ProfileActivationClaudeEffects(
            resyncBeforeSwitching: {
                try cliSyncService.resyncBeforeSwitching(for: $0)
            },
            applyProfileCredentials: {
                try cliSyncService.applyProfileCredentials($0)
            },
            switchAccountAndSync: { accountName in
                try ClaudeSwitchService.shared.switchToAccount(accountName)
                if SharedDataStore.shared.loadAutoSyncMCPEnabled() {
                    _ = ClaudeSwitchService.shared.bidirectionalMcpSync()
                    _ = ClaudeSwitchService.shared.syncSkills()
                }
            },
            updateStatuslineScripts: {
                try StatuslineService.shared.updateScriptsIfInstalled()
            },
            updateStatuslineProfileName: {
                try StatuslineService.shared.updateProfileNameInConfig($0)
            }
        )
    }
}

struct ProfileLifecycleEventSink {
    var deletionStarted: (Profile) -> Void
    var deletionCleanup: (Profile) throws -> Void
    var deletionCompleted: (Profile) -> Void

    init(
        deletionStarted: @escaping (Profile) -> Void,
        deletionCleanup:
            @escaping (Profile) throws -> Void = { _ in },
        deletionCompleted: @escaping (Profile) -> Void
    ) {
        self.deletionStarted = deletionStarted
        self.deletionCleanup = deletionCleanup
        self.deletionCompleted = deletionCompleted
    }

    static let live = ProfileLifecycleEventSink(
        deletionStarted: {
            NotificationCenter.default.post(
                name: .profileDeletionStarted,
                object: $0.id,
                userInfo: Self.userInfo(for: $0)
            )
        },
        deletionCleanup: {
            try NotificationManager.shared
                .clearNotificationsForProfile(
                    $0.id,
                    providerID: $0.providerID
                )
        },
        deletionCompleted: {
            NotificationCenter.default.post(
                name: .profileDeletionCompleted,
                object: $0.id,
                userInfo: Self.userInfo(for: $0)
            )
        }
    )

    private static func userInfo(for profile: Profile) -> [String: Any] {
        [
            "profileID": profile.id,
            "providerKind": profile.providerConfiguration.kind.rawValue,
            "providerRevision": profile.providerRevision
        ]
    }
}

@MainActor
class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    @Published var profiles: [Profile] = []
    @Published var activeProfile: Profile? {
        didSet {
            if oldValue?.id != activeProfile?.id {
                activeProfileIdentityGeneration &+= 1
            }
        }
    }
    private(set) var activeProfileIdentityGeneration: UInt64 = 0
    @Published var displayMode: ProfileDisplayMode = .single
    @Published var multiProfileConfig: MultiProfileDisplayConfig = .default
    @Published var isSwitchingProfile: Bool = false
    @Published private(set) var legacyMigrationPendingProfileID: UUID?

    private let profileStore: ProfileStore
    private let historyService: any ProfileHistoryDeleting
    private let activationClaudeEffects: ProfileActivationClaudeEffects
    private let codexHomeCanonicalizer: CodexHomeCanonicalizer
    private let lifecycleEventSink: ProfileLifecycleEventSink
    private let postClaudeCreationMigration: (UUID) throws -> Profile
    private let now: () -> Date

    private var switchingSemaphore = false

    init(
        profileStore: ProfileStore? = nil,
        cliSyncService: ClaudeCodeSyncService? = nil,
        historyService: (any ProfileHistoryDeleting)? = nil,
        activationClaudeEffects: ProfileActivationClaudeEffects? = nil,
        codexHomeCanonicalizer: CodexHomeCanonicalizer? = nil,
        lifecycleEventSink: ProfileLifecycleEventSink? = nil,
        postClaudeCreationMigration: ((UUID) throws -> Profile)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.profileStore = profileStore ?? .shared
        let resolvedCLISyncService = cliSyncService ?? .shared
        self.historyService = historyService ?? UsageHistoryService.shared
        self.activationClaudeEffects =
            activationClaudeEffects
            ?? .live(cliSyncService: resolvedCLISyncService)
        self.codexHomeCanonicalizer =
            codexHomeCanonicalizer ?? CodexHomeCanonicalizer()
        self.lifecycleEventSink = lifecycleEventSink ?? .live
        self.postClaudeCreationMigration =
            postClaudeCreationMigration
            ?? {
                try ProfileMigrationService.shared
                    .migrateClaudeProfileIfNeeded(to: $0)
            }
        self.now = now
    }

    // MARK: - Initialization

    func loadProfiles() {
        profiles = profileStore.loadProfiles()

        // Load active profile
        if let activeId = profileStore.loadActiveProfileId(),
           let profile = profiles.first(where: {
               $0.id == activeId && !$0.deletionInProgress
           }) {
            activeProfile = profile
        } else {
            activeProfile = profiles.first(where: {
                !$0.deletionInProgress
            })
            if let first = activeProfile {
                profileStore.saveActiveProfileId(first.id)
            }
        }

        displayMode = profileStore.loadDisplayMode()
        multiProfileConfig = profileStore.loadMultiProfileConfig()

        LoggingService.shared.log("ProfileManager: Loaded \(profiles.count) profile(s), active: \(activeProfile?.name ?? "none")")
    }

    // MARK: - Profile Operations

    @discardableResult
    func createInitialProfile(
        name: String? = nil,
        providerConfiguration: ProfileProviderConfiguration
    ) throws -> Profile {
        try createInitialProfile(
            name: name,
            providerConfiguration: providerConfiguration,
            allowInitiallyLinkedCodex: false
        )
    }

    @discardableResult
    func createInitialCodexProfile(
        name: String? = nil,
        linkedHomePath: String
    ) throws -> Profile {
        let home = try codexHomeCanonicalizer.canonicalize(
            linkedHomePath,
            existingProfiles: profiles
        )
        return try createInitialProfile(
            name: name,
            providerConfiguration: .codex(
                CodexProfileConfiguration(linkedHome: home)
            ),
            allowInitiallyLinkedCodex: true
        )
    }

    private func createInitialProfile(
        name: String?,
        providerConfiguration: ProfileProviderConfiguration,
        allowInitiallyLinkedCodex: Bool
    ) throws -> Profile {
        guard profiles.isEmpty else {
            throw ProfileProviderConfigurationError
                .initialProfileAlreadyExists
        }
        try validateCreationConfiguration(
            providerConfiguration,
            allowInitiallyLinkedCodex: allowInitiallyLinkedCodex
        )
        let profile = makeProfile(
            name: name,
            providerConfiguration: providerConfiguration,
            copySettingsFrom: nil
        )
        try profileStore.createInitialProfile(profile)
        profiles = [profile]
        activeProfile = profile
        profileStore.saveActiveProfileId(profile.id)
        guard profile.providerConfiguration.kind == .claude else {
            return profile
        }
        let migrated = attemptPostClaudeCreationMigration(profile)
        profiles = [migrated]
        activeProfile = migrated
        return migrated
    }

    func createProfile(
        name: String? = nil,
        copySettingsFrom: Profile? = nil
    ) -> Profile? {
        do {
            return try createProfileThrowing(
                name: name,
                providerConfiguration: .claude,
                copySettingsFrom: copySettingsFrom
            )
        } catch {
            LoggingService.shared.logError(
                "ProfileManager.createProfile: Create was not verified",
                error: error
            )
            return nil
        }
    }

    @discardableResult
    func createProfileThrowing(
        name: String? = nil,
        providerConfiguration: ProfileProviderConfiguration,
        copySettingsFrom: Profile? = nil
    ) throws -> Profile {
        try createProfileThrowing(
            name: name,
            providerConfiguration: providerConfiguration,
            copySettingsFrom: copySettingsFrom,
            allowInitiallyLinkedCodex: false
        )
    }

    @discardableResult
    func createCodexProfile(
        name: String? = nil,
        linkedHomePath: String,
        copySettingsFrom: Profile? = nil
    ) throws -> Profile {
        let home = try codexHomeCanonicalizer.canonicalize(
            linkedHomePath,
            existingProfiles: profiles
        )
        return try createProfileThrowing(
            name: name,
            providerConfiguration: .codex(
                CodexProfileConfiguration(linkedHome: home)
            ),
            copySettingsFrom: copySettingsFrom,
            allowInitiallyLinkedCodex: true
        )
    }

    /// Commits a setup draft only if the physical home still exactly matches
    /// the path and filesystem identity verified before account inspection.
    @discardableResult
    func createVerifiedCodexProfile(
        name: String? = nil,
        linkedHomePath: String,
        expectedPath: String,
        expectedIdentity: CodexHomeFilesystemIdentity
    ) throws -> Profile {
        let home = try codexHomeCanonicalizer.canonicalize(
            linkedHomePath,
            existingProfiles: profiles
        )
        guard home.path == expectedPath,
              home.filesystemIdentity == expectedIdentity else {
            throw CodexHomeCanonicalizationError
                .changedSinceVerification
        }
        if profiles.isEmpty {
            return try createInitialProfile(
                name: name,
                providerConfiguration: .codex(
                    .init(linkedHome: home)
                ),
                allowInitiallyLinkedCodex: true
            )
        }
        return try createProfileThrowing(
            name: name,
            providerConfiguration: .codex(
                .init(linkedHome: home)
            ),
            copySettingsFrom: nil,
            allowInitiallyLinkedCodex: true
        )
    }

    private func createProfileThrowing(
        name: String?,
        providerConfiguration: ProfileProviderConfiguration,
        copySettingsFrom: Profile?,
        allowInitiallyLinkedCodex: Bool
    ) throws -> Profile {
        try validateCreationConfiguration(
            providerConfiguration,
            allowInitiallyLinkedCodex: allowInitiallyLinkedCodex
        )
        let hadClaudeProfile = profiles.contains(where: {
            !$0.deletionInProgress
                && $0.providerConfiguration.kind == .claude
        })
        let newProfile = makeProfile(
            name: name,
            providerConfiguration: providerConfiguration,
            copySettingsFrom: copySettingsFrom
        )
        try profileStore.appendProfile(
            newProfile,
            expectedExistingIDs: Set(profiles.map(\.id))
        )
        profiles.append(newProfile)

        if providerConfiguration.kind == .claude && !hadClaudeProfile {
            let migrated = attemptPostClaudeCreationMigration(newProfile)
            if let index = profiles.firstIndex(where: {
                $0.id == newProfile.id
            }) {
                profiles[index] = migrated
            }
            LoggingService.shared.log("Created new profile: \(migrated.name)")
            return migrated
        }

        LoggingService.shared.log("Created new profile: \(newProfile.name)")
        return newProfile
    }

    @discardableResult
    func retryPendingLegacyMigration() throws -> Profile? {
        guard let profileID = legacyMigrationPendingProfileID else {
            return nil
        }
        let migrated = try postClaudeCreationMigration(profileID)
        if let index = profiles.firstIndex(where: { $0.id == profileID }) {
            profiles[index] = migrated
        }
        if activeProfile?.id == profileID {
            activeProfile = migrated
        }
        legacyMigrationPendingProfileID = nil
        return migrated
    }

    private func attemptPostClaudeCreationMigration(
        _ profile: Profile
    ) -> Profile {
        do {
            let migrated = try postClaudeCreationMigration(profile.id)
            legacyMigrationPendingProfileID = nil
            return migrated
        } catch {
            // Profile choice is already durably committed. Preserve it,
            // retain legacy sources, and expose an explicit retry signal.
            legacyMigrationPendingProfileID = profile.id
            LoggingService.shared.logError(
                "Post-create legacy migration remains pending",
                error: error
            )
            return profileStore.loadProfiles().first(where: {
                $0.id == profile.id
            }) ?? profile
        }
    }

    private func validateCreationConfiguration(
        _ configuration: ProfileProviderConfiguration,
        allowInitiallyLinkedCodex: Bool
    ) throws {
        if case .codex(let codex) = configuration,
           codex.linkedHome != nil,
           !allowInitiallyLinkedCodex {
            throw ProfileProviderConfigurationError
                .codexInitialHomeRequiresDedicatedCreation
        }
    }

    private func makeProfile(
        name: String?,
        providerConfiguration: ProfileProviderConfiguration,
        copySettingsFrom: Profile?
    ) -> Profile {
        let usedNames = profiles.map { $0.name }
        let profileName = name ?? FunnyNameGenerator.getRandomName(excluding: usedNames)
        let providerDefaultIconConfiguration:
            MenuBarIconConfiguration
        switch providerConfiguration.kind {
        case .claude:
            providerDefaultIconConfiguration = .default(for: .claude)
        case .codex:
            providerDefaultIconConfiguration = .default(for: .codex)
        }

        return Profile(
            id: UUID(),
            name: profileName,
            providerConfiguration: providerConfiguration,
            hasCliAccount: false,
            iconConfig:
                copySettingsFrom?.iconConfig
                ?? providerDefaultIconConfiguration,
            refreshInterval: copySettingsFrom?.refreshInterval ?? 30.0,
            autoStartSessionEnabled: copySettingsFrom?.autoStartSessionEnabled ?? false,
            checkOverageLimitEnabled: copySettingsFrom?.checkOverageLimitEnabled ?? true,
            notificationSettings: copySettingsFrom?.notificationSettings ?? NotificationSettings(),
            isSelectedForDisplay: true
        )
    }

    @discardableResult
    func linkCodexHome(_ path: String, for profileID: UUID) throws -> Profile {
        guard let profile = profiles.first(where: {
            $0.id == profileID
        }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }
        guard profile.providerConfiguration.kind == .codex else {
            throw ProfileProviderConfigurationError
                .codexProfileRequired(profileID)
        }
        if let existingHome = profile.providerConfiguration
            .codexConfiguration?.linkedHome,
           existingHome.path == path {
            do {
                let home = try codexHomeCanonicalizer.canonicalize(
                    path,
                    excludingProfileID: profileID,
                    existingProfiles: profiles
                )
                return try replaceCodexLinkedHome(home, for: profileID)
            } catch let error as CodexHomeCanonicalizationError {
                guard error == .missing,
                      existingHome.filesystemIdentity != nil else {
                    throw error
                }
                // Preserve an already-verified offline link. This keeps
                // unrelated metadata edits and pending-mutation recovery
                // available without allowing a legacy path-only link to
                // bypass explicit re-verification.
                return try replaceCodexLinkedHome(
                    existingHome,
                    for: profileID
                )
            }
        }
        let home = try codexHomeCanonicalizer.canonicalize(
            path,
            excludingProfileID: profileID,
            existingProfiles: profiles
        )
        return try replaceCodexLinkedHome(home, for: profileID)
    }

    @discardableResult
    func unlinkCodexHome(for profileID: UUID) throws -> Profile {
        try replaceCodexLinkedHome(nil, for: profileID)
    }

    private func replaceCodexLinkedHome(
        _ home: CanonicalCodexHome?,
        for profileID: UUID
    ) throws -> Profile {
        do {
            guard let previous = profiles.first(where: {
                $0.id == profileID
            }) else {
                throw ProfileStoreError.profileNotFound(profileID)
            }
            let updated = try profileStore.replaceCodexLinkedHome(
                home,
                for: profileID
            )
            guard let index = profiles.firstIndex(where: {
                $0.id == profileID
            }) else {
                throw ProfileStoreError.profileNotFound(profileID)
            }
            profiles[index] = updated
            if activeProfile?.id == profileID {
                activeProfile = updated
            }
            if previous.providerConfiguration
                    != updated.providerConfiguration
                || previous.providerRevision != updated.providerRevision {
                NotificationCenter.default.post(
                    name: .providerConfigurationChanged,
                    object: profileID,
                    userInfo: [
                        "profileID": profileID,
                        "providerRevision": updated.providerRevision
                    ]
                )
            }
            return updated
        } catch {
            // Rollback recovery may have completed forward on relaunch. Reload
            // the authoritative metadata before surfacing the failure.
            profiles = profileStore.loadProfiles()
            if let activeID = activeProfile?.id {
                activeProfile = profiles.first(where: { $0.id == activeID })
            }
            throw error
        }
    }

    func updateProfile(_ profile: Profile) {
        do {
            try updateProfileThrowing(profile)
        } catch {
            LoggingService.shared.logError(
                "ProfileManager.updateProfile: Update was not verified",
                error: error
            )
        }
    }

    /// Credential-aware update for workflows that must not report success
    /// unless secure storage and profile metadata have both been verified.
    func updateProfileThrowing(_ profile: Profile) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw ProfileStoreError.profileNotFound(profile.id)
        }

        let previous = profiles[index]
        let claudeSecretChanged = previous.claudeSessionKey != profile.claudeSessionKey
        let apiSecretChanged = previous.apiSessionKey != profile.apiSessionKey
        let cliSecretChanged = previous.cliCredentialsJSON != profile.cliCredentialsJSON
        let changedComponent = credentialChangeComponent(
            claudeChanged:
                claudeSecretChanged
                || previous.organizationId != profile.organizationId
                || previous.checkOverageLimitEnabled
                    != profile.checkOverageLimitEnabled,
            apiChanged:
                apiSecretChanged
                || previous.apiOrganizationId != profile.apiOrganizationId,
            cliChanged: cliSecretChanged
        )

        if cliSecretChanged && !claudeSecretChanged && !apiSecretChanged {
            try profileStore.saveCLIProfileUpdate(profile)
        } else if claudeSecretChanged || apiSecretChanged || cliSecretChanged {
            try profileStore.saveProfileUpdate(profile)
        } else {
            var candidate = profiles
            candidate[index] = profile
            try profileStore.saveProfilesThrowing(candidate)
        }

        profiles[index] = profile

        if activeProfile?.id == profile.id {
            activeProfile = profile
            LoggingService.shared.log(
                "ProfileManager.updateProfile: Updated active profile"
            )
        } else {
            LoggingService.shared.log("ProfileManager.updateProfile: Updated profile")
        }

        if let changedComponent {
            postCredentialChange(
                profileID: profile.id,
                component: changedComponent
            )
        }
    }

    func deleteProfile(_ id: UUID) throws {
        let profileName = profiles.first(where: { $0.id == id })?.name ?? "unknown"

        guard let deletionTarget = profiles.first(where: {
            $0.id == id
        }) else {
            throw ProfileStoreError.profileNotFound(id)
        }
        let usableProfileCount = profiles.filter {
            !$0.deletionInProgress
        }.count
        if !deletionTarget.deletionInProgress && usableProfileCount <= 1 {
            throw ProfileError.cannotDeleteLastProfile
        }

        // Atomically retain a scrubbed marker before any destructive cleanup.
        // On failure or relaunch, identity remains for retry without allowing
        // migration envelopes or surviving stores to rehydrate deleted data.
        let wasActive = activeProfile?.id == id
        let scrubbedProfile = try profileStore.beginProfileDeletion(id)
        lifecycleEventSink.deletionStarted(scrubbedProfile)
        if let index = profiles.firstIndex(where: { $0.id == id }) {
            profiles[index] = scrubbedProfile
        }
        if wasActive {
            if let survivor = profiles.first(where: {
                $0.id != id && !$0.deletionInProgress
            }) {
                activeProfile = survivor
                profileStore.saveActiveProfileId(survivor.id)
                applyPostDeletionActivationEffects(survivor)
            } else {
                activeProfile = nil
            }
        }

        if scrubbedProfile.providerConfiguration.kind == .claude {
            try profileStore.deleteProfileSecrets(for: id)
        }
        try historyService.deleteHistoryThrowing(for: id)
        try profileStore.deleteProfileUsageData(for: id)
        try lifecycleEventSink.deletionCleanup(
            scrubbedProfile
        )
        LoggingService.shared.log("Successfully deleted usage history for profile: \(profileName)")

        let remainingProfiles = profiles.filter { $0.id != id }
        try profileStore.finalizeProfileDeletion(
            id,
            expectedRemainingIDs: Set(remainingProfiles.map(\.id))
        )
        profiles = remainingProfiles

        lifecycleEventSink.deletionCompleted(scrubbedProfile)

        LoggingService.shared.log("Deleted profile: \(profileName)")
    }

    private func applyPostDeletionActivationEffects(_ profile: Profile) {
        guard profile.providerConfiguration.kind == .claude else {
            return
        }
        if profile.cliCredentialsJSON != nil {
            do {
                try activationClaudeEffects
                    .applyProfileCredentials(profile.id)
            } catch {
                LoggingService.shared.logError(
                    "Post-delete CLI credential activation failed",
                    error: error
                )
            }
        }
        if let accountName = profile.cliAccountName {
            do {
                try activationClaudeEffects
                    .switchAccountAndSync(accountName)
            } catch {
                LoggingService.shared.logError(
                    "Post-delete CLI account activation failed",
                    error: error
                )
            }
        }
        if profile.claudeSessionKey != nil
            && profile.organizationId != nil {
            do {
                try activationClaudeEffects.updateStatuslineScripts()
            } catch {
                LoggingService.shared.logError(
                    "Post-delete statusline update failed",
                    error: error
                )
            }
        }
        do {
            try activationClaudeEffects
                .updateStatuslineProfileName(profile.name)
        } catch {
            LoggingService.shared.logError(
                "Post-delete statusline profile update failed",
                error: error
            )
        }
    }

    func toggleProfileSelection(_ id: UUID) {
        // Use async to avoid "Publishing changes from within view updates" warning
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let index = self.profiles.firstIndex(where: { $0.id == id }) {
                self.profiles[index].isSelectedForDisplay.toggle()
                self.profileStore.saveProfiles(self.profiles)
            }
        }
    }

    func getSelectedProfiles() -> [Profile] {
        displayMode == .single
            ? [activeProfile].compactMap { $0 }
            : profiles.filter {
                $0.isSelectedForDisplay && !$0.deletionInProgress
            }
    }

    func updateDisplayMode(_ mode: ProfileDisplayMode) {
        // Use async to avoid "Publishing changes from within view updates" warning
        DispatchQueue.main.async { [weak self] in
            self?.displayMode = mode
            self?.profileStore.saveDisplayMode(mode)
            LoggingService.shared.log("Updated display mode to: \(mode.rawValue)")
        }
    }

    func updateMultiProfileConfig(_ config: MultiProfileDisplayConfig) {
        // Use async to avoid "Publishing changes from within view updates" warning
        DispatchQueue.main.async { [weak self] in
            self?.multiProfileConfig = config
            self?.profileStore.saveMultiProfileConfig(config)
            LoggingService.shared.log("Updated multi-profile config: style=\(config.iconStyle.rawValue), showWeek=\(config.showWeek)")
        }
    }

    // MARK: - Profile Activation (Centralized)

    func activateProfile(_ id: UUID) async {
        guard !switchingSemaphore else {
            LoggingService.shared.log("Profile switch already in progress, ignoring")
            return
        }

        guard let profile = profiles.first(where: {
            $0.id == id && !$0.deletionInProgress
        }) else {
            LoggingService.shared.log("Profile not found: \(id)")
            return
        }

        if activeProfile?.id == id {
            LoggingService.shared.log("Profile already active: \(profile.name)")
            return
        }

        switchingSemaphore = true
        isSwitchingProfile = true
        defer {
            switchingSemaphore = false
            isSwitchingProfile = false
        }

        LoggingService.shared.log("Switching to profile: \(profile.name)")

        // The target provider selects the branch before any provider-specific
        // side effect. Codex selection is app metadata only.
        if profile.providerConfiguration.kind == .codex {
            do {
                let updated = try profileStore.updateActivationMetadata(
                    for: id,
                    at: now()
                )
                if let index = profiles.firstIndex(where: { $0.id == id }) {
                    profiles[index] = updated
                }
                activeProfile = updated
                profileStore.saveActiveProfileId(id)
                LoggingService.shared.log(
                    "Successfully activated Codex profile: \(updated.name)"
                )
            } catch {
                LoggingService.shared.logError(
                    "Failed to activate Codex profile",
                    error: error
                )
            }
            return
        }

        // Re-sync current profile before leaving (if CLI credentials exist)
        if let currentProfile = activeProfile, currentProfile.cliCredentialsJSON != nil {
            do {
                try activationClaudeEffects
                    .resyncBeforeSwitching(currentProfile.id)
                // Reload profiles to get the updated data in memory
                profiles = profileStore.loadProfiles()
                LoggingService.shared.log("✓ Re-synced current profile before switching")
            } catch {
                LoggingService.shared.logError("Failed to re-sync current profile (non-fatal)", error: error)
            }
        }

        // Reload profiles from disk to get latest data (including any resyncs from other profiles)
        profiles = profileStore.loadProfiles()

        // Get the updated target profile from the reloaded data
        guard let updatedProfile = profiles.first(where: { $0.id == id }) else {
            LoggingService.shared.log("Profile not found after reload: \(id)")
            return
        }

        // Apply new profile's CLI credentials (if available)
        LoggingService.shared.log("Checking CLI credentials for profile '\(updatedProfile.name)': hasJSON=\(updatedProfile.cliCredentialsJSON != nil)")

        if updatedProfile.cliCredentialsJSON != nil {
            do {
                try activationClaudeEffects
                    .applyProfileCredentials(updatedProfile.id)
                LoggingService.shared.log("✓ Applied CLI credentials for: \(updatedProfile.name)")
            } catch {
                LoggingService.shared.logError("Failed to apply CLI credentials (non-fatal)", error: error)
            }
        } else {
            LoggingService.shared.log("⚠️ Profile '\(updatedProfile.name)' has no CLI credentials JSON")
        }

        // Switch CLI account if profile has a mapped account name
        LoggingService.shared.log("CLI account check for '\(updatedProfile.name)': cliAccountName=\(updatedProfile.cliAccountName ?? "nil")")
        if let accountName = updatedProfile.cliAccountName {
            do {
                try activationClaudeEffects.switchAccountAndSync(accountName)
                LoggingService.shared.log("✓ Switched CLI account to: \(accountName)")
            } catch {
                LoggingService.shared.logError("Failed to switch CLI account (non-fatal)", error: error)
            }
        }

        // Update last used timestamp
        var updated = updatedProfile
        updated.lastUsedAt = now()

        if let index = profiles.firstIndex(where: { $0.id == updatedProfile.id }) {
            profiles[index] = updated
        }

        activeProfile = updated
        profileStore.saveActiveProfileId(id)
        profileStore.saveProfiles(profiles)

        // Update statusline script if the new profile has credentials
        if updated.claudeSessionKey != nil && updated.organizationId != nil {
            do {
                try activationClaudeEffects.updateStatuslineScripts()
                LoggingService.shared.log("✓ Updated statusline for profile: \(updated.name)")
            } catch {
                LoggingService.shared.logError("Failed to update statusline (non-fatal)", error: error)
            }
        }

        // Update profile name in statusline config
        do {
            try activationClaudeEffects
                .updateStatuslineProfileName(updated.name)
        } catch {
            LoggingService.shared.logError("Failed to update statusline profile name (non-fatal)", error: error)
        }

        LoggingService.shared.log("Successfully activated profile: \(updatedProfile.name)")
    }

    // MARK: - Credentials

    func loadCredentials(for profileId: UUID) throws -> ProfileCredentials {
        return try profileStore.loadProfileCredentials(profileId)
    }

    func saveCredentials(for profileId: UUID, credentials: ProfileCredentials) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            throw ProfileStoreError.profileNotFound(profileId)
        }
        let previous = profiles[index]
        let requestInputsChanged =
            previous.claudeSessionKey != credentials.claudeSessionKey
            || previous.organizationId != credentials.organizationId
            || previous.apiSessionKey != credentials.apiSessionKey
            || previous.apiOrganizationId != credentials.apiOrganizationId
            || previous.cliCredentialsJSON != credentials.cliCredentialsJSON

        try profileStore.saveProfileCredentials(profileId, credentials: credentials)

        profiles[index].claudeSessionKey = credentials.claudeSessionKey
        profiles[index].organizationId = credentials.organizationId
        profiles[index].apiSessionKey = credentials.apiSessionKey
        profiles[index].apiOrganizationId = credentials.apiOrganizationId
        profiles[index].apiSessionKeyExpiry = credentials.apiSessionKeyExpiry
        profiles[index].cliCredentialsJSON = credentials.cliCredentialsJSON

        if activeProfile?.id == profileId {
            activeProfile = profiles[index]
        }
        if requestInputsChanged {
            postCredentialChange(profileID: profileId, component: .all)
        }
    }

    /// Removes Claude.ai credentials for a profile
    func removeClaudeAICredentials(for profileId: UUID) throws {
        do {
            try profileStore.unlinkClaudeAI(for: profileId)
        } catch {
            if let storeError = error as? ProfileStoreError,
               case .credentialUsageUnlinkRollbackFailed = storeError {
                failCloseCredentialUsageRuntime(
                    for: profileId,
                    component: .claude
                )
                postCredentialChange(
                    profileID: profileId,
                    component: .claude
                )
            }
            throw error
        }
        failCloseCredentialUsageRuntime(
            for: profileId,
            component: .claude
        )

        LoggingService.shared.log("ProfileManager: Removed Claude.ai credentials for profile \(profileId)")
        postCredentialChange(profileID: profileId, component: .claude)
    }

    /// Removes API Console credentials for a profile
    func removeAPICredentials(for profileId: UUID) throws {
        do {
            try profileStore.unlinkAPIConsole(for: profileId)
        } catch {
            if let storeError = error as? ProfileStoreError,
               case .credentialUsageUnlinkRollbackFailed = storeError {
                failCloseCredentialUsageRuntime(
                    for: profileId,
                    component: .api
                )
                postCredentialChange(
                    profileID: profileId,
                    component: .api
                )
            }
            throw error
        }
        failCloseCredentialUsageRuntime(
            for: profileId,
            component: .api
        )

        LoggingService.shared.log("ProfileManager: Removed API credentials for profile \(profileId)")
        postCredentialChange(profileID: profileId, component: .api)
    }

    private enum CredentialUsageComponent: String {
        case claude
        case api
    }

    private enum CredentialChangeComponent: String {
        case claude
        case api
        case cli
        case all
    }

    private func failCloseCredentialUsageRuntime(
        for profileID: UUID,
        component: CredentialUsageComponent
    ) {
        guard let index = profiles.firstIndex(where: {
            $0.id == profileID
        }) else {
            return
        }

        let targetField: ProfileSecretField =
            component == .claude
                ? .claudeSessionKey
                : .apiSessionKey
        profiles[index].credentialMigrationRetry.setValue(
            nil,
            for: targetField
        )
        if var usageRetry =
            profiles[index].currentUsageMigrationRetry {
            if component == .claude {
                usageRetry.report = nil
                usageRetry.claudeUsage = nil
            } else {
                usageRetry.apiUsage = nil
            }
            profiles[index].currentUsageMigrationRetry =
                usageRetry.isEmpty ? nil : usageRetry
        }

        if component == .claude {
            profiles[index].claudeSessionKey = nil
            profiles[index].organizationId = nil
            profiles[index].claudeUsage = nil
        } else {
            profiles[index].apiSessionKey = nil
            profiles[index].apiOrganizationId = nil
            profiles[index].apiSessionKeyExpiry = nil
            profiles[index].apiUsage = nil
        }

        if activeProfile?.id == profileID {
            activeProfile = profiles[index]
        }
    }

    private func postCredentialChange(
        profileID: UUID,
        component: CredentialChangeComponent
    ) {
        NotificationCenter.default.post(
            name: .credentialsChanged,
            object: profileID,
            userInfo: [
                "profileID": profileID,
                "component": component.rawValue
            ]
        )
    }

    private func credentialChangeComponent(
        claudeChanged: Bool,
        apiChanged: Bool,
        cliChanged: Bool
    ) -> CredentialChangeComponent? {
        let changes = [
            claudeChanged ? .claude : nil,
            apiChanged ? .api : nil,
            cliChanged ? .cli : nil
        ] as [CredentialChangeComponent?]
        let resolvedChanges = changes.compactMap { $0 }
        guard resolvedChanges.count == 1 else {
            return resolvedChanges.isEmpty ? nil : .all
        }
        return resolvedChanges[0]
    }

    // MARK: - Usage Data

    /// Installs one complete provider result and updates compatibility
    /// projections only after the provider/revision/deletion fence and exact
    /// durable readback succeed.
    @discardableResult
    func commitCurrentUsage(
        _ usage: ProfileCurrentUsage,
        for profileID: UUID,
        expectedProviderID: ProviderID,
        expectedProviderRevision: UInt64,
        publishToActiveProfile: Bool = true
    ) throws -> (
        previous: ProfileCurrentUsage?,
        current: ProfileCurrentUsage
    ) {
        guard let index = profiles.firstIndex(where: {
            $0.id == profileID
        }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }
        let profile = profiles[index]
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

        let committed = try profileStore.commitCurrentUsage(
            usage,
            for: profileID,
            expectedProviderID: expectedProviderID,
            expectedProviderRevision: expectedProviderRevision
        )
        profiles[index].claudeUsage = committed.current.claudeUsage
        profiles[index].apiUsage = committed.current.apiUsage
        if publishToActiveProfile, activeProfile?.id == profileID {
            activeProfile = profiles[index]
        }
        return committed
    }

    func loadCurrentUsage(
        for profileID: UUID,
        expectedProviderID: ProviderID,
        expectedProviderRevision: UInt64
    ) throws -> ProfileCurrentUsage? {
        try profileStore.loadCurrentUsage(
            for: profileID,
            expectedProviderID: expectedProviderID,
            expectedProviderRevision: expectedProviderRevision
        )
    }

    /// Saves Claude usage data for a specific profile
    @discardableResult
    func saveClaudeUsage(
        _ usage: ClaudeUsage,
        for profileId: UUID,
        publishToActiveProfile: Bool = true
    ) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            LoggingService.shared.logError("saveClaudeUsage: Profile not found with ID: \(profileId)")
            return false
        }

        do {
            try profileStore.saveClaudeUsage(usage, for: profileId)
        } catch {
            LoggingService.shared.logStorageError("saveClaudeUsage", error: error)
            return false
        }

        profiles[index].claudeUsage = usage

        // Update activeProfile reference if it's the same profile
        if publishToActiveProfile, activeProfile?.id == profileId {
            activeProfile = profiles[index]
        }

        LoggingService.shared.log("Saved Claude usage for profile: \(profiles[index].name)")
        return true
    }

    /// Loads Claude usage data for a specific profile
    func loadClaudeUsage(for profileId: UUID) -> ClaudeUsage? {
        do {
            let usage = try profileStore.loadClaudeUsage(for: profileId)
            updateClaudeUsageInMemory(usage, for: profileId)
            return usage
        } catch {
            LoggingService.shared.logStorageError("loadClaudeUsage", error: error)
            return profiles.first(where: { $0.id == profileId })?.claudeUsage
        }
    }

    /// Saves API usage data for a specific profile
    @discardableResult
    func saveAPIUsage(
        _ usage: APIUsage,
        for profileId: UUID,
        publishToActiveProfile: Bool = true
    ) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            LoggingService.shared.logError("saveAPIUsage: Profile not found with ID: \(profileId)")
            return false
        }

        do {
            try profileStore.saveAPIUsage(usage, for: profileId)
        } catch {
            LoggingService.shared.logStorageError("saveAPIUsage", error: error)
            return false
        }

        profiles[index].apiUsage = usage

        // Update activeProfile reference if it's the same profile
        if publishToActiveProfile, activeProfile?.id == profileId {
            activeProfile = profiles[index]
        }

        LoggingService.shared.log("Saved API usage for profile: \(profiles[index].name)")
        return true
    }

    /// Loads API usage data for a specific profile
    func loadAPIUsage(for profileId: UUID) -> APIUsage? {
        do {
            let usage = try profileStore.loadAPIUsage(for: profileId)
            updateAPIUsageInMemory(usage, for: profileId)
            return usage
        } catch {
            LoggingService.shared.logStorageError("loadAPIUsage", error: error)
            return profiles.first(where: { $0.id == profileId })?.apiUsage
        }
    }

    // MARK: - Profile Settings

    /// Updates icon configuration for a profile
    func updateIconConfig(_ config: MenuBarIconConfiguration, for profileId: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].iconConfig = config

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }
    }

    /// Updates refresh interval for a profile
    func updateRefreshInterval(_ interval: TimeInterval, for profileId: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].refreshInterval = interval

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }
    }

    /// Updates auto-start session setting for a profile
    func updateAutoStartSessionEnabled(_ enabled: Bool, for profileId: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].autoStartSessionEnabled = enabled

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }
    }

    /// Updates check overage limit setting for a profile
    func updateCheckOverageLimitEnabled(_ enabled: Bool, for profileId: UUID) {
        guard var profile = profiles.first(where: { $0.id == profileId }) else {
            return
        }
        profile.checkOverageLimitEnabled = enabled
        updateProfile(profile)
    }

    /// Updates notification settings for a profile
    func updateNotificationSettings(_ settings: NotificationSettings, for profileId: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].notificationSettings = settings

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }
    }

    /// Updates organization ID for a profile
    func updateOrganizationId(_ orgId: String?, for profileId: UUID) {
        guard var profile = profiles.first(where: { $0.id == profileId }) else {
            return
        }
        profile.organizationId = orgId
        updateProfile(profile)
    }

    /// Updates API organization ID for a profile
    func updateAPIOrganizationId(_ orgId: String?, for profileId: UUID) {
        guard var profile = profiles.first(where: { $0.id == profileId }) else {
            return
        }
        profile.apiOrganizationId = orgId
        updateProfile(profile)
    }

    // MARK: - Private Helpers

    private func updateClaudeUsageInMemory(_ usage: ClaudeUsage?, for profileID: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            return
        }
        profiles[index].claudeUsage = usage
        if activeProfile?.id == profileID {
            activeProfile = profiles[index]
        }
    }

    private func updateAPIUsageInMemory(_ usage: APIUsage?, for profileID: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            return
        }
        profiles[index].apiUsage = usage
        if activeProfile?.id == profileID {
            activeProfile = profiles[index]
        }
    }

}

// MARK: - ProfileError

enum ProfileError: LocalizedError, Equatable {
    case cannotDeleteLastProfile

    var errorDescription: String? {
        switch self {
        case .cannotDeleteLastProfile:
            return "Cannot delete the last profile. At least one profile is required."
        }
    }
}
