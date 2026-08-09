//
//  UsageHistory.swift
//  Claude Usage
//
//  Created by Claude Code on 2025-01-26.
//

import Foundation
import UsageCore

/// Stable identity for one provider window reset cycle.
///
/// Display names are deliberately excluded because providers may localize or
/// rename them without changing the underlying limit.
struct UsageHistoryWindowIdentity: Codable, Hashable, Sendable {
    let profileID: UUID
    let providerID: ProviderID
    let groupID: UsageLimitGroupID
    let windowID: UsageWindowID
    let cycleID: String
}

/// Provider-neutral history point captured from a normalized usage report.
struct NormalizedUsageSnapshot: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let profileID: UUID
    let providerID: ProviderID
    let groupID: UsageLimitGroupID
    let groupDisplayName: String?
    let windowID: UsageWindowID
    let windowDisplayName: String?
    let cycleID: String
    let usedPercentage: Double?
    let quantity: UsageQuantity?
    let startedAt: Date?
    let resetsAt: Date?
    let duration: TimeInterval?
    let sourceUpdatedAt: Date?
    let fetchedAt: Date

    var identity: UsageHistoryWindowIdentity {
        UsageHistoryWindowIdentity(
            profileID: profileID,
            providerID: providerID,
            groupID: groupID,
            windowID: windowID,
            cycleID: cycleID
        )
    }

    init(
        id: UUID = UUID(),
        timestamp: Date,
        profileID: UUID,
        providerID: ProviderID,
        groupID: UsageLimitGroupID,
        groupDisplayName: String? = nil,
        windowID: UsageWindowID,
        windowDisplayName: String? = nil,
        cycleID: String,
        usedPercentage: Double?,
        quantity: UsageQuantity?,
        startedAt: Date?,
        resetsAt: Date?,
        duration: TimeInterval?,
        sourceUpdatedAt: Date?,
        fetchedAt: Date
    ) {
        self.id = id
        self.timestamp = timestamp
        self.profileID = profileID
        self.providerID = providerID
        self.groupID = groupID
        self.groupDisplayName = groupDisplayName
        self.windowID = windowID
        self.windowDisplayName = windowDisplayName
        self.cycleID = cycleID
        self.usedPercentage = usedPercentage
        self.quantity = quantity
        self.startedAt = startedAt
        self.resetsAt = resetsAt
        self.duration = duration
        self.sourceUpdatedAt = sourceUpdatedAt
        self.fetchedAt = fetchedAt
    }

    init(
        profileID: UUID,
        report: UsageReport,
        group: UsageLimitGroup,
        window: UsageWindow
    ) {
        self.init(
            timestamp: report.fetchedAt,
            profileID: profileID,
            providerID: report.providerID,
            groupID: group.id,
            groupDisplayName: group.displayName,
            windowID: window.id,
            windowDisplayName: window.displayName,
            cycleID: Self.cycleID(for: window),
            usedPercentage: window.usedPercentage
                ?? window.quantity?.calculatedUsedPercentage,
            quantity: window.quantity,
            startedAt: window.startedAt,
            resetsAt: window.resetsAt,
            duration: window.duration,
            sourceUpdatedAt: report.sourceUpdatedAt,
            fetchedAt: report.fetchedAt
        )
    }

    /// Identifies which usage cycle a window is currently in.
    ///
    /// This comment previously asserted that reset and start timestamps
    /// "come from the provider protocol and are stable across refreshes".
    /// That assumption was wrong and was the direct cause of a false
    /// "session reset" notification on nearly every poll — see
    /// `timestampComponent` for the measured jitter. Providers report the
    /// same reset instant with sub-second variation, so the timestamp is
    /// quantized before it becomes an identity.
    ///
    /// The fallback remains stable for an unbounded window instead of using
    /// a display label or fetch timestamp.
    static func cycleID(for window: UsageWindow) -> String {
        if let resetsAt = window.resetsAt {
            return "reset:\(Self.timestampComponent(resetsAt))"
        }
        if let startedAt = window.startedAt {
            return "start:\(Self.timestampComponent(startedAt))"
        }
        if let duration = window.duration {
            return "duration:\(duration.bitPattern)"
        }
        return "unbounded"
    }

    /// Buckets a timestamp to the whole minute before hashing it into a
    /// cycle identity.
    ///
    /// Real polling captured the *same* reset instant reported with
    /// sub-second jitter between two consecutive fetches (e.g. 807826200.294
    /// then 807826200.236 fifty seconds later — a 58ms wobble, not a new
    /// cycle). Hashing the raw `Double` bit pattern turned that jitter into a
    /// brand-new identity on every poll, which downstream reset detection
    /// read as a fresh session — producing a false "your session has reset"
    /// notification roughly once per poll. Flooring to the minute absorbs
    /// realistic provider-side jitter (observed up to ~1s) while still
    /// changing identity whenever a window's reset boundary meaningfully
    /// moves.
    ///
    /// This alone does not make cycle identity fully stable for *rolling*
    /// windows, whose `resetsAt` advances continuously by design (observed
    /// advancing 60s per poll) — a rolling window can still cross a minute
    /// boundary on every fetch. That case is intentionally left to the
    /// notification policy's separate material-usage-drop gate
    /// (`UsageNotificationPolicy`), because no identity derived solely from
    /// `resetsAt` can be stable for a window that is designed to keep moving.
    private static func timestampComponent(_ date: Date) -> String {
        let bucketWidth: TimeInterval = 60
        let seconds = date.timeIntervalSinceReferenceDate
        let bucket = (seconds / bucketWidth).rounded(.down) * bucketWidth
        return String(bucket.bitPattern)
    }

    /// Cycle identity for a legacy snapshot, whose only cycle signal is the
    /// reset time that triggered it.
    ///
    /// Exists so the legacy CSV-export path shares this type's single
    /// definition of cycle identity rather than rebuilding one from a raw
    /// `Double` bit pattern. Two independent definitions meant one exported
    /// file could carry two incompatible identity formats — quantized on
    /// normalized rows, unquantized on legacy rows — for the same concept.
    static func resetCycleID(forResetTime resetTime: Date) -> String {
        "reset:\(Self.timestampComponent(resetTime))"
    }
}

