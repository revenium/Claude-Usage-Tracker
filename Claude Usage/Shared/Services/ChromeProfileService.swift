import AppKit
import Darwin
import Foundation
import Security

/// The intentionally small, non-sensitive representation of a Chrome profile.
/// Values such as GAIA IDs, avatars, and account emails are never retained.
nonisolated struct ChromeProfile: Equatable, Sendable {
    let name: String
    let directoryName: String

    var label: String {
        "\(name) — \(directoryName)"
    }
}

nonisolated struct ChromeProfileFileMetadata: Equatable, Sendable {
    let exists: Bool
    let isRegularFile: Bool
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let ownerUserID: UInt32?
    let size: Int?

    static let missing = Self(
        exists: false,
        isRegularFile: false,
        isDirectory: false,
        isSymbolicLink: false,
        ownerUserID: nil,
        size: nil
    )
}

/// Filesystem boundary for profile discovery. It is deliberately narrower than
/// FileManager: production reads only Chrome's `Local State` file and performs
/// metadata checks on direct children of its user-data directory.
nonisolated struct ChromeProfileFilesystem: Sendable {
    let metadata: @Sendable (URL) -> ChromeProfileFileMetadata
    let readData: @Sendable (URL) throws -> Data
    let currentUserID: @Sendable () -> UInt32

    static let live = Self(
        metadata: { url in
            let manager = FileManager.default
            guard let attributes = try? manager.attributesOfItem(
                atPath: url.path
            ) else {
                return .missing
            }
            let type = attributes[.type] as? FileAttributeType
            let owner = (attributes[.ownerAccountID] as? NSNumber)
                .map { $0.uint32Value }
            let size = (attributes[.size] as? NSNumber).map { $0.intValue }
            return ChromeProfileFileMetadata(
                exists: true,
                isRegularFile: type == .typeRegular,
                isDirectory: type == .typeDirectory,
                isSymbolicLink: type == .typeSymbolicLink
                    || (try? manager.destinationOfSymbolicLink(
                        atPath: url.path
                    )) != nil,
                ownerUserID: owner,
                size: size
            )
        },
        readData: { url in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try handle.read(
                upToCount: 5 * 1024 * 1024 + 1
            ) ?? Data()
        },
        currentUserID: { UInt32(getuid()) }
    )
}

/// Parses Chrome's `Local State` profile cache without persisting any account
/// identity data. Failure is intentionally represented as no available profiles.
nonisolated struct ChromeProfileDiscoverer: Sendable {
    static let maximumLocalStateSize = 5 * 1024 * 1024

    private let userDataDirectory: URL
    private let filesystem: ChromeProfileFilesystem

    init(
        userDataDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Google/Chrome",
                isDirectory: true
            ),
        filesystem: ChromeProfileFilesystem = .live
    ) {
        self.userDataDirectory = userDataDirectory
        self.filesystem = filesystem
    }

    func discoverProfiles() -> [ChromeProfile] {
        let localState = userDataDirectory.appendingPathComponent(
            "Local State",
            isDirectory: false
        )
        guard isSafeUserDataDirectory(),
              isSafeLocalState(localState),
              let data = try? filesystem.readData(localState),
              data.count <= Self.maximumLocalStateSize,
              isSafeLocalState(localState),
              let root = try? JSONSerialization.jsonObject(
                with: data,
                options: []
              ) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else {
            return []
        }

        return cache.compactMap { directoryName, rawMetadata in
            guard ChromeProfilePathPolicy.isValidDirectoryName(directoryName),
                  let metadata = rawMetadata as? [String: Any],
                  !isExcluded(directoryName, metadata: metadata),
                  let rawName = metadata["name"] as? String,
                  let name = Self.sanitizedName(rawName),
                  isSafeProfileDirectory(directoryName) else {
                return nil
            }
            return ChromeProfile(name: name, directoryName: directoryName)
        }
        .sorted {
            if $0.name == $1.name {
                return $0.directoryName < $1.directoryName
            }
            return $0.name < $1.name
        }
    }

    func isSafeProfileDirectory(_ directoryName: String) -> Bool {
        guard isSafeUserDataDirectory(),
              ChromeProfilePathPolicy.isValidDirectoryName(directoryName) else {
            return false
        }
        let metadata = filesystem.metadata(
            userDataDirectory.appendingPathComponent(
                directoryName,
                isDirectory: true
            )
        )
        return metadata.exists && metadata.isDirectory
            && !metadata.isSymbolicLink
            && metadata.ownerUserID == filesystem.currentUserID()
    }

    private func isSafeUserDataDirectory() -> Bool {
        let metadata = filesystem.metadata(userDataDirectory)
        return metadata.exists && metadata.isDirectory
            && !metadata.isSymbolicLink
            && metadata.ownerUserID == filesystem.currentUserID()
    }

    private func isSafeLocalState(_ url: URL) -> Bool {
        let metadata = filesystem.metadata(url)
        return metadata.exists && metadata.isRegularFile
            && !metadata.isSymbolicLink
            && metadata.ownerUserID == filesystem.currentUserID()
            && (metadata.size ?? Self.maximumLocalStateSize + 1)
                <= Self.maximumLocalStateSize
    }

    private func isExcluded(
        _ directoryName: String,
        metadata: [String: Any]
    ) -> Bool {
        directoryName == "Guest Profile"
            || directoryName == "System Profile"
            || metadata["is_ephemeral"] as? Bool == true
            || metadata["is_omitted_from_profile_list"] as? Bool == true
    }

    private static func sanitizedName(_ value: String) -> String? {
        let cleaned = value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                ? " " : String(scalar)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return nil
        }
        return String(cleaned.prefix(256))
    }
}

