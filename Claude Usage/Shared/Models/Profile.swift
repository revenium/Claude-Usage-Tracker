//
//  Profile.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation

/// Represents a complete isolated profile with all credentials and settings
struct Profile: Codable, Identifiable, Equatable {
    // MARK: - Identity
    let id: UUID
    var name: String

    // MARK: - Credentials (runtime values hydrated from secure storage)
    var claudeSessionKey: String?
    var organizationId: String?
    var apiSessionKey: String?
    var apiOrganizationId: String?
    var apiSessionKeyExpiry: Date?
    var cliCredentialsJSON: String?

    // MARK: - CLI Account Sync Metadata
    var hasCliAccount: Bool
    var cliAccountSyncedAt: Date?
    var cliAccountName: String?  // Maps to a claude-switch account directory name

    // MARK: - Usage Data (Per-Profile)
    var claudeUsage: ClaudeUsage?
    var apiUsage: APIUsage?

    // MARK: - Appearance Settings (Per-Profile)
    var iconConfig: MenuBarIconConfiguration

    // MARK: - Behavior Settings (Per-Profile)
    var refreshInterval: TimeInterval
    var autoStartSessionEnabled: Bool
    var checkOverageLimitEnabled: Bool

    // MARK: - Notification Settings (Per-Profile)
    var notificationSettings: NotificationSettings

    // MARK: - Display Configuration
    var isSelectedForDisplay: Bool  // For multi-profile menu bar mode

    // MARK: - Metadata
    var createdAt: Date
    var lastUsedAt: Date

    /// Plaintext retained only when a legacy credential could not yet be
    /// committed to verified secure storage. ProfileStore retries each field
    /// independently and removes it after successful Keychain readback.
    var credentialMigrationRetry: ProfileCredentialMigrationRetry

    /// Usage retained only while a legacy preference-blob migration has not
    /// yet passed an exact durable file readback. Runtime usage remains on the
    /// profile for UI compatibility, but normal profile JSON never encodes it.
    var currentUsageMigrationRetry: ProfileCurrentUsage?

    /// Set before any destructive profile cleanup starts. The retained record
    /// keeps enough identity for the user to retry deletion, while loaders
    /// refuse to hydrate credentials or usage back into a partially deleted
    /// profile.
    var deletionInProgress: Bool

