//
//  MenuBarSpaceCalculator.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-08-07.
//

import CoreGraphics

/// The plain-number inputs `MenuBarSpaceCalculator` needs to decide how many
/// of our own status items should collapse into the overflow item.
///
/// Deliberately contains no AppKit/CoreGraphics/Accessibility *calls* — only
/// the `CGFloat` type, which is just a number here. Every field is something
/// a caller measures once and hands in, which is what makes this type (and
/// the calculator that consumes it) fully unit-testable without a GUI.
/// `MenuBarSpaceProbe` is the production code that fills one of these in
/// from a real screen, the real window server, and the real Accessibility
/// tree.
///
/// Both boundaries are exact measurements, not estimates:
/// - `appMenuMaxX` is the right edge of the frontmost application's menu bar
///   menus (File, Edit, ...), read from its Accessibility tree.
/// - `statusRegionMinX` is the leftmost x of any on-screen status item
///   (ours or anyone else's — CGWindowList cannot attribute a status item
///   to its owning app, since macOS proxies every app's item through
///   Control Center, so this is a MINIMUM over all of them, not a sum of
///   "foreign" ones).
struct MenuBarLayoutInput: Equatable {
    /// Right edge (in the global menu-bar coordinate space) of the
    /// frontmost application's menu bar menus.
    let appMenuMaxX: CGFloat
    /// Left edge of the status item region on the screen that owns the
    /// menu bar.
    let statusRegionMinX: CGFloat
    /// Measured/estimated width of each of our own profile items, in the
    /// order they would be displayed.
    let ourItemWidths: [CGFloat]
    /// Width of the single "+N" overflow item, if one is rendered.
    let overflowItemWidth: CGFloat

    init(
        appMenuMaxX: CGFloat,
        statusRegionMinX: CGFloat,
        ourItemWidths: [CGFloat],
        overflowItemWidth: CGFloat
    ) {
        self.appMenuMaxX = appMenuMaxX
        self.statusRegionMinX = statusRegionMinX
        self.ourItemWidths = ourItemWidths
        self.overflowItemWidth = overflowItemWidth
    }
}

/// Pure decision logic for automatic (space-aware) menu bar overflow.
///
/// Given how much of the menu bar is actually free — the exact gap between
/// the frontmost app's menus and the status item region — decides how many
/// of our trailing profile items should collapse into the single "+N"
/// overflow item. Contains no AppKit/CoreGraphics/Accessibility *calls*:
/// everything it needs arrives as plain numbers in a `MenuBarLayoutInput`,
/// so it is entirely unit-testable without a GUI, unlike `MenuBarSpaceProbe`,
/// which measures those numbers.
enum MenuBarSpaceCalculator {
    /// Small fixed visual-spacing value so our leftmost item never butts
    /// directly against the frontmost app's last menu title. This is a
    /// deliberate layout-design constant, not a stand-in for anything we
    /// can't measure — both `appMenuMaxX` and `statusRegionMinX` are exact.
    static let gutter: CGFloat = 8

    /// Decides how many of our items should be collapsed into the overflow
    /// item, given the current layout and how many are collapsed right now.
    ///
    /// `currentCollapsedCount` drives hysteresis: collapsing further (space
    /// got tighter — e.g. the user switched to a wide-menu app) always
    /// applies immediately, but *expanding* back out (space got looser)
    /// only happens once there is a full extra average item width of slack
    /// beyond the bare minimum — otherwise a width that hovers right at the
    /// boundary would make items appear and disappear every recompute.
    /// This is the ONLY damping this calculator applies: it does not track
    /// a running minimum, and the layout is expected to visibly respond
    /// (correctly) every time the frontmost application changes.
    ///
    /// Never returns a count of exactly 1: collapsing a single profile into
    /// a "+1" item saves no menu bar space (one item just becomes another
    /// item) and looks broken. When only one item would be collapsed, either
    /// it is kept individual (0 collapsed) or a second item collapses with
    /// it (2 collapsed).
    static func collapsedCount(
        for input: MenuBarLayoutInput,
        currentCollapsedCount: Int
    ) -> Int {
        let itemCount = input.ourItemWidths.count
        guard itemCount > 1 else {
            // Collapsing a single item can never help — see the doc
            // comment above.
            return 0
        }
        let clampedCurrent = min(max(currentCollapsedCount, 0), itemCount)

        // Collapsing further is never deferred: if the actual free space
        // requires it right now, apply it immediately.
        let requiredNow = idealCollapsedCount(
            for: input,
            freeWidth: freeWidth(for: input)
        )
        if requiredNow > clampedCurrent {
            return requiredNow
        }

        // Expanding back out requires a margin of slack beyond the bare
        // minimum, so a width oscillating near the boundary doesn't flap
        // items in and out on every recompute.
        let margin = averageItemWidth(input.ourItemWidths)
        let requiredWithMargin = idealCollapsedCount(
            for: input,
            freeWidth: freeWidth(for: input) - margin
        )
        if requiredWithMargin < clampedCurrent {
            return requiredWithMargin
        }

        return clampedCurrent
    }

    /// The exact gap available for our own items: everything between the
    /// frontmost app's menus and the status item region, minus the gutter.
    private static func freeWidth(for input: MenuBarLayoutInput) -> CGFloat {
        input.statusRegionMinX - input.appMenuMaxX - gutter
    }

    private static func averageItemWidth(_ widths: [CGFloat]) -> CGFloat {
        guard !widths.isEmpty else { return 0 }
        return widths.reduce(0, +) / CGFloat(widths.count)
    }

    /// The collapsed count implied by `freeWidth` alone, with no hysteresis
    /// applied — the building block `collapsedCount(for:currentCollapsedCount:)`
    /// evaluates twice (once for the real free width, once with the margin
    /// subtracted).
    private static func idealCollapsedCount(
        for input: MenuBarLayoutInput,
        freeWidth: CGFloat
    ) -> Int {
        let widths = input.ourItemWidths
        let itemCount = widths.count
        guard itemCount > 1 else { return 0 }

        let totalWidth = widths.reduce(0, +)
        if totalWidth <= freeWidth {
            return 0
        }

        // Valid individually-shown counts, given the "never collapse
        // exactly one" rule: `itemCount` (nothing collapses — already
        // handled above) or 0...itemCount-2 (two or more collapse).
        // Search from the most generous down so we keep as many
        // individual items as will actually fit.
        var prefixSums: [CGFloat] = [0]
        prefixSums.reserveCapacity(itemCount + 1)
        for width in widths {
            prefixSums.append(prefixSums[prefixSums.count - 1] + width)
        }

        let maxIndividualCount = itemCount - 2
        for individualCount in stride(
            from: maxIndividualCount,
            through: 0,
            by: -1
        ) {
            if prefixSums[individualCount] + input.overflowItemWidth
                <= freeWidth {
                return itemCount - individualCount
            }
        }

        // Nothing fits even at maximum collapse (e.g. the overflow item
        // itself doesn't fit alongside any items). There is nothing better
        // to do than collapse everything.
        return itemCount
    }
}
