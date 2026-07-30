import XCTest
@testable import Claude_Usage

final class UITestLaunchConfigurationTests: XCTestCase {
    private let temporaryRoot = URL(
        fileURLWithPath: "/tmp/claude-usage-ui-tests",
        isDirectory: true
    )

    func testRequiresCompileTimeGate() {
        let result = UITestLaunchConfiguration.evaluate(
            arguments: ["Claude Usage", "--ui-testing"],
            environment: validEnvironment(),
            compilationEnabled: false,
            temporaryDirectoryURL: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertEqual(
            result,
            .rejected("UI automation is unavailable in this build.")
        )
    }

    func testRequiresBothRuntimeGates() {
        var environment = validEnvironment()
        environment.removeValue(
            forKey: UITestLaunchConfiguration.environmentGate
        )

        XCTAssertEqual(
            UITestLaunchConfiguration.evaluate(
                arguments: ["Claude Usage", "--ui-testing"],
                environment: environment,
                compilationEnabled: true,
                temporaryDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            .rejected(
                "UI automation requires both UI_TESTING=1 and --ui-testing."
            )
        )
    }

    func testRejectsPathsOutsideTemporaryDirectory() {
        var environment = validEnvironment()
        environment[UITestLaunchConfiguration.rootEnvironmentKey] =
            "/Users/example/Library/Application Support/Claude Usage"

        XCTAssertEqual(
            UITestLaunchConfiguration.evaluate(
                arguments: ["Claude Usage", "--ui-testing"],
                environment: environment,
                compilationEnabled: true,
                temporaryDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            .rejected(
                "UI_TEST_ROOT must be an absolute child of the temporary directory."
            )
        )
    }

    func testRejectsLinkedHomeOutsideIsolatedRoot() {
        var environment = validEnvironment()
        environment[UITestLaunchConfiguration.homeEnvironmentKey] =
            "/tmp/another-session/codex-home"

        XCTAssertEqual(
            UITestLaunchConfiguration.evaluate(
                arguments: ["Claude Usage", "--ui-testing"],
                environment: environment,
                compilationEnabled: true,
                temporaryDirectoryURL: URL(fileURLWithPath: "/tmp")
            ),
            .rejected(
                "UI_TEST_CODEX_HOME must be contained by UI_TEST_ROOT."
            )
        )
    }

    func testParsesSupportedIsolatedConfiguration() {
        let result = UITestLaunchConfiguration.evaluate(
            arguments: ["Claude Usage", "--ui-testing"],
            environment: validEnvironment(),
            compilationEnabled: true,
            temporaryDirectoryURL: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertEqual(
            result,
            .enabled(
                UITestLaunchConfiguration(
                    rootURL: temporaryRoot,
                    sessionID: "session-01",
                    codexHomeURL: temporaryRoot.appendingPathComponent(
                        "codex-home",
                        isDirectory: true
                    ),
                    seed: .linkedCodex,
                    surface: .account,
                    locale: "de"
                )
            )
        )
    }

    private func validEnvironment() -> [String: String] {
        [
            UITestLaunchConfiguration.environmentGate: "1",
            UITestLaunchConfiguration.rootEnvironmentKey:
                temporaryRoot.path,
            UITestLaunchConfiguration.sessionEnvironmentKey: "session-01",
            UITestLaunchConfiguration.homeEnvironmentKey:
                temporaryRoot.appendingPathComponent(
                    "codex-home",
                    isDirectory: true
                ).path,
            UITestLaunchConfiguration.seedEnvironmentKey:
                UITestLaunchConfiguration.Seed.linkedCodex.rawValue,
            UITestLaunchConfiguration.surfaceEnvironmentKey:
                UITestLaunchConfiguration.Surface.account.rawValue,
            UITestLaunchConfiguration.localeEnvironmentKey: "de"
        ]
    }
}
