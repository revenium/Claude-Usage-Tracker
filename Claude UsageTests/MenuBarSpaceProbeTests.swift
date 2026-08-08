//
//  MenuBarSpaceProbeTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-08-07.
//

import CoreGraphics
import XCTest
@testable import Claude_Usage

/// Pure-logic tests for `MenuBarSpaceProbe`'s screen-matching helpers.
///
/// `MenuBarSpaceProbe.statusRegionMinX(in:)` and `.frontmostAppMenuMaxX()`
/// themselves call real `CGWindowListCopyWindowInfo`/Accessibility APIs and
/// cannot be exercised here — real multi-monitor geometry can only be
/// proven live (see the diagnostic run described in the commit that added
/// these helpers). What CAN be pinned in CI is the pure decision logic two
/// real bugs turned out to live in, both found only by running this
/// feature on real 3-monitor hardware:
///
/// 1. A naive global minimum over every on-screen status item can pick up
///    a DIFFERENT screen's full replica of the same items ("Displays have
///    separate Spaces" gives every screen its own copy) — including
///    negative x values. `isWithinScreen(x:screenFrame:)` is the filter
///    that excludes them.
/// 2. The frontmost app's active menu bar follows whichever screen has
///    focus, which is not always `NSScreen.screens.first`. `screenFrame
///    (containing:screenFrames:)` is what finds the correct screen from
///    the AX measurement instead of assuming a fixed one.
final class MenuBarSpaceProbeTests: XCTestCase {
    // MARK: - isWithinScreen(x:screenFrame:)

    func testIsWithinScreenAcceptsXInsideTheScreensRange() {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        XCTAssertTrue(
            MenuBarSpaceProbe.isWithinScreen(x: 1614, screenFrame: screen)
        )
    }

    func testIsWithinScreenRejectsAnotherScreensReplicaOfTheSameItem() {
        // The exact regression this fixed: on this developer's real
        // 3-monitor machine, CGWindowList returned the identical set of
        // status items three times — once per screen — with display 3's
        // copy sitting at negative x (screen 3's frame: -2560...0). A
        // status item belonging to that replica must never be counted as
        // "on" the menu bar screen (0...2560).
        let menuBarScreen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let statusItemXOnDisplay3Replica: CGFloat = -946
        XCTAssertFalse(
            MenuBarSpaceProbe.isWithinScreen(
                x: statusItemXOnDisplay3Replica,
                screenFrame: menuBarScreen
            )
        )
    }

    func testIsWithinScreenAcceptsBothInclusiveBoundaries() {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        XCTAssertTrue(
            MenuBarSpaceProbe.isWithinScreen(x: 0, screenFrame: screen)
        )
        XCTAssertTrue(
            MenuBarSpaceProbe.isWithinScreen(x: 2560, screenFrame: screen)
        )
    }

    func testIsWithinScreenRejectsXJustOutsideEitherBoundary() {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        XCTAssertFalse(
            MenuBarSpaceProbe.isWithinScreen(x: -0.5, screenFrame: screen)
        )
        XCTAssertFalse(
            MenuBarSpaceProbe.isWithinScreen(x: 2560.5, screenFrame: screen)
        )
    }

    // MARK: - screenFrame(containing:screenFrames:)

    /// The exact 3-monitor layout measured on this developer's real
    /// machine: three 2560×1440 screens, contiguous in the global
    /// coordinate space, with the menu-bar-owning screen in the middle of
    /// the x-range rather than at either extreme.
    private let threeMonitorLayout: [CGRect] = [
        CGRect(x: 0, y: 0, width: 2560, height: 1440),
        CGRect(x: 2560, y: 0, width: 2560, height: 1440),
        CGRect(x: -2560, y: 0, width: 2560, height: 1440),
    ]

    func testScreenFrameContainingFindsTheCorrectDisplayAmongThree() {
        // Focus on display 1 (0...2560): a menu bar boundary measured
        // there must resolve to display 1's frame, not any other.
        XCTAssertEqual(
            MenuBarSpaceProbe.screenFrame(
                containing: 234,
                screenFrames: threeMonitorLayout
            ),
            threeMonitorLayout[0]
        )
        // Focus on display 2 (2560...5120).
        XCTAssertEqual(
            MenuBarSpaceProbe.screenFrame(
                containing: 2794,
                screenFrames: threeMonitorLayout
            ),
            threeMonitorLayout[1]
        )
        // Focus on display 3 (-2560...0).
        XCTAssertEqual(
            MenuBarSpaceProbe.screenFrame(
                containing: -2326,
                screenFrames: threeMonitorLayout
            ),
            threeMonitorLayout[2]
        )
    }

    func testScreenFrameContainingReturnsNilWhenNoScreenMatches() {
        XCTAssertNil(
            MenuBarSpaceProbe.screenFrame(
                containing: 100_000,
                screenFrames: threeMonitorLayout
            )
        )
    }

    func testScreenFrameContainingNeverMatchesTwoContiguousScreensAtTheSharedBoundary() {
        // x = 2560 is simultaneously screen 1's maxX and screen 2's minX.
        // Exactly one screen must match, not zero and not both.
        let match = MenuBarSpaceProbe.screenFrame(
            containing: 2560,
            screenFrames: threeMonitorLayout
        )
        XCTAssertEqual(match, threeMonitorLayout[1])
    }

    /// This is the scenario the second live-verification bug report
    /// described: measuring the AX menu bar on one screen while scanning
    /// status items filtered to a DIFFERENT, fixed screen produces a wrong
    /// `freeWidth` in either direction. Asserting that `screenFrame(
    /// containing:)` picks display 2 (not display 1) when focus is on
    /// display 2 is what a fixed `NSScreen.screens.first` fallback would
    /// have gotten wrong.
    func testScreenFrameContainingFollowsFocusRatherThanAFixedDisplay() {
        let focusedOnDisplay2AppMenuMaxX: CGFloat = 2794
        XCTAssertEqual(
            MenuBarSpaceProbe.screenFrame(
                containing: focusedOnDisplay2AppMenuMaxX,
                screenFrames: threeMonitorLayout
            ),
            threeMonitorLayout[1],
            "must resolve to the focused display, not screens.first"
        )
    }
}
