import Foundation

/// A physical CODEX_HOME path verified at link time. The unchecked factory is
/// same-file private so app callers cannot bypass canonicalization; Codable
/// decoding accepts a previously verified path even while it is offline.
struct CanonicalCodexHome: Codable, Equatable, Hashable {
    let path: String

    fileprivate init(verifiedPath: String) {
        path = verifiedPath
    }

    private enum CodingKeys: String, CodingKey {
        case path
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CanonicalCodingKey.self
        )
        guard Set(container.allKeys.map(\.stringValue))
                == [CodingKeys.path.rawValue] else {
            throw ProfileProviderConfigurationError.invalidCanonicalHome
        }
        let value = try container.decode(
            String.self,
            forKey: CanonicalCodingKey(CodingKeys.path.rawValue)
        )
        guard Self.isValidPersistedPath(value) else {
            throw ProfileProviderConfigurationError.invalidCanonicalHome
        }
        path = value
    }

    func encode(to encoder: Encoder) throws {
        guard Self.isValidPersistedPath(path) else {
            throw EncodingError.invalidValue(
                path,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Invalid canonical Codex home"
                )
            )
        }
        var container = encoder.container(keyedBy: CanonicalCodingKey.self)
        try container.encode(
            path,
            forKey: CanonicalCodingKey(CodingKeys.path.rawValue)
        )
    }

    private static func isValidPersistedPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              path != "/",
              path == path.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              !CodexHomeCanonicalizer.containsShellSyntax(path) else {
            return false
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path == path
    }
}

private struct CanonicalCodingKey: CodingKey {
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

enum CodexHomeCanonicalizationError: Error, LocalizedError, Equatable {
    case empty
    case relative
    case root
    case missing
    case notDirectory
    case unsafeCharacters
    case filesystemIdentityUnavailable

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Choose a Codex home directory."
        case .relative:
            return "The Codex home must be an absolute path."
        case .root:
            return "The filesystem root cannot be used as a Codex home."
        case .missing:
            return "The Codex home directory does not exist."
        case .notDirectory:
            return "The Codex home must be a directory."
        case .unsafeCharacters:
            return "The Codex home path contains unsupported characters."
        case .filesystemIdentityUnavailable:
            return "The Codex home filesystem identity could not be verified."
        }
    }
}

struct CodexHomeCanonicalizer {
    private struct Resolution {
        let home: CanonicalCodexHome
        let filesystemIdentity: NSObject
    }

    private let fileManager: FileManager
    private let homeDirectory: URL

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectory =
            homeDirectory ?? fileManager.homeDirectoryForCurrentUser
    }

    func canonicalize(
        _ input: String,
        excludingProfileID: UUID? = nil,
        existingProfiles: [Profile] = []
    ) throws -> CanonicalCodexHome {
        let candidate = try resolve(input)

        for profile in existingProfiles where profile.id != excludingProfileID {
            guard case .codex(let configuration) =
                    profile.providerConfiguration,
                  let existingHome = configuration.linkedHome else {
                continue
            }
            if existingHome == candidate.home {
                throw ProfileProviderConfigurationError
                    .duplicateCodexHome(profile.id)
            }

            // Stored homes are already physical paths. If they are online,
            // compare filesystem identity as a defense against alternate
            // mount/symlink spellings; if offline, exact path comparison above
            // remains available without blocking unrelated metadata edits.
            if let existing = try? resolve(existingHome.path),
               existing.filesystemIdentity.isEqual(
                   candidate.filesystemIdentity
               ) {
                throw ProfileProviderConfigurationError
                    .duplicateCodexHome(profile.id)
            }
        }

        return candidate.home
    }

    private func resolve(_ input: String) throws -> Resolution {
        guard !input.isEmpty else {
            throw CodexHomeCanonicalizationError.empty
        }
        guard input == input.trimmingCharacters(in: .whitespacesAndNewlines),
              !input.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              !Self.containsShellSyntax(input) else {
            throw CodexHomeCanonicalizationError.unsafeCharacters
        }

        let expanded: String
        if input == "~" {
            expanded = homeDirectory.path
        } else if input.hasPrefix("~/") {
            expanded = homeDirectory
                .appendingPathComponent(String(input.dropFirst(2)))
                .path
        } else if input.hasPrefix("~") {
            throw CodexHomeCanonicalizationError.relative
        } else {
            expanded = input
        }

        guard expanded.hasPrefix("/") else {
            throw CodexHomeCanonicalizationError.relative
        }

        let lexicalURL = URL(fileURLWithPath: expanded)
            .standardizedFileURL
        guard lexicalURL.path != "/" else {
            throw CodexHomeCanonicalizationError.root
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: lexicalURL.path,
            isDirectory: &isDirectory
        ) else {
            throw CodexHomeCanonicalizationError.missing
        }
        guard isDirectory.boolValue else {
            throw CodexHomeCanonicalizationError.notDirectory
        }

        let physicalURL = lexicalURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard physicalURL.path != "/" else {
            throw CodexHomeCanonicalizationError.root
        }

        var physicalIsDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: physicalURL.path,
            isDirectory: &physicalIsDirectory
        ) else {
            throw CodexHomeCanonicalizationError.missing
        }
        guard physicalIsDirectory.boolValue else {
            throw CodexHomeCanonicalizationError.notDirectory
        }

        let values = try physicalURL.resourceValues(
            forKeys: [.fileResourceIdentifierKey, .isDirectoryKey]
        )
        guard values.isDirectory == true else {
            throw CodexHomeCanonicalizationError.notDirectory
        }
        guard let identity = values.fileResourceIdentifier as? NSObject else {
            throw CodexHomeCanonicalizationError
                .filesystemIdentityUnavailable
        }

        return Resolution(
            home: CanonicalCodexHome(verifiedPath: physicalURL.path),
            filesystemIdentity: identity
        )
    }

    static func containsShellSyntax(_ path: String) -> Bool {
        path.contains(";")
            || path.contains("|")
            || path.contains("&")
            || path.contains("`")
            || path.contains("$(")
            || path.contains("${")
            || path.contains("<")
            || path.contains(">")
    }
}
