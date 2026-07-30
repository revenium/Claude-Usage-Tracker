import Foundation

enum ProfileProviderKind: String, Codable, Equatable {
    case claude
    case codex
}

enum ProfileProviderConfigurationError: Error, LocalizedError, Equatable {
    case invalidTaggedShape
    case invalidCanonicalHome
    case providerChangeNotAllowed(UUID)
    case codexHomeChangeRequiresLink(UUID)
    case providerRevisionChangeNotAllowed(UUID)
    case providerRevisionExhausted(UUID)
    case duplicateCodexHome(UUID)
    case claudeStateOnCodexProfile(UUID)
    case initialProfileAlreadyExists
    case duplicateProfileID(UUID)
    case profileSetChanged
    case deletionStateChangeRequiresLifecycle(UUID)
    case codexProfileRequired(UUID)
    case claudeProfileRequired(UUID)
    case codexInitialHomeRequiresDedicatedCreation
    case codexConfigurationMutationFailed(UUID)
    case codexConfigurationRollbackFailed(UUID, metadata: Bool, usage: Bool)
    case codexConfigurationMarkerVerificationFailed

    var errorDescription: String? {
        switch self {
        case .invalidTaggedShape:
            return "The profile provider configuration is invalid."
        case .invalidCanonicalHome:
            return "The stored Codex home reference is invalid."
        case .providerChangeNotAllowed(let profileID):
            return "Profile \(profileID.uuidString.prefix(8)) cannot change providers. Create a new profile instead."
        case .codexHomeChangeRequiresLink(let profileID):
            return "Profile \(profileID.uuidString.prefix(8)) must use the Codex link or unlink operation."
        case .providerRevisionChangeNotAllowed(let profileID):
            return "Profile \(profileID.uuidString.prefix(8)) cannot change its provider revision through a metadata edit."
        case .providerRevisionExhausted(let profileID):
            return "Profile \(profileID.uuidString.prefix(8)) cannot accept another provider configuration revision."
        case .duplicateCodexHome(let profileID):
            return "That Codex home is already linked to profile \(profileID.uuidString.prefix(8))."
        case .claudeStateOnCodexProfile(let profileID):
            return "Codex profile \(profileID.uuidString.prefix(8)) contains Claude-specific state."
        case .initialProfileAlreadyExists:
            return "An initial profile can be created only while no profiles exist."
        case .duplicateProfileID(let profileID):
            return "Profile \(profileID.uuidString.prefix(8)) already exists."
        case .profileSetChanged:
            return "The profile list changed. Reload it before creating a profile."
        case .deletionStateChangeRequiresLifecycle(let profileID):
            return "Profile \(profileID.uuidString.prefix(8)) must use the verified deletion lifecycle."
        case .codexProfileRequired(let profileID):
            return "Profile \(profileID.uuidString.prefix(8)) is not a Codex profile."
        case .claudeProfileRequired(let profileID):
            return "Profile \(profileID.uuidString.prefix(8)) is not a Claude profile."
        case .codexInitialHomeRequiresDedicatedCreation:
            return "Use the verified Codex-home creation operation for an initially linked profile."
        case .codexConfigurationMutationFailed(let profileID):
            return "The Codex profile update failed safely for profile \(profileID.uuidString.prefix(8))."
        case .codexConfigurationRollbackFailed(let profileID, let metadata, let usage):
            return "The Codex profile rollback is unresolved for profile "
                + "\(profileID.uuidString.prefix(8)); metadata: "
                + "\(metadata ? "unresolved" : "restored"), usage: "
                + "\(usage ? "unresolved" : "restored")."
        case .codexConfigurationMarkerVerificationFailed:
            return "Codex profile recovery state could not be verified."
        }
    }
}

struct CodexProfileConfiguration: Codable, Equatable {
    var linkedHome: CanonicalCodexHome?

    init(linkedHome: CanonicalCodexHome? = nil) {
        self.linkedHome = linkedHome
    }

    private enum CodingKeys: String, CodingKey {
        case linkedHome
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictProviderCodingKey.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        guard keys.isSubset(of: [CodingKeys.linkedHome.rawValue]) else {
            throw ProfileProviderConfigurationError.invalidTaggedShape
        }
        linkedHome = try container.decodeIfPresent(
            CanonicalCodexHome.self,
            forKey: StrictProviderCodingKey(CodingKeys.linkedHome.rawValue)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictProviderCodingKey.self)
        try container.encodeIfPresent(
            linkedHome,
            forKey: StrictProviderCodingKey(CodingKeys.linkedHome.rawValue)
        )
    }
}

enum ProfileProviderConfiguration: Codable, Equatable {
    case claude
    case codex(CodexProfileConfiguration)

    var kind: ProfileProviderKind {
        switch self {
        case .claude:
            return .claude
        case .codex:
            return .codex
        }
    }

    var codexConfiguration: CodexProfileConfiguration? {
        guard case .codex(let configuration) = self else {
            return nil
        }
        return configuration
    }

    private enum CodingKeys: String {
        case kind
        case codex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StrictProviderCodingKey.self)
        let keys = Set(container.allKeys.map(\.stringValue))
        let kindKey = StrictProviderCodingKey(CodingKeys.kind.rawValue)
        let kind = try container.decode(ProfileProviderKind.self, forKey: kindKey)

        switch kind {
        case .claude:
            guard keys == [CodingKeys.kind.rawValue] else {
                throw ProfileProviderConfigurationError.invalidTaggedShape
            }
            self = .claude
        case .codex:
            guard keys == [
                CodingKeys.kind.rawValue,
                CodingKeys.codex.rawValue
            ] else {
                throw ProfileProviderConfigurationError.invalidTaggedShape
            }
            self = .codex(
                try container.decode(
                    CodexProfileConfiguration.self,
                    forKey: StrictProviderCodingKey(CodingKeys.codex.rawValue)
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StrictProviderCodingKey.self)
        try container.encode(
            kind,
            forKey: StrictProviderCodingKey(CodingKeys.kind.rawValue)
        )
        if case .codex(let configuration) = self {
            try container.encode(
                configuration,
                forKey: StrictProviderCodingKey(CodingKeys.codex.rawValue)
            )
        }
    }
}

private struct StrictProviderCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        return nil
    }
}
