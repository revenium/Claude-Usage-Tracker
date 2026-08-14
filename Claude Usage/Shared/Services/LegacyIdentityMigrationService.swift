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
/// where the destination does not already exist, and the legacy data is left
/// in place (a later release may clean it up). When a legacy entry and its
/// destination exist but disagree on kind (a file where a directory is
/// expected, or vice versa), the destination wins, the conflict is logged,
/// and — because that outcome is deliberate and already handled, not a
/// failure — it is treated as verified rather than retried forever.
/// Completion is recorded in the current domain only after both imports
/// succeed, so a partial failure retries on the next launch.
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

    /// Recursively copies `source` into `destination`, skipping any entry
    /// that already exists at the destination. Per-entry granularity keeps a
    /// retry after a partially failed copy from being blocked by its own
    /// debris.
    ///
    /// A kind conflict (the destination exists but is a file where the
    /// legacy entry is a directory, or vice versa) is never clobbered: the
    /// destination — whatever the renamed app or AppKit already put there —
    /// always wins, and the conflict is logged so it is visible without
    /// blocking the migration.
    private func mergeCopy(from source: URL, to destination: URL) throws {
        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
        }
        _ = try walkLegacyTree(from: source, to: destination) { entry in
            switch entry.destination {
            case .absent where entry.isDirectory:
                try fileManager.createDirectory(
                    at: entry.target,
                    withIntermediateDirectories: true
                )
            case .absent:
                try fileManager.copyItem(at: entry.source, to: entry.target)
            case .sameKind:
                break
            case .kindConflict:
                LoggingService.shared.logWarning(
                    "Legacy identity migration found a "
                        + (entry.isDirectory ? "directory" : "file")
                        + " at \(entry.target.path) shadowed by a"
                        + " destination entry of the other kind;"
                        + " keeping the destination entry as-is"
                )
            }
            return true
        }
    }

    /// Recursively confirms every legacy entry was adopted, treating a
    /// logged kind conflict as a settled, verified outcome — not a failure —
    /// so completion is recorded and the migration does not retry forever
    /// over a conflict `mergeCopy` has already resolved (destination wins).
    /// Only a genuinely absent destination withholds the completion marker.
    private func verifyEveryLegacyFileExists(
        from source: URL,
        at destination: URL
    ) throws -> Bool {
        try walkLegacyTree(from: source, to: destination) { entry in
            switch entry.destination {
            case .sameKind, .kindConflict:
                return true
            case .absent:
                return false
            }
        }
    }

    /// How a legacy entry relates to whatever already occupies its
    /// destination.
    private enum DestinationState {
        case absent
        case sameKind
        case kindConflict
    }

    private struct LegacyEntry {
        let source: URL
        let target: URL
        let isDirectory: Bool
        let destination: DestinationState
    }

    /// Kind-aware destination probe: distinguishes "nothing there" from
    /// "something there of the same kind" from "something there of the
    /// other kind," which a bare `fileExists(atPath:)` check cannot.
    private func destinationState(
        for target: URL,
        legacyIsDirectory: Bool
    ) -> DestinationState {
        var targetIsDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: target.path,
            isDirectory: &targetIsDirectory
        ) else {
            return .absent
        }
        return targetIsDirectory.boolValue == legacyIsDirectory
            ? .sameKind
            : .kindConflict
    }

    /// The single recursive walk shared by `mergeCopy` and
    /// `verifyEveryLegacyFileExists`, so the two passes can never drift
    /// against each other. `visit` returns `false` to abandon the walk
    /// early (the walk then also returns `false`).
    ///
    /// A directory is descended into only when its destination is absent or
    /// is itself a directory. A legacy directory shadowed by a destination
    /// file is a kind conflict with nowhere to descend into — it is
    /// surfaced to `visit` once and not walked further.
    private func walkLegacyTree(
        from source: URL,
        to destination: URL,
        visit: (LegacyEntry) throws -> Bool
    ) throws -> Bool {
        for entry in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            let target = destination
                .appendingPathComponent(entry.lastPathComponent)
            let isDirectory =
                (try? entry.resourceValues(forKeys: [.isDirectoryKey])
                    .isDirectory) ?? false
            let entryState = destinationState(
                for: target,
                legacyIsDirectory: isDirectory
            )
            guard try visit(
                LegacyEntry(
                    source: entry,
                    target: target,
                    isDirectory: isDirectory,
                    destination: entryState
                )
            ) else {
                return false
            }
            if isDirectory, entryState != .kindConflict {
                guard try walkLegacyTree(
                    from: entry,
                    to: target,
                    visit: visit
                ) else {
                    return false
                }
            }
        }
        return true
    }
}
