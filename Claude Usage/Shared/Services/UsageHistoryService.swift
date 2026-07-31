//
//  UsageHistoryService.swift
//  Claude Usage
//
//  Created by Claude Code on 2025-01-26.
//

import Foundation
import AppKit
import UniformTypeIdentifiers
import UsageCore

@MainActor
protocol ProfileHistoryDeleting: AnyObject {
    func deleteHistoryThrowing(for profileId: UUID) throws
}

enum UsageHistoryServiceError: Error, LocalizedError {
    case defaultsCleanupVerificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .defaultsCleanupVerificationFailed(let key):
            return "Usage history preference \(key) still exists after deletion."
        }
    }
}

/// Service for managing usage history data
@MainActor
class UsageHistoryService: ProfileHistoryDeleting {
    static let shared = UsageHistoryService()

    private let defaults: UserDefaults
    private let decoder = JSONDecoder()
    private let fileStore: ProfileUsageFileStore
    private let now: () -> Date

    /// Key prefix for profile-specific history storage
    private let historyKeyPrefix = "usageHistory_"
    private let lastSessionRecordTimePrefix = "lastSessionRecordTime_"
    private let lastWeeklyRecordTimePrefix = "lastWeeklyRecordTime_"

    /// Maximum snapshots to keep per type (to prevent excessive data)
    private let maxSessionSnapshots = 1000   // ~7 days at 10-min intervals
    private let maxWeeklySnapshots = 500     // ~6 weeks at 2-hour intervals
    private let maxNormalizedSnapshots: Int

    /// Recording intervals for periodic snapshots
    private let sessionRecordingInterval: TimeInterval = 10 * 60  // 10 minutes
    private let weeklyRecordingInterval: TimeInterval = 2 * 60 * 60  // 2 hours

    private let legacyProviderID = ProviderID.claude

    init(
        defaults: UserDefaults = .standard,
        fileStore: ProfileUsageFileStore? = nil,
        now: @escaping () -> Date = Date.init,
        maxNormalizedSnapshots: Int = 5000
    ) {
        self.defaults = defaults
        self.fileStore = fileStore ?? ProfileUsageFileStore()
        self.now = now
        self.maxNormalizedSnapshots = max(
            1,
            maxNormalizedSnapshots
        )
        migrateLegacyHistory()
    }

    // MARK: - Persistent Timestamp Tracking

    /// Gets the last session recording time for a profile (persisted)
    private func getLastSessionRecordTime(for profileId: UUID) -> Date? {
        return defaults.object(forKey: "\(lastSessionRecordTimePrefix)\(profileId.uuidString)") as? Date
    }

    /// Sets the last session recording time for a profile (persisted)
    private func setLastSessionRecordTime(_ date: Date, for profileId: UUID) {
        defaults.set(date, forKey: "\(lastSessionRecordTimePrefix)\(profileId.uuidString)")
    }

    /// Gets the last weekly recording time for a profile (persisted)
    private func getLastWeeklyRecordTime(for profileId: UUID) -> Date? {
        return defaults.object(forKey: "\(lastWeeklyRecordTimePrefix)\(profileId.uuidString)") as? Date
    }

    /// Sets the last weekly recording time for a profile (persisted)
    private func setLastWeeklyRecordTime(_ date: Date, for profileId: UUID) {
        defaults.set(date, forKey: "\(lastWeeklyRecordTimePrefix)\(profileId.uuidString)")
    }

    // MARK: - Storage Key

    /// Generates the storage key for a specific profile's history
    private func storageKey(for profileId: UUID) -> String {
        return "\(historyKeyPrefix)\(profileId.uuidString)"
    }

    // MARK: - Save/Load History

    /// Saves usage history for a profile in durable file storage.
    func saveHistory(
        _ history: UsageHistoryData,
        for profileId: UUID,
        providerID: ProviderID = .claude
    ) {
        do {
            try fileStore.save(
                history,
                for: profileId,
                providerID: providerID.rawValue,
                kind: .history
            )
            LoggingService.shared.logStorageSave("usageHistory for profile \(profileId.uuidString.prefix(8))")
        } catch {
            LoggingService.shared.logStorageError("saveHistory", error: error)
        }
    }

