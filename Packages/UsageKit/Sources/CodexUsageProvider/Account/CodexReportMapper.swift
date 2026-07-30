import Foundation
import UsageCore

enum CodexReportMapper {
    static func limitGroups(
        from response: CodexRateLimitsResponse
    ) throws -> [UsageLimitGroup] {
        let snapshots = selectedSnapshots(from: response)
        return try snapshots.map { sourceID, snapshot in
            let stableComponent = stableIdentifierComponent(
                snapshot.limitID ?? sourceID
            )
            let groupID = try UsageLimitGroupID(
                "codex.limit.\(stableComponent)"
            )
            var windows: [UsageWindow] = []
            if let primary = snapshot.primary {
                windows.append(
                    try window(
                        primary,
                        id: "codex.limit.\(stableComponent).primary",
                        displayName: "Primary"
                    )
                )
            }
            if let secondary = snapshot.secondary {
                windows.append(
                    try window(
                        secondary,
                        id: "codex.limit.\(stableComponent).secondary",
                        displayName: "Secondary"
                    )
                )
            }
            return try UsageLimitGroup(
                id: groupID,
                displayName: safeDisplayName(
                    snapshot.limitName
                        ?? snapshot.limitID
                        ?? sourceID
                ),
                windows: windows
            )
        }
    }

    static func credits(
        from response: CodexRateLimitsResponse
    ) throws -> [UsageCredit] {
        var credits: [UsageCredit] = []
        for (sourceID, snapshot) in selectedSnapshots(from: response) {
            guard let snapshotCredits = snapshot.credits,
                  snapshotCredits.hasCredits,
                  !snapshotCredits.unlimited,
                  let balanceString = snapshotCredits.balance,
                  let balance = Double(balanceString),
                  balance.isFinite,
                  balance >= 0
            else {
                continue
            }
            let stableComponent = stableIdentifierComponent(
                snapshot.limitID ?? sourceID
            )
            credits.append(
                try UsageCredit(
                    id: UsageMetricID(
                        "codex.limit.\(stableComponent).credits"
                    ),
                    displayName: "Credits",
                    balance: balance,
                    unit: .count
                )
            )
        }

        if let resetSummary = response.rateLimitResetCredits {
            guard resetSummary.availableCount >= 0 else {
                throw UsageProviderError.malformedResponse
            }
            let availableExpirations = resetSummary.credits?
                .filter { $0.status == "available" }
                .compactMap(\.expiresAt)
                .map(unixDate)
            credits.append(
                try UsageCredit(
                    id: UsageMetricID("codex.rate-limit-reset-credits"),
                    displayName: "Rate-limit reset credits",
                    balance: Double(resetSummary.availableCount),
                    unit: .count,
                    resetsAt: availableExpirations?.min()
                )
            )
        }

        return credits
    }

    static func usageSummary(
        from response: CodexAccountTokenUsageResponse
    ) throws -> UsageSummary? {
        var metrics: [UsageMetric] = []
        if let summary = response.summary {
            try appendMetric(
                summary.lifetimeTokens,
                id: "codex.lifetime-tokens",
                name: "Lifetime tokens",
                unit: .tokens,
                to: &metrics
            )
            try appendMetric(
                summary.peakDailyTokens,
                id: "codex.peak-daily-tokens",
                name: "Peak daily tokens",
                unit: .tokens,
                to: &metrics
            )
            try appendMetric(
                summary.longestRunningTurnSec,
                id: "codex.longest-running-turn-seconds",
                name: "Longest running turn",
                unit: try UsageUnit("seconds"),
                to: &metrics
            )
            try appendMetric(
                summary.currentStreakDays,
                id: "codex.current-streak-days",
                name: "Current streak",
                unit: try UsageUnit("days"),
                to: &metrics
            )
            try appendMetric(
                summary.longestStreakDays,
                id: "codex.longest-streak-days",
                name: "Longest streak",
                unit: try UsageUnit("days"),
                to: &metrics
            )
        }

        let validBuckets = try response.dailyUsageBuckets.map(
            validDailyBuckets
        )
        if let validBuckets, !validBuckets.isEmpty {
            let total = try validBuckets.reduce(Int64(0)) { total, bucket in
                let (sum, overflow) = total.addingReportingOverflow(
                    bucket.tokens
                )
                guard !overflow else {
                    throw UsageProviderError.malformedResponse
                }
                return sum
            }
            try appendMetric(
                total,
                id: "codex.reported-daily-bucket-tokens",
                name: "Reported daily-bucket tokens",
                unit: .tokens,
                to: &metrics
            )
            try appendMetric(
                Int64(validBuckets.count),
                id: "codex.reported-daily-buckets",
                name: "Reported daily buckets",
                unit: .count,
                to: &metrics
            )
        }

        guard response.summary != nil
                || response.dailyUsageBuckets != nil else {
            return nil
        }

        let dates = validBuckets?.map(\.date) ?? []
        let periodStart = dates.min()
        // Daily bucket dates are parsed at midnight UTC. Add one exact UTC day
        // so the persisted period is independent of the host time zone and DST.
        let periodEnd = dates.max()?.addingTimeInterval(86_400)
        let dailyBuckets = try validBuckets?.map { bucket in
            try UsageDailyBucket(
                startedAt: bucket.date,
                endsAt: bucket.date.addingTimeInterval(86_400),
                metrics: [
                    UsageMetric(
                        id: UsageMetricID("codex.tokens"),
                        displayName: "Tokens",
                        value: Double(bucket.tokens),
                        unit: .tokens
                    )
                ]
            )
        }
        return try UsageSummary(
            metrics: metrics,
            periodStartedAt: periodStart,
            periodEndsAt: periodEnd,
            dailyBuckets: dailyBuckets
        )
    }

