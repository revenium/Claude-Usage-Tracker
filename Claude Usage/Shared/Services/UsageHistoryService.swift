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

/// Whether a snapshot can ever be returned by `UsageHistoryData`'s
/// display-filtered queries (`sessionSnapshots`, `weeklySnapshots`,
/// `billingCycleSnapshots`), each of which requires
/// `triggeringResetTime <= timestamp + tolerance`.
///
/// Reset detection can declare a reset whose triggering instant has not
/// happened yet: Claude's session window is anchored to first message, so
/// its reset time legitimately moves without an actual reset occurring, and
/// each such false positive produces a snapshot dated slightly ahead of
/// itself. Those snapshots were previously admitted, then hidden by the
/// query filters above — and hidden from the pruner too, because it computed
/// its counts from those same filtered views. A record invisible to every
/// reader can never be selected for removal, so it accumulates forever
/// (measured at ~97% of stored history on live installs). Rejecting it here,
/// before it is ever written, is the fix: a record that can never be
/// displayed is now never stored.
nonisolated struct HistorySnapshotAdmission: Equatable, Sendable {
    /// Matches the tolerance already used by `UsageHistoryData`'s display
    /// filters, so admission and display agree by construction.
    static let tolerance: TimeInterval = 60

    static func isAdmissible(
        timestamp: Date,
        triggeringResetTime: Date
    ) -> Bool {
        triggeringResetTime <= timestamp.addingTimeInterval(tolerance)
    }

    static func isAdmissible(_ snapshot: UsageSnapshot) -> Bool {
        isAdmissible(
            timestamp: snapshot.timestamp,
            triggeringResetTime: snapshot.triggeringResetTime
        )
    }
}

