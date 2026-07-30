import Foundation
import UsageCore
import CodexUsageProvider

/// Process inputs from which a fresh Codex provider/client pair is created.
///
/// The captured value contains no authentication-file data. Authentication
/// remains owned by the linked `CODEX_HOME` and the official Codex process.
nonisolated struct CapturedCodexProviderConfiguration:
    Equatable,
    Sendable
{
    let executableURL: URL
    let codexHomeURL: URL
    let codexHomeIdentity: CodexHomeFilesystemIdentity
}

typealias CodexExecutableResolver =
    @Sendable () throws -> URL
typealias CodexProviderFetchFactory =
    @Sendable (CapturedCodexProviderConfiguration) throws
        -> @Sendable () async throws -> UsageReport

typealias CodexProviderBuilder =
    @Sendable (CodexAppServerClient) -> CodexUsageProvider

/// Product-level availability. Codex remains unavailable in production until
/// the final parity and release-readiness gates pass.
nonisolated struct UsageProviderFeatureAvailability: Equatable, Sendable {
    let codexRefreshEnabled: Bool

    /// Whole-product alias used by setup, settings, and refresh surfaces.
    var codexSupportEnabled: Bool {
        codexRefreshEnabled
    }

    static let production = UsageProviderFeatureAvailability(
        codexRefreshEnabled: false
    )

    static func testing(codexRefreshEnabled: Bool = true) -> Self {
        Self(codexRefreshEnabled: codexRefreshEnabled)
    }
}

/// Safe failures from Codex dependency capture and construction.
///
/// Cases deliberately carry no paths, process arguments, command output, or
/// underlying errors so they are safe to surface in presentation state.
nonisolated enum CodexProviderFactoryError: Error, Equatable, Sendable {
    case featureDisabled
    case homeUnlinked
    case homeUnavailable
    case executableMissing
    case providerConstructionFailed
}

