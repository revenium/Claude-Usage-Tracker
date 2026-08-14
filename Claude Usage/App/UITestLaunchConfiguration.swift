import Foundation
import Darwin

/// Pure, side-effect-free parsing for the native UI automation launch contract.
///
/// The parser is compiled into every configuration so the contract can be unit
/// tested. The application bootstrap that consumes an enabled configuration is
/// compiled only when `UI_TESTING` is set by the dedicated build configuration.
nonisolated struct UITestLaunchConfiguration: Equatable, Sendable {
    enum Seed: String, CaseIterable, Sendable {
        case firstRun = "first-run"
        case linkedCodex = "linked-codex"
        case mixedProviders = "mixed-providers"
    }

    enum Surface: String, CaseIterable, Sendable {
        case setup
        case account
        case profiles
        case settings
        case history
        case popover
        case menuStatus = "menu-status"
    }

    enum Evaluation: Equatable, Sendable {
        case disabled
        case rejected(String)
        case enabled(UITestLaunchConfiguration)
    }

    static let launchArgument = "--ui-testing"
    static let environmentGate = "UI_TESTING"
    static let rootEnvironmentKey = "UI_TEST_ROOT"
    static let sessionEnvironmentKey = "UI_TEST_SESSION_ID"
    static let homeEnvironmentKey = "UI_TEST_CODEX_HOME"
    static let seedEnvironmentKey = "UI_TEST_SEED"
    static let surfaceEnvironmentKey = "UI_TEST_SURFACE"
    static let localeEnvironmentKey = "UI_TEST_LOCALE"
    static let uiTestRunnerBundleIdentifier =
        "com.revenium.RevvyTachUITests.xctrunner"

    static let supportedLocales = [
        "en", "de", "es", "fr", "it", "ja", "ko", "pt", "zh-Hans"
    ]

    let rootURL: URL
    let sessionID: String
    let codexHomeURL: URL?
    let seed: Seed
    let surface: Surface
    let locale: String

    static func evaluate(
        arguments: [String],
        environment: [String: String],
        compilationEnabled: Bool,
        runnerTemporaryAnchorURL: URL? =
            uiTestRunnerTemporaryAnchorURL()
    ) -> Evaluation {
        let hasArgument = arguments.contains(launchArgument)
        let hasEnvironmentGate =
            environment[environmentGate] == "1"

        guard compilationEnabled else {
            return hasArgument || hasEnvironmentGate
                ? .rejected("UI automation is unavailable in this build.")
                : .disabled
        }

        // A UI-testing binary never falls through to production startup when
        // one half of the explicit runtime gate is missing.
        guard hasArgument, hasEnvironmentGate else {
            return .rejected(
                "UI automation requires both UI_TESTING=1 and --ui-testing."
            )
        }

        guard arguments.filter({ $0 == launchArgument }).count == 1 else {
            return .rejected(
                "The --ui-testing launch argument must appear exactly once."
            )
        }

        guard let runnerTemporaryAnchorURL,
              let temporaryRoot = canonicalExistingDirectory(
                runnerTemporaryAnchorURL
              ),
              let root = validatedFixtureRoot(
                  environment[rootEnvironmentKey],
                  temporaryRoot: temporaryRoot
              ) else {
            return .rejected(
                "UI_TEST_ROOT must be an absolute child of the temporary directory."
            )
        }

        guard let sessionID = environment[sessionEnvironmentKey],
              isSafeSessionID(sessionID) else {
            return .rejected(
                "UI_TEST_SESSION_ID must contain only letters, numbers, dots, dashes, or underscores."
            )
        }

        guard let rawSeed = environment[seedEnvironmentKey],
              let seed = Seed(rawValue: rawSeed) else {
            return .rejected("UI_TEST_SEED is missing or unsupported.")
        }
        guard let rawSurface = environment[surfaceEnvironmentKey],
              let surface = Surface(rawValue: rawSurface) else {
            return .rejected("UI_TEST_SURFACE is missing or unsupported.")
        }
        let locale = environment[localeEnvironmentKey] ?? "en"
        guard supportedLocales.contains(locale) else {
            return .rejected("UI_TEST_LOCALE is unsupported.")
        }

        let requiresHome = seed != .firstRun
        let rawHome = environment[homeEnvironmentKey]
        let home = validatedTemporaryDirectory(
            rawHome,
            temporaryRoot: temporaryRoot
        )
        guard rawHome == nil || home != nil,
              !requiresHome || home != nil else {
            return .rejected(
                "Linked UI-test seeds require UI_TEST_CODEX_HOME inside the temporary directory."
            )
        }
        if let home, !isStrictDescendant(home, of: root) {
            return .rejected(
                "UI_TEST_CODEX_HOME must be contained by UI_TEST_ROOT."
            )
        }

        return .enabled(
            UITestLaunchConfiguration(
                rootURL: root,
                sessionID: sessionID,
                codexHomeURL: home,
                seed: seed,
                surface: surface,
                locale: locale
            )
        )
    }

    private static func validatedFixtureRoot(
        _ rawPath: String?,
        temporaryRoot: URL
    ) -> URL? {
        guard let candidate = validatedTemporaryDirectory(
            rawPath,
            temporaryRoot: temporaryRoot
        ) else {
            return nil
        }
        let prefix = "claude-usage-ui-"
        let name = candidate.lastPathComponent
        guard name.hasPrefix(prefix) else {
            return nil
        }
        let rawUUID = String(name.dropFirst(prefix.count))
        guard rawUUID.count == 36,
              let uuid = UUID(uuidString: rawUUID),
              uuid.uuidString.caseInsensitiveCompare(rawUUID)
                == .orderedSame else {
            return nil
        }
        return candidate
    }

    private static func validatedTemporaryDirectory(
        _ rawPath: String?,
        temporaryRoot: URL
    ) -> URL? {
        guard let rawPath, !rawPath.isEmpty, rawPath.hasPrefix("/") else {
            return nil
        }
        let candidate = URL(
            fileURLWithPath: rawPath,
            isDirectory: true
        )
        .standardizedFileURL
        .resolvingSymlinksInPath()
        guard isStrictDescendant(candidate, of: temporaryRoot),
              isExistingDirectory(candidate) else {
            return nil
        }
        return candidate
    }

    /// Derives the exact sandbox temporary anchor assigned to the dedicated
    /// XCUITest runner. Production derivation never trusts HOME,
    /// `NSHomeDirectory()`, or a process-specific temporary directory.
    static func uiTestRunnerTemporaryAnchorURL() -> URL? {
        guard let userHomeURL = currentUserHomeDirectoryURL() else {
            return nil
        }
        return uiTestRunnerTemporaryAnchorURL(
            userHomeDirectoryURL: userHomeURL
        )
    }

    static func uiTestRunnerTemporaryAnchorURL(
        userHomeDirectoryURL: URL
    ) -> URL? {
        guard userHomeDirectoryURL.isFileURL,
              userHomeDirectoryURL.path.hasPrefix("/") else {
            return nil
        }
        return canonicalURL(userHomeDirectoryURL)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent(
                uiTestRunnerBundleIdentifier,
                isDirectory: true
            )
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private static func currentUserHomeDirectoryURL() -> URL? {
        let maximumBufferSize = 1_048_576
        let fallbackBufferSize = 16_384
        let configuredSize = sysconf(_SC_GETPW_R_SIZE_MAX)
        let initialBufferSize: Int
        if configuredSize > 0 {
            guard configuredSize <= maximumBufferSize else {
                return nil
            }
            initialBufferSize = Int(configuredSize)
        } else {
            initialBufferSize = fallbackBufferSize
        }

        var bufferSize = initialBufferSize
        while bufferSize <= maximumBufferSize {
            var record = passwd()
            var result: UnsafeMutablePointer<passwd>?
            var buffer = [CChar](
                repeating: 0,
                count: bufferSize
            )
            let lookup = buffer.withUnsafeMutableBufferPointer {
                pointer -> (status: Int32, homePath: String?) in
                guard let baseAddress = pointer.baseAddress else {
                    return (EINVAL, nil)
                }
                let status = getpwuid_r(
                    getuid(),
                    &record,
                    baseAddress,
                    pointer.count,
                    &result
                )
                guard status == 0,
                      result != nil,
                      let directory = record.pw_dir else {
                    return (status, nil)
                }
                return (
                    status,
                    String(validatingCString: directory)
                )
            }
            if lookup.status == 0 {
                guard let homePath = lookup.homePath,
                      homePath.hasPrefix("/") else {
                    return nil
                }
                return URL(
                    fileURLWithPath: homePath,
                    isDirectory: true
                )
            }
            guard lookup.status == ERANGE,
                  bufferSize < maximumBufferSize else {
                return nil
            }
            bufferSize = min(
                bufferSize * 2,
                maximumBufferSize
            )
        }
        return nil
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func canonicalExistingDirectory(
        _ url: URL
    ) -> URL? {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            return nil
        }
        let canonical = canonicalURL(url)
        return isExistingDirectory(canonical) ? canonical : nil
    }

    private static func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    private static func isStrictDescendant(
        _ candidate: URL,
        of root: URL
    ) -> Bool {
        let candidateComponents = candidate.pathComponents
        let rootComponents = root.pathComponents
        guard candidateComponents.count > rootComponents.count else {
            return false
        }
        return candidateComponents
            .prefix(rootComponents.count)
            .elementsEqual(rootComponents)
    }

    private static func isSafeSessionID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 80 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || $0 == "."
                || $0 == "-"
                || $0 == "_"
        }
    }
}