struct UsageHistoryExportProfile: Codable, Equatable {
    let profileID: UUID
    let profileName: String
    let providerID: ProviderID
    let legacySnapshots: [UsageSnapshot]
    let normalizedSnapshots: [NormalizedUsageSnapshot]
}

/// Explicit, forward-versioned user export. It intentionally contains only
/// display metadata and usage values—never credentials, provider home paths,
/// executable paths, or authentication-file content.
struct UsageHistoryExportDocument: Codable, Equatable {
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let exportedAt: Date
    let profiles: [UsageHistoryExportProfile]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        exportedAt: Date,
        profiles: [UsageHistoryExportProfile]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.profiles = profiles
    }

    func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy =
            Self.losslessDateEncodingStrategy
        return try String(
            decoding: encoder.encode(self),
            as: UTF8.self
        )
    }

    static func decodedJSON(
        from data: Data
    ) throws -> UsageHistoryExportDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy =
            losslessDateDecodingStrategy
        return try decoder.decode(
            UsageHistoryExportDocument.self,
            from: data
        )
    }

    /// Schema v3 represents every Date as its binary64 seconds from Apple's
    /// reference date. JSONEncoder emits a round-trippable decimal Double,
    /// avoiding the subsecond truncation of Foundation's ISO-8601 strategy.
    private static let losslessDateEncodingStrategy:
        JSONEncoder.DateEncodingStrategy = .custom {
            date,
            encoder in
            var container = encoder.singleValueContainer()
            try container.encode(
                date.timeIntervalSinceReferenceDate
            )
        }

    private static let losslessDateDecodingStrategy:
        JSONDecoder.DateDecodingStrategy = .custom {
            decoder in
            let container = try decoder.singleValueContainer()
            return Date(
                timeIntervalSinceReferenceDate:
                    try container.decode(Double.self)
            )
        }
}

/// Reset type that triggers a usage snapshot
enum ResetType: String, Codable, CaseIterable {
    case sessionReset     // Session reset (every 5 hours)
    case weeklyReset      // Weekly usage reset (every Monday)
    case billingCycle     // API billing cycle reset (monthly)

    var localizedName: String {
        switch self {
        case .sessionReset:
            return "history.reset_type.session".localized
        case .weeklyReset:
            return "history.reset_type.weekly".localized
        case .billingCycle:
            return "history.reset_type.billing".localized
        }
    }
}