    init(
        id: UUID = UUID(),
        name: String,
        claudeSessionKey: String? = nil,
        organizationId: String? = nil,
        apiSessionKey: String? = nil,
        apiOrganizationId: String? = nil,
        apiSessionKeyExpiry: Date? = nil,
        cliCredentialsJSON: String? = nil,
        hasCliAccount: Bool = false,
        cliAccountSyncedAt: Date? = nil,
        cliAccountName: String? = nil,
        claudeUsage: ClaudeUsage? = nil,
        apiUsage: APIUsage? = nil,
        iconConfig: MenuBarIconConfiguration = .default,
        refreshInterval: TimeInterval = 30.0,
        autoStartSessionEnabled: Bool = false,
        checkOverageLimitEnabled: Bool = true,
        notificationSettings: NotificationSettings = NotificationSettings(),
        isSelectedForDisplay: Bool = true,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date(),
        credentialMigrationRetry: ProfileCredentialMigrationRetry = .init(),
        currentUsageMigrationRetry: ProfileCurrentUsage? = nil,
        deletionInProgress: Bool = false
    ) {
        self.id = id
        self.name = name
        self.claudeSessionKey = claudeSessionKey
        self.organizationId = organizationId
        self.apiSessionKey = apiSessionKey
        self.apiOrganizationId = apiOrganizationId
        self.apiSessionKeyExpiry = apiSessionKeyExpiry
        self.cliCredentialsJSON = cliCredentialsJSON
        self.hasCliAccount = hasCliAccount
        self.cliAccountSyncedAt = cliAccountSyncedAt
        self.cliAccountName = cliAccountName
        self.claudeUsage = claudeUsage
        self.apiUsage = apiUsage
        self.iconConfig = iconConfig
        self.refreshInterval = refreshInterval
        self.autoStartSessionEnabled = autoStartSessionEnabled
        self.checkOverageLimitEnabled = checkOverageLimitEnabled
        self.notificationSettings = notificationSettings
        self.isSelectedForDisplay = isSelectedForDisplay
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.credentialMigrationRetry = credentialMigrationRetry
        self.currentUsageMigrationRetry = currentUsageMigrationRetry
        self.deletionInProgress = deletionInProgress
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case claudeSessionKey
        case organizationId
        case apiSessionKey
        case apiOrganizationId
        case apiSessionKeyExpiry
        case cliCredentialsJSON
        case hasCliAccount
        case cliAccountSyncedAt
        case cliAccountName
        case claudeUsage
        case apiUsage
        case iconConfig
        case refreshInterval
        case autoStartSessionEnabled
        case checkOverageLimitEnabled
        case notificationSettings
        case isSelectedForDisplay
        case createdAt
        case lastUsedAt
        case credentialMigrationRetry
        case currentUsageMigrationRetry
        case deletionInProgress
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        organizationId = try container.decodeIfPresent(String.self, forKey: .organizationId)
        apiOrganizationId = try container.decodeIfPresent(String.self, forKey: .apiOrganizationId)
        apiSessionKeyExpiry = try container.decodeIfPresent(Date.self, forKey: .apiSessionKeyExpiry)
        hasCliAccount = try container.decodeIfPresent(Bool.self, forKey: .hasCliAccount) ?? false
        cliAccountSyncedAt = try container.decodeIfPresent(Date.self, forKey: .cliAccountSyncedAt)
        cliAccountName = try container.decodeIfPresent(String.self, forKey: .cliAccountName)
        let legacyClaudeUsage = try container.decodeIfPresent(
            ClaudeUsage.self,
            forKey: .claudeUsage
        )
        let legacyAPIUsage = try container.decodeIfPresent(
            APIUsage.self,
            forKey: .apiUsage
        )
        iconConfig = try container.decodeIfPresent(
            MenuBarIconConfiguration.self,
            forKey: .iconConfig
        ) ?? .default
        refreshInterval = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .refreshInterval
        ) ?? 30
        autoStartSessionEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .autoStartSessionEnabled
        ) ?? false
        checkOverageLimitEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .checkOverageLimitEnabled
        ) ?? true
        notificationSettings = try container.decodeIfPresent(
            NotificationSettings.self,
            forKey: .notificationSettings
        ) ?? NotificationSettings()
        isSelectedForDisplay = try container.decodeIfPresent(
            Bool.self,
            forKey: .isSelectedForDisplay
        ) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt) ?? createdAt
        deletionInProgress = try container.decodeIfPresent(
            Bool.self,
            forKey: .deletionInProgress
        ) ?? false

        var retry = try container.decodeIfPresent(
            ProfileCredentialMigrationRetry.self,
            forKey: .credentialMigrationRetry
        ) ?? .init()

        // Legacy v3 profile blobs placed secrets directly on Profile. Decode
        // them for migration, but immediately classify them as retry material
        // so a subsequent ordinary encode cannot silently discard them.
        if let value = try container.decodeIfPresent(String.self, forKey: .claudeSessionKey) {
            retry.claudeSessionKey = value
        }
        if let value = try container.decodeIfPresent(String.self, forKey: .apiSessionKey) {
            retry.apiSessionKey = value
        }
        if let value = try container.decodeIfPresent(String.self, forKey: .cliCredentialsJSON) {
            retry.cliCredentialsJSON = value
        }

        credentialMigrationRetry = retry
        claudeSessionKey = retry.claudeSessionKey
        apiSessionKey = retry.apiSessionKey
        cliCredentialsJSON = retry.cliCredentialsJSON

        var usageRetry = try container.decodeIfPresent(
            ProfileCurrentUsage.self,
            forKey: .currentUsageMigrationRetry
        )
        if legacyClaudeUsage != nil || legacyAPIUsage != nil {
            usageRetry = ProfileCurrentUsage(
                claudeUsage: legacyClaudeUsage ?? usageRetry?.claudeUsage,
                apiUsage: legacyAPIUsage ?? usageRetry?.apiUsage
            )
        }
        currentUsageMigrationRetry = usageRetry?.isEmpty == false ? usageRetry : nil
        claudeUsage = currentUsageMigrationRetry?.claudeUsage
        apiUsage = currentUsageMigrationRetry?.apiUsage
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(organizationId, forKey: .organizationId)
        try container.encodeIfPresent(apiOrganizationId, forKey: .apiOrganizationId)
        try container.encodeIfPresent(apiSessionKeyExpiry, forKey: .apiSessionKeyExpiry)
        try container.encode(hasCliAccount, forKey: .hasCliAccount)
        try container.encodeIfPresent(cliAccountSyncedAt, forKey: .cliAccountSyncedAt)
        try container.encodeIfPresent(cliAccountName, forKey: .cliAccountName)
        try container.encode(iconConfig, forKey: .iconConfig)
        try container.encode(refreshInterval, forKey: .refreshInterval)
        try container.encode(autoStartSessionEnabled, forKey: .autoStartSessionEnabled)
        try container.encode(checkOverageLimitEnabled, forKey: .checkOverageLimitEnabled)
        try container.encode(notificationSettings, forKey: .notificationSettings)
        try container.encode(isSelectedForDisplay, forKey: .isSelectedForDisplay)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(lastUsedAt, forKey: .lastUsedAt)
        if deletionInProgress {
            try container.encode(true, forKey: .deletionInProgress)
        }

        if !credentialMigrationRetry.isEmpty {
            try container.encode(credentialMigrationRetry, forKey: .credentialMigrationRetry)
        }
        if let currentUsageMigrationRetry, !currentUsageMigrationRetry.isEmpty {
            try container.encode(
                currentUsageMigrationRetry,
                forKey: .currentUsageMigrationRetry
            )
        }
    }

    // MARK: - Computed Properties
    var hasClaudeAI: Bool {
        claudeSessionKey != nil && organizationId != nil
    }

    var hasAPIConsole: Bool {
        apiSessionKey != nil && apiOrganizationId != nil
    }

    /// True if profile has credentials that can fetch usage data (Claude.ai, CLI OAuth, or API Console)
    /// Note: System keychain fallback is handled in ClaudeAPIService.getAuthentication() during actual API calls
    var hasUsageCredentials: Bool {
        hasClaudeAI || hasAPIConsole || hasValidCLIOAuth
    }

    /// True if profile has CLI OAuth credentials that are not expired
    var hasValidCLIOAuth: Bool {
        guard let cliJSON = cliCredentialsJSON else { return false }
        return !ClaudeCodeSyncService.shared.isTokenExpired(cliJSON)
    }

    var hasAnyCredentials: Bool {
        hasClaudeAI || hasAPIConsole || cliCredentialsJSON != nil
    }
}

