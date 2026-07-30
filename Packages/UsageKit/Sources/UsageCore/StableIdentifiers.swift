import Foundation

public enum UsageCoreValidationError: Error, Equatable, Sendable {
    case invalidIdentifier(kind: String)
    case duplicateIdentifier(kind: String, identifier: String)
    case invalidValue(field: String)
    case invalidDateRange(field: String)
}

private func isValidStableIdentifier(_ value: String) -> Bool {
    guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
        return false
    }

    return value.unicodeScalars.allSatisfy { scalar in
        !CharacterSet.controlCharacters.contains(scalar)
    }
}

private func decodeStableIdentifier(
    from decoder: Decoder,
    kind: String
) throws -> String {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard isValidStableIdentifier(value) else {
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "\(kind) must be nonempty and contain no surrounding whitespace or control characters"
        )
    }
    return value
}

public struct ProviderID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    private static func wellKnown(_ rawValue: String) -> ProviderID {
        do {
            return try ProviderID(rawValue)
        } catch {
            preconditionFailure("Invalid well-known provider identifier: \(rawValue)")
        }
    }

    public init(_ rawValue: String) throws {
        guard isValidStableIdentifier(rawValue) else {
            throw UsageCoreValidationError.invalidIdentifier(kind: "provider")
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decodeStableIdentifier(from: decoder, kind: "ProviderID")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    /// The stable identity used by the built-in Claude provider adapter.
    public static let claude = ProviderID.wellKnown("claude")

    /// The stable identity used by the built-in Codex provider.
    public static let codex = ProviderID.wellKnown("codex")
}

public struct UsageLimitGroupID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard isValidStableIdentifier(rawValue) else {
            throw UsageCoreValidationError.invalidIdentifier(kind: "limit group")
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decodeStableIdentifier(from: decoder, kind: "UsageLimitGroupID")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

public struct UsageWindowID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard isValidStableIdentifier(rawValue) else {
            throw UsageCoreValidationError.invalidIdentifier(kind: "usage window")
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decodeStableIdentifier(from: decoder, kind: "UsageWindowID")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

public struct UsageMetricID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard isValidStableIdentifier(rawValue) else {
            throw UsageCoreValidationError.invalidIdentifier(kind: "usage metric")
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decodeStableIdentifier(from: decoder, kind: "UsageMetricID")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

public struct ProviderAccountID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard isValidStableIdentifier(rawValue) else {
            throw UsageCoreValidationError.invalidIdentifier(kind: "provider account")
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decodeStableIdentifier(from: decoder, kind: "ProviderAccountID")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}
