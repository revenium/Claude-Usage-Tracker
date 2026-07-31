import XCTest
@testable import Claude_Usage

final class UITestLaunchConfigurationTests: XCTestCase {
    private let rootID = UUID()
    private let runnerDirectoryID = UUID()

    private var processTemporaryDirectory: URL {
        FileManager.default.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private var testDirectory: URL {
        processTemporaryDirectory.appendingPathComponent(
            "ui-root-contract-\(runnerDirectoryID.uuidString)",
            isDirectory: true
        )
    }

    private var injectedRunnerAnchor: URL {
        testDirectory.appendingPathComponent(
            "runner-container-tmp",
            isDirectory: true
        )
    }

    private var runnerTemporaryDirectory: URL {
        injectedRunnerAnchor.appendingPathComponent(
            "process-temporary-directory",
            isDirectory: true
        )
    }

    private var temporaryRoot: URL {
        runnerTemporaryDirectory.appendingPathComponent(
            "claude-usage-ui-\(rootID.uuidString)",
            isDirectory: true
        )
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(
            at: temporaryRoot.appendingPathComponent(
                "codex-home",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(
            at: testDirectory
        )
        try super.tearDownWithError()
    }

    func testRequiresCompileTimeGate() {
        let result = UITestLaunchConfiguration.evaluate(
            arguments: ["Claude Usage", "--ui-testing"],
            environment: validEnvironment(),
            compilationEnabled: false,
            runnerTemporaryAnchorURL: nil
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
                runnerTemporaryAnchorURL: nil
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
            evaluateWithInjectedAnchor(environment),
            .rejected(
                "UI_TEST_ROOT must be an absolute child of the temporary directory."
            )
        )
    }

    func testInjectedAnchorAcceptsNestedRunnerTemporaryFixture() {
        let result = UITestLaunchConfiguration.evaluate(
            arguments: ["Claude Usage", "--ui-testing"],
            environment: validEnvironment(),
            compilationEnabled: true,
            runnerTemporaryAnchorURL: injectedRunnerAnchor
        )

        guard case .enabled(let configuration) = result else {
            return XCTFail(
                "Expected the nested runner fixture to parse."
            )
        }
        XCTAssertGreaterThan(
            temporaryRoot.pathComponents.count,
            injectedRunnerAnchor.pathComponents.count + 1
        )
        XCTAssertEqual(
            configuration.rootURL.pathComponents,
            temporaryRoot.pathComponents
        )
    }

    func testUnavailableRunnerAnchorFailsClosed() {
        XCTAssertEqual(
            UITestLaunchConfiguration.evaluate(
                arguments: ["Claude Usage", "--ui-testing"],
                environment: validEnvironment(),
                compilationEnabled: true,
                runnerTemporaryAnchorURL: nil
            ),
            .rejected(
                "UI_TEST_ROOT must be an absolute child of the temporary directory."
            )
        )
    }

    func testInvalidRunnerAnchorFailsClosed() throws {
        let invalidAnchor = temporaryRoot.appendingPathComponent(
            "not-a-directory",
            isDirectory: false
        )
        try Data("invalid".utf8).write(to: invalidAnchor)

        XCTAssertEqual(
            UITestLaunchConfiguration.evaluate(
                arguments: ["Claude Usage", "--ui-testing"],
                environment: validEnvironment(),
                compilationEnabled: true,
                runnerTemporaryAnchorURL: invalidAnchor
            ),
            .rejected(
                "UI_TEST_ROOT must be an absolute child of the temporary directory."
            )
        )
    }

    func testRunnerAnchorDerivationUsesExactContainerPath() {
        let fakeUserHome = testDirectory.appendingPathComponent(
            "users/example",
            isDirectory: true
        )
        let result = UITestLaunchConfiguration
            .uiTestRunnerTemporaryAnchorURL(
                userHomeDirectoryURL: fakeUserHome
            )
        let expected = fakeUserHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent(
                "com.revenium.Claude-UsageUITests.xctrunner",
                isDirectory: true
            )
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)

        XCTAssertEqual(
            result?.pathComponents,
            expected.pathComponents
        )
    }

    func testReturnsCanonicalURLsWithoutTrailingSlashSensitivity() {
        var environment = validEnvironment()
        environment[UITestLaunchConfiguration.rootEnvironmentKey] =
            temporaryRoot.path + "/"
        environment[UITestLaunchConfiguration.homeEnvironmentKey] =
            temporaryRoot.appendingPathComponent(
                "codex-home",
                isDirectory: true
            ).path + "/"

        let result = evaluateWithInjectedAnchor(environment)

        guard case .enabled(let configuration) = result else {
            return XCTFail(
                "Expected trailing slashes to canonicalize."
            )
        }
        XCTAssertEqual(
            configuration.rootURL.pathComponents,
            temporaryRoot.pathComponents
        )
        XCTAssertEqual(
            configuration.codexHomeURL?.pathComponents,
            temporaryRoot.appendingPathComponent(
                "codex-home",
                isDirectory: true
            ).pathComponents
        )
    }

    func testRejectsRelativeRoot() {
        var environment = validEnvironment()
        environment[UITestLaunchConfiguration.rootEnvironmentKey] =
            "claude-usage-ui-\(UUID().uuidString)"

        XCTAssertEqual(
            evaluateWithInjectedAnchor(environment),
            .rejected(
                "UI_TEST_ROOT must be an absolute child of the temporary directory."
            )
        )
    }

    func testRejectsRunnerAnchorEquality() {
        var environment = validEnvironment()
        environment[UITestLaunchConfiguration.rootEnvironmentKey] =
            injectedRunnerAnchor.path

        XCTAssertEqual(
            evaluateWithInjectedAnchor(environment),
            .rejected(
                "UI_TEST_ROOT must be an absolute child of the temporary directory."
            )
        )
    }

    func testRejectsRunnerAnchorSibling() throws {
        let sibling = testDirectory.appendingPathComponent(
            "claude-usage-ui-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sibling,
            withIntermediateDirectories: true
        )
        var environment = validEnvironment()
        environment[UITestLaunchConfiguration.rootEnvironmentKey] =
            sibling.path

        XCTAssertEqual(
            evaluateWithInjectedAnchor(environment),
            .rejected(
                "UI_TEST_ROOT must be an absolute child of the temporary directory."
            )
        )
    }

    func testRejectsDotDotEscapeFromRunnerAnchor() throws {
        let escapedRoot = testDirectory.appendingPathComponent(
            "claude-usage-ui-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: escapedRoot,
            withIntermediateDirectories: true
        )
        var environment = validEnvironment()
        environment[UITestLaunchConfiguration.rootEnvironmentKey] =
            injectedRunnerAnchor.path
            + "/nested/../../\(escapedRoot.lastPathComponent)"

        XCTAssertEqual(
            evaluateWithInjectedAnchor(environment),
            .rejected(
                "UI_TEST_ROOT must be an absolute child of the temporary directory."
            )
        )
    }

    func testRejectsNestedFixtureWithInvalidUUIDName() throws {
        let invalidRoot = runnerTemporaryDirectory
            .appendingPathComponent(
                "claude-usage-ui-not-a-uuid",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: invalidRoot,
            withIntermediateDirectories: true
        )
        var environment = validEnvironment()
        environment[UITestLaunchConfiguration.rootEnvironmentKey] =
            invalidRoot.path

        XCTAssertEqual(
            evaluateWithInjectedAnchor(environment),
            .rejected(
                "UI_TEST_ROOT must be an absolute child of the temporary directory."
            )
        )
    }

    func testRejectsMissingFixtureRoot() {
        let missingRoot = runnerTemporaryDirectory
            .appendingPathComponent(
                "claude-usage-ui-\(UUID().uuidString)",
                isDirectory: true
            )
        var environment = validEnvironment()
        environment[UITestLaunchConfiguration.rootEnvironmentKey] =
            missingRoot.path

        XCTAssertEqual(
            evaluateWithInjectedAnchor(environment),
            .rejected(
                "UI_TEST_ROOT must be an absolute child of the temporary directory."
            )
        )
    }

    func testRejectsSymlinkReRootedOutsideRunnerAnchor() throws {
        let escapedRoot = runnerTemporaryDirectory
            .appendingPathComponent(
                "claude-usage-ui-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createSymbolicLink(
            at: escapedRoot,
            withDestinationURL: URL(
                fileURLWithPath: "/Users",
                isDirectory: true
            )
        )
        var environment = validEnvironment()
        environment[UITestLaunchConfiguration.rootEnvironmentKey] =
            escapedRoot.path

        XCTAssertEqual(
            evaluateWithInjectedAnchor(environment),
            .rejected(
                "UI_TEST_ROOT must be an absolute child of the temporary directory."
            )
        )
    }

    func testRejectsLinkedHomeOutsideIsolatedRoot() throws {
        let outsideHome = runnerTemporaryDirectory
            .appendingPathComponent(
                "outside-home-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: outsideHome,
            withIntermediateDirectories: true
        )
        var environment = validEnvironment()
        environment[UITestLaunchConfiguration.homeEnvironmentKey] =
            outsideHome.path

        XCTAssertEqual(
            evaluateWithInjectedAnchor(environment),
            .rejected(
                "UI_TEST_CODEX_HOME must be contained by UI_TEST_ROOT."
            )
        )
    }

    func testRejectsLinkedHomeEqualToIsolatedRoot() {
        var environment = validEnvironment()
        environment[UITestLaunchConfiguration.homeEnvironmentKey] =
            temporaryRoot.path

        XCTAssertEqual(
            evaluateWithInjectedAnchor(environment),
            .rejected(
                "UI_TEST_CODEX_HOME must be contained by UI_TEST_ROOT."
            )
        )
    }

    func testRejectsMissingLinkedHome() {
        var environment = validEnvironment()
        environment[UITestLaunchConfiguration.homeEnvironmentKey] =
            temporaryRoot.appendingPathComponent(
                "missing-home",
                isDirectory: true
            ).path

        XCTAssertEqual(
            evaluateWithInjectedAnchor(environment),
            .rejected(
                "Linked UI-test seeds require UI_TEST_CODEX_HOME inside the temporary directory."
            )
        )
    }

    func testRejectsLinkedHomeSymlinkEscapingRunnerAnchor() throws {
        let escapedHome = temporaryRoot.appendingPathComponent(
            "escaped-home",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: escapedHome,
            withDestinationURL: URL(
                fileURLWithPath: "/Users",
                isDirectory: true
            )
        )
        var environment = validEnvironment()
        environment[UITestLaunchConfiguration.homeEnvironmentKey] =
            escapedHome.path

        XCTAssertEqual(
            evaluateWithInjectedAnchor(environment),
            .rejected(
                "Linked UI-test seeds require UI_TEST_CODEX_HOME inside the temporary directory."
            )
        )
    }

    func testParsesSupportedIsolatedConfiguration() {
        let result = evaluateWithInjectedAnchor(
            validEnvironment()
        )

        guard case .enabled(let configuration) = result else {
            return XCTFail("Expected the isolated configuration to parse.")
        }
        XCTAssertEqual(
            configuration.rootURL.pathComponents,
            temporaryRoot.pathComponents
        )
        XCTAssertEqual(configuration.sessionID, "session-01")
        XCTAssertEqual(
            configuration.codexHomeURL?.pathComponents,
            temporaryRoot.appendingPathComponent(
                "codex-home",
                isDirectory: true
            ).pathComponents
        )
        XCTAssertEqual(configuration.seed, .linkedCodex)
        XCTAssertEqual(configuration.surface, .account)
        XCTAssertEqual(configuration.locale, "de")
    }

    func testParsesMenuStatusSurface() {
        var environment = validEnvironment()
        environment[
            UITestLaunchConfiguration.surfaceEnvironmentKey
        ] = UITestLaunchConfiguration.Surface.menuStatus.rawValue

        let result = evaluateWithInjectedAnchor(environment)

        guard case .enabled(let configuration) = result else {
            return XCTFail("Expected the menu-status surface to parse.")
        }
        XCTAssertEqual(configuration.surface, .menuStatus)
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

    private func evaluateWithInjectedAnchor(
        _ environment: [String: String]
    ) -> UITestLaunchConfiguration.Evaluation {
        UITestLaunchConfiguration.evaluate(
            arguments: ["Claude Usage", "--ui-testing"],
            environment: environment,
            compilationEnabled: true,
            runnerTemporaryAnchorURL: injectedRunnerAnchor
        )
    }
}
