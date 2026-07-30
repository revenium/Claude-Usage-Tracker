import Foundation

public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    var capabilities: ProviderCapabilities { get }

    func account() async throws -> ProviderAccount?
    func health() async -> ProviderHealth
    func fetchUsage() async throws -> UsageReport
}

public enum UsageProviderError: Error, Equatable, Sendable {
    case capabilityUnavailable(ProviderCapability)
    case unauthenticated
    case unsupportedAccount
    case invalidConfiguration
    case dependencyMissing
    case transportFailure
    case protocolFailure
    case malformedResponse
    case timedOut
    case cancelled
}
