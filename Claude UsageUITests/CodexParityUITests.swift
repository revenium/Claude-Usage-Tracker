import XCTest

final class CodexParityUITests: XCTestCase {
    private var temporaryRoots: [URL] = []
    private var launchedApplications: [XCUIApplication] = []
    private var lastHomeURL: URL?

    override func tearDownWithError() throws {
        for app in launchedApplications {
            app.terminate()
        }
        launchedApplications.removeAll()
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots.removeAll()
        lastHomeURL = nil
    }

    func testFirstRunProviderChoiceAndCodexHomeVerification() throws {
        let app = try launch(
            seed: "first-run",
            surface: "setup",
            scenario: "provider_current"
        )

        let codexChoice = element(
            app,
            identifier: "setup.provider.codex"
        )
        XCTAssertTrue(codexChoice.waitForExistence(timeout: 5))
        XCTAssertTrue(
            element(app, identifier: "setup.provider.claude").exists
        )
        codexChoice.click()

        let home = element(app, identifier: "codex.home.path")
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        let profileName = element(
            app,
            identifier: "codex.profile.name"
        )
        XCTAssertTrue(profileName.exists)
        profileName.click()
        profileName.typeText("Codex Pro")
        home.click()
        home.typeText(try currentHome(for: app).path)

        let verify = element(app, identifier: "codex.home.link")
        XCTAssertTrue(verify.isEnabled)
        verify.click()

        XCTAssertTrue(
            element(app, identifier: "codex.account.status")
                .waitForExistence(timeout: 8)
        )
        let complete = element(
            app,
            identifier: "codex.setup.start_tracking"
        )
        XCTAssertTrue(complete.waitForExistence(timeout: 3))
        XCTAssertTrue(complete.isEnabled)
        complete.click()
        let activeProfile = element(
            app,
            identifier: "ui-testing.setup.active-codex-profile"
        )
        XCTAssertTrue(activeProfile.waitForExistence(timeout: 8))
        XCTAssertEqual(activeProfile.label, "Codex Pro")
    }

    func testLinkedAccountRefreshUnlinkAndUnsupportedRecovery()
        throws
    {
        var app = try launch(
            seed: "linked-codex",
            surface: "account",
            scenario: "provider_current"
        )
        XCTAssertTrue(
            element(app, identifier: "codex.account.status")
                .waitForExistence(timeout: 8)
        )
        let refresh = element(
            app,
            identifier: "codex.account.refresh"
        )
        XCTAssertTrue(refresh.exists)
        refresh.click()
        XCTAssertTrue(
            element(app, identifier: "codex.home.unlink").exists
        )
        let unlink = element(
            app,
            identifier: "codex.home.unlink"
        )
        unlink.click()
        let cancelUnlink = element(
            app,
            identifier: "codex.home.unlink.cancel"
        )
        XCTAssertTrue(cancelUnlink.waitForExistence(timeout: 3))
        cancelUnlink.click()
        XCTAssertTrue(unlink.waitForExistence(timeout: 3))

        unlink.click()
        let confirmUnlink = element(
            app,
            identifier: "codex.home.unlink.confirm"
        )
        XCTAssertTrue(confirmUnlink.waitForExistence(timeout: 3))
        confirmUnlink.click()
        XCTAssertTrue(
            element(app, identifier: "codex.home.link")
                .waitForExistence(timeout: 5)
        )
        app.terminate()

        app = try launch(
            seed: "linked-codex",
            surface: "account",
            scenario: "provider_api_key"
        )
        XCTAssertTrue(
            element(app, identifier: "codex.account.unsupported")
                .waitForExistence(timeout: 8)
        )
        app.terminate()

        app = try launch(
            seed: "linked-codex",
            surface: "account",
            scenario: "provider_health_rate_rpc_failure"
        )
        XCTAssertTrue(
            element(app, identifier: "codex.account.unavailable")
                .waitForExistence(timeout: 8)
        )
        let errorRefresh = element(
            app,
            identifier: "codex.account.refresh"
        )
        XCTAssertTrue(errorRefresh.isEnabled)
        errorRefresh.click()
        XCTAssertTrue(
            element(app, identifier: "codex.account.unavailable")
                .waitForExistence(timeout: 8)
        )
    }

