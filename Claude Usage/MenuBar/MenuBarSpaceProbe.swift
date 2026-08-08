//
//  MenuBarSpaceProbe.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-08-07.
//

import Cocoa
import CoreGraphics

/// Supplies the real, measured numbers `MenuBarSpaceCalculator` needs,
/// behind a protocol so tests can inject a fake instead of touching real
/// screens or the window server. Every AppKit/CoreGraphics call this
/// feature makes lives here — `MenuBarSpaceCalculator` itself stays pure.
protocol MenuBarSpaceProbing {
    /// Builds a `MenuBarLayoutInput` from the current real screen and
    /// window-server state, or `nil` if no screen is available to measure
    /// against (e.g. a fully headless session before a display attaches).
    ///
    /// - Parameters:
    ///   - ourItemWidths: Widths of our own profile items, in display
    ///     order. The caller (`StatusBarUIManager`) supplies these since it
    ///     already tracks each profile's `NSStatusItem`.
    ///   - overflowItemWidth: Width of the "+N" overflow item, if one is
    ///     currently rendered.
    func makeLayoutInput(
        ourItemWidths: [CGFloat],
        overflowItemWidth: CGFloat
    ) -> MenuBarLayoutInput?
}

/// Production `MenuBarSpaceProbing`. Measures the screen that owns the menu
/// bar and every *other* application's status item width on it via
/// `CGWindowListCopyWindowInfo`.
///
/// This deliberately reads only a window's layer, owning process ID, and
/// bounds — never `kCGWindowName` (the window title). Per Apple's
/// documentation, only the window title is gated behind Screen Recording
/// permission; layer, owner, and bounds have always been available to any
/// process without prompting the user. Verified empirically against this
/// machine's real menu bar (Control Center alone hosts dozens of per-module
/// status windows on modern macOS) with zero permission prompt.
struct MenuBarSpaceProbe: MenuBarSpaceProbing {
    /// The window layer status items live on. Equivalent to
    /// `CGWindowLevelForKey(.statusWindow)`, which is what every status
    /// item — ours and everyone else's — is created at.
    private static var statusItemLayer: Int {
        Int(CGWindowLevelForKey(.statusWindow))
    }

    /// The screen AppKit documents as owning the menu bar: `NSScreen
    /// .screens[0]` is always the screen containing the menu bar and the
    /// global coordinate space's origin, regardless of which screen is
    /// `.main` (the one with the key window) or physically arranged where.
    var menuBarScreen: NSScreen? {
        NSScreen.screens.first
    }

    func makeLayoutInput(
        ourItemWidths: [CGFloat],
        overflowItemWidth: CGFloat
    ) -> MenuBarLayoutInput? {
        guard let screen = menuBarScreen else { return nil }
        return MenuBarLayoutInput(
            screenWidth: screen.frame.width,
            foreignItemsWidth: Self.foreignStatusItemWidth(on: screen),
            ourItemWidths: ourItemWidths,
            overflowItemWidth: overflowItemWidth
        )
    }

    /// Sums the width of every on-screen status item on `screen` that isn't
    /// owned by this process.
    static func foreignStatusItemWidth(on screen: NSScreen) -> CGFloat {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return 0
        }
        let ownPID = Int(getpid())
        let statusLayer = statusItemLayer
        let screenRangeX = screen.frame.minX...screen.frame.maxX

        var total: CGFloat = 0
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  layer == statusLayer,
                  let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
                  ownerPID != ownPID,
                  let boundsDict = window[kCGWindowBounds as String]
                    as? [String: CGFloat],
                  let x = boundsDict["X"],
                  let width = boundsDict["Width"],
                  screenRangeX.contains(x)
            else { continue }
            total += width
        }
        return total
    }
}
