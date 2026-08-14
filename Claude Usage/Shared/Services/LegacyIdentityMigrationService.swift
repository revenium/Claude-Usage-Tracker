//
//  LegacyIdentityMigrationService.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-08-14.
//

import Foundation

/// Adopts data written under the app's pre-rename identity the first time a
/// renamed build launches.
///
/// Pre-rename releases persist everything in exactly two places:
/// - the `UserDefaults` standard suite, whose on-disk domain is the bundle
///   identifier (`HamedElfayome.Claude-Usage`, plus `.uat` for the UAT
///   variant), and
/// - one Application Support folder (`"Claude Usage"` plus the UAT path
///   suffix), which holds profile-data, usage history, and network logs.
///
/// Keychain items deliberately need no migration: their service names are
/// versioned literals (`com.claudeusagetracker.*.v1`) independent of the
/// bundle identifier — see `KeychainService.profileSecretsService`.
///
/// Behavior is additive and idempotent: legacy preference keys are imported
/// only where the current domain has no value, legacy files are copied only
/// where the destination file does not exist, and the legacy data is left in
/// place (a later release may clean it up). Completion is recorded in the
/// current domain only after both imports succeed, so a partial failure
/// retries on the next launch.
///
/// While the running bundle identifier still equals the legacy identifier —
/// i.e. until the rename actually ships — `migrateIfNeeded()` returns
/// immediately and touches nothing.
/// `nonisolated` is load-bearing: under this target's MainActor default
/// isolation, test-created instances of an isolated class crash in the
/// synthesized deinit (malloc "pointer being freed was not allocated") —
/// the same trap KeychainService and ProfileUsageFileStore opt out of.
nonisolated final class LegacyIdentityMigrationService {
    static let shared = LegacyIdentityMigrationService()

    /// Recorded in the current defaults domain after a verified migration.
    static let migrationCompletedKey = "legacyIdentityMigrationCompleted_v1"

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let currentBundleIdentifier: String?
    private let currentDomainName: String?
    private let legacyBundleIdentifier: String
    private let currentFolderName: String
    private let legacyFolderName: String
    private let applicationSupportURL: URL

    /// - Parameters:
    ///   - defaults: The suite legacy preferences are imported into, and
    ///     which records completion.
    ///   - currentDomainName: On-disk domain name of `defaults`, used to
    ///     decide which keys already have a persisted value (searching the
    ///     suite directly would also match registration-domain defaults).
    ///     In production this is the bundle identifier.
    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        currentDomainName: String? = Bundle.main.bundleIdentifier,
        legacyBundleIdentifier: String =
            AppIdentity.legacyBundleIdentifierBase
                + (AppBuildVariant.isUAT ? ".uat" : ""),
        currentFolderName: String =
            AppIdentity.appSupportFolderName + AppBuildVariant.pathSuffix,
        legacyFolderName: String =
            AppIdentity.legacyAppSupportFolderName + AppBuildVariant.pathSuffix,
        applicationSupportURL: URL? = nil
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.currentBundleIdentifier = currentBundleIdentifier
        self.currentDomainName = currentDomainName
        self.legacyBundleIdentifier = legacyBundleIdentifier
        self.currentFolderName = currentFolderName
        self.legacyFolderName = legacyFolderName
        self.applicationSupportURL = applicationSupportURL
            ?? fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support",
                    isDirectory: true
                )
    }

    func migrateIfNeeded() {
        guard let bundleIdentifier = currentBundleIdentifier,
            bundleIdentifier != legacyBundleIdentifier
        else {
            // Still shipping under the legacy identity; nothing to adopt.
            return
        }
        guard !defaults.bool(forKey: Self.migrationCompletedKey) else {
            return
        }

        let preferencesImported = importLegacyPreferences()
        let filesImported = importLegacyFiles()

        if preferencesImported && filesImported {
            defaults.set(true, forKey: Self.migrationCompletedKey)
            LoggingService.shared.logInfo(
                "Legacy identity migration completed"
                    + " (from \(legacyBundleIdentifier))"
            )
        }
    }

    // MARK: - Preferences

    /// Copies every legacy-domain key the current domain has no persisted
    /// value for. Never overwrites: anything the renamed app (or AppKit)
    /// already wrote wins.
    private func importLegacyPreferences() -> Bool {
        guard
            let legacy = defaults.persistentDomain(
                forName: legacyBundleIdentifier
            ),
            !legacy.isEmpty
        else {
            // No legacy preferences on this machine — a fresh install of the
            // renamed app. Nothing to do is success.
            return true
        }

        let existing = currentDomainName
            .flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        for (key, value) in legacy where existing[key] == nil {
            defaults.set(value, forKey: key)
        }
        return true
    }

    // MARK: - Files

    private func importLegacyFiles() -> Bool {
        let legacyDirectory = applicationSupportURL
            .appendingPathComponent(legacyFolderName, isDirectory: true)
        let currentDirectory = applicationSupportURL
            .appendingPathComponent(currentFolderName, isDirectory: true)

        guard legacyDirectory.path != currentDirectory.path else {
            return true
        }

        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(
                atPath: legacyDirectory.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue
        else {
            return true
        }

        do {
            try mergeCopy(from: legacyDirectory, to: currentDirectory)
            return try verifyEveryLegacyFileExists(
                from: legacyDirectory,
                at: currentDirectory
            )
        } catch {
            LoggingService.shared.logError(
                "Legacy identity migration could not copy Application Support"
                    + " data; it will retry on next launch",
                error: error
            )
            return false
        }
    }

    /// Recursively copies `source` into `destination`, skipping any file that
    /// already exists at the destination. Per-file granularity keeps a retry
    /// after a partially failed copy from being blocked by its own debris.
    private func mergeCopy(from source: URL, to destination: URL) throws {
        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
        }
        for entry in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            let target = destination
                .appendingPathComponent(entry.lastPathComponent)
            let entryIsDirectory =
                (try? entry.resourceValues(forKeys: [.isDirectoryKey])
                    .isDirectory) ?? false
            if entryIsDirectory {
                try mergeCopy(from: entry, to: target)
            } else if !fileManager.fileExists(atPath: target.path) {
                try fileManager.copyItem(at: entry, to: target)
            }
        }
    }

    private func verifyEveryLegacyFileExists(
        from source: URL,
        at destination: URL
    ) throws -> Bool {
        for entry in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            let target = destination
                .appendingPathComponent(entry.lastPathComponent)
            let entryIsDirectory =
                (try? entry.resourceValues(forKeys: [.isDirectoryKey])
                    .isDirectory) ?? false
            if entryIsDirectory {
                guard
                    try verifyEveryLegacyFileExists(
                        from: entry,
                        at: target
                    )
                else {
                    return false
                }
            } else if !fileManager.fileExists(atPath: target.path) {
                return false
            }
        }
        return true
    }
}
