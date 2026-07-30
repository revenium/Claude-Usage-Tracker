//
//  KeychainMigrationService.swift
//  Claude Usage
//
//  Created by Claude Code on 2025-12-28.
//

import Foundation

struct LegacyCredentialSnapshot {
    var globalClaudeSessionKey: String?
    var fileClaudeSessionKey: String?
    var globalAPISessionKey: String?
    var defaultsAPISessionKey: String?

    var isEmpty: Bool {
        globalClaudeSessionKey == nil
            && fileClaudeSessionKey == nil
            && globalAPISessionKey == nil
            && defaultsAPISessionKey == nil
    }
}

protocol LegacyCredentialSource {
    func readSnapshot() throws -> LegacyCredentialSnapshot
    func removeVerifiedSources(from snapshot: LegacyCredentialSnapshot) throws
}

enum LegacyCredentialMigrationError: Error, LocalizedError {
    case invalidClaudeSessionFile
    case sourceChanged(String)
    case cleanupVerificationFailed(String)
    case targetReadbackFailed

    var errorDescription: String? {
        switch self {
        case .invalidClaudeSessionFile:
            return "The legacy Claude session-key file is invalid and was preserved."
        case .sourceChanged(let source):
            return "The legacy \(source) changed during migration and was preserved."
        case .cleanupVerificationFailed(let source):
            return "Cleanup of the legacy \(source) could not be verified."
        case .targetReadbackFailed:
            return "The profile credential target did not match after migration."
        }
    }
}

final class SystemLegacyCredentialSource: LegacyCredentialSource {
    private let defaults: UserDefaults
    private let keychain: KeychainService
    private let fileManager: FileManager
    private let claudeSessionFile: URL

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainService = .shared,
        fileManager: FileManager = .default,
        claudeSessionFile: URL = Constants.ClaudePaths.homeDirectory
            .appendingPathComponent(".claude-session-key")
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.fileManager = fileManager
        self.claudeSessionFile = claudeSessionFile
    }

    func readSnapshot() throws -> LegacyCredentialSnapshot {
        var fileValue: String?
        if fileManager.fileExists(atPath: claudeSessionFile.path) {
            let raw = try String(contentsOf: claudeSessionFile, encoding: .utf8)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard SessionKeyValidator().isValid(trimmed) else {
                throw LegacyCredentialMigrationError.invalidClaudeSessionFile
            }
            fileValue = trimmed
        }

        return LegacyCredentialSnapshot(
            globalClaudeSessionKey: try keychain.load(for: .claudeSessionKey),
            fileClaudeSessionKey: fileValue,
            globalAPISessionKey: try keychain.load(for: .apiSessionKey),
            defaultsAPISessionKey: defaults.string(
                forKey: Constants.UserDefaultsKeys.apiSessionKey
            )
        )
    }

    func removeVerifiedSources(from snapshot: LegacyCredentialSnapshot) throws {
        if let expected = snapshot.globalClaudeSessionKey {
            guard try keychain.load(for: .claudeSessionKey) == expected else {
                throw LegacyCredentialMigrationError.sourceChanged("Claude Keychain item")
            }
            try keychain.delete(for: .claudeSessionKey)
            guard try keychain.load(for: .claudeSessionKey) == nil else {
                throw LegacyCredentialMigrationError.cleanupVerificationFailed(
                    "Claude Keychain item"
                )
            }
        }

        if let expected = snapshot.globalAPISessionKey {
            guard try keychain.load(for: .apiSessionKey) == expected else {
                throw LegacyCredentialMigrationError.sourceChanged("API Keychain item")
            }
            try keychain.delete(for: .apiSessionKey)
            guard try keychain.load(for: .apiSessionKey) == nil else {
                throw LegacyCredentialMigrationError.cleanupVerificationFailed(
                    "API Keychain item"
                )
            }
        }

        if let expected = snapshot.fileClaudeSessionKey {
            let current = try String(contentsOf: claudeSessionFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard current == expected else {
                throw LegacyCredentialMigrationError.sourceChanged("Claude session-key file")
            }
            try fileManager.removeItem(at: claudeSessionFile)
            guard !fileManager.fileExists(atPath: claudeSessionFile.path) else {
                throw LegacyCredentialMigrationError.cleanupVerificationFailed(
                    "Claude session-key file"
                )
            }
        }

        if let expected = snapshot.defaultsAPISessionKey {
            guard defaults.string(forKey: Constants.UserDefaultsKeys.apiSessionKey) == expected else {
                throw LegacyCredentialMigrationError.sourceChanged("API preference")
            }
            defaults.removeObject(forKey: Constants.UserDefaultsKeys.apiSessionKey)
            guard defaults.string(forKey: Constants.UserDefaultsKeys.apiSessionKey) == nil else {
                throw LegacyCredentialMigrationError.cleanupVerificationFailed("API preference")
            }
        }
    }
}

/// Moves every legacy credential source directly into the profile-keyed,
/// verified store. There is no intermediate destructive global-Keychain hop.
class KeychainMigrationService {
    static let shared = KeychainMigrationService()

    private let source: any LegacyCredentialSource
    private let defaults: UserDefaults
    private let migrationCompletedKey = "profileCredentialMigrationCompleted_v2"

    init(
        source: any LegacyCredentialSource = SystemLegacyCredentialSource(),
        defaults: UserDefaults = .standard
    ) {
        self.source = source
        self.defaults = defaults
    }

    func migrateIfNeeded(to profileID: UUID, profileStore: ProfileStore) throws {
        guard !defaults.bool(forKey: migrationCompletedKey) else {
            return
        }

        let snapshot = try source.readSnapshot()
        var credentials = try profileStore.loadProfileCredentials(profileID)

        // Preserve the same precedence the legacy runtime used: existing
        // profile-keyed values, then global Keychain, then plaintext fallback.
        if credentials.claudeSessionKey == nil {
            credentials.claudeSessionKey =
                snapshot.globalClaudeSessionKey ?? snapshot.fileClaudeSessionKey
        }
        if credentials.apiSessionKey == nil {
            credentials.apiSessionKey =
                snapshot.globalAPISessionKey ?? snapshot.defaultsAPISessionKey
        }

        if !snapshot.isEmpty {
            try profileStore.saveProfileCredentials(profileID, credentials: credentials)
        }

        let verified = try profileStore.loadProfileCredentials(profileID)
        guard verified.claudeSessionKey == credentials.claudeSessionKey,
              verified.apiSessionKey == credentials.apiSessionKey,
              verified.cliCredentialsJSON == credentials.cliCredentialsJSON else {
            throw LegacyCredentialMigrationError.targetReadbackFailed
        }

        // Sources are removed only after the destination's secure write,
        // direct readback, and metadata rewrite have all succeeded.
        try source.removeVerifiedSources(from: snapshot)
        defaults.set(true, forKey: migrationCompletedKey)
        guard defaults.bool(forKey: migrationCompletedKey) else {
            throw ProfileStoreError.profileWriteVerificationFailed
        }
    }

    /// Backward-compatible safe entry point for any older startup caller.
    func performMigrationIfNeeded() {
        do {
            guard let profileID = ProfileStore.shared.loadProfiles()
                .first(where: {
                    !$0.deletionInProgress
                        && $0.providerConfiguration.kind == .claude
                })?.id else {
                return
            }
            try migrateIfNeeded(to: profileID, profileStore: .shared)
        } catch {
            LoggingService.shared.logError("Profile credential migration failed", error: error)
        }
    }

    func resetMigrationForTesting() {
        defaults.removeObject(forKey: migrationCompletedKey)
    }
}
