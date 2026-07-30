import AppKit
import XCTest
@testable import Claude_Usage

@MainActor
final class MenuReliabilityTests: XCTestCase {
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

    func testImageFingerprintUsesStableCGImageBytes() {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 4, height: 4)).fill()
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
        let queue = DispatchQueue(label: "MenuReliabilityTests.notification-order")
        let recorder = ThreadSafeRecorder()
        let notificationName = Notification.Name("MenuReliabilityTests.notification")
        let notificationPosted = expectation(description: "notification posted")

        let observer = center.addObserver(
            forName: notificationName,
            object: nil,
            queue: nil
        ) { _ in
            recorder.append("notification")
            notificationPosted.fulfill()
        }
        defer { center.removeObserver(observer) }

        // ProfileManager enqueues its mutation first. The view helper must enqueue
        // the notification second on the same serial queue.
        queue.async {
            recorder.append("mutation")
        }
        ManageProfilesView.enqueueMenuBarNotification(
            notificationName,
            queue: queue,
            center: center
        )

        wait(for: [notificationPosted], timeout: 1)
        XCTAssertEqual(recorder.snapshot(), ["mutation", "notification"])
    }
}