    private static func selectedSnapshots(
        from response: CodexRateLimitsResponse
    ) -> [(String, CodexRateLimitsResponse.Snapshot)] {
        if !response.rateLimitsByLimitID.isEmpty {
            return response.rateLimitsByLimitID.sorted { $0.key < $1.key }
        }
        if let legacy = response.rateLimits {
            return [(legacy.limitID ?? "default", legacy)]
        }
        return []
    }

    private static func window(
        _ source: CodexRateLimitsResponse.Snapshot.Window,
        id: String,
        displayName: String
    ) throws -> UsageWindow {
        guard source.usedPercent.isFinite, source.usedPercent >= 0 else {
            throw UsageProviderError.malformedResponse
        }
        let duration: TimeInterval?
        if let minutes = source.windowDurationMins {
            guard minutes > 0,
                  minutes <= Int64.max / 60
            else {
                throw UsageProviderError.malformedResponse
            }
            duration = Double(minutes) * 60
        } else {
            duration = nil
        }
        let resetsAt = source.resetsAt.map(unixDate)
        let startedAt: Date?
        if let resetsAt, let duration {
            startedAt = resetsAt.addingTimeInterval(-duration)
        } else {
            startedAt = nil
        }
        return try UsageWindow(
            id: UsageWindowID(id),
            displayName: displayName,
            usedPercentage: source.usedPercent,
            startedAt: startedAt,
            resetsAt: resetsAt,
            duration: duration
        )
    }

    private static func appendMetric(
        _ value: Int64?,
        id: String,
        name: String,
        unit: UsageUnit,
        to metrics: inout [UsageMetric]
    ) throws {
        guard let value else { return }
        guard value >= 0 else {
            throw UsageProviderError.malformedResponse
        }
        metrics.append(
            try UsageMetric(
                id: UsageMetricID(id),
                displayName: name,
                value: Double(value),
                unit: unit
            )
        )
    }

    private static func validDailyBuckets(
        _ buckets: [CodexAccountTokenUsageResponse.DailyBucket]
    ) throws -> [(date: Date, tokens: Int64)] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false

        var seenDates = Set<Date>()
        return try buckets.map { bucket in
            guard bucket.tokens >= 0,
                  let date = formatter.date(from: bucket.startDate)
            else {
                throw UsageProviderError.malformedResponse
            }
            guard seenDates.insert(date).inserted else {
                throw UsageProviderError.malformedResponse
            }
            return (date, bucket.tokens)
        }.sorted { $0.date < $1.date }
    }

    private static func unixDate(_ seconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private static func stableIdentifierComponent(_ value: String) -> String {
        let normalized = value.isEmpty ? "default" : value
        return normalized.utf8.map { byte in
            let scalar = UnicodeScalar(byte)
            if (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45
                || byte == 95
            {
                return String(Character(scalar))
            }
            return String(format: "~%02X", byte)
        }.joined()
    }

    private static func safeDisplayName(_ value: String) -> String? {
        guard let value = CodexUsageProvider.safeOpaqueValue(value),
              value.count <= 512
        else {
            return nil
        }
        return value
    }
}