/// Stateless, injectable construction boundary shared by refresh and UI flows.
///
/// Every successful `makeFreshProvider` or `makeFreshFetch` call creates a new
/// app-server client. The factory never reads `auth.json`, invokes a shell, or
/// pools a provider/session between requests.
nonisolated struct CodexProviderFactory: Sendable {
    typealias HomeValidator =
        @Sendable (URL, CodexHomeFilesystemIdentity) -> Bool
    typealias ExecutableValidator = @Sendable (URL) -> Bool

    private let availability: UsageProviderFeatureAvailability
    private let homeValidator: HomeValidator
    private let executableResolver: CodexExecutableResolver
    private let executableValidator: ExecutableValidator
    private let providerBuilder: CodexProviderBuilder
    private let fetchFactory: CodexProviderFetchFactory?

    init(
        availability: UsageProviderFeatureAvailability = .production,
        homeValidator: @escaping HomeValidator =
            CodexProviderFactory.defaultHomeValidator,
        executableResolver: @escaping CodexExecutableResolver = {
            try CodexProviderFactory.resolveExecutable()
        },
        executableValidator: @escaping ExecutableValidator =
            CodexProviderFactory.defaultExecutableValidator,
        providerBuilder: @escaping CodexProviderBuilder = {
            CodexUsageProvider(client: $0)
        },
        fetchFactory: CodexProviderFetchFactory? = nil
    ) {
        self.availability = availability
        self.homeValidator = homeValidator
        self.executableResolver = executableResolver
        self.executableValidator = executableValidator
        self.providerBuilder = providerBuilder
        self.fetchFactory = fetchFactory
    }

    var isEnabled: Bool {
        availability.codexSupportEnabled
    }

    static let capabilities =
        CodexUsageProvider.supportedCapabilities

    var capabilities: ProviderCapabilities {
        Self.capabilities
    }

    /// Resolves and validates one direct absolute executable URL.
    ///
    /// Symlinks are resolved before the URL is returned so downstream process
    /// launch does not depend on a mutable indirection.
    func resolveExecutable() throws -> URL {
        let candidate: URL
        do {
            candidate = try executableResolver()
        } catch {
            throw CodexProviderFactoryError.executableMissing
        }
        let resolved = candidate
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard executableValidator(resolved) else {
            throw CodexProviderFactoryError.executableMissing
        }
        return resolved
    }

    /// Captures validated process inputs from a persisted linked home.
    func capture(
        linkedHome: CanonicalCodexHome?
    ) throws -> CapturedCodexProviderConfiguration {
        guard isEnabled else {
            throw CodexProviderFactoryError.featureDisabled
        }
        guard let linkedHome else {
            throw CodexProviderFactoryError.homeUnlinked
        }
        guard let identity = linkedHome.filesystemIdentity else {
            throw CodexProviderFactoryError.homeUnavailable
        }
        let homeURL = URL(
            fileURLWithPath: linkedHome.path,
            isDirectory: true
        )
        guard homeValidator(homeURL, identity) else {
            throw CodexProviderFactoryError.homeUnavailable
        }
        return CapturedCodexProviderConfiguration(
            executableURL: try resolveExecutable(),
            codexHomeURL: homeURL,
            codexHomeIdentity: identity
        )
    }

    /// Revalidates the persisted physical path and identity without launching.
    func isHomeAvailable(_ linkedHome: CanonicalCodexHome?) -> Bool {
        guard let linkedHome,
              let identity = linkedHome.filesystemIdentity else {
            return false
        }
        return homeValidator(
            URL(
                fileURLWithPath: linkedHome.path,
                isDirectory: true
            ),
            identity
        )
    }

    /// Revalidates already captured inputs immediately before a request.
    func isHomeAvailable(
        _ configuration: CapturedCodexProviderConfiguration
    ) -> Bool {
        homeValidator(
            configuration.codexHomeURL,
            configuration.codexHomeIdentity
        )
    }

    /// Creates a new provider and a new app-server client for this request.
    func makeFreshProvider(
        _ configuration: CapturedCodexProviderConfiguration
    ) throws -> CodexUsageProvider {
        guard isEnabled else {
            throw CodexProviderFactoryError.featureDisabled
        }
        guard isHomeAvailable(configuration) else {
            throw CodexProviderFactoryError.homeUnavailable
        }
        guard executableValidator(configuration.executableURL) else {
            throw CodexProviderFactoryError.executableMissing
        }
        do {
            let processConfiguration = try CodexProcessConfiguration(
                executableURL: configuration.executableURL,
                codexHomeURL: configuration.codexHomeURL,
                expectedCodexHomeIdentity: CodexHomeIdentity(
                    deviceID:
                        configuration.codexHomeIdentity.deviceID,
                    fileID:
                        configuration.codexHomeIdentity.fileID
                )
            )
            return providerBuilder(
                CodexAppServerClient(
                    processConfiguration: processConfiguration
                )
            )
        } catch {
            throw CodexProviderFactoryError.providerConstructionFailed
        }
    }

    /// Creates a request-scoped fetch operation. Injected test fetches follow
    /// the same one-call/one-operation lifecycle as the production provider.
    func makeFreshFetch(
        _ configuration: CapturedCodexProviderConfiguration
    ) throws -> @Sendable () async throws -> UsageReport {
        guard isEnabled else {
            throw CodexProviderFactoryError.featureDisabled
        }
        guard isHomeAvailable(configuration) else {
            throw CodexProviderFactoryError.homeUnavailable
        }
        guard executableValidator(configuration.executableURL) else {
            throw CodexProviderFactoryError.executableMissing
        }
        if let fetchFactory {
            do {
                return try fetchFactory(configuration)
            } catch {
                throw CodexProviderFactoryError.providerConstructionFailed
            }
        }
        let provider = try makeFreshProvider(configuration)
        return {
            try await provider.fetchUsage()
        }
    }

    /// Resolves `codex` using PATH order, followed by common direct-install
    /// locations. Empty and relative PATH entries are ignored.
    static func resolveExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryURL: URL =
            FileManager.default.homeDirectoryForCurrentUser,
        fallbackDirectories: [URL]? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let pathDirectories = environment["PATH"]?
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init) ?? []
        let fallbackDirectories = fallbackDirectories ?? [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            homeDirectoryURL.appendingPathComponent(
                ".local/bin",
                isDirectory: true
            )
        ]

        var visitedDirectories = Set<String>()
        for rawDirectory in pathDirectories {
            guard !rawDirectory.isEmpty,
                  rawDirectory.hasPrefix("/") else {
                continue
            }
            let directory = URL(
                fileURLWithPath: rawDirectory,
                isDirectory: true
            )
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard visitedDirectories.insert(directory.path).inserted,
                  let executable = validatedExecutable(
                    at: directory.appendingPathComponent(
                        "codex",
                        isDirectory: false
                    ),
                    fileManager: fileManager
                  ) else {
                continue
            }
            return executable
        }

        for directoryURL in fallbackDirectories {
            let directory = directoryURL
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard directory.isFileURL,
                  directory.path.hasPrefix("/"),
                  visitedDirectories.insert(directory.path).inserted,
                  let executable = validatedExecutable(
                    at: directory.appendingPathComponent(
                        "codex",
                        isDirectory: false
                    ),
                    fileManager: fileManager
                  ) else {
                continue
            }
            return executable
        }
        throw CodexProviderFactoryError.executableMissing
    }

    private static func validatedExecutable(
        at candidate: URL,
        fileManager: FileManager
    ) -> URL? {
        let resolved = candidate
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard resolved.isFileURL,
              resolved.path.hasPrefix("/"),
              fileManager.fileExists(
                atPath: resolved.path,
                isDirectory: &isDirectory
              ),
              !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: resolved.path) else {
            return nil
        }
        return resolved
    }

    static func defaultHomeValidator(
        _ url: URL,
        expectedIdentity: CodexHomeFilesystemIdentity
    ) -> Bool {
        guard url.isFileURL, url.path.hasPrefix("/"), url.path != "/" else {
            return false
        }
        let lexicalURL = url.standardizedFileURL
        let physicalURL = lexicalURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        // Linked homes are persisted as physical paths. Fail closed if the
        // path is later replaced by a symlink.
        guard lexicalURL.path == url.path,
              physicalURL.path == lexicalURL.path else {
            return false
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: physicalURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return false
        }
        return CodexHomeFilesystemIdentity.read(from: physicalURL)
            == expectedIdentity
    }

    static func defaultExecutableValidator(_ url: URL) -> Bool {
        let resolved = url
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        return resolved.isFileURL
            && resolved.path.hasPrefix("/")
            && FileManager.default.fileExists(
                atPath: resolved.path,
                isDirectory: &isDirectory
            )
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: resolved.path)
    }
}
