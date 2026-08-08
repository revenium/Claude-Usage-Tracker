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
/// cannot be exercised here. What CAN be pinned in CI is the pure decision
/// logic two real bugs turned out to live in, both found — and both
/// measured with real numbers — only by running this feature on real
/// 3-monitor hardware:
///
/// 1. A naive global minimum over every on-screen status item can pick up
///    a DIFFERENT screen's full replica of the same items ("Displays have
///    separate Spaces" gives every screen its own copy, at a shifted x
///    range — including negative x). `isWithinScreen(x:screenFrame:)` is
///    the filter that excludes them.
/// 2. The frontmost app's active menu bar follows whichever screen has
///    focus, which is not always `NSScreen.screens.first`. Pairing an
///    unfiltered `appMenuMaxX` with a `statusRegionMinX` fixed to one
///    screen silently computes `freeWidth` from two different displays.
///    `screenFrame(containing:screenFrames:)` finds the correct screen
///    from the AX measurement itself instead of assuming a fixed one.
///
/// Every fixture number below (the three screen frames, the three
/// `appMenuMaxX` readings, and the three per-screen status-item replica
/// offsets) is a real measurement from this developer's actual 3-monitor
/// machine, not invented. See the commits that introduced these fixes for
/// how they were obtained.
final class MenuBarSpaceProbeTests: XCTestCase {
    /// The real 3-monitor layout: three 2560×1440 screens, contiguous in
    /// the global coordinate space, with the menu-bar-owning ("origin")
    /// screen in the middle of the x-range rather than at either extreme.
    private let origin = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    private let rightDisplay = CGRect(
        x: 2560, y: 0, width: 2560, height: 1440
    )
    private let leftDisplay = CGRect(
        x: -2560, y: 0, width: 2560, height: 1440
    )
    private var threeMonitorLayout: [CGRect] {
        [origin, rightDisplay, leftDisplay]
    }

    /// Real per-screen status-item replica anchors: with "Displays have
    /// separate Spaces", the identical set of status items is replicated
    /// onto every screen's own menu bar, each shifted into that screen's
    /// x-range. Measured directly (`CGWindowListCopyWindowInfo`, layer 25)
    /// on the real machine.
    private let originStatusItemsAnchorX: CGFloat = 1614
    private let rightDisplayStatusItemsAnchorX: CGFloat = 4177
    private let leftDisplayStatusItemsAnchorX: CGFloat = -946

    // MARK: - isWithinScreen(x:screenFrame:)

    func testIsWithinScreenAcceptsXInsideTheScreensRange() {
        XCTAssertTrue(
            MenuBarSpaceProbe.isWithinScreen(
                x: originStatusItemsAnchorX,
                screenFrame: origin
            )
        )
    }

    func testIsWithinScreenRejectsAnotherScreensReplicaOfTheSameItem() {
        // The exact regression this fixed: a status item belonging to the
        // left display's replica of the status-item set must never be
        // counted as "on" the origin (menu bar) screen.
        XCTAssertFalse(
            MenuBarSpaceProbe.isWithinScreen(
                x: leftDisplayStatusItemsAnchorX,
                screenFrame: origin
            )
        )
    }

    func testIsWithinScreenAcceptsBothInclusiveBoundaries() {
        XCTAssertTrue(
            MenuBarSpaceProbe.isWithinScreen(x: 0, screenFrame: origin)
        )
        XCTAssertTrue(
            MenuBarSpaceProbe.isWithinScreen(x: 2560, screenFrame: origin)
        )
    }

    func testIsWithinScreenRejectsXJustOutsideEitherBoundary() {
        XCTAssertFalse(
            MenuBarSpaceProbe.isWithinScreen(x: -0.5, screenFrame: origin)
        )
        XCTAssertFalse(
            MenuBarSpaceProbe.isWithinScreen(x: 2560.5, screenFrame: origin)
        )
    }

    // MARK: - screenFrame(containing:screenFrames:)