/// Usage snapshot - records usage data at the moment of reset
struct UsageSnapshot: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date           // When the snapshot was recorded
    let resetType: ResetType      // Type of reset that triggered this snapshot

    // Claude.ai session usage data (captured before reset)
    let sessionTokensUsed: Int?
    let sessionPercentage: Double?

    // Claude.ai weekly usage data (captured before reset)
    let weeklyTokensUsed: Int?
    let weeklyPercentage: Double?
    let opusWeeklyTokensUsed: Int?
    let opusWeeklyPercentage: Double?
    let sonnetWeeklyTokensUsed: Int?
    let sonnetWeeklyPercentage: Double?
    let fableWeeklyTokensUsed: Int?
    let fableWeeklyPercentage: Double?

    // API billing data (captured before reset)
    let apiSpendCents: Int?
    let apiPrepaidCreditsCents: Int?
    let apiCurrency: String?

    // The reset time that triggered this snapshot
    let triggeringResetTime: Date

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        resetType: ResetType,
        sessionTokensUsed: Int? = nil,
        sessionPercentage: Double? = nil,
        weeklyTokensUsed: Int? = nil,
        weeklyPercentage: Double? = nil,
        opusWeeklyTokensUsed: Int? = nil,
        opusWeeklyPercentage: Double? = nil,
        sonnetWeeklyTokensUsed: Int? = nil,
        sonnetWeeklyPercentage: Double? = nil,
        fableWeeklyTokensUsed: Int? = nil,
        fableWeeklyPercentage: Double? = nil,
        apiSpendCents: Int? = nil,
        apiPrepaidCreditsCents: Int? = nil,
        apiCurrency: String? = nil,
        triggeringResetTime: Date
    ) {
        self.id = id
        self.timestamp = timestamp
        self.resetType = resetType
        self.sessionTokensUsed = sessionTokensUsed
        self.sessionPercentage = sessionPercentage
        self.weeklyTokensUsed = weeklyTokensUsed
        self.weeklyPercentage = weeklyPercentage
        self.opusWeeklyTokensUsed = opusWeeklyTokensUsed
        self.opusWeeklyPercentage = opusWeeklyPercentage
        self.sonnetWeeklyTokensUsed = sonnetWeeklyTokensUsed
        self.sonnetWeeklyPercentage = sonnetWeeklyPercentage
        self.fableWeeklyTokensUsed = fableWeeklyTokensUsed
        self.fableWeeklyPercentage = fableWeeklyPercentage
        self.apiSpendCents = apiSpendCents
        self.apiPrepaidCreditsCents = apiPrepaidCreditsCents
        self.apiCurrency = apiCurrency
        self.triggeringResetTime = triggeringResetTime
    }

    /// Creates a snapshot from ClaudeUsage data (for session reset).
    /// Token fields are intentionally omitted: Claude's API reports only
    /// utilization percentages, so any token count would be fabricated.
    static func fromSessionReset(_ usage: ClaudeUsage, resetTime: Date) -> UsageSnapshot {
        UsageSnapshot(
            resetType: .sessionReset,
            sessionPercentage: usage.sessionPercentage,
            triggeringResetTime: resetTime
        )
    }

    /// Creates a snapshot from ClaudeUsage data (for weekly reset).
    /// Token fields are intentionally omitted: Claude's API reports only
    /// utilization percentages, so any token count would be fabricated.
    static func fromWeeklyReset(_ usage: ClaudeUsage, resetTime: Date) -> UsageSnapshot {
        UsageSnapshot(
            resetType: .weeklyReset,
            weeklyPercentage: usage.weeklyPercentage,
            opusWeeklyPercentage: usage.opusWeeklyPercentage,
            sonnetWeeklyPercentage: usage.sonnetWeeklyPercentage,
            fableWeeklyPercentage: usage.fableWeeklyPercentage,
            triggeringResetTime: resetTime
        )
    }

    /// Creates a snapshot from APIUsage data (for billing cycle reset)
    static func fromBillingCycleReset(_ usage: APIUsage, resetTime: Date) -> UsageSnapshot {
        UsageSnapshot(
            resetType: .billingCycle,
            apiSpendCents: usage.currentSpendCents,
            apiPrepaidCreditsCents: usage.prepaidCreditsCents,
            apiCurrency: usage.currency,
            triggeringResetTime: resetTime
        )
    }

    /// Formatted API spend amount
    var formattedApiSpend: String? {
        guard let cents = apiSpendCents, let currency = apiCurrency else { return nil }
        let amount = Double(cents) / 100.0
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: amount))
    }

    /// Formatted date string for display
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }

    /// Short date string (for weekly chart labels - shows date and hour)
    var shortDateString: String {
        let formatter = DateFormatter()
        let timeFmt = SharedDataStore.shared.uses24HourTime() ? "HH:mm" : "h:mma"
        formatter.dateFormat = "MM/dd \(timeFmt)"
        return formatter.string(from: timestamp)
    }

    /// Short time string (for session chart labels - shows hour and minute)
    var shortTimeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = SharedDataStore.shared.uses24HourTime() ? "HH:mm" : "h:mma"
        return formatter.string(from: timestamp)
    }
}

/// Container for a profile's usage history
struct UsageHistoryData: Codable, Equatable {
    var snapshots: [UsageSnapshot]
    var normalizedSnapshots: [NormalizedUsageSnapshot]

    init(
        snapshots: [UsageSnapshot] = [],
        normalizedSnapshots: [NormalizedUsageSnapshot] = []
    ) {
        self.snapshots = snapshots
        self.normalizedSnapshots = normalizedSnapshots
    }

    private enum CodingKeys: String, CodingKey {
        case snapshots
        case normalizedSnapshots
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snapshots = try container.decodeIfPresent(
            [UsageSnapshot].self,
            forKey: .snapshots
        ) ?? []
        normalizedSnapshots = try container.decodeIfPresent(
            [NormalizedUsageSnapshot].self,
            forKey: .normalizedSnapshots
        ) ?? []
    }

