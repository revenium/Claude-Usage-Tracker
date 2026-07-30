import Foundation

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

    static let supportedLocales = [
        "en", "de", "es", "fr", "it", "ja", "ko", "pt", "zh-ch"
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
        temporaryDirectoryURL: URL = FileManager.default
            .temporaryDirectory
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

        guard let root = validatedTemporaryDirectory(
            environment[rootEnvironmentKey],
            temporaryDirectoryURL: temporaryDirectoryURL
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
        let home = validatedTemporaryDirectory(
            environment[homeEnvironmentKey],
            temporaryDirectoryURL: temporaryDirectoryURL
        )
        guard !requiresHome || home != nil else {
            return .rejected(
                "Linked UI-test seeds require UI_TEST_CODEX_HOME inside the temporary directory."
            )
        }
        if let home, !home.path.hasPrefix(root.path + "/") {
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

    private static func validatedTemporaryDirectory(
        _ rawPath: String?,
        temporaryDirectoryURL: URL
    ) -> URL? {
        guard let rawPath, !rawPath.isEmpty, rawPath.hasPrefix("/") else {
            return nil
        }
        let candidate = URL(
            fileURLWithPath: rawPath,
            isDirectory: true
        ).standardizedFileURL
        let temporaryRoot = temporaryDirectoryURL.standardizedFileURL
        guard candidate.path != temporaryRoot.path,
              candidate.path.hasPrefix(temporaryRoot.path + "/") else {
            return nil
        }
        return candidate
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