    /// Loads usage history for a profile
    func loadHistory(
        for profileId: UUID,
        providerID: ProviderID = .claude
    ) -> UsageHistoryData {
        do {
            if let history = try fileStore.load(
                UsageHistoryData.self,
                for: profileId,
                providerID: providerID.rawValue,
                kind: .history
            ) {
                let matching = history.normalizedSnapshots.filter {
                    $0.profileID == profileId
                        && $0.providerID == providerID
                }
                guard matching.count
                        == history.normalizedSnapshots.count else {
                    LoggingService.shared.logError(
                        "Ignored normalized history with mismatched "
                            + "profile or provider identity"
                    )
                    return UsageHistoryData(
                        snapshots: history.snapshots,
                        normalizedSnapshots: matching
                    )
                }
                return history
            }
        } catch {
            LoggingService.shared.logStorageError("loadHistory", error: error)
        }

        // A failed migration never deletes its source. Falling back here keeps
        // history available until a later launch can complete the file write.
        if providerID == .claude,
           let legacy = decodeLegacyHistory(for: profileId) {
            return legacy
        }
        return UsageHistoryData()
    }

    // MARK: - Legacy UserDefaults Migration

    /// Migrates each legacy history key independently. A key is removed only
    /// after the file-backed value has been decoded and compared successfully.
    /// Failed keys remain eligible for retry on the next service initialization.
    private func migrateLegacyHistory() {
        let keys = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(historyKeyPrefix) }