/// Durable current-usage payload for the existing Claude.ai and Anthropic API
/// surfaces. Codex persists its normalized usage independently through the
/// provider-neutral file envelope introduced for that later integration.
struct ProfileCurrentUsage: Codable, Equatable {
    var claudeUsage: ClaudeUsage?
    var apiUsage: APIUsage?

    init(claudeUsage: ClaudeUsage? = nil, apiUsage: APIUsage? = nil) {
        self.claudeUsage = claudeUsage
        self.apiUsage = apiUsage
    }

    var isEmpty: Bool {
        claudeUsage == nil && apiUsage == nil
    }
}

/// Per-field recovery envelope for credentials that have not yet passed a
/// verified Keychain write. This is deliberately separate from Profile's
/// legacy secret keys so normal Codable output never recreates the old format.
struct ProfileCredentialMigrationRetry: Codable, Equatable {
    var claudeSessionKey: String?
    var apiSessionKey: String?
    var cliCredentialsJSON: String?

    var isEmpty: Bool {
        claudeSessionKey == nil && apiSessionKey == nil && cliCredentialsJSON == nil
    }

    private enum CodingKeys: String, CodingKey {
        case claudeSessionKey = "claude-session-key"
        case apiSessionKey = "api-session-key"
        case cliCredentialsJSON = "cli-credentials"
    }

    func value(for field: ProfileSecretField) -> String? {
        switch field {
        case .claudeSessionKey:
            return claudeSessionKey
        case .apiSessionKey:
            return apiSessionKey
        case .cliCredentialsJSON:
            return cliCredentialsJSON
        }
    }

    mutating func setValue(_ value: String?, for field: ProfileSecretField) {
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

// MARK: - ProfileCredentials (for compatibility)
/// Simple struct for passing credentials around
struct ProfileCredentials {
    var claudeSessionKey: String?
    var organizationId: String?
    var apiSessionKey: String?
    var apiOrganizationId: String?
    var apiSessionKeyExpiry: Date?
    var cliCredentialsJSON: String?

    var hasClaudeAI: Bool {
        claudeSessionKey != nil && organizationId != nil
    }

    var hasAPIConsole: Bool {
        apiSessionKey != nil && apiOrganizationId != nil
    }

    var hasCLI: Bool {
        cliCredentialsJSON != nil
    }
}
