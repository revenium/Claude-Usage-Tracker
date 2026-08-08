//
//  MenuBarManagerDetectionTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-08-08.
//

import XCTest
@testable import Claude_Usage

/// Pure logic tests for `MenuBarManagerDetection` — no GUI, no real
/// `NSWorkspace` state, just plain `[String]` values. See
/// `StatusBarOverflowTests` for how this feeds the `.automatic` overflow
/// guard end to end.
final class MenuBarManagerDetectionTests: XCTestCase {
    func testDetectsEachKnownManagerByItsOwnBundleIdentifier() {
        for manager in MenuBarManagerDetection.knownManagers {
            let detected = MenuBarManagerDetection.detectedManager(
                runningBundleIdentifiers: [manager.bundleIdentifier]
            )
            XCTAssertEqual(
                detected,
                manager,
                "\(manager.bundleIdentifier) must be detected on its own"
            )
        }
    }

    func testDetectsAKnownManagerAlongsideUnrelatedRunningApplications() {
        let detected = MenuBarManagerDetection.detectedManager(
            runningBundleIdentifiers: [
                "com.apple.finder",
                "com.apple.Safari",
                "com.jordanbaird.Ice",
                "com.apple.Terminal"
            ]
        )
        XCTAssertEqual(detected?.displayName, "Ice")
    }

    func testReturnsNilWhenNoKnownManagerIsRunning() {
        let detected = MenuBarManagerDetection.detectedManager(
            runningBundleIdentifiers: [
                "com.apple.finder", "com.apple.Safari"
            ]
        )
        XCTAssertNil(detected)
    }

    func testReturnsNilForAnEmptyRunningApplicationList() {
        XCTAssertNil(
            MenuBarManagerDetection.detectedManager(
                runningBundleIdentifiers: []
            )
        )
    }

    func testIsCaseSensitiveAndDoesNotFuzzyMatch() {
        // A near-miss (wrong case, or a substring/prefix of a real
        // identifier) must not match — this guard exists specifically to
        // avoid a silent false positive on an unrelated app.
        let detected = MenuBarManagerDetection.detectedManager(
            runningBundleIdentifiers: [
                "com.jordanbaird.ice", "com.jordanbaird.IceSomethingElse"
            ]
        )
        XCTAssertNil(detected)
    }

    func testKnownManagerBundleIdentifiersAreUnique() {
        let identifiers = MenuBarManagerDetection.knownManagers.map(
            \.bundleIdentifier
        )
        XCTAssertEqual(
            identifiers.count,
            Set(identifiers).count,
            "a duplicated bundle identifier would silently mask one entry"
        )
    }
}

/// Tests for `MenuBarManagerTransitionTracker`, which filters
/// `NSWorkspace`'s launch/quit notifications — fired for every application
/// on the system — down to genuine transitions in the detected manager, so
/// `MenuBarManager.handleMenuBarManagerActivityChange()` only replans the
/// menu bar overflow when the answer to "which manager is running" actually
/// changed. Everything here is `[String]` in, `Bool`/optional out — no real
/// process list, no `NSWorkspace`, no `MenuBarManager`.
final class MenuBarManagerTransitionTrackerTests: XCTestCase {
    func testNoManagerRunningAtStartIsNotATransition() {
        let tracker = MenuBarManagerTransitionTracker()
        XCTAssertNil(tracker.lastDetected)
    }

    func testSeedingWithAnAlreadyRunningManagerIsNotATransitionOnFirstUpdate() {
        // A manager already running when the tracker is created (i.e. when
        // the app launches) is already accounted for by the app's initial
        // overflow plan, so the very next update — even reporting the same
        // manager again — must not read as a fresh transition.
        let tracker = MenuBarManagerTransitionTracker(
            initialRunningBundleIdentifiers: ["com.stonerl.Thaw"]
        )
        let changed = tracker.update(
            runningBundleIdentifiers: ["com.stonerl.Thaw"]
        )
        XCTAssertFalse(changed)
    }

    func testManagerLaunchingIsATransition() {
        let tracker = MenuBarManagerTransitionTracker()
        let changed = tracker.update(
            runningBundleIdentifiers: ["com.stonerl.Thaw"]
        )
        XCTAssertTrue(changed)
        XCTAssertEqual(tracker.lastDetected?.displayName, "Thaw")
    }

    func testManagerQuittingIsATransition() {
        let tracker = MenuBarManagerTransitionTracker(
            initialRunningBundleIdentifiers: ["com.stonerl.Thaw"]
        )
        let changed = tracker.update(runningBundleIdentifiers: [])
        XCTAssertTrue(changed)
        XCTAssertNil(tracker.lastDetected)
    }

    func testSwitchingFromOneManagerToAnotherIsATransition() {
        let tracker = MenuBarManagerTransitionTracker(
            initialRunningBundleIdentifiers: ["com.stonerl.Thaw"]
        )
        let changed = tracker.update(
            runningBundleIdentifiers: ["com.jordanbaird.Ice"]
        )
        XCTAssertTrue(changed)
        XCTAssertEqual(tracker.lastDetected?.displayName, "Ice")
    }

    func testAnUnrelatedApplicationLaunchingIsNotATransition() {
        // This is the volume `NSWorkspace.didLaunchApplicationNotification`
        // actually fires at: any app, not just menu bar managers. Adding an
        // unrelated bundle identifier to an otherwise-unchanged running set
        // must not register as a transition.
        let tracker = MenuBarManagerTransitionTracker(
            initialRunningBundleIdentifiers: ["com.apple.finder"]
        )
        let changed = tracker.update(
            runningBundleIdentifiers: ["com.apple.finder", "com.apple.Safari"]
        )
        XCTAssertFalse(changed)
        XCTAssertNil(tracker.lastDetected)
    }

    func testAnUnrelatedApplicationQuittingWhileAManagerStaysRunningIsNotATransition() {
        let tracker = MenuBarManagerTransitionTracker(
            initialRunningBundleIdentifiers: [
                "com.stonerl.Thaw", "com.apple.Safari"
            ]
        )
        let changed = tracker.update(
            runningBundleIdentifiers: ["com.stonerl.Thaw"]
        )
        XCTAssertFalse(changed)
        XCTAssertEqual(tracker.lastDetected?.displayName, "Thaw")
    }

    func testRepeatingTheSameSnapshotIsNotATransition() {
        let tracker = MenuBarManagerTransitionTracker()
        XCTAssertFalse(tracker.update(runningBundleIdentifiers: []))
        XCTAssertFalse(tracker.update(runningBundleIdentifiers: []))
    }
}
