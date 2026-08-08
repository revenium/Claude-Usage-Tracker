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
/// `MenuBarManager.handleMenuBarManagerActivityChange(launched:terminated:)`
/// only replans the menu bar overflow when the answer to "which manager is
/// running" actually changed. Everything here is `[String]` in,
/// `Bool`/optional out — no real process list, no `NSWorkspace`, no
/// `MenuBarManager`.
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

/// Tests for `MenuBarManagerActivityReconciler`, the pure helper that folds
/// a launch/quit notification's own bundle identifier into a freshly
/// sampled process list — see its doc comment in
/// `MenuBarManagerDetection.swift` for why the resample alone can lag the
/// notification that triggered it. Every test injects its own bundle
/// identifier list; none reads real `NSWorkspace` state, which matters
/// because this machine genuinely runs Thaw (`com.stonerl.Thaw`).
final class MenuBarManagerActivityReconcilerTests: XCTestCase {
    func testAppendsALaunchedIdentifierMissingFromTheSample() {
        let reconciled = MenuBarManagerActivityReconciler.reconciled(
            sample: ["com.apple.finder"],
            launched: "com.stonerl.Thaw",
            terminated: nil
        )
        XCTAssertEqual(
            Set(reconciled),
            ["com.apple.finder", "com.stonerl.Thaw"]
        )
    }

    func testDoesNotDuplicateALaunchedIdentifierAlreadyInTheSample() {
        let reconciled = MenuBarManagerActivityReconciler.reconciled(
            sample: ["com.apple.finder", "com.stonerl.Thaw"],
            launched: "com.stonerl.Thaw",
            terminated: nil
        )
        XCTAssertEqual(
            reconciled.filter { $0 == "com.stonerl.Thaw" }.count,
            1
        )
    }

    func testRemovesATerminatedIdentifierStillPresentInTheSample() {
        let reconciled = MenuBarManagerActivityReconciler.reconciled(
            sample: ["com.apple.finder", "com.stonerl.Thaw"],
            launched: nil,
            terminated: "com.stonerl.Thaw"
        )
        XCTAssertEqual(reconciled, ["com.apple.finder"])
    }

    func testATerminatedIdentifierAlreadyAbsentFromTheSampleIsANoOp() {
        let reconciled = MenuBarManagerActivityReconciler.reconciled(
            sample: ["com.apple.finder"],
            launched: nil,
            terminated: "com.stonerl.Thaw"
        )
        XCTAssertEqual(reconciled, ["com.apple.finder"])
    }

    func testNilLaunchedAndTerminatedReturnsTheSampleUnchanged() {
        let sample = ["com.apple.finder", "com.apple.Safari"]
        let reconciled = MenuBarManagerActivityReconciler.reconciled(
            sample: sample,
            launched: nil,
            terminated: nil
        )
        XCTAssertEqual(reconciled, sample)
    }
}

/// End-to-end tests proving the reconciler actually closes the launch/quit
/// races described in `MenuBarManagerActivityReconciler`'s doc comment: a
/// notification's payload reconciled against a stale resample must still
/// produce a transition the tracker reports, and an unrelated app must
/// still be a no-op even after going through reconciliation. These mirror
/// what `MenuBarManager.handleMenuBarManagerActivityChange(launched:terminated:)`
/// actually does — reconcile, then feed the result to the tracker — without
/// touching real `NSWorkspace` state.
final class MenuBarManagerActivityReconciliationTransitionTests: XCTestCase {
    func testALaunchedManagerMissingFromTheResampleIsStillDetectedAsATransition() {
        // Simulates the launch race: Thaw just launched, but the resampled
        // process list hasn't caught up yet and still doesn't list it.
        let tracker = MenuBarManagerTransitionTracker()
        let staleSample = ["com.apple.finder"]

        let reconciled = MenuBarManagerActivityReconciler.reconciled(
            sample: staleSample,
            launched: "com.stonerl.Thaw",
            terminated: nil
        )
        let changed = tracker.update(runningBundleIdentifiers: reconciled)

        XCTAssertTrue(changed)
        XCTAssertEqual(tracker.lastDetected?.displayName, "Thaw")
    }

    func testATerminatedManagerStillInTheResampleIsStillDetectedAsATransition() {
        // Simulates the terminate race: Thaw just quit, but the resampled
        // process list hasn't caught up yet and still lists it.
        let tracker = MenuBarManagerTransitionTracker(
            initialRunningBundleIdentifiers: ["com.stonerl.Thaw"]
        )
        let staleSample = ["com.stonerl.Thaw", "com.apple.finder"]

        let reconciled = MenuBarManagerActivityReconciler.reconciled(
            sample: staleSample,
            launched: nil,
            terminated: "com.stonerl.Thaw"
        )
        let changed = tracker.update(runningBundleIdentifiers: reconciled)

        XCTAssertTrue(changed)
        XCTAssertNil(tracker.lastDetected)
    }

    func testAnUnrelatedAppLaunchingIsStillNotATransitionAfterReconciliation() {
        let tracker = MenuBarManagerTransitionTracker(
            initialRunningBundleIdentifiers: ["com.apple.finder"]
        )
        let staleSample = ["com.apple.finder"]

        let reconciled = MenuBarManagerActivityReconciler.reconciled(
            sample: staleSample,
            launched: "com.apple.Safari",
            terminated: nil
        )
        let changed = tracker.update(runningBundleIdentifiers: reconciled)

        XCTAssertFalse(changed)
        XCTAssertNil(tracker.lastDetected)
    }
}
