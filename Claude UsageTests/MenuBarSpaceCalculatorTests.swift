//
//  MenuBarSpaceCalculatorTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-08-07.
//

import CoreGraphics
import XCTest
@testable import Claude_Usage

/// Pure-logic tests for `MenuBarSpaceCalculator`. Every case here constructs
/// its own `MenuBarLayoutInput` by hand — no AppKit, no screens, no status
/// items — which is exactly the point: this is the part of the space-aware
/// overflow feature that doesn't need a GUI to be fully exercised.
final class MenuBarSpaceCalculatorTests: XCTestCase {
    /// Builds an input with exactly `freeWidth` of room between the
    /// (fictional) frontmost app's menus and the status item region,
    /// starting from an arbitrary `appMenuMaxX` (default 0, as if the
    /// frontmost app had no menus at all) so tests can also exercise a
    /// nonzero app-menu boundary without hand-deriving `statusRegionMinX`.
    private func input(
        freeWidth: CGFloat,
        ourItemWidths: [CGFloat],
        overflowItemWidth: CGFloat = 20,
        appMenuMaxX: CGFloat = 0,
        currentlyOnScreenWidth: CGFloat = 0
    ) -> MenuBarLayoutInput {
        // `freeWidth` names the space genuinely free of OUR items, so the
        // status region is placed as the window server would report it —
        // pushed left by whatever we already occupy.
        MenuBarLayoutInput(
            appMenuMaxX: appMenuMaxX,
            statusRegionMinX: appMenuMaxX
                + freeWidth
                + MenuBarSpaceCalculator.gutter
                - currentlyOnScreenWidth,
            ourItemWidths: ourItemWidths,
            overflowItemWidth: overflowItemWidth,
            currentlyOnScreenWidth: currentlyOnScreenWidth
        )
    }

    // MARK: - Basic fit

    func testAllItemsFitProducesNoOverflow() {
        let layout = input(
            freeWidth: 1300,
            ourItemWidths: [40, 40, 40, 40, 40],
            overflowItemWidth: 30
        )
        XCTAssertEqual(
            MenuBarSpaceCalculator.collapsedCount(
                for: layout,
                currentCollapsedCount: 0
            ),
            0
        )
    }

    func testSingleItemNeverCollapsesEvenWhenItDoesNotFit() {
        let layout = input(
            freeWidth: 10,
            ourItemWidths: [500],
            overflowItemWidth: 30
        )
        XCTAssertEqual(
            MenuBarSpaceCalculator.collapsedCount(
                for: layout,
                currentCollapsedCount: 0
            ),
            0,
            "Collapsing the only item into \"+1\" saves no space, so a "
                + "single item must never collapse regardless of fit"
        )
    }

    func testInsufficientSpaceCollapsesImmediately() {
        // Free space suddenly too small for anything (e.g. a monitor was
        // unplugged). Must collapse right away — no hysteresis applies
        // when *tightening*.
        let layout = input(
            freeWidth: 40,
            ourItemWidths: [40, 40, 40, 40],
            overflowItemWidth: 20
        )
        XCTAssertEqual(
            MenuBarSpaceCalculator.collapsedCount(
                for: layout,
                currentCollapsedCount: 0
            ),
            4
        )
    }

    func testCollapsesOnlyAsManyAsNecessary() {
        // 5 items of width 40 (total 200), overflow item 30, free width
        // 100: only individualCount=1 (40+30=70<=100) fits; individualCount=2
        // (80+30=110) does not. Expect 4 collapsed, 1 kept individual.
        let layout = input(
            freeWidth: 100,
            ourItemWidths: [40, 40, 40, 40, 40],
            overflowItemWidth: 30
        )
        XCTAssertEqual(
            MenuBarSpaceCalculator.collapsedCount(
                for: layout,
                currentCollapsedCount: 0
            ),
            4
        )
    }

    // MARK: - Never collapse exactly one

