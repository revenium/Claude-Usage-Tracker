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