    func testDeviceCodeLoginCanStartAndCancelWithoutBrowser()
        throws
    {
        let app = try launch(
            seed: "linked-codex",
            surface: "account",
            scenario: "ui_device_login"
        )
        XCTAssertTrue(
            element(app, identifier: "codex.account.unauthenticated")
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            element(app, identifier: "codex.login.browser.start")
                .isEnabled
        )
        element(
            app,
            identifier: "codex.login.device.start"
        ).click()
        XCTAssertTrue(
            element(app, identifier: "codex.login.device.code")
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            element(
                app,
                identifier: "codex.login.device.open_verification"
            ).exists
        )
        let cancel = element(
            app,
            identifier: "codex.login.cancel"
        )
        XCTAssertTrue(cancel.exists)
        cancel.click()
        XCTAssertTrue(
            element(app, identifier: "codex.login.device.start")
                .waitForExistence(timeout: 8)
        )
    }

    func testMixedProviderProfileActionsAreAddressable() throws {
        let app = try launch(
            seed: "mixed-providers",
            surface: "profiles",
            scenario: "provider_current"
        )
        XCTAssertTrue(
            element(app, identifier: "profile.row.codex")
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            element(app, identifier: "profile.row.claude").exists
        )
        XCTAssertTrue(
            element(app, identifier: "profile.create").exists
        )
        XCTAssertTrue(
            element(app, identifier: "profile.rename").exists
        )
        XCTAssertTrue(
            element(app, identifier: "profile.activate").exists
        )
        XCTAssertTrue(
            element(app, identifier: "profile.delete").exists
        )
    }

    func testSettingsHistoryAndPopoverSurfaces() throws {
        var app = try launch(
            seed: "linked-codex",
            surface: "settings",
            scenario: "provider_current"
        )
        XCTAssertTrue(
            element(
                app,
                identifier: "settings.section.providerAccount"
            ).waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            element(app, identifier: "settings.profile.picker").exists
        )
        app.terminate()

        app = try launch(
            seed: "linked-codex",
            surface: "history",
            scenario: "provider_current"
        )
        XCTAssertTrue(
            element(app, identifier: "history.surface")
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            element(app, identifier: "history.time_scale").exists
        )
        XCTAssertTrue(
            element(app, identifier: "history.export").exists
        )
        app.terminate()

        app = try launch(
            seed: "linked-codex",
            surface: "popover",
            scenario: "provider_current"
        )
        XCTAssertTrue(
            element(app, identifier: "ui-testing.surface.popover")
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            element(app, identifier: "popover.action.refresh").exists
        )
        XCTAssertTrue(
            element(app, identifier: "popover.action.settings").exists
        )
        let popoverRefresh = element(
            app,
            identifier: "popover.action.refresh"
        )
        popoverRefresh.click()
        XCTAssertTrue(
            element(app, identifier: "popover.provider.header.codex")
                .waitForExistence(timeout: 8)
        )
        element(
            app,
            identifier: "popover.action.settings"
        ).click()
        XCTAssertTrue(
            element(
                app,
                identifier: "ui-testing.surface.popover-settings"
            ).waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            element(app, identifier: "settings.profile.picker").exists
        )
    }