    func testScreenFrameContainingFindsTheCorrectDisplayAmongThree() {
        // Real appMenuMaxX readings, one per focused display.
        XCTAssertEqual(
            MenuBarSpaceProbe.screenFrame(
                containing: 234.0,  // focus: RevvySwarm, origin display
                screenFrames: threeMonitorLayout
            ),
            origin
        )
        XCTAssertEqual(
            MenuBarSpaceProbe.screenFrame(
                containing: 2984.0,  // focus: Notion, right display
                screenFrames: threeMonitorLayout
            ),
            rightDisplay
        )
        XCTAssertEqual(
            MenuBarSpaceProbe.screenFrame(
                containing: -1932.0,  // focus: Chrome, left display
                screenFrames: threeMonitorLayout
            ),
            leftDisplay
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
        // x = 2560 is simultaneously the origin screen's maxX and the
        // right display's minX. Exactly one screen must match.
        XCTAssertEqual(
            MenuBarSpaceProbe.screenFrame(
                containing: 2560,
                screenFrames: threeMonitorLayout
            ),
            rightDisplay
        )
    }

    // MARK: - The multi-display bug, reproduced and fixed with real numbers

    /// Reproduces, with the exact numbers measured live on the real
    /// machine, the silently-inflated `freeWidth` the bug produced: focus
    /// on the LEFT display gave `appMenuMaxX = -1932`, but the buggy code
    /// paired it with `statusRegionMinX` fixed to the origin screen
    /// (1614), yielding `1614 - (-1932) - 8 = 3538` — enough imaginary
    /// free space that the app would never collapse no matter how full
    /// the real menu bar was.
    ///
    /// With the fix, `statusRegionMinX` is measured on the SAME screen
    /// `appMenuMaxX` came from (here, the left display's own replica,
    /// anchored at -946), giving a small, sane, positive `freeWidth`.
    func testLeftDisplayFocusNoLongerProducesInflatedFreeWidth() {
        let appMenuMaxX: CGFloat = -1932.0
        let matchedScreen = MenuBarSpaceProbe.screenFrame(
            containing: appMenuMaxX,
            screenFrames: threeMonitorLayout
        )
        XCTAssertEqual(matchedScreen, leftDisplay)

        let buggyFreeWidth =
            originStatusItemsAnchorX - appMenuMaxX
                - MenuBarSpaceCalculator.gutter
        XCTAssertEqual(
            buggyFreeWidth, 3538,
            "sanity check against the measured bug reading"
        )

        let fixedFreeWidth =
            leftDisplayStatusItemsAnchorX - appMenuMaxX
                - MenuBarSpaceCalculator.gutter
        XCTAssertEqual(fixedFreeWidth, 978)
        XCTAssertLessThan(
            fixedFreeWidth, buggyFreeWidth,
            "the fix must not still report the inflated width"
        )
    }

    /// Same reproduction for the RIGHT display, where the bug produced a
    /// negative `freeWidth` (`1614 - 2984 - 8 = -1378`) that would
    /// collapse every profile even on a completely empty menu bar.
    func testRightDisplayFocusNoLongerProducesNegativeFreeWidth() {
        let appMenuMaxX: CGFloat = 2984.0
        let matchedScreen = MenuBarSpaceProbe.screenFrame(
            containing: appMenuMaxX,
            screenFrames: threeMonitorLayout
        )
        XCTAssertEqual(matchedScreen, rightDisplay)

        let buggyFreeWidth =
            originStatusItemsAnchorX - appMenuMaxX
                - MenuBarSpaceCalculator.gutter
        XCTAssertEqual(
            buggyFreeWidth, -1378,
            "sanity check against the measured bug reading"
        )

        let fixedFreeWidth =
            rightDisplayStatusItemsAnchorX - appMenuMaxX
                - MenuBarSpaceCalculator.gutter
        XCTAssertEqual(fixedFreeWidth, 1185)
        XCTAssertGreaterThan(
            fixedFreeWidth, 0,
            "the fix must not still report a negative width"
        )
    }

    /// The consistent (already-correct) case: focus on the origin display
    /// itself, both numbers naturally agreeing even without the fix.
    /// Included so the fix is shown to be a no-op in the case that always
    /// worked, not just a change in behavior everywhere.
    func testOriginDisplayFocusIsUnaffectedByTheFix() {
        let appMenuMaxX: CGFloat = 234.0
        XCTAssertEqual(
            MenuBarSpaceProbe.screenFrame(
                containing: appMenuMaxX,
                screenFrames: threeMonitorLayout
            ),
            origin
        )
        let freeWidth =
            originStatusItemsAnchorX - appMenuMaxX
                - MenuBarSpaceCalculator.gutter
        XCTAssertEqual(freeWidth, 1372)
    }
}