    func testNeverCollapsesExactlyOneAtABoundaryThatWouldFitTwoIndividualItems() {
        // 3 items of width 10 (total 30), overflow width 5, free width 25:
        // "2 individual + 1 collapsed" (20 + 5 = 25) would fit exactly, but
        // collapsing exactly one profile is forbidden, so the calculator
        // must fall back to collapsing two instead of picking the
        // would-otherwise-ideal split.
        let layout = input(
            freeWidth: 25,
            ourItemWidths: [10, 10, 10],
            overflowItemWidth: 5
        )
        XCTAssertEqual(
            MenuBarSpaceCalculator.collapsedCount(
                for: layout,
                currentCollapsedCount: 0
            ),
            2
        )
    }

    func testNeverReturnsExactlyOneAcrossAnEntireRangeOfFreeWidths() {
        let widths: [CGFloat] = [30, 45, 20, 60, 25]
        let overflowWidth: CGFloat = 15
        for rawFreeWidth in stride(
            from: CGFloat(0),
            through: 220,
            by: 1
        ) {
            let layout = input(
                freeWidth: rawFreeWidth,
                ourItemWidths: widths,
                overflowItemWidth: overflowWidth
            )
            let collapsed = MenuBarSpaceCalculator.collapsedCount(
                for: layout,
                currentCollapsedCount: 0
            )
            XCTAssertNotEqual(
                collapsed,
                1,
                "freeWidth=\(rawFreeWidth) produced a lone \"+1\" "
                    + "overflow item"
            )
        }
    }

    // MARK: - Hysteresis

    func testHysteresisPreventsOscillationNearTheCollapseBoundary() {
        // 4 items of width 40, overflow width 20. Working out the raw
        // (no-hysteresis) thresholds:
        //   freeWidth >= 160         -> 0 collapsed (everything fits)
        //   100 <= freeWidth < 160   -> 2 collapsed
        //   60  <= freeWidth < 100   -> 3 collapsed
        //   20  <= freeWidth < 60    -> 4 collapsed
        // The average item width (the hysteresis margin) is 40.
        let widths: [CGFloat] = [40, 40, 40, 40]

        func layout(freeWidth: CGFloat) -> MenuBarLayoutInput {
            input(
                freeWidth: freeWidth,
                ourItemWidths: widths,
                overflowItemWidth: 20
            )
        }

        // Bootstrap solidly inside the "3 collapsed" band.
        var collapsed = MenuBarSpaceCalculator.collapsedCount(
            for: layout(freeWidth: 90),
            currentCollapsedCount: 0
        )
        XCTAssertEqual(collapsed, 3)

        // Crossing the raw "2 collapsed" threshold (100) must NOT expand
        // immediately: only a full margin (40) of slack beyond it may.
        for freeWidth: CGFloat in [100, 105, 110, 120, 139] {
            collapsed = MenuBarSpaceCalculator.collapsedCount(
                for: layout(freeWidth: freeWidth),
                currentCollapsedCount: collapsed
            )
            XCTAssertEqual(
                collapsed,
                3,
                "freeWidth=\(freeWidth) is within the hysteresis margin "
                    + "of the collapse threshold and must not expand yet"
            )
        }

        // Once there is a full margin of slack beyond the threshold
        // (100 + 40 = 140), expanding back out is safe.
        collapsed = MenuBarSpaceCalculator.collapsedCount(
            for: layout(freeWidth: 140),
            currentCollapsedCount: collapsed
        )
        XCTAssertEqual(collapsed, 2)

        // Oscillating back down past the raw threshold must re-collapse
        // immediately — hysteresis only guards expansion, not collapse.
        collapsed = MenuBarSpaceCalculator.collapsedCount(
            for: layout(freeWidth: 95),
            currentCollapsedCount: collapsed
        )
        XCTAssertEqual(collapsed, 3)
    }

