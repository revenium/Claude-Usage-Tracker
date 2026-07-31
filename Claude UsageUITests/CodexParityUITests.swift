import XCTest

final class CodexParityUITests: XCTestCase {
    private static let codexProfileID =
        "00000000-0000-0000-0000-000000000101"
    private static let secondaryCodexProfileID =
        "00000000-0000-0000-0000-000000000102"
    private static let claudeProfileID =
        "00000000-0000-0000-0000-000000000202"
    private static let codexMetricID =
        "v1.window.Y29kZXg.c3Vic2NyaXB0aW9u.Zml2ZS1ob3Vy"
    private static let claudeMetricID =
        "v1.window.Y2xhdWRl.Y2xhdWRlLnN1YnNjcmlwdGlvbg.Y2xhdWRlLnNlc3Npb24"
    private var temporaryRoots: [URL] = []
    private var launchedApplications: [XCUIApplication] = []
    private var lastHomeURL: URL?
    private var lastMethodTraceURL: URL?

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
        lastMethodTraceURL = nil
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
        let back = element(app, identifier: "codex.setup.back")
        XCTAssertTrue(back.exists)
        back.click()
        XCTAssertTrue(codexChoice.waitForExistence(timeout: 5))
        codexChoice.click()
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
        XCTAssertEqual(accessibilityText(activeProfile), "Codex Pro")
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
        let healthyRefreshBaseline = methodCount("account/read")
        refresh.click()
        XCTAssertTrue(
            waitForMethodCount(
                "account/read",
                greaterThan: healthyRefreshBaseline,
                timeout: 8
            ),
            "Refresh must issue a new account/read request."
        )
        let unlink = element(
            app,
            identifier: "codex.home.unlink"
        )
        XCTAssertTrue(unlink.exists)
        unlink.click()
        let cancelUnlink = element(
            app,
            identifier: "codex.home.unlink.cancel"
        )
        XCTAssertTrue(cancelUnlink.waitForExistence(timeout: 3))
        cancelUnlink.click()
        XCTAssertTrue(
            cancelUnlink.waitForNonExistence(timeout: 3),
            "Cancel must dismiss the unlink confirmation."
        )
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
        let degradedStatus = app.staticTexts
            .matching(
                identifier: "codex.account.status"
            )
            .matching(
                NSPredicate(
                    format: "value == %@",
                    "Degraded"
                )
            )
            .firstMatch
        XCTAssertTrue(degradedStatus.waitForExistence(timeout: 8))
        let errorRefresh = element(
            app,
            identifier: "codex.account.refresh"
        )
        XCTAssertTrue(errorRefresh.isEnabled)
        let failedRefreshBaseline = methodCount(
            "account/rateLimits/read"
        )
        errorRefresh.click()
        XCTAssertTrue(
            waitForMethodCount(
                "account/rateLimits/read",
                greaterThan: failedRefreshBaseline,
                timeout: 8
            ),
            "Retry must issue a new account/rateLimits/read request."
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

    func testBrowserLoginButtonStartsProductionLoginFlow() throws {
        let app = try launch(
            seed: "linked-codex",
            surface: "account",
            scenario: "ui_browser_login"
        )
        XCTAssertTrue(
            element(app, identifier: "codex.account.unauthenticated")
                .waitForExistence(timeout: 8)
        )
        let browser = element(
            app,
            identifier: "codex.login.browser.start"
        )
        XCTAssertTrue(browser.isEnabled)
        browser.click()
        let succeeded = element(
            app,
            identifier: "codex.login.succeeded"
        )
        let waiting = element(
            app,
            identifier: "codex.login.browser.waiting"
        )
        XCTAssertTrue(
            succeeded.waitForExistence(timeout: 8)
                || waiting.waitForExistence(timeout: 2)
        )
    }

    func testMixedProviderProfileActionsMutateExactStableProfiles()
        throws
    {
        let app = try launch(
            seed: "mixed-providers",
            surface: "profiles",
            scenario: "provider_current"
        )
        let codexRow = element(
            app,
            identifier: "profile.row.\(Self.codexProfileID)"
        )
        let secondCodexRow = element(
            app,
            identifier: "profile.row.\(Self.secondaryCodexProfileID)"
        )
        let claudeRow = element(
            app,
            identifier: "profile.row.\(Self.claudeProfileID)"
        )
        XCTAssertTrue(codexRow.waitForExistence(timeout: 5))
        XCTAssertTrue(secondCodexRow.exists)
        XCTAssertTrue(claudeRow.exists)
        XCTAssertTrue(
            element(app, identifier: "profile.create.open").exists
        )

        claudeRow.descendants(matching: .any)["profile.rename"]
            .click()
        let renameField = claudeRow.descendants(matching: .any)[
            "profile.rename.field"
        ]
        XCTAssertTrue(renameField.waitForExistence(timeout: 3))
        renameField.click()
        renameField.typeKey("a", modifierFlags: .command)
        renameField.typeText("Claude Renamed")
        claudeRow.descendants(matching: .any)[
            "profile.rename.save"
        ].click()
        XCTAssertTrue(
            claudeRow.staticTexts["Claude Renamed"]
                .waitForExistence(timeout: 3)
        )

        let activate = claudeRow.descendants(matching: .any)[
            "profile.activate"
        ]
        activate.click()
        XCTAssertTrue(
            activate.waitForNonExistence(timeout: 5),
            "The exact Claude profile must become active."
        )
        XCTAssertTrue(
            claudeRow.staticTexts["Active"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            codexRow.descendants(matching: .any)[
                "profile.activate"
            ].waitForExistence(timeout: 5)
        )

        secondCodexRow.descendants(matching: .any)[
            "profile.delete"
        ].click()
        let confirmDelete = element(
            app,
            identifier: "profile.delete.confirm"
        )
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 3))
        confirmDelete.click()
        XCTAssertTrue(
            secondCodexRow.waitForNonExistence(timeout: 3)
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
        element(app, identifier: "settings.section.appearance").click()
        let appearanceSurface = element(
            app,
            identifier: "settings.appearance.surface"
        )
        XCTAssertTrue(
            appearanceSurface.waitForExistence(timeout: 5)
        )
        XCTAssertEqual(
            accessibilityText(appearanceSurface),
            "\(Self.codexProfileID)|codex"
        )
        element(
            app,
            identifier: "settings.section.manageProfiles"
        ).click()
        XCTAssertTrue(
            element(
                app,
                identifier: "profile.row.\(Self.codexProfileID)"
            ).waitForExistence(timeout: 3)
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
        let timeScale = element(
            app,
            identifier: "history.time_scale"
        )
        timeScale.click()
        XCTAssertTrue(app.menuItems["24 Hours"].waitForExistence(timeout: 3))
        app.menuItems["24 Hours"].click()
        XCTAssertTrue(
            String(describing: timeScale.value).contains("24 Hours")
                || timeScale.label.contains("24 Hours")
        )
        element(app, identifier: "history.export").click()
        XCTAssertTrue(
            app.menuItems["Export as JSON"]
                .waitForExistence(timeout: 3)
        )
        app.menuItems["Export as JSON"].click()
        let cancelExport = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancelExport.waitForExistence(timeout: 5))
        cancelExport.click()
        XCTAssertTrue(
            cancelExport.waitForNonExistence(timeout: 5),
            "Cancel must dismiss the export save panel."
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
        XCTAssertTrue(
            waitForEnabled(popoverRefresh, timeout: 8),
            "Refresh must become enabled after the initial load."
        )
        let popoverRefreshBaseline = methodCount("account/read")
        popoverRefresh.click()
        XCTAssertTrue(
            waitForMethodCount(
                "account/read",
                greaterThan: popoverRefreshBaseline,
                timeout: 8
            ),
            "Popover Refresh must issue a new account/read request."
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
            element(app, identifier: "settings.section.providerAccount")
                .exists
        )
        XCTAssertTrue(
            element(app, identifier: "settings.profile.picker").exists
        )
        app.terminate()

        app = try launch(
            seed: "mixed-providers",
            surface: "popover",
            scenario: "provider_current"
        )
        let switcher = element(
            app,
            identifier: "popover.profile.switcher"
        )
        XCTAssertTrue(switcher.waitForExistence(timeout: 5))
        switcher.click()
        element(
            app,
            identifier:
                "popover.profile.switcher.\(Self.claudeProfileID)"
        ).click()
        XCTAssertTrue(
            waitForLabel(
                element(
                    app,
                    identifier: "ui-testing.popover.profile-id"
                ),
                prefix: Self.claudeProfileID,
                timeout: 5
            )
        )
        element(
            app,
            identifier: "popover.action.settings"
        ).click()
        XCTAssertTrue(
            element(app, identifier: "settings.section.appSettings")
                .waitForExistence(timeout: 5)
        )
        app.typeKey("w", modifierFlags: .command)

        switcher.click()
        let manageProfiles = element(
            app,
            identifier: "popover.action.manage_profiles"
        )
        XCTAssertTrue(manageProfiles.waitForExistence(timeout: 3))
        manageProfiles.click()
        XCTAssertTrue(
            element(app, identifier: "settings.section.manageProfiles")
                .waitForExistence(timeout: 5)
        )
    }

    func testMenuStatusRoutesExactProviderTargetsAndCapturesQuit()
        throws
    {
        let app = try launch(
            seed: "mixed-providers",
            surface: "menu-status",
            scenario: "provider_current"
        )
        XCTAssertTrue(
            element(app, identifier: "ui-testing.surface.menu-status")
                .waitForExistence(timeout: 5)
        )
        for state in [
            "ready", "loading", "stale", "degraded", "error", "noData",
        ] {
            XCTAssertTrue(
                element(
                    app,
                    identifier: "ui-testing.status.state.\(state)"
                ).exists
            )
        }
        let action = element(
            app,
            identifier: "ui-testing.menu.last-action"
        )
        let singleCodex = element(
            app,
            identifier: "ui-testing.status.single.codex"
        )
        singleCodex.click()
        XCTAssertEqual(
            accessibilityText(action),
            "popover.open|\(Self.codexProfileID)|codex|0|\(Self.codexMetricID)"
        )
        singleCodex.click()
        XCTAssertTrue(
            waitForLabel(
                action,
                prefix:
                    "popover.closed|\(Self.codexProfileID)|codex|0|\(Self.codexMetricID)",
                timeout: 3
            )
        )

        let activeCodex = element(
            app,
            identifier: "ui-testing.status.multi.codex.active"
        )
        activeCodex.rightClick()
        XCTAssertTrue(app.menuItems["Codex — Codex Pro"].exists)
        XCTAssertFalse(app.menuItems["Make Active"].exists)
        XCTAssertTrue(app.menuItems["Refresh"].exists)
        XCTAssertTrue(app.menuItems["Codex Account…"].exists)
        XCTAssertTrue(app.menuItems["Appearance…"].exists)
        XCTAssertTrue(app.menuItems["Manage Profiles…"].exists)
        XCTAssertTrue(app.menuItems["Quit"].exists)
        app.menuItems["Refresh"].click()
        XCTAssertTrue(
            waitForLabel(
                action,
                prefix:
                    "refresh.success|\(Self.codexProfileID)|codex|0|\(Self.codexMetricID)",
                timeout: 10
            )
        )
        activeCodex.rightClick()
        app.menuItems["Codex Account…"].click()
        XCTAssertEqual(
            accessibilityText(action),
            "settings.account|\(Self.codexProfileID)|codex|0|\(Self.codexMetricID)"
        )
        XCTAssertTrue(
            element(app, identifier: "settings.section.providerAccount")
                .waitForExistence(timeout: 5)
        )
        app.typeKey("w", modifierFlags: .command)

        activeCodex.rightClick()
        app.menuItems["Appearance…"].click()
        XCTAssertEqual(
            accessibilityText(action),
            "settings.appearance|\(Self.codexProfileID)|codex|0|\(Self.codexMetricID)"
        )
        XCTAssertTrue(
            element(app, identifier: "settings.section.appearance")
                .waitForExistence(timeout: 5)
        )
        app.typeKey("w", modifierFlags: .command)

        activeCodex.rightClick()
        app.menuItems["Manage Profiles…"].click()
        XCTAssertEqual(
            accessibilityText(action),
            "settings.profiles|\(Self.codexProfileID)|codex|0|\(Self.codexMetricID)"
        )
        XCTAssertTrue(
            element(app, identifier: "settings.section.manageProfiles")
                .waitForExistence(timeout: 5)
        )
        app.typeKey("w", modifierFlags: .command)

        let inactiveCodex = element(
            app,
            identifier: "ui-testing.status.multi.codex.inactive"
        )
        inactiveCodex.rightClick()
        XCTAssertTrue(app.menuItems["Codex — Codex Team"].exists)
        XCTAssertTrue(app.menuItems["Make Active"].exists)
        app.menuItems["Make Active"].click()
        XCTAssertTrue(
            waitForLabel(
                element(
                    app,
                    identifier: "ui-testing.menu.active-profile"
                ),
                prefix: Self.secondaryCodexProfileID,
                timeout: 5
            )
        )
        XCTAssertEqual(
            accessibilityText(action),
            "activate|\(Self.secondaryCodexProfileID)|codex|0|\(Self.codexMetricID)"
        )

        inactiveCodex.rightClick()
        XCTAssertFalse(app.menuItems["Make Active"].exists)
        app.menuItems["Quit"].click()
        XCTAssertEqual(
            accessibilityText(action),
            "quit.requested|\(Self.secondaryCodexProfileID)|codex|0|\(Self.codexMetricID)"
        )
        XCTAssertEqual(app.state, .runningForeground)

        let claude = element(
            app,
            identifier: "ui-testing.status.multi.claude.inactive"
        )
        claude.rightClick()
        XCTAssertTrue(app.menuItems["Refresh"].exists)
        XCTAssertTrue(app.menuItems["Settings"].exists)
        XCTAssertTrue(app.menuItems["Quit"].exists)
        app.menuItems["Settings"].click()
        XCTAssertEqual(
            accessibilityText(action),
            "settings.default|\(Self.claudeProfileID)|claude|0|\(Self.claudeMetricID)"
        )
        XCTAssertTrue(
            element(app, identifier: "settings.section.appSettings")
                .waitForExistence(timeout: 5)
        )
        app.typeKey("w", modifierFlags: .command)

        claude.rightClick()
        app.menuItems["Refresh"].click()
        XCTAssertEqual(
            accessibilityText(action),
            "refresh.legacy|\(Self.claudeProfileID)|claude|0|\(Self.claudeMetricID)"
        )

        element(app, identifier: "ui-testing.status.none").click()
        XCTAssertEqual(
            accessibilityText(action),
            "popover.open|\(Self.secondaryCodexProfileID)|codex|0|no-metric"
        )
    }

    func testMenuStatusPopoverLifecycleAndLiveStaleTargetNoOps()
        throws
    {
        var app = try launch(
            seed: "mixed-providers",
            surface: "menu-status",
            scenario: "provider_current"
        )
        let action = element(
            app,
            identifier: "ui-testing.menu.last-action"
        )
        element(
            app,
            identifier: "ui-testing.menu.arm-revision"
        ).click()
        element(
            app,
            identifier: "ui-testing.status.multi.codex.inactive"
        ).rightClick()
        XCTAssertTrue(
            waitForLabel(
                action,
                prefix:
                    "mutated.revision|\(Self.secondaryCodexProfileID)|codex|0|\(Self.codexMetricID)",
                timeout: 5
            )
        )
        app.menuItems["Refresh"].click()
        XCTAssertTrue(
            waitForLabel(
                action,
                prefix:
                    "ignored.stale|\(Self.secondaryCodexProfileID)|codex|0|\(Self.codexMetricID)",
                timeout: 5
            )
        )

        let status = element(
            app,
            identifier: "ui-testing.status.multi.codex.active"
        )
        status.click()
        XCTAssertTrue(
            element(app, identifier: "ui-testing.popover.profile-id")
                .waitForExistence(timeout: 5)
        )
        XCTAssertEqual(
            accessibilityText(
                element(
                    app,
                    identifier: "ui-testing.popover.profile-id"
                )
            ),
            Self.codexProfileID
        )
        XCTAssertEqual(
            accessibilityText(action),
            "popover.open|\(Self.codexProfileID)|codex|0|\(Self.codexMetricID)"
        )

        status.click()
        XCTAssertTrue(
            waitForLabel(
                action,
                prefix:
                    "popover.closed|\(Self.codexProfileID)|codex|0|\(Self.codexMetricID)",
                timeout: 3
            )
        )
        status.click()
        let detach = element(
            app,
            identifier: "ui-testing.popover.detach"
        )
        XCTAssertTrue(detach.waitForExistence(timeout: 3))
        detach.click()
        let detached = element(
            app,
            identifier: "ui-testing.detached.popover"
        )
        XCTAssertTrue(detached.waitForExistence(timeout: 5))
        XCTAssertEqual(
            accessibilityText(
                element(
                    app,
                    identifier: "ui-testing.popover.profile-id"
                )
            ),
            Self.codexProfileID
        )
        XCTAssertEqual(
            accessibilityText(action),
            "popover.detached.contract-ok|\(Self.codexProfileID)|codex|0|\(Self.codexMetricID)"
        )
        element(
            app,
            identifier: "popover.profile.switcher"
        ).click()
        let activateWhileDetached = element(
            app,
            identifier:
                "popover.profile.switcher.\(Self.secondaryCodexProfileID)"
        )
        XCTAssertTrue(
            activateWhileDetached.waitForExistence(timeout: 3)
        )
        activateWhileDetached.click()
        XCTAssertTrue(
            element(
                app,
                identifier: "ui-testing.menu.active-profile"
            ).waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            waitForLabel(
                element(
                    app,
                    identifier: "ui-testing.menu.active-profile"
                ),
                prefix: Self.secondaryCodexProfileID,
                timeout: 5
            )
        )
        XCTAssertTrue(
            detached.waitForNonExistence(timeout: 5),
            "Activating profile B must close profile A's detached surface."
        )
        status.click()
        XCTAssertTrue(
            element(app, identifier: "ui-testing.popover.profile-id")
                .waitForExistence(timeout: 5)
        )

        element(
            app,
            identifier: "ui-testing.popover.mutate-revision"
        ).click()
        element(app, identifier: "popover.action.refresh").click()
        XCTAssertTrue(
            waitForLabel(
                action,
                prefix:
                    "ignored.stale|\(Self.codexProfileID)|codex|0|\(Self.codexMetricID)",
                timeout: 5
            )
        )
        XCTAssertFalse(
            element(
                app,
                identifier: "ui-testing.detached.popover"
            ).exists
        )
        app.terminate()

        app = try launch(
            seed: "mixed-providers",
            surface: "menu-status",
            scenario: "provider_current"
        )
        let second = element(
            app,
            identifier: "ui-testing.status.multi.codex.inactive"
        )
        element(
            app,
            identifier: "ui-testing.menu.arm-deletion"
        ).click()
        second.rightClick()
        XCTAssertTrue(app.menuItems["Manage Profiles…"].exists)
        let secondAction = element(
            app,
            identifier: "ui-testing.menu.last-action"
        )
        XCTAssertTrue(
            waitForLabel(
                secondAction,
                prefix:
                    "mutated.deletion|\(Self.secondaryCodexProfileID)|codex|0|\(Self.codexMetricID)",
                timeout: 5
            )
        )
        app.menuItems["Manage Profiles…"].click()
        XCTAssertTrue(
            waitForLabel(
                secondAction,
                prefix:
                    "ignored.stale|\(Self.secondaryCodexProfileID)|codex|0|\(Self.codexMetricID)",
                timeout: 5
            )
        )
        XCTAssertFalse(
            element(
                app,
                identifier: "ui-testing.menu.settings"
            ).exists
        )
    }

    func testMenuStatusTrueNoProfileSelectionFailsClosed() throws {
        let app = try launch(
            seed: "first-run",
            surface: "menu-status",
            scenario: "provider_current"
        )
        element(app, identifier: "ui-testing.status.none").click()
        XCTAssertEqual(
            accessibilityText(
                element(
                    app,
                    identifier: "ui-testing.menu.last-action"
                )
            ),
            "ignored.no-profile"
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
                accessibilityText(title),
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
            .standardizedFileURL
            .resolvingSymlinksInPath()
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
        let methodTrace = root.appendingPathComponent(
            "codex-request-methods.log"
        )
        lastMethodTraceURL = methodTrace
        try installCodexWrapper(
            in: bin,
            home: home,
            scenario: scenario,
            methodTrace: methodTrace
        )

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
        home: URL,
        scenario: String,
        methodTrace: URL
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
            FileManager.default.isReadableFile(
                atPath: fixture.path
            ),
            "Missing readable Codex fixture at \(fixture.path)"
        )
        let script: String
        if scenario == "ui_device_login" {
            script = pendingDeviceLoginScript
        } else if scenario == "ui_browser_login" {
            script = browserLoginScript
        } else {
            script = """
            #!/bin/sh
            TEST_SCENARIO=\(shellQuote(scenario))
            METHOD_LOG=\(shellQuote(methodTrace.path))
            export TEST_SCENARIO
            export METHOD_LOG
            exec /bin/sh \(shellQuote(fixture.path)) "$@"
            """
        }
        let appServerScript = home.appendingPathComponent(
            "app-server"
        )
        try script.write(
            to: appServerScript,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: appServerScript.path
        )

        // The UI-test runner's data-vault path cannot be executed directly
        // on hosted macOS runners. Resolve the fixture command to the trusted
        // system shell; production still resolves and launches Codex itself.
        try FileManager.default.createSymbolicLink(
            at: bin.appendingPathComponent("codex"),
            withDestinationURL: URL(fileURLWithPath: "/bin/sh")
        )
    }

    private func element(
        _ app: XCUIApplication,
        identifier: String
    ) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func waitForLabel(
        _ element: XCUIElement,
        prefix: String,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate { [weak self] object, _ in
            guard let element = object as? XCUIElement else {
                return false
            }
            return self?.accessibilityText(element)
                .hasPrefix(prefix) == true
        }
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: element
        )
        return XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
    }

    private func accessibilityText(
        _ element: XCUIElement
    ) -> String {
        if let value = element.value as? String,
           !value.isEmpty {
            return value
        }
        return element.label
    }

    private func waitForEnabled(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(format: "isEnabled == true")
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: element
        )
        return XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
    }

    private func methodCount(_ method: String) -> Int {
        guard let trace = lastMethodTraceURL,
              let contents = try? String(
                  contentsOf: trace,
                  encoding: .utf8
              ) else {
            return 0
        }
        return contents.split(whereSeparator: \.isNewline)
            .filter { $0 == method }
            .count
    }

    private func waitForMethodCount(
        _ method: String,
        greaterThan baseline: Int,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate { [weak self] _, _ in
            (self?.methodCount(method) ?? 0) > baseline
        }
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: nil
        )
        return XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
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

    private var browserLoginScript: String {
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
              printf '{"id":%s,"result":{"type":"chatgpt","loginId":"ui-browser-login","authUrl":"https://example.invalid/codex-login"}}\\n' "$id"
              printf '{"method":"account/login/completed","params":{"loginId":"ui-browser-login","success":true,"error":null}}\\n'
              ;;
            *) exit 41 ;;
          esac
        done
        """
    }

    private func currentHome(
        for app: XCUIApplication
    ) throws -> URL {
        _ = app
        return try XCTUnwrap(
            lastHomeURL,
            "Missing isolated Codex home"
        )
    }
}
