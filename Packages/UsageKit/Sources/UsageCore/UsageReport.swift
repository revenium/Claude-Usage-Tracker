import Foundation

public enum UsageReportFreshness: Equatable, Sendable {
    case fresh
    case stale(since: Date)
    case unknown
}

public struct UsageReport: Codable, Equatable, Sendable {
    public var providerID: ProviderID
    public var account: ProviderAccount?
    public var health: ProviderHealth
    public var limitGroups: [UsageLimitGroup]
    public var usageSummary: UsageSummary?
    public var credits: [UsageCredit]
    public var sourceUpdatedAt: Date?
    public var fetchedAt: Date
    public var staleAt: Date?

    public init(
        providerID: ProviderID,
        account: ProviderAccount? = nil,
        health: ProviderHealth,
        limitGroups: [UsageLimitGroup],
        usageSummary: UsageSummary? = nil,
        credits: [UsageCredit] = [],
        sourceUpdatedAt: Date? = nil,
        fetchedAt: Date,
        staleAt: Date? = nil
    ) throws {
        var seenGroups = Set<UsageLimitGroupID>()
        for group in limitGroups where !seenGroups.insert(group.id).inserted {
            throw UsageCoreValidationError.duplicateIdentifier(
                kind: "limit group",
                identifier: group.id.rawValue
            )
        }

        var seenCredits = Set<UsageMetricID>()
        for credit in credits where !seenCredits.insert(credit.id).inserted {
            throw UsageCoreValidationError.duplicateIdentifier(
                kind: "usage credit",
                identifier: credit.id.rawValue
            )
        }

        if let staleAt, staleAt < fetchedAt {
            throw UsageCoreValidationError.invalidDateRange(field: "usageReport.staleAt")
        }

        self.providerID = providerID
        self.account = account
        self.health = health
        self.limitGroups = limitGroups
        self.usageSummary = usageSummary
        self.credits = credits
        self.sourceUpdatedAt = sourceUpdatedAt
        self.fetchedAt = fetchedAt
        self.staleAt = staleAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            providerID: container.decode(ProviderID.self, forKey: .providerID),
            account: container.decodeIfPresent(ProviderAccount.self, forKey: .account),
            health: container.decode(ProviderHealth.self, forKey: .health),
            limitGroups: container.decodeIfPresent([UsageLimitGroup].self, forKey: .limitGroups) ?? [],
            usageSummary: container.decodeIfPresent(UsageSummary.self, forKey: .usageSummary),
            credits: container.decodeIfPresent([UsageCredit].self, forKey: .credits) ?? [],
            sourceUpdatedAt: container.decodeIfPresent(Date.self, forKey: .sourceUpdatedAt),
            fetchedAt: container.decode(Date.self, forKey: .fetchedAt),
            staleAt: container.decodeIfPresent(Date.self, forKey: .staleAt)
        )
    }

    public func freshness(at date: Date) -> UsageReportFreshness {
        guard let staleAt else { return .unknown }
        return date >= staleAt ? .stale(since: staleAt) : .fresh
    }

    public func isStale(at date: Date) -> Bool {
        if case .stale = freshness(at: date) {
            return true
        }
        return false
    }
}
