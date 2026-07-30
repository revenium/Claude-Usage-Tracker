import Foundation

public struct ProviderAccount: Codable, Equatable, Sendable {
    public var id: ProviderAccountID?
    public var displayName: String?
    public var planName: String?
    public var organizationName: String?

    public init(
        id: ProviderAccountID? = nil,
        displayName: String? = nil,
        planName: String? = nil,
        organizationName: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.planName = planName
        self.organizationName = organizationName
    }
}

public enum ProviderHealthStatus: String, Codable, Hashable, Sendable {
    case healthy
    case degraded
    case unavailable
    case unauthenticated
    case unsupported
}

public enum ProviderHealthIssue: String, Codable, Hashable, Sendable {
    case dependencyMissing
    case configurationInvalid
    case authenticationRequired
    case accountUnsupported
    case transportUnavailable
    case protocolMismatch
    case responseInvalid
    case optionalUsageUnavailable
    case unknown
}

public struct ProviderHealth: Codable, Equatable, Sendable {
    public var status: ProviderHealthStatus
    public var checkedAt: Date
    public var issue: ProviderHealthIssue?

    public init(
        status: ProviderHealthStatus,
        checkedAt: Date,
        issue: ProviderHealthIssue? = nil
    ) {
        self.status = status
        self.checkedAt = checkedAt
        self.issue = issue
    }
}