    func testWidthOscillatingWithinTheMarginStaysStable() {
        let widths: [CGFloat] = [40, 40, 40, 40]
        func layout(freeWidth: CGFloat) -> MenuBarLayoutInput {
            input(
                freeWidth: freeWidth,
                ourItemWidths: widths,
                overflowItemWidth: 20
            )
        }

        var collapsed = MenuBarSpaceCalculator.collapsedCount(
            for: layout(freeWidth: 90),
            currentCollapsedCount: 0
        )
        XCTAssertEqual(collapsed, 3)

        // Bounce the free width back and forth across the raw 100pt
        // threshold, always staying within the 40pt margin of it. The
        // collapsed count must never move.
        let bouncingWidths: [CGFloat] = [
            105, 95, 110, 90, 100, 130, 92,
        ]
        for freeWidth in bouncingWidths {
            collapsed = MenuBarSpaceCalculator.collapsedCount(
                for: layout(freeWidth: freeWidth),
                currentCollapsedCount: collapsed
            )
            XCTAssertEqual(
                collapsed,
                3,
                "freeWidth=\(freeWidth) oscillates within the hysteresis "
                    + "margin and must not change the collapsed count"
            )
        }
    }

    // MARK: - Self-inclusion of our own items (regression)

    /// The status region's left edge is the leftmost status item on the
    /// screen — and once we have rendered, that is one of OURS. Measuring
    /// the gap after we are placed and then comparing our full width
    /// against it subtracts our width twice.
    ///
    /// Measured on real hardware: the region's edge moved 1566 -> 1342
    /// purely because this app rendered six items totalling ~224pt.
    func testFreeWidthIsUnchangedByWhetherOurItemsAreAlreadyOnScreen() {
        let widths: [CGFloat] = [100, 100, 100, 100, 100]

        // Same physical situation, measured at two different moments:
        // before we have rendered anything, and after all 500pt of us is up.
        let beforeRendering = input(
            freeWidth: 534,
            ourItemWidths: widths,
            currentlyOnScreenWidth: 0
        )
        let afterRendering = input(
            freeWidth: 534,
            ourItemWidths: widths,
            currentlyOnScreenWidth: 500
        )

        let collapsedBefore = MenuBarSpaceCalculator.collapsedCount(
            for: beforeRendering,
            currentCollapsedCount: 0
        )
        let collapsedAfter = MenuBarSpaceCalculator.collapsedCount(
            for: afterRendering,
            currentCollapsedCount: 0
        )

        XCTAssertEqual(
            collapsedBefore, 0,
            "500pt of items fit in 534pt of genuinely free space"
        )
        XCTAssertEqual(
            collapsedAfter, collapsedBefore,
            """
            The verdict must not depend on whether our items happened to be \
            on screen when the measurement was taken. Without adding \
            currentlyOnScreenWidth back, the region reads 500pt further \
            left, the apparent free width collapses to 34pt, and 500pt of \
            items 'no longer fit' — the double-count.
            """
        )
    }

    /// The feedback loop the invariant above forecloses: collapsing frees
    /// space, which invites expanding, which consumes it again. Driving the
    /// calculator from its own previous verdict must reach a fixed point.
    func testRepeatedRecomputesFromOwnOutputReachAFixedPoint() {
        let widths: [CGFloat] = [100, 100, 100, 100, 100]
        var collapsed = 0

        var seen: [Int] = []
        for _ in 0..<8 {
            // Only the items still individual are on screen; a collapsed
            // group is one overflow item instead.
            let individualCount = widths.count - collapsed
            let onScreen = widths.prefix(individualCount).reduce(0, +)
                + (collapsed > 0 ? 20 : 0)
            collapsed = MenuBarSpaceCalculator.collapsedCount(
                for: input(
                    freeWidth: 534,
                    ourItemWidths: widths,
                    currentlyOnScreenWidth: onScreen
                ),
                currentCollapsedCount: collapsed
            )
            seen.append(collapsed)
        }

        XCTAssertEqual(
            Set(seen.suffix(4)).count, 1,
            "layout must settle, not oscillate; saw \(seen)"
        )
        XCTAssertEqual(
            seen.last, 0,
            "500pt fits in 534pt, so the fixed point is 'nothing collapsed'"
        )
    }
}