    /// Snapshots filtered by reset type
    func snapshots(for resetType: ResetType) -> [UsageSnapshot] {
        snapshots.filter { $0.resetType == resetType }
    }

    /// Session reset snapshots sorted by date (newest first), filtered for valid data
    var sessionSnapshots: [UsageSnapshot] {
        snapshots(for: .sessionReset)
            .filter {
                $0.triggeringResetTime <= $0.timestamp
                    .addingTimeInterval(HistorySnapshotAdmission.tolerance)
            }
            .sorted { $0.timestamp > $1.timestamp }
    }

    /// Weekly reset snapshots sorted by date (newest first), filtered for valid data
    var weeklySnapshots: [UsageSnapshot] {
        snapshots(for: .weeklyReset)
            .filter {
                $0.triggeringResetTime <= $0.timestamp
                    .addingTimeInterval(HistorySnapshotAdmission.tolerance)
            }
            .sorted { $0.timestamp > $1.timestamp }
    }

    /// Billing cycle snapshots sorted by date (newest first), filtered for valid data
    var billingCycleSnapshots: [UsageSnapshot] {
        snapshots(for: .billingCycle)
            .filter {
                $0.triggeringResetTime <= $0.timestamp
                    .addingTimeInterval(HistorySnapshotAdmission.tolerance)
            }
            .sorted { $0.timestamp > $1.timestamp }
    }

    /// Total number of snapshots
    var count: Int {
        snapshots.count + normalizedSnapshots.count
    }

    /// Whether there are any snapshots
    var isEmpty: Bool {
        snapshots.isEmpty && normalizedSnapshots.isEmpty
    }

    /// Add a new snapshot
    mutating func addSnapshot(_ snapshot: UsageSnapshot) {
        snapshots.append(snapshot)
    }

    mutating func addNormalizedSnapshot(
        _ snapshot: NormalizedUsageSnapshot
    ) {
        normalizedSnapshots.append(snapshot)
    }

    func normalizedSnapshots(
        providerID: ProviderID? = nil,
        groupID: UsageLimitGroupID? = nil,
        windowID: UsageWindowID? = nil
    ) -> [NormalizedUsageSnapshot] {
        normalizedSnapshots.filter { snapshot in
            (providerID == nil || snapshot.providerID == providerID)
                && (groupID == nil || snapshot.groupID == groupID)
                && (windowID == nil || snapshot.windowID == windowID)
        }
        .sorted { $0.timestamp > $1.timestamp }
    }

    /// Export to JSON string
    func exportToJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Export specific reset type to JSON
    func exportToJSON(for resetType: ResetType) -> String? {
        let filtered = UsageHistoryData(snapshots: snapshots(for: resetType))
        return filtered.exportToJSON()
    }

    /// Export to CSV format
    func exportToCSV() -> String {
        var csv = "Timestamp,Reset Type,Session %,Session Tokens,Weekly %,Weekly Tokens,Opus %,Sonnet %,Fable %,API Spend,Currency\n"

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        for snapshot in snapshots.sorted(by: { $0.timestamp > $1.timestamp }) {
            let timestamp = dateFormatter.string(from: snapshot.timestamp)
            let resetType = snapshot.resetType.rawValue

            let sessionPct = snapshot.sessionPercentage.map { String(format: "%.1f", $0) } ?? ""
            let sessionTokens = snapshot.sessionTokensUsed.map { String($0) } ?? ""

            let weeklyPct = snapshot.weeklyPercentage.map { String(format: "%.1f", $0) } ?? ""
            let weeklyTokens = snapshot.weeklyTokensUsed.map { String($0) } ?? ""

            let opusPct = snapshot.opusWeeklyPercentage.map { String(format: "%.1f", $0) } ?? ""
            let sonnetPct = snapshot.sonnetWeeklyPercentage.map { String(format: "%.1f", $0) } ?? ""
            let fablePct = snapshot.fableWeeklyPercentage.map { String(format: "%.1f", $0) } ?? ""

            let apiSpend = snapshot.apiSpendCents.map { String(Double($0) / 100.0) } ?? ""
            let currency = snapshot.apiCurrency ?? ""

            csv += "\(timestamp),\(resetType),\(sessionPct),\(sessionTokens),\(weeklyPct),\(weeklyTokens),\(opusPct),\(sonnetPct),\(fablePct),\(apiSpend),\(currency)\n"
        }

        return csv
    }

    /// Export specific reset type to CSV
    func exportToCSV(for resetType: ResetType) -> String {
        let filtered = UsageHistoryData(snapshots: snapshots(for: resetType))
        return filtered.exportToCSV()
    }
}