/// Pure policy used both by the launcher and focused tests.
nonisolated enum ChromeProfileLaunchPolicy {
    static let destination = "https://claude.ai/"

    static func arguments(for directoryName: String) -> [String]? {
        guard ChromeProfilePathPolicy.isValidDirectoryName(directoryName) else {
            return nil
        }
        return [
            "--profile-directory=\(directoryName)",
            "--ignore-profile-directory-if-not-exists",
            "--new-window",
            destination,
        ]
    }
}

nonisolated enum ChromeProfilePathPolicy {
    static func isValidDirectoryName(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 255
            && value != "."
            && value != ".."
            && !value.hasPrefix("/")
            && !value.contains("/")
            && !value.contains("\\")
            && !value.unicodeScalars.contains(where: {
                $0 == "\0"
                    || CharacterSet.controlCharacters.contains($0)
            })
    }
}

nonisolated struct ChromeApplication: Equatable, Sendable {
    let url: URL
    let bundleIdentifier: String?
}

nonisolated struct ChromeCodeSignature: Equatable, Sendable {
    let bundleIdentifier: String?
    let teamIdentifier: String?
    let satisfiesTrustedRequirement: Bool
}

/// Configuration represented separately so tests can assert the exact launch
/// contract without constructing or opening a real NSWorkspace application.
nonisolated struct ChromeWorkspaceLaunchRequest: Equatable, Sendable {
    let arguments: [String]
    let activates: Bool
    let createsNewApplicationInstance: Bool
    let allowsRunningApplicationSubstitution: Bool
}

/// Validates the selected direct Chrome profile child and a freshly resolved
/// Chrome stable application immediately before handing off to NSWorkspace.
nonisolated struct ChromeProfileLauncher: Sendable {
    static let chromeBundleIdentifier = "com.google.Chrome"
    static let chromeTeamIdentifier = "EQHXZ8M8AV"
    static let chromeCodeRequirement = """
        anchor apple generic
        and identifier "com.google.Chrome"
        and certificate 1[field.1.2.840.113635.100.6.2.6] exists
        and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
        and certificate leaf[subject.OU] = "EQHXZ8M8AV"
        """
    static let signatureValidationFlags = SecCSFlags(
        rawValue: kSecCSCheckAllArchitectures
    )

    typealias ApplicationResolver = @Sendable (String) -> ChromeApplication?
    typealias SignatureVerifier = @Sendable (URL) -> ChromeCodeSignature?
    typealias WorkspaceLauncher = @Sendable (
        URL,
        ChromeWorkspaceLaunchRequest
    ) async -> Bool

    private let discoverer: ChromeProfileDiscoverer
    private let applicationResolver: ApplicationResolver
    private let signatureVerifier: SignatureVerifier
    private let workspaceLauncher: WorkspaceLauncher

    init(
        discoverer: ChromeProfileDiscoverer,
        applicationResolver: @escaping ApplicationResolver =
            ChromeProfileLauncher.resolveChromeApplication,
        signatureVerifier: @escaping SignatureVerifier =
            ChromeProfileLauncher.verifyChromeSignature,
        workspaceLauncher: @escaping WorkspaceLauncher =
            ChromeProfileLauncher.openInWorkspace
    ) {
        self.discoverer = discoverer
        self.applicationResolver = applicationResolver
        self.signatureVerifier = signatureVerifier
        self.workspaceLauncher = workspaceLauncher
    }

    @discardableResult
    func launch(profile: ChromeProfile) async -> Bool {
        guard let arguments = ChromeProfileLaunchPolicy.arguments(
            for: profile.directoryName
        ), discoverer.isSafeProfileDirectory(profile.directoryName),
              let application = applicationResolver(
                Self.chromeBundleIdentifier
              ), application.bundleIdentifier == Self.chromeBundleIdentifier,
              let signature = signatureVerifier(application.url),
              signature.satisfiesTrustedRequirement,
              signature.bundleIdentifier == Self.chromeBundleIdentifier,
              signature.teamIdentifier == Self.chromeTeamIdentifier else {
            return false
        }

        return await workspaceLauncher(
            application.url,
            ChromeWorkspaceLaunchRequest(
                arguments: arguments,
                activates: true,
                createsNewApplicationInstance: true,
                allowsRunningApplicationSubstitution: false
            )
        )
    }

    private static func resolveChromeApplication(
        bundleIdentifier: String
    ) -> ChromeApplication? {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else {
            return nil
        }
        return ChromeApplication(
            url: url,
            bundleIdentifier: Bundle(url: url)?.bundleIdentifier
        )
    }

    private static func verifyChromeSignature(
        at url: URL
    ) -> ChromeCodeSignature? {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            Self.chromeCodeRequirement as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess, let requirement else {
            return nil
        }
        guard SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(),
            &code
        ) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(
                code,
                Self.signatureValidationFlags,
                requirement
              )
                == errSecSuccess else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(),
            &information
        ) == errSecSuccess,
              let values = information as? [String: Any] else {
            return nil
        }
        return ChromeCodeSignature(
            bundleIdentifier: values[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: values[kSecCodeInfoTeamIdentifier as String] as? String,
            satisfiesTrustedRequirement: true
        )
    }

    private static func openInWorkspace(
        applicationURL: URL,
        request: ChromeWorkspaceLaunchRequest
    ) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = request.arguments
        configuration.activates = request.activates
        configuration.createsNewApplicationInstance =
            request.createsNewApplicationInstance
        configuration.allowsRunningApplicationSubstitution =
            request.allowsRunningApplicationSubstitution
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { application, error in
                continuation.resume(
                    returning: application != nil && error == nil
                )
            }
        }
    }
}
