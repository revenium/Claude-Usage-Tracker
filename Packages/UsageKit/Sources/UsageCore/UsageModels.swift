import Foundation

public struct UsageUnit: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) throws {
        guard !rawValue.isEmpty,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              rawValue.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw UsageCoreValidationError.invalidIdentifier(kind: "usage unit")
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        do {
            try self.init(rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "UsageUnit must be a stable, nonempty identifier"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static let tokens = UsageUnit(unchecked: "tokens")
    public static let requests = UsageUnit(unchecked: "requests")
    public static let currency = UsageUnit(unchecked: "currency")
    public static let count = UsageUnit(unchecked: "count")
}

public struct UsageQuantity: Codable, Equatable, Sendable {
    public var used: Double
    public var limit: Double?
    public var unit: UsageUnit

    public init(used: Double, limit: Double? = nil, unit: UsageUnit) throws {
        guard used.isFinite, used >= 0 else {
            throw UsageCoreValidationError.invalidValue(field: "used")
        }
        if let limit {
            guard limit.isFinite, limit >= 0 else {
                throw UsageCoreValidationError.invalidValue(field: "limit")
            }
        }

        self.used = used
        self.limit = limit
        self.unit = unit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            used: container.decode(Double.self, forKey: .used),
            limit: container.decodeIfPresent(Double.self, forKey: .limit),
            unit: container.decode(UsageUnit.self, forKey: .unit)
        )
    }

    public var calculatedUsedPercentage: Double? {
        guard let limit, limit > 0 else { return nil }
        return used / limit * 100
    }
}

public struct UsageWindow: Codable, Equatable, Sendable, Identifiable {
    public var id: UsageWindowID
    public var displayName: String?
    public var usedPercentage: Double?
    public var quantity: UsageQuantity?
    public var startedAt: Date?
    public var resetsAt: Date?
    public var duration: TimeInterval?

    public init(
        id: UsageWindowID,
        displayName: String? = nil,
        usedPercentage: Double? = nil,
        quantity: UsageQuantity? = nil,
        startedAt: Date? = nil,
        resetsAt: Date? = nil,
        duration: TimeInterval? = nil
    ) throws {
        if let usedPercentage {
            guard usedPercentage.isFinite, usedPercentage >= 0 else {
                throw UsageCoreValidationError.invalidValue(field: "usedPercentage")
            }
        }
        if let duration {
            guard duration.isFinite, duration > 0 else {
                throw UsageCoreValidationError.invalidValue(field: "duration")
            }
        }
        if let startedAt, let resetsAt, resetsAt < startedAt {
            throw UsageCoreValidationError.invalidDateRange(field: "usageWindow")
        }
        guard usedPercentage != nil || quantity != nil else {
            throw UsageCoreValidationError.invalidValue(field: "usageWindow.measurement")
        }

        self.id = id
        self.displayName = displayName
        self.usedPercentage = usedPercentage
        self.quantity = quantity
        self.startedAt = startedAt
        self.resetsAt = resetsAt
        self.duration = duration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UsageWindowID.self, forKey: .id),
            displayName: container.decodeIfPresent(String.self, forKey: .displayName),
            usedPercentage: container.decodeIfPresent(Double.self, forKey: .usedPercentage),
            quantity: container.decodeIfPresent(UsageQuantity.self, forKey: .quantity),
            startedAt: container.decodeIfPresent(Date.self, forKey: .startedAt),
            resetsAt: container.decodeIfPresent(Date.self, forKey: .resetsAt),
            duration: container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        )
    }
}

public struct UsageLimitGroup: Codable, Equatable, Sendable, Identifiable {
    public var id: UsageLimitGroupID
    public var displayName: String?
    public var windows: [UsageWindow]

    public init(
        id: UsageLimitGroupID,
        displayName: String? = nil,
        windows: [UsageWindow]
    ) throws {
        var seen = Set<UsageWindowID>()
        for window in windows where !seen.insert(window.id).inserted {
            throw UsageCoreValidationError.duplicateIdentifier(
                kind: "usage window",
                identifier: window.id.rawValue
            )
        }
        self.id = id
        self.displayName = displayName
        self.windows = windows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UsageLimitGroupID.self, forKey: .id),
            displayName: container.decodeIfPresent(String.self, forKey: .displayName),
            windows: container.decode([UsageWindow].self, forKey: .windows)
        )
    }
}

public struct UsageMetric: Codable, Equatable, Sendable, Identifiable {
    public var id: UsageMetricID
    public var displayName: String?
    public var value: Double
    public var unit: UsageUnit

    public init(
        id: UsageMetricID,
        displayName: String? = nil,
        value: Double,
        unit: UsageUnit
    ) throws {
        guard value.isFinite, value >= 0 else {
            throw UsageCoreValidationError.invalidValue(field: "usageMetric.value")
        }
        self.id = id
        self.displayName = displayName
        self.value = value
        self.unit = unit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UsageMetricID.self, forKey: .id),
            displayName: container.decodeIfPresent(String.self, forKey: .displayName),
            value: container.decode(Double.self, forKey: .value),
            unit: container.decode(UsageUnit.self, forKey: .unit)
        )
    }
}

public struct UsageSummary: Codable, Equatable, Sendable {
    public var metrics: [UsageMetric]
    public var periodStartedAt: Date?
    public var periodEndsAt: Date?

    public init(
        metrics: [UsageMetric],
        periodStartedAt: Date? = nil,
        periodEndsAt: Date? = nil
    ) throws {
        var seen = Set<UsageMetricID>()
        for metric in metrics where !seen.insert(metric.id).inserted {
            throw UsageCoreValidationError.duplicateIdentifier(
                kind: "usage metric",
                identifier: metric.id.rawValue
            )
        }
        if let periodStartedAt, let periodEndsAt, periodEndsAt < periodStartedAt {
            throw UsageCoreValidationError.invalidDateRange(field: "usageSummary")
        }
        self.metrics = metrics
        self.periodStartedAt = periodStartedAt
        self.periodEndsAt = periodEndsAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            metrics: container.decode([UsageMetric].self, forKey: .metrics),
            periodStartedAt: container.decodeIfPresent(Date.self, forKey: .periodStartedAt),
            periodEndsAt: container.decodeIfPresent(Date.self, forKey: .periodEndsAt)
        )
    }
}

/// Informational credit balance supplied by a provider for display.
///
/// Credits are deliberately read-only in UsageCore. This type exposes no
/// mutation or redemption operation; any provider action API belongs outside
/// the usage-report contract.
public struct UsageCredit: Codable, Equatable, Sendable, Identifiable {
    public var id: UsageMetricID
    public var displayName: String?
    public var balance: Double
    public var unit: UsageUnit
    public var resetsAt: Date?

    public init(
        id: UsageMetricID,
        displayName: String? = nil,
        balance: Double,
        unit: UsageUnit,
        resetsAt: Date? = nil
    ) throws {
        guard balance.isFinite, balance >= 0 else {
            throw UsageCoreValidationError.invalidValue(field: "usageCredit.balance")
        }
        self.id = id
        self.displayName = displayName
        self.balance = balance
        self.unit = unit
        self.resetsAt = resetsAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UsageMetricID.self, forKey: .id),
            displayName: container.decodeIfPresent(String.self, forKey: .displayName),
            balance: container.decode(Double.self, forKey: .balance),
            unit: container.decode(UsageUnit.self, forKey: .unit),
            resetsAt: container.decodeIfPresent(Date.self, forKey: .resetsAt)
        )
    }
}