    func testAllSupportedLocalesRenderCodexSetup() throws {
        let locales = [
            ("en", "Set Up Codex Usage"),
            ("de", "Codex-Nutzung einrichten"),
            ("es", "Configurar el uso de Codex"),
            ("fr", "Configurer le suivi de l'utilisation Codex"),
            ("it", "Configura l'utilizzo di Codex"),
            ("ja", "Codex使用状況のセットアップ"),
            ("ko", "Codex 사용량 설정"),
            ("pt", "Configurar Uso do Codex"),
            ("zh-Hans", "设置 Codex 用量")
        ]
        for (locale, expectedTitle) in locales {
            let app = try launch(
                seed: "first-run",
                surface: "setup",
                scenario: "provider_current",
                locale: locale
            )
            XCTAssertTrue(
                element(app, identifier: "setup.provider.codex")
                    .waitForExistence(timeout: 5),
                "Codex setup choice did not render for \(locale)"
            )
            element(
                app,
                identifier: "setup.provider.codex"
            ).click()
            XCTAssertTrue(
                element(app, identifier: "codex.home.path")
                    .waitForExistence(timeout: 5),
                "Codex setup details did not render for \(locale)"
            )
            let title = element(
                app,
                identifier: "codex.setup.title"
            )
            XCTAssertTrue(title.waitForExistence(timeout: 3))
            XCTAssertEqual(
                title.label,
                expectedTitle,
                "Codex title fell back or mismatched for \(locale)"
            )
            XCTAssertTrue(
                element(app, identifier: "codex.setup.start_tracking")
                    .exists
            )
            let attachment = XCTAttachment(
                screenshot: app.screenshot()
            )
            attachment.name = "codex-setup-\(locale)"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    func testRuntimeGateFailsClosed() {
        let app = XCUIApplication()
        launchedApplications.append(app)
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment = ["UI_TESTING": "0"]
        app.launch()
        XCTAssertTrue(
            element(
                app,
                identifier: "ui-testing.configuration.error"
            ).waitForExistence(timeout: 5)
        )
    }

    private func launch(
        seed: String,
        surface: String,
        scenario: String,
        locale: String = "en"
    ) throws -> XCUIApplication {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "claude-usage-ui-\(UUID().uuidString)",
                isDirectory: true
            )
        let home = root.appendingPathComponent(
            "codex-home",
            isDirectory: true
        )
        let bin = root.appendingPathComponent(
            "bin",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: bin,
            withIntermediateDirectories: true
        )
        temporaryRoots.append(root)
        lastHomeURL = home
        try installCodexWrapper(in: bin, scenario: scenario)

        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "-AppleLanguages", "(\(locale))",
            "-AppleLocale", locale
        ]
        app.launchEnvironment = [
            "UI_TESTING": "1",
            "UI_TEST_ROOT": root.path,
            "UI_TEST_SESSION_ID":
                UUID().uuidString.replacingOccurrences(
                    of: "-",
                    with: ""
                ),
            "UI_TEST_CODEX_HOME": home.path,
            "UI_TEST_SEED": seed,
            "UI_TEST_SURFACE": surface,
            "UI_TEST_LOCALE": locale,
            "PATH": "\(bin.path):/usr/bin:/bin"
        ]
        launchedApplications.append(app)
        app.launch()
        return app
    }

    private func installCodexWrapper(
        in bin: URL,
        scenario: String
    ) throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Packages/UsageKit/Tests/"
                    + "CodexUsageProviderTests/Fixtures/"
                    + "fake-codex-app-server.sh"
            )
        XCTAssertTrue(
            FileManager.default.isExecutableFile(
                atPath: fixture.path
            ),
            "Missing executable Codex fixture at \(fixture.path)"
        )
        let script: String
        if scenario == "ui_device_login" {
            script = pendingDeviceLoginScript
        } else {
            script = """
            #!/bin/sh
            TEST_SCENARIO=\(shellQuote(scenario))
            export TEST_SCENARIO
            exec \(shellQuote(fixture.path)) "$@"
            """
        }
        let wrapper = bin.appendingPathComponent("codex")
        try script.write(
            to: wrapper,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: wrapper.path
        )
    }

    private func element(
        _ app: XCUIApplication,
        identifier: String
    ) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(
            of: "'",
            with: "'\"'\"'"
        ) + "'"
    }

    private var pendingDeviceLoginScript: String {
        """
        #!/bin/sh
        extract_id() {
          printf '%s\\n' "$1" | /usr/bin/sed -n \
            's/.*"id"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p'
        }
        IFS= read -r line || exit 10
        id="$(extract_id "$line")"
        printf '{"id":%s,"result":{"codexHome":"/fake","platformFamily":"unix","platformOs":"macos","userAgent":"ui-test"}}\\n' "$id"
        IFS= read -r line || exit 11
        while IFS= read -r line; do
          id="$(extract_id "$line")"
          case "$line" in
            *'"method":"account/read"'*|*'"method":"account\\/read"'*)
              printf '{"id":%s,"result":{"account":null,"requiresOpenaiAuth":true}}\\n' "$id"
              ;;
            *'"method":"account/login/start"'*|*'"method":"account\\/login\\/start"'*)
              printf '{"id":%s,"result":{"type":"chatgptDeviceCode","loginId":"ui-device-login","verificationUrl":"https://auth.openai.com/codex/device","userCode":"ABCD-1234"}}\\n' "$id"
              ;;
            *'"method":"account/login/cancel"'*|*'"method":"account\\/login\\/cancel"'*)
              printf '{"id":%s,"result":{"status":"canceled"}}\\n' "$id"
              printf '{"method":"account/login/completed","params":{"loginId":"ui-device-login","success":false,"error":"canceled"}}\\n'
              exit 0
              ;;
            *) exit 40 ;;
          esac
        done
        """
    }

    private func currentHome(
        for app: XCUIApplication
    ) throws -> URL {
        _ = app
        guard let home = lastHomeURL else {
            throw XCTSkip("Missing isolated Codex home")
        }
        return home
    }
}