        for key in keys {
            let idString = String(key.dropFirst(historyKeyPrefix.count))
            guard let profileID = UUID(uuidString: idString) else {
                continue
            }
            migrateLegacyHistory(for: profileID)
        }
    }

    private func migrateLegacyHistory(for profileID: UUID) {
        let key = storageKey(for: profileID)
        guard let legacyData = defaults.data(forKey: key) else {
            return
        }

        let legacyHistory: UsageHistoryData
        do {
            legacyHistory = try decoder.decode(UsageHistoryData.self, from: legacyData)
        } catch {
            LoggingService.shared.logStorageError("migrateHistory.decode", error: error)
            return
        }

        do {
            if try fileStore.load(
                UsageHistoryData.self,
                for: profileID,
                providerID: legacyProviderID.rawValue,
                kind: .history
            ) != nil {
                // A valid file is authoritative if a previous migration wrote
                // it but the app terminated before removing the legacy key.
                defaults.removeObject(forKey: key)
                LoggingService.shared.logInfo(
                    "Removed verified legacy usage history for profile \(profileID.uuidString.prefix(8))"
                )
                return
            }

            try fileStore.save(
                legacyHistory,
                for: profileID,
                providerID: legacyProviderID.rawValue,
                kind: .history
            )

            guard let verified = try fileStore.load(
                UsageHistoryData.self,
                for: profileID,
                providerID: legacyProviderID.rawValue,
                kind: .history
            ), verified == legacyHistory else {
                LoggingService.shared.logError(
                    "UsageHistory migration verification failed for profile \(profileID.uuidString.prefix(8))"
                )
                return
            }

            defaults.removeObject(forKey: key)
            LoggingService.shared.logInfo(
                "Migrated usage history for profile \(profileID.uuidString.prefix(8)) to file storage"
            )
        } catch {
            LoggingService.shared.logStorageError("migrateHistory.write", error: error)
        }
    }

    private func decodeLegacyHistory(for profileID: UUID) -> UsageHistoryData? {
        guard let data = defaults.data(forKey: storageKey(for: profileID)) else {
            return nil
        }
        do {
            return try decoder.decode(UsageHistoryData.self, from: data)
        } catch {
            LoggingService.shared.logStorageError("loadLegacyHistory", error: error)
            return nil
        }
    }

    @discardableResult
    private func updateHistory(
        for profileID: UUID,
        providerID: ProviderID = .claude,
        transform: (inout UsageHistoryData) -> Void
    ) throws -> UsageHistoryData {
        let initialHistory =
            providerID == .claude
            ? (decodeLegacyHistory(for: profileID) ?? UsageHistoryData())
            : UsageHistoryData()
        return try fileStore.update(
            UsageHistoryData.self,
            for: profileID,
            providerID: providerID.rawValue,
            kind: .history,
            initialValue: initialHistory,
            transform: transform
        )
    }

    // MARK: - Provider-Neutral Recording

    /// Records one point per normalized provider window.
    ///
    /// A reset-cycle change records immediately. Otherwise points are sampled
    /// at the existing session cadence to keep durable history bounded.
    func recordNormalizedReport(
        _ report: UsageReport,
        for profileID: UUID,
        providerID: ProviderID,
        recordedAt: Date? = nil
    ) {
        guard report.providerID == providerID else {
            LoggingService.shared.logError(
                "History report provider does not match profile provider"
            )
            return
        }
        let effectiveNow = recordedAt ?? now()
        guard !report.isStale(at: effectiveNow),
              report.health.status != .unavailable,
              report.health.status != .unauthenticated,
              report.health.status != .unsupported else {
            LoggingService.shared.logInfo(
                "Skipping stale or unavailable normalized history report"
            )
            return
        }

        let candidates = report.limitGroups.flatMap { group in
            group.windows.map {
                NormalizedUsageSnapshot(
                    profileID: profileID,
                    report: report,
                    group: group,
                    window: $0
                )
            }
        }
        guard !candidates.isEmpty else { return }

        do {
            try updateHistory(
                for: profileID,
                providerID: providerID
            ) { history in
                for candidate in candidates {
                    let previous = history.normalizedSnapshots
                        .filter {
                            $0.profileID == candidate.profileID
                                && $0.providerID
                                    == candidate.providerID
                                && $0.groupID == candidate.groupID
                                && $0.windowID == candidate.windowID
                        }
                        .max { $0.timestamp < $1.timestamp }
                    if let previous,
                       previous.cycleID == candidate.cycleID,
                       candidate.timestamp
                        .timeIntervalSince(previous.timestamp)
                            < sessionRecordingInterval {
                        continue
                    }
                    history.addNormalizedSnapshot(candidate)
                }
                pruneNormalizedSnapshots(in: &history)
            }
        } catch {
            LoggingService.shared.logStorageError(
                "recordNormalizedReport",
                error: error
            )
        }
    }

    // MARK: - Record Resets

    /// Records a session reset snapshot
    func recordSessionReset(for profileId: UUID, previousUsage: ClaudeUsage?, resetTime: Date) {
        guard let usage = previousUsage else {
            LoggingService.shared.logInfo("recordSessionReset: No previous usage data to record")
            return
        }

        // Only record if there was actual usage
        guard usage.sessionTokensUsed > 0 || usage.sessionPercentage > 0 else {
            LoggingService.shared.logInfo("recordSessionReset: Skipping snapshot - no usage to record")
            return
        }

        let snapshot = UsageSnapshot.fromSessionReset(usage, resetTime: resetTime)
        do {
            try updateHistory(for: profileId) { history in
                history.addSnapshot(snapshot)
                pruneSessionSnapshots(in: &history)
            }
            LoggingService.shared.logInfo("Recorded session reset snapshot for profile \(profileId.uuidString.prefix(8)): \(usage.sessionPercentage)% usage")
        } catch {
            LoggingService.shared.logStorageError("recordSessionReset", error: error)
        }
    }

    /// Records a weekly reset snapshot
    func recordWeeklyReset(for profileId: UUID, previousUsage: ClaudeUsage?, resetTime: Date) {
        guard let usage = previousUsage else {
            LoggingService.shared.logInfo("recordWeeklyReset: No previous usage data to record")
            return
        }

        // Only record if there was actual usage
        guard usage.weeklyTokensUsed > 0 || usage.weeklyPercentage > 0 else {
            LoggingService.shared.logInfo("recordWeeklyReset: Skipping snapshot - no usage to record")
            return
        }

        let snapshot = UsageSnapshot.fromWeeklyReset(usage, resetTime: resetTime)
        do {
            try updateHistory(for: profileId) { history in
                history.addSnapshot(snapshot)
                pruneWeeklySnapshots(in: &history)
            }
            LoggingService.shared.logInfo("Recorded weekly reset snapshot for profile \(profileId.uuidString.prefix(8)): \(usage.weeklyPercentage)% usage")
        } catch {
            LoggingService.shared.logStorageError("recordWeeklyReset", error: error)
        }
    }

    /// Records a billing cycle reset snapshot
    func recordBillingCycleReset(for profileId: UUID, previousUsage: APIUsage?, resetTime: Date) {
        guard let usage = previousUsage else {
            LoggingService.shared.logInfo("recordBillingCycleReset: No previous usage data to record")
            return
        }

        // Only record if there was actual spend (keep original logic)
        guard usage.currentSpendCents > 0 else {
            LoggingService.shared.logInfo("recordBillingCycleReset: Skipping snapshot - no spend to record")
            return
        }

        let snapshot = UsageSnapshot.fromBillingCycleReset(usage, resetTime: resetTime)
        do {
            try updateHistory(for: profileId) { history in
                history.addSnapshot(snapshot)
            }
            LoggingService.shared.logInfo("Recorded billing cycle snapshot for profile \(profileId.uuidString.prefix(8)): \(usage.formattedUsed) spent")
        } catch {
            LoggingService.shared.logStorageError("recordBillingCycleReset", error: error)
        }
    }

    // MARK: - Periodic Recording

    /// Records session usage periodically (every 10 minutes)
    func recordSessionPeriodic(for profileId: UUID, usage: ClaudeUsage) {
        let now = now()

        // Check if enough time has passed since last recording (using persisted timestamp)
        if let lastRecord = getLastSessionRecordTime(for: profileId) {
            let elapsed = now.timeIntervalSince(lastRecord)
            if elapsed < sessionRecordingInterval {
                return  // Not enough time passed
            }
        }

        // Create periodic snapshot
        let snapshot = UsageSnapshot(
            resetType: .sessionReset,
            sessionTokensUsed: usage.sessionTokensUsed,
            sessionPercentage: usage.sessionPercentage,
            triggeringResetTime: now
        )

        do {
            try updateHistory(for: profileId) { history in
                history.addSnapshot(snapshot)
                pruneSessionSnapshots(in: &history)
            }
            setLastSessionRecordTime(now, for: profileId)
            LoggingService.shared.logInfo("Recorded periodic session snapshot: \(usage.sessionPercentage)%")
        } catch {
            LoggingService.shared.logStorageError("recordSessionPeriodic", error: error)
        }
    }

    /// Records weekly usage periodically (every 2 hours)
    func recordWeeklyPeriodic(for profileId: UUID, usage: ClaudeUsage) {
        let now = now()

        // Check if enough time has passed since last recording (using persisted timestamp)
        if let lastRecord = getLastWeeklyRecordTime(for: profileId) {
            let elapsed = now.timeIntervalSince(lastRecord)
            if elapsed < weeklyRecordingInterval {
                return  // Not enough time passed
            }
        }

        // Create periodic snapshot
        let snapshot = UsageSnapshot(
            resetType: .weeklyReset,
            weeklyTokensUsed: usage.weeklyTokensUsed,
            weeklyPercentage: usage.weeklyPercentage,
            opusWeeklyTokensUsed: usage.opusWeeklyTokensUsed,
            opusWeeklyPercentage: usage.opusWeeklyPercentage,
            sonnetWeeklyTokensUsed: usage.sonnetWeeklyTokensUsed,
            sonnetWeeklyPercentage: usage.sonnetWeeklyPercentage,
            fableWeeklyTokensUsed: usage.fableWeeklyTokensUsed,
            fableWeeklyPercentage: usage.fableWeeklyPercentage,
            triggeringResetTime: now
        )

        do {
            try updateHistory(for: profileId) { history in
                history.addSnapshot(snapshot)
                pruneWeeklySnapshots(in: &history)
            }
            setLastWeeklyRecordTime(now, for: profileId)
            LoggingService.shared.logInfo("Recorded periodic weekly snapshot: \(usage.weeklyPercentage)%")
        } catch {
            LoggingService.shared.logStorageError("recordWeeklyPeriodic", error: error)
        }
    }

    private func pruneSessionSnapshots(in history: inout UsageHistoryData) {
        let sessionCount = history.sessionSnapshots.count
        guard sessionCount > maxSessionSnapshots else {
            return
        }
        let toRemove = sessionCount - maxSessionSnapshots
        let oldestSessions = history.sessionSnapshots.suffix(toRemove)
        let idsToRemove = Set(oldestSessions.map { $0.id })
        history.snapshots.removeAll { idsToRemove.contains($0.id) }
    }

    private func pruneWeeklySnapshots(in history: inout UsageHistoryData) {
        let weeklyCount = history.weeklySnapshots.count
        guard weeklyCount > maxWeeklySnapshots else {
            return
        }
        let toRemove = weeklyCount - maxWeeklySnapshots
        let oldestWeekly = history.weeklySnapshots.suffix(toRemove)
        let idsToRemove = Set(oldestWeekly.map { $0.id })
        history.snapshots.removeAll { idsToRemove.contains($0.id) }
    }

    private func pruneNormalizedSnapshots(
        in history: inout UsageHistoryData
    ) {
        guard history.normalizedSnapshots.count
                > maxNormalizedSnapshots else {
            return
        }
        history.normalizedSnapshots = Array(
            history.normalizedSnapshots
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(maxNormalizedSnapshots)
        )
    }

    // MARK: - Query Methods

    /// Gets session snapshots for a profile (sorted newest first)
    func getSessionSnapshots(for profileId: UUID) -> [UsageSnapshot] {
        return loadHistory(for: profileId).sessionSnapshots
    }

    /// Gets weekly snapshots for a profile (sorted newest first)
    func getWeeklySnapshots(for profileId: UUID) -> [UsageSnapshot] {
        return loadHistory(for: profileId).weeklySnapshots
    }

    /// Gets billing cycle snapshots for a profile (sorted newest first)
    func getBillingCycleSnapshots(for profileId: UUID) -> [UsageSnapshot] {
        return loadHistory(for: profileId).billingCycleSnapshots
    }

    /// Gets all snapshots for a profile (sorted newest first)
    func getAllSnapshots(
        for profileId: UUID,
        providerID: ProviderID = .claude
    ) -> [UsageSnapshot] {
        return loadHistory(
            for: profileId,
            providerID: providerID
        ).snapshots.sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - Export

    /// Exports history to file in specified format
    func makeExport(
        profiles: [Profile],
        exportedAt: Date? = nil
    ) -> UsageHistoryExportDocument {
        UsageHistoryExportDocument(
            exportedAt: exportedAt ?? now(),
            profiles: profiles.map { profile in
                let history = loadHistory(
                    for: profile.id,
                    providerID: profile.providerID
                )
                return UsageHistoryExportProfile(
                    profileID: profile.id,
                    profileName: profile.name,
                    providerID: profile.providerID,
                    legacySnapshots: history.snapshots,
                    normalizedSnapshots:
                        history.normalizedSnapshots
                )
            }
        )
    }

    func exportContent(
        profiles: [Profile],
        resetType: ResetType? = nil,
        format: ExportFormat = .json,
        exportedAt: Date? = nil
    ) -> String? {
        let document = makeExport(
            profiles: profiles,
            exportedAt: exportedAt
        )
        switch format {
        case .json:
            return try? document.encodedJSON()
        case .csv:
            return Self.csv(
                document: document,
                resetType: resetType
            )
        }
    }

    /// Exports history to file in specified format.
    func exportToFile(
        profile: Profile,
        resetType: ResetType? = nil,
        format: ExportFormat = .json
    ) {
        let content = exportContent(
            profiles: [profile],
            resetType: resetType,
            format: format
        ) ?? ""
        let fileExtension: String

        switch format {
        case .json:
            fileExtension = "json"

        case .csv:
            fileExtension = "csv"
        }

        guard !content.isEmpty else {
            LoggingService.shared.logError("Failed to export history")
            return
        }

        // Create save panel
        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFormatter.string(from: Date())

        let typeSuffix = resetType?.rawValue ?? "all"
        savePanel.nameFieldStringValue =
            "\(profile.providerID.rawValue)-usage-history-"
            + "\(typeSuffix)-\(dateStr).\(fileExtension)"

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                do {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                    LoggingService.shared.logInfo("Exported history to \(url.path)")
                } catch {
                    LoggingService.shared.logError("Failed to save export file: \(error.localizedDescription)")
                }
            }
        }
    }

    enum ExportFormat {
        case json
        case csv
    }

    /// Stable analysis-oriented projection for spreadsheets. Versioned JSON
    /// remains the lossless export containing every normalized field.
    private static func csv(
        document: UsageHistoryExportDocument,
        resetType: ResetType?
    ) -> String {
        var rows = [
            "Schema Version,Profile ID,Profile Name,Provider,Timestamp,"
                + "Group ID,Window ID,Cycle ID,Usage %,Used,Limit,Unit,"
                + "Currency,Started At,Resets At,Session Tokens,"
                + "Weekly Tokens,Opus %,Sonnet %,Fable %,API Spend,"
                + "API Prepaid Credits"
        ]
        let formatter = ISO8601DateFormatter()

        for profile in document.profiles {
            let normalized = profile.normalizedSnapshots
                .sorted { $0.timestamp > $1.timestamp }
            for snapshot in normalized {
                let percentage = snapshot.usedPercentage.map {
                    String($0)
                } ?? ""
                let used = snapshot.quantity.map {
                    String($0.used)
                } ?? ""
                let limit = snapshot.quantity?.limit.map {
                    String($0)
                } ?? ""
                let startedAt = snapshot.startedAt.map {
                    formatter.string(from: $0)
                } ?? ""
                let resetsAt = snapshot.resetsAt.map {
                    formatter.string(from: $0)
                } ?? ""
                let columns: [String] = [
                    String(document.schemaVersion),
                    profile.profileID.uuidString,
                    escapedCSV(profile.profileName),
                    escapedCSV(profile.providerID.rawValue),
                    formatter.string(from: snapshot.timestamp),
                    escapedCSV(snapshot.groupID.rawValue),
                    escapedCSV(snapshot.windowID.rawValue),
                    escapedCSV(snapshot.cycleID),
                    percentage,
                    used,
                    limit,
                    escapedCSV(
                        snapshot.quantity?.unit.rawValue ?? ""
                    ),
                    escapedCSV(
                        snapshot.quantity?.currencyCode?.rawValue
                            ?? ""
                    ),
                    startedAt,
                    resetsAt,
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                    ""
                ]
                rows.append(columns.joined(separator: ","))
            }

            let legacy = resetType.map { selectedType in
                profile.legacySnapshots.filter {
                    $0.resetType == selectedType
                }
            } ?? profile.legacySnapshots
            for snapshot in legacy.sorted(
                by: { $0.timestamp > $1.timestamp }
            ) {
                let percentage =
                    snapshot.sessionPercentage.map {
                        String($0)
                    }
                    ?? snapshot.weeklyPercentage.map {
                        String($0)
                    }
                    ?? ""
                let cycleBits = snapshot.triggeringResetTime
                    .timeIntervalSinceReferenceDate
                    .bitPattern
                let cycleID = "reset:" + String(cycleBits)
                let sessionTokens = snapshot.sessionTokensUsed.map {
                    String($0)
                } ?? ""
                let weeklyTokens = snapshot.weeklyTokensUsed.map {
                    String($0)
                } ?? ""
                let opusPercentage =
                    snapshot.opusWeeklyPercentage.map {
                        String($0)
                    } ?? ""
                let sonnetPercentage =
                    snapshot.sonnetWeeklyPercentage.map {
                        String($0)
                    } ?? ""
                let fablePercentage =
                    snapshot.fableWeeklyPercentage.map {
                        String($0)
                    } ?? ""
                let apiSpend = snapshot.apiSpendCents.map {
                    String(Double($0) / 100)
                } ?? ""
                let apiPrepaidCredits =
                    snapshot.apiPrepaidCreditsCents.map {
                        String(Double($0) / 100)
                    } ?? ""
                let columns: [String] = [
                    String(document.schemaVersion),
                    profile.profileID.uuidString,
                    escapedCSV(profile.profileName),
                    escapedCSV(profile.providerID.rawValue),
                    formatter.string(from: snapshot.timestamp),
                    escapedCSV("legacy"),
                    escapedCSV(snapshot.resetType.rawValue),
                    escapedCSV(cycleID),
                    percentage,
                    "",
                    "",
                    "",
                    escapedCSV(snapshot.apiCurrency ?? ""),
                    "",
                    formatter.string(
                        from: snapshot.triggeringResetTime
                    ),
                    sessionTokens,
                    weeklyTokens,
                    opusPercentage,
                    sonnetPercentage,
                    fablePercentage,
                    apiSpend,
                    apiPrepaidCredits
                ]
                rows.append(columns.joined(separator: ","))
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func escapedCSV(_ value: String) -> String {
        let formulaPrefixes: Set<Character> = [
            "=", "+", "-", "@", "\t", "\r"
        ]
        let safeValue: String
        if let first = value.first,
           formulaPrefixes.contains(first) {
            // Keep user-controlled labels from becoming formulas when the
            // export is opened in a spreadsheet application.
            safeValue = "'" + value
        } else {
            safeValue = value
        }
        guard safeValue.contains(",")
                || safeValue.contains("\"")
                || safeValue.contains("\n")
                || safeValue.contains("\r") else {
            return safeValue
        }
        return "\"\(safeValue.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    // MARK: - Cleanup

    /// Deletes all history for a profile
    func deleteHistory(for profileId: UUID) {
        do {
            try deleteHistoryThrowing(for: profileId)
        } catch {
            LoggingService.shared.logStorageError("deleteHistory", error: error)
        }
    }

    /// Throwing deletion primitive for callers that must verify cleanup before
    /// proceeding with profile removal.
    func deleteHistoryThrowing(for profileId: UUID) throws {
        try fileStore.delete(for: profileId, kind: .history)
        // Clear the legacy source only after durable artifacts are gone, so a
        // filesystem failure cannot be mistaken for a successful deletion.
        let keys = [
            storageKey(for: profileId),
            "\(lastSessionRecordTimePrefix)\(profileId.uuidString)",
            "\(lastWeeklyRecordTimePrefix)\(profileId.uuidString)"
        ]
        for key in keys {
            defaults.removeObject(forKey: key)
            guard defaults.object(forKey: key) == nil else {
                throw UsageHistoryServiceError.defaultsCleanupVerificationFailed(key)
            }
        }
        LoggingService.shared.logInfo("Deleted usage history for profile \(profileId.uuidString.prefix(8))")
    }

    /// Clears all snapshots for a profile but keeps the history structure
    func clearHistory(for profileId: UUID) {
        saveHistory(UsageHistoryData(), for: profileId)
        LoggingService.shared.logInfo("Cleared usage history for profile \(profileId.uuidString.prefix(8))")
    }

    /// Clears snapshots of a specific type for a profile
    func clearHistory(for profileId: UUID, resetType: ResetType) {
        do {
            try updateHistory(for: profileId) { history in
                history.snapshots.removeAll { $0.resetType == resetType }
            }
            LoggingService.shared.logInfo("Cleared \(resetType.rawValue) history for profile \(profileId.uuidString.prefix(8))")
        } catch {
            LoggingService.shared.logStorageError("clearHistory", error: error)
        }
    }
}