/// Corrected retention policy for legacy `UsageSnapshot` history.
///
/// The previous pruners (`pruneSessionSnapshots` / `pruneWeeklySnapshots`,
/// now removed) counted from `UsageHistoryData.sessionSnapshots` /
/// `.weeklySnapshots`, which are already filtered by
/// `HistorySnapshotAdmission`'s display predicate. A record that predicate
/// hides was therefore also hidden from pruning and could never be evicted —
/// measured at ~97% of stored records on live installs. This type counts
/// and selects from the raw `snapshots` array instead, so every stored
/// record — reachable or not — is subject to its cap.
///
/// Applying this to already-oversized history is destructive by design: the
/// whole point is to finally evict records the old pruner could never see.
/// It must never run against unarchived data — see `retentionVersion` and
/// `UsageHistoryService.enforceRetention`, which archives before the first
/// application per profile.
nonisolated struct HistoryRetentionPolicy: Equatable, Sendable {
    /// Bumped whenever the retention rules change in a way that requires
    /// re-applying them to already-repaired data. `UsageHistoryData` carries
    /// the version it was last repaired to; a mismatch means the stored
    /// array predates this version and cannot be trusted to already satisfy
    /// the caps below.
    static let currentVersion = 1

    static let maxSessionSnapshots = 1000     // ~7 days at 10-min intervals
    static let maxWeeklySnapshots = 500       // ~6 weeks at 2-hour intervals
    /// No cap existed at all before this policy — `recordBillingCycleReset`
    /// called `updateHistory` with no prune of any kind. Monthly resets make
    /// even this generous a span cover decades; it exists as a backstop,
    /// not because billing history is expected to approach it.
    static let maxBillingCycleSnapshots = 500
    /// Backstop against a future `ResetType` shipping without its own cap
    /// above. Not expected to bind today — the per-type caps already sum to
    /// exactly this value.
    static let maxTotalSnapshots =
        maxSessionSnapshots + maxWeeklySnapshots + maxBillingCycleSnapshots

    /// Whether `history.snapshots` may contain records this policy's caps
    /// would evict but a prior, uncorrected pruner could never see.
    static func needsRepair(_ history: UsageHistoryData) -> Bool {
        (history.retentionVersion ?? 0) < currentVersion
    }

    /// Evicts every inadmissible record, then applies the per-type caps and
    /// the total backstop to what remains. Idempotent — pruning an
    /// already-pruned array removes nothing further — which is what makes
    /// re-running a repair after an interruption safe.
    ///
    /// The inadmissible-eviction step is unconditional, not merely another
    /// cap, and it must run *before* the per-type caps below rather than
    /// being folded into a single "keep the newest N regardless of
    /// reachability" pass. On real data, inadmissible records vastly
    /// outnumber admissible ones and are written no less recently — capping
    /// by raw timestamp alone would let that recent garbage crowd out
    /// older, currently-displayed legitimate records out of the cap.
    /// Measured against real profiles, a naive raw-timestamp cap kept as
    /// few as 20 of a profile's 500 currently-visible weekly records,
    /// silently erasing the rest of what the user can see today. Evicting
    /// inadmissible records first — categorically, since a record no query
    /// can ever return has zero value at any recency — then capping only
    /// the admissible remainder is what makes the caps below a no-op on
    /// every profile measured (each already sits at or under them),
    /// reproducing exactly what `UsageHistoryData`'s display queries
    /// already return.
    static func pruned(_ snapshots: [UsageSnapshot]) -> [UsageSnapshot] {
        var result = snapshots.filter(HistorySnapshotAdmission.isAdmissible)
        result = pruned(result, type: .sessionReset, cap: maxSessionSnapshots)
        result = pruned(result, type: .weeklyReset, cap: maxWeeklySnapshots)
        result = pruned(result, type: .billingCycle, cap: maxBillingCycleSnapshots)
        result = prunedToTotal(result, cap: maxTotalSnapshots)
        return result
    }

    /// Applies `pruned(_:)` and stamps `currentVersion`, but only when
    /// `history` is not already at `currentVersion`. A no-op on
    /// already-repaired history, by construction.
    static func repairedIfNeeded(_ history: UsageHistoryData) -> UsageHistoryData {
        guard needsRepair(history) else { return history }
        var repaired = history
        repaired.snapshots = pruned(history.snapshots)
        repaired.retentionVersion = currentVersion
        return repaired
    }

    /// Keeps the newest `cap` records of `type`, dropping the rest — from
    /// the full array, not a display-filtered view.
    private static func pruned(
        _ snapshots: [UsageSnapshot],
        type: ResetType,
        cap: Int
    ) -> [UsageSnapshot] {
        let matching = snapshots.filter { $0.resetType == type }
        guard matching.count > cap else { return snapshots }
        let idsToRemove = Set(
            matching
                .sorted { $0.timestamp > $1.timestamp }
                .suffix(matching.count - cap)
                .map(\.id)
        )
        return snapshots.filter { !idsToRemove.contains($0.id) }
    }

    /// Keeps the newest `cap` records overall, regardless of type.
    private static func prunedToTotal(
        _ snapshots: [UsageSnapshot],
        cap: Int
    ) -> [UsageSnapshot] {
        guard snapshots.count > cap else { return snapshots }
        let idsToRemove = Set(
            snapshots
                .sorted { $0.timestamp > $1.timestamp }
                .suffix(snapshots.count - cap)
                .map(\.id)
        )
        return snapshots.filter { !idsToRemove.contains($0.id) }
    }
}

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

    /// Maximum normalized snapshots to keep (to prevent excessive data).
    /// Legacy snapshot caps live on `HistoryRetentionPolicy` instead, since
    /// they must be applied consistently whether triggered by an ordinary
    /// write or by the one-time repair.
    private let maxNormalizedSnapshots: Int

    /// Recording intervals for periodic snapshots
    private let sessionRecordingInterval: TimeInterval = 10 * 60  // 10 minutes
    private let weeklyRecordingInterval: TimeInterval = 2 * 60 * 60  // 2 hours

    private let legacyProviderID = ProviderID.claude

    /// Runs `ProfileUsageFileStore.sweepStaleArtifacts` at most once per
    /// service lifetime — see `updateHistory`.
    private var hasSweptStaleArtifacts = false

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
        sweepStaleArtifactsIfNeeded()
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
                enforceRetention(for: profileID, providerID: providerID, in: &history)
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
        var admitted = false
        do {
            try updateHistory(for: profileId) { history in
                admitted = addSnapshotIfAdmissible(snapshot, for: profileId, to: &history)
                enforceRetention(for: profileId, providerID: .claude, in: &history)
            }
            if admitted {
                LoggingService.shared.logInfo("Recorded session reset snapshot for profile \(profileId.uuidString.prefix(8)): \(usage.sessionPercentage)% usage")
            }
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
        var admitted = false
        do {
            try updateHistory(for: profileId) { history in
                admitted = addSnapshotIfAdmissible(snapshot, for: profileId, to: &history)
                enforceRetention(for: profileId, providerID: .claude, in: &history)
            }
            if admitted {
                LoggingService.shared.logInfo("Recorded weekly reset snapshot for profile \(profileId.uuidString.prefix(8)): \(usage.weeklyPercentage)% usage")
            }
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
        var admitted = false
        do {
            try updateHistory(for: profileId) { history in
                admitted = addSnapshotIfAdmissible(snapshot, for: profileId, to: &history)
                enforceRetention(for: profileId, providerID: .claude, in: &history)
            }
            if admitted {
                LoggingService.shared.logInfo("Recorded billing cycle snapshot for profile \(profileId.uuidString.prefix(8)): \(usage.formattedUsed) spent")
            }
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

        // Create periodic snapshot (percentages only — Claude's API does not
        // report token counts, so none are recorded)
        let snapshot = UsageSnapshot(
            resetType: .sessionReset,
            sessionPercentage: usage.sessionPercentage,
            triggeringResetTime: now
        )

        var admitted = false
        do {
            try updateHistory(for: profileId) { history in
                admitted = addSnapshotIfAdmissible(snapshot, for: profileId, to: &history)
                enforceRetention(for: profileId, providerID: .claude, in: &history)
            }
            setLastSessionRecordTime(now, for: profileId)
            if admitted {
                LoggingService.shared.logInfo("Recorded periodic session snapshot: \(usage.sessionPercentage)%")
            }
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

        // Create periodic snapshot (percentages only — Claude's API does not
        // report token counts, so none are recorded)
        let snapshot = UsageSnapshot(
            resetType: .weeklyReset,
            weeklyPercentage: usage.weeklyPercentage,
            opusWeeklyPercentage: usage.opusWeeklyPercentage,
            sonnetWeeklyPercentage: usage.sonnetWeeklyPercentage,
            fableWeeklyPercentage: usage.fableWeeklyPercentage,
            triggeringResetTime: now
        )

        var admitted = false
        do {
            try updateHistory(for: profileId) { history in
                admitted = addSnapshotIfAdmissible(snapshot, for: profileId, to: &history)
                enforceRetention(for: profileId, providerID: .claude, in: &history)
            }
            setLastWeeklyRecordTime(now, for: profileId)
            if admitted {
                LoggingService.shared.logInfo("Recorded periodic weekly snapshot: \(usage.weeklyPercentage)%")
            }
        } catch {
            LoggingService.shared.logStorageError("recordWeeklyPeriodic", error: error)
        }
    }

    /// Adds `snapshot` to `history` unless `HistorySnapshotAdmission` would
    /// reject it. A rejected snapshot can never be returned by any query, so
    /// storing it would only grow the file forever with no user-visible
    /// benefit.
    /// Returns whether the snapshot was actually stored, so callers do not
    /// log a successful recording for a snapshot that was rejected. The
    /// rejection log is the only signal of how often reset detection fires
    /// falsely, so a "Recorded" line beside it would make that signal
    /// useless to the person reading it.
    @discardableResult
    private func addSnapshotIfAdmissible(
        _ snapshot: UsageSnapshot,
        for profileId: UUID,
        to history: inout UsageHistoryData
    ) -> Bool {
        guard HistorySnapshotAdmission.isAdmissible(snapshot) else {
            LoggingService.shared.logInfo(
                "Rejected unreachable \(snapshot.resetType.rawValue) "
                    + "snapshot for profile \(profileId.uuidString.prefix(8)): "
                    + "triggeringResetTime is after timestamp + "
                    + "\(Int(HistorySnapshotAdmission.tolerance))s tolerance"
            )
            return false
        }
        history.addSnapshot(snapshot)
        return true
    }

    /// Applies `HistoryRetentionPolicy` to `history.snapshots` in place,
    /// archiving the pre-repair file first if this is the first time this
    /// profile has been repaired.
    ///
    /// This is the single choke point every write to a profile's legacy
    /// history passes through, so the corrected policy — which, unlike the
    /// pruners it replaces, can see and evict records the display filter
    /// hides — can never run against a profile whose pre-correction records
    /// have not already been safely archived. Ordering is what makes this
    /// safe: `fileStore.archive` runs against whatever is on disk *before*
    /// this method mutates `history`, and `history` is only ever persisted
    /// afterward, by the `ProfileUsageFileStore.update` call already in
    /// progress around this transform. If archiving fails, retention is
    /// simply not enforced this cycle — the array stays large but nothing
    /// is lost, and repair is retried on the next write to this profile.
    private func enforceRetention(
        for profileID: UUID,
        providerID: ProviderID,
        in history: inout UsageHistoryData
    ) {
        guard HistoryRetentionPolicy.needsRepair(history) else {
            history.snapshots = HistoryRetentionPolicy.pruned(history.snapshots)
            return
        }
        do {
            try fileStore.archive(
                UsageHistoryData.self,
                for: profileID,
                kind: .history
            )
        } catch {
            LoggingService.shared.logStorageError(
                "historyRepair.archive",
                error: error
            )
            return
        }
        let before = history.snapshots.count
        history = HistoryRetentionPolicy.repairedIfNeeded(history)
        let after = history.snapshots.count
        if before != after {
            LoggingService.shared.logInfo(
                "Repaired usage history for profile "
                    + "\(profileID.uuidString.prefix(8)): "
                    + "\(before) -> \(after) records"
            )
        }
    }

    /// Removes stale `.tmp` and history-archive artifacts across every
    /// profile this service's file store manages. Runs at most once per
    /// service lifetime, on the first write, so it never runs at launch and
    /// never repeats needlessly while the app stays open.
    private func sweepStaleArtifactsIfNeeded() {
        guard !hasSweptStaleArtifacts else { return }
        hasSweptStaleArtifacts = true
        fileStore.sweepStaleArtifacts()
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
                let cycleID = NormalizedUsageSnapshot.resetCycleID(
                    forResetTime: snapshot.triggeringResetTime
                )
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
