import AppKit
import UsageCore
import XCTest
@testable import Claude_Usage

@MainActor
final class MenuReliabilityTests: HostedAppTestCase {
    private final class MenuTarget: NSObject {
        @objc func refresh() {}
        @objc func settings() {}
        @objc func quit() {}
    }

    private final class ThreadSafeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ value: String) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    func testContextMenuContainsExpectedLocalizedActionsAndShortcuts() {
        let target = MenuTarget()
        let menu = MenuBarManager.makeContextMenu(
            target: target,
            refreshAction: #selector(MenuTarget.refresh),
            settingsAction: #selector(MenuTarget.settings),
            quitAction: #selector(MenuTarget.quit)
        )

        XCTAssertEqual(menu.items.count, 4)
        let refresh = menu.items[0]
        XCTAssertEqual(refresh.title, "common.refresh".localized)
        XCTAssertEqual(refresh.action, #selector(MenuTarget.refresh))
        XCTAssertTrue(refresh.target === target)
        XCTAssertEqual(refresh.keyEquivalent, "")
        XCTAssertTrue(menu.items[1].isSeparatorItem)

        let settings = menu.items[2]
        XCTAssertEqual(settings.title, "common.settings".localized)
        XCTAssertEqual(settings.action, #selector(MenuTarget.settings))
        XCTAssertTrue(settings.target === target)
        XCTAssertEqual(settings.keyEquivalent, ",")
        XCTAssertEqual(settings.keyEquivalentModifierMask, .command)

        let quit = menu.items[3]
        XCTAssertEqual(quit.title, "common.quit".localized)
        XCTAssertEqual(quit.action, #selector(MenuTarget.quit))
        XCTAssertTrue(quit.target === target)
        XCTAssertEqual(quit.keyEquivalent, "q")
        XCTAssertEqual(quit.keyEquivalentModifierMask, .command)
    }

    func testPopoverCloseDebounceOnlySuppressesTheSameButtonBriefly() {
        let firstButton = NSObject()
        let secondButton = NSObject()
        let closeDate = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertTrue(
            MenuBarManager.shouldSuppressPopoverOpen(
                button: firstButton,
                lastButton: firstButton,
                lastCloseDate: closeDate,
                now: closeDate.addingTimeInterval(0.1)
            )
        )
        XCTAssertFalse(
            MenuBarManager.shouldSuppressPopoverOpen(
                button: secondButton,
                lastButton: firstButton,
                lastCloseDate: closeDate,
                now: closeDate.addingTimeInterval(0.1)
            )
        )
        XCTAssertFalse(
            MenuBarManager.shouldSuppressPopoverOpen(
                button: firstButton,
                lastButton: firstButton,
                lastCloseDate: closeDate,
                now: closeDate.addingTimeInterval(0.25)
            )
        )
    }

    func testCredentialChangeRoutingRefreshesOnlyAffectedVisibleProfiles() {
        let profileA = UUID()
        let profileB = UUID()

        let inactiveSingle = MenuBarManager.credentialChangeRouting(
            changedProfileID: profileA,
            activeProfileID: profileB,
            selectedProfileIDs: [],
            isMultiProfileMode: false
        )
        XCTAssertEqual(inactiveSingle.invalidation, .profile(profileA))
        XCTAssertFalse(inactiveSingle.shouldRefreshVisibleProfiles)

        let selectedMulti = MenuBarManager.credentialChangeRouting(
            changedProfileID: profileA,
            activeProfileID: profileB,
            selectedProfileIDs: [profileA],
            isMultiProfileMode: true
        )
        XCTAssertEqual(selectedMulti.invalidation, .profile(profileA))
        XCTAssertTrue(selectedMulti.shouldRefreshVisibleProfiles)

        let legacy = MenuBarManager.credentialChangeRouting(
            changedProfileID: nil,
            activeProfileID: profileB,
            selectedProfileIDs: [],
            isMultiProfileMode: false
        )
        XCTAssertEqual(legacy.invalidation, .allCapturedProfiles)
        XCTAssertTrue(legacy.shouldRefreshVisibleProfiles)
    }

    func testDeferredCredentialRefreshRechecksCapturedVisibilityScope() {
        let profileA = UUID()
        let profileB = UUID()
        let routingAtNotification =
            MenuBarManager.credentialChangeRouting(
                changedProfileID: profileA,
                activeProfileID: profileA,
                selectedProfileIDs: [],
                isMultiProfileMode: false
            )
        XCTAssertTrue(routingAtNotification.shouldRefreshVisibleProfiles)

        XCTAssertFalse(
            MenuBarManager.shouldExecuteCredentialRefresh(
                routingAtNotification,
                activeProfileID: profileB,
                selectedProfileIDs: [],
                isMultiProfileMode: false
            )
        )

        let legacy = MenuBarManager.credentialChangeRouting(
            changedProfileID: nil,
            activeProfileID: profileA,
            selectedProfileIDs: [],
            isMultiProfileMode: false
        )
        XCTAssertTrue(
            MenuBarManager.shouldExecuteCredentialRefresh(
                legacy,
                activeProfileID: profileB,
                selectedProfileIDs: [],
                isMultiProfileMode: false
            )
        )
    }

    func testSingleProfilePopoverRefreshProjectsToPrimaryUsage() {
        let profileID = UUID()
        XCTAssertEqual(
            MenuBarManager.usageProjectionTarget(
                displayMode: .single,
                clickedProfileID: profileID,
                snapshotProfileID: profileID
            ),
            .primary
        )
    }

    func testMultiProfileClickedRefreshProjectsToClickedUsage() {
        let activeID = UUID()
        let clickedID = UUID()
        XCTAssertEqual(
            MenuBarManager.usageProjectionTarget(
                displayMode: .multi,
                clickedProfileID: clickedID,
                snapshotProfileID: clickedID
            ),
            .clickedProfile
        )
        XCTAssertEqual(
            MenuBarManager.usageProjectionTarget(
                displayMode: .multi,
                clickedProfileID: clickedID,
                snapshotProfileID: activeID
            ),
            .primary
        )
    }

    func testFailureRoutingRequiresExactContextAndActiveProfile() {
        let profileID = UUID()
        let context = UsagePresentationContext(
            epoch: 7,
            focusedProfileID: profileID,
            visibleProfileIDs: [profileID]
        )
        let event = UsageRefreshFailureEvent(
            sequence: 1,
            identity: ProviderRefreshIdentity(
                profileID: profileID,
                providerID: .claude,
                providerRevision: 0
            ),
            profileName: "A",
            invocationOrder: 1,
            trigger: .timer,
            presentationContext: context,
            component: .providerUsage,
            failure: ProviderRefreshFailure(
                kind: .transport,
                occurredAt: Date(timeIntervalSince1970: 1),
                isRecoverable: true,
                consecutiveCount: 1
            )
        )

        XCTAssertTrue(
            MenuBarManager.isCurrentFailureEvent(
                event,
                presentationContext: context,
                activeProfileID: profileID
            )
        )
        XCTAssertFalse(
            MenuBarManager.isCurrentFailureEvent(
                event,
                presentationContext: UsagePresentationContext(
                    epoch: 8,
                    focusedProfileID: profileID,
                    visibleProfileIDs: [profileID]
                ),
                activeProfileID: profileID
            )
        )
        XCTAssertFalse(
            MenuBarManager.isCurrentFailureEvent(
                event,
                presentationContext: context,
                activeProfileID: UUID()
            )
        )
    }

    func testResetHistorySuppressesDuplicatePeriodicComponents() {
        XCTAssertEqual(
            MenuBarManager.periodicHistoryComponents(
                sessionResetRecorded: false,
                weeklyResetRecorded: false
            ),
            [.session, .weekly]
        )
        XCTAssertEqual(
            MenuBarManager.periodicHistoryComponents(
                sessionResetRecorded: true,
                weeklyResetRecorded: false
            ),
            [.weekly]
        )
        XCTAssertEqual(
            MenuBarManager.periodicHistoryComponents(
                sessionResetRecorded: false,
                weeklyResetRecorded: true
            ),
            [.session]
        )
        XCTAssertTrue(
            MenuBarManager.periodicHistoryComponents(
                sessionResetRecorded: true,
                weeklyResetRecorded: true
            ).isEmpty
        )
    }

    func testRefreshFailureReconstructsCanonicalSafeLegacyErrors() {
        let cases: [(ErrorCode, AppError)] = [
            (.apiUnauthorized, .apiUnauthorized()),
            (.apiRateLimited, .apiRateLimited()),
            (.apiServerError, .apiServerError(statusCode: 500)),
            (.networkTimeout, .networkTimeout())
        ]

        for (code, expected) in cases {
            let actual = MenuBarManager.appError(
                for: ProviderRefreshFailure(
                    kind: .transport,
                    occurredAt: Date(
                        timeIntervalSinceReferenceDate: 1
                    ),
                    isRecoverable: true,
                    consecutiveCount: 1,
                    legacyErrorCode: code
                )
            )

            XCTAssertEqual(actual.code, expected.code)
            XCTAssertEqual(actual.message, expected.message)
            XCTAssertEqual(
                actual.recoverySuggestion,
                expected.recoverySuggestion
            )
            XCTAssertNil(actual.underlyingError)
        }
    }

    func testInteractiveRefreshSideEffectsAreSingleProfileOnly() {
        let profileID = UUID()
        let single = UsagePresentationContext(
            epoch: 1,
            focusedProfileID: profileID,
            visibleProfileIDs: [profileID],
            mode: .single
        )
        XCTAssertTrue(
            MenuBarManager
                .shouldApplyInteractiveRefreshSideEffects(
                    eventContext: single,
                    currentContext: single,
                    eventProfileID: profileID,
                    activeProfileID: profileID
                )
        )

        let multi = UsagePresentationContext(
            epoch: 2,
            focusedProfileID: profileID,
            visibleProfileIDs: [profileID],
            mode: .multi
        )
        XCTAssertFalse(
            MenuBarManager
                .shouldApplyInteractiveRefreshSideEffects(
                    eventContext: multi,
                    currentContext: multi,
                    eventProfileID: profileID,
                    activeProfileID: profileID
                )
        )
    }

    func testImageFingerprintUsesStableCGImageBytes() {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(
            rect: NSRect(x: 0, y: 0, width: 4, height: 4)
        ).fill()
        image.unlockFocus()

        let first = StatusBarUIManager.imageFingerprint(image)
        let second = StatusBarUIManager.imageFingerprint(image)

        XCTAssertNotNil(first)
        XCTAssertFalse(first?.isEmpty ?? true)
        XCTAssertEqual(first, second)
    }

    func testBorderlessSettingsWindowRecognizesCommandW() {
        XCTAssertTrue(
            BorderlessSettingsWindow.isCloseShortcut(
                modifierFlags: .command,
                charactersIgnoringModifiers: "w"
            )
        )
        XCTAssertTrue(
            BorderlessSettingsWindow.isCloseShortcut(
                modifierFlags: [.command, .shift],
                charactersIgnoringModifiers: "W"
            )
        )
        XCTAssertFalse(
            BorderlessSettingsWindow.isCloseShortcut(
                modifierFlags: [],
                charactersIgnoringModifiers: "w"
            )
        )
        XCTAssertFalse(
            BorderlessSettingsWindow.isCloseShortcut(
                modifierFlags: .command,
                charactersIgnoringModifiers: "q"
            )
        )
    }

    func testMenuBarNotificationIsEnqueuedAfterPendingProfileMutation() {
        let center = NotificationCenter()
        let queue = DispatchQueue(
            label: "MenuReliabilityTests.notification-order"
        )
        let recorder = ThreadSafeRecorder()
        let notificationName = Notification.Name(
            "MenuReliabilityTests.notification"
        )
        let notificationPosted = expectation(
            description: "notification posted"
        )

        let observer = center.addObserver(
            forName: notificationName,
            object: nil,
            queue: nil
        ) { _ in
            recorder.append("notification")
            notificationPosted.fulfill()
        }
        defer { center.removeObserver(observer) }

        queue.async {
            recorder.append("mutation")
        }
        ManageProfilesView.enqueueMenuBarNotification(
            notificationName,
            queue: queue,
            center: center
        )

        wait(for: [notificationPosted], timeout: 1)
        XCTAssertEqual(
            recorder.snapshot(),
            ["mutation", "notification"]
        )
    }

    func testProfileDeletionErrorUsesAuthoredLocalizedDescription() {
        let presentation = ProfileDeletionErrorPresentation(
            error: LocalizedDeletionError.expected
        )
        XCTAssertEqual(presentation.message, "Safe deletion failure")
    }

    func testProfileDeletionErrorDoesNotExposeOpaqueErrorPayload() {
        let secret = "DELETE_ERROR_SECRET_FIXTURE"
        let opaqueError = NSError(
            domain: "MenuReliabilityTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: secret]
        )

        let presentation = ProfileDeletionErrorPresentation(
            error: opaqueError
        )
        XCTAssertEqual(
            presentation.message,
            ProfileDeletionErrorPresentation.genericMessage
        )
        XCTAssertFalse(presentation.message.contains(secret))
    }
}

private enum LocalizedDeletionError: LocalizedError {
    case expected

    var errorDescription: String? {
        "Safe deletion failure"
    }
}
