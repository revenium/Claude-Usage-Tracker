import Foundation

public struct ProviderCapability: Hashable, Sendable, Codable, CustomStringConvertible {
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
            throw UsageCoreValidationError.invalidIdentifier(kind: "provider capability")
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
                debugDescription: "ProviderCapability must be a stable, nonempty identifier"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static let account = ProviderCapability(unchecked: "account")
    public static let health = ProviderCapability(unchecked: "health")
    public static let usageLimits = ProviderCapability(unchecked: "usage-limits")
    public static let usageSummary = ProviderCapability(unchecked: "usage-summary")
    public static let credits = ProviderCapability(unchecked: "credits")
    public static let resetCredits = ProviderCapability(unchecked: "reset-credits")
    public static let interactiveLogin = ProviderCapability(unchecked: "interactive-login")
    public static let automaticSessionStart = ProviderCapability(unchecked: "automatic-session-start")
    public static let automaticProfileSwitch = ProviderCapability(unchecked: "automatic-profile-switch")
    public static let statusLineIntegration = ProviderCapability(unchecked: "status-line-integration")
    public static let usageHistory = ProviderCapability(unchecked: "usage-history")
    public static let usageNotifications = ProviderCapability(unchecked: "usage-notifications")
    public static let cliAccountSync = ProviderCapability(unchecked: "cli-account-sync")
    public static let apiBilling = ProviderCapability(unchecked: "api-billing")
}

public enum CapabilityAvailability: String, Codable, Hashable, Sendable {
    case available
    case unavailable
    case unknown
}

/// A forward-compatible capability map.
///
/// Providers only need to publish entries they can determine. Looking up an
/// omitted capability returns `.unknown`, which is intentionally distinct from
/// an explicitly unsupported capability.
public struct ProviderCapabilities: Codable, Equatable, Sendable {
    private var storage: [String: CapabilityAvailability]

    public init(_ entries: [ProviderCapability: CapabilityAvailability] = [:]) {
        storage = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.key.rawValue, $0.value) }
        )
    }

    public subscript(_ capability: ProviderCapability) -> CapabilityAvailability {
        get { storage[capability.rawValue] ?? .unknown }
        set { storage[capability.rawValue] = newValue }
    }

    public var entries: [ProviderCapability: CapabilityAvailability] {
        Dictionary(
            uniqueKeysWithValues: storage.compactMap { key, value in
                guard let capability = try? ProviderCapability(key) else {
                    return nil
                }
                return (capability, value)
            }
        )
    }

    public func supports(_ capability: ProviderCapability) -> Bool {
        self[capability] == .available
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded = try container.decode([String: CapabilityAvailability].self)
        for key in decoded.keys {
            _ = try ProviderCapability(key)
        }
        storage = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storage)
    }
}
