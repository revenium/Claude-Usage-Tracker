//
//  MenuBarSpaceProbe.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-08-07.
//

import Cocoa
import ApplicationServices
import CoreGraphics

/// Supplies the real, measured numbers `MenuBarSpaceCalculator` needs,
/// behind a protocol so tests can inject a fake instead of touching real
/// screens, the window server, or the Accessibility tree. Every
/// AppKit/CoreGraphics/Accessibility call this feature makes lives here —
/// `MenuBarSpaceCalculator` itself stays pure.
protocol MenuBarSpaceProbing {
    /// Builds a `MenuBarLayoutInput` from the current real screen, window
    /// server, and Accessibility state, or `nil` if either boundary can't
    /// currently be measured (no Accessibility grant, no frontmost app menu
    /// bar, or no on-screen status items to anchor the status region). A
    /// `nil` result means `.automatic` mode falls back to showing every
    /// profile individually rather than guessing.
    ///
    /// - Parameters:
    ///   - ourItemWidths: Widths of our own profile items, in display
    ///     order. The caller (`StatusBarUIManager`) supplies these since it
    ///     already tracks each profile's `NSStatusItem`.
    ///   - overflowItemWidth: Width of the "+N" overflow item, if one is
    ///     currently rendered.
    ///   - currentlyOnScreenWidth: Total width of our own items already on
    ///     the menu bar, which the measured status region therefore already
    ///     accounts for. Zero on a first layout. See
    ///     `MenuBarLayoutInput.currentlyOnScreenWidth` for why omitting this
    ///     double-counts our own width.
    func makeLayoutInput(
        ourItemWidths: [CGFloat],
        overflowItemWidth: CGFloat,
        currentlyOnScreenWidth: CGFloat
    ) -> MenuBarLayoutInput?
}

/// The single source of truth for "do we currently have the Accessibility
/// grant this feature needs", and the only place that ever asks for it.
///
/// Reads exactly one thing from the Accessibility tree anywhere in this
/// feature: `kAXMenuBarAttribute`'s children's position/size, on the
/// frontmost application only (see `MenuBarSpaceProbe.frontmostAppMenuMaxX`).
/// No other attribute, and no other application, is ever touched.
enum MenuBarAccessibilityAccess {
    /// Silent check — safe to call at any time, including on every launch.
    /// Never itself triggers the system permission prompt.
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the system Accessibility permission dialog. Call ONLY from
    /// an explicit user action (a Settings button) — never at launch or
    /// silently in the background, per Apple's guidance and this app's own
    /// rule of never surprising the user with a permission prompt.
    @discardableResult
    static func requestAccess() -> Bool {
        let options: [String: Any] = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}

/// Production `MenuBarSpaceProbing`.
///
/// Two independent measurements, both exact — and, critically, both taken
/// on the SAME physical screen:
///
/// 1. `frontmostAppMenuMaxX` — the right edge of the frontmost
///    application's menu bar menus, via its Accessibility tree
///    (`kAXMenuBarAttribute`). This DOES need the user's explicit
///    Accessibility grant (see `MenuBarAccessibilityAccess`), and is the
///    only reason this feature asks for one.
///
/// 2. `statusRegionMinX` — the leftmost x of any status item **on the same
///    screen `frontmostAppMenuMaxX` was measured on**, via
///    `CGWindowListCopyWindowInfo` filtered to the status-item window
///    layer. This needs no permission (verified empirically: layer, owner,
///    and bounds are unrestricted; only `kCGWindowName`, which this probe
///    never reads, is gated behind Screen Recording).
///
/// Both the "which screen" step and the "minimum over that screen's items"
/// step matter, and both were bugs found only by running this live on
/// multi-monitor hardware — no unit test with fabricated numbers could
/// have caught either:
///
/// - With "Displays have separate Spaces" (the default), macOS gives every
///   screen its own menu bar AND its own full copy of every status item —
///   on this developer's 3-monitor machine, `CGWindowListCopyWindowInfo`
///   returns the identical set of status items three times, once per
///   screen, each shifted into that screen's x-range. A naive global
///   minimum can land on a different screen's copy entirely, including a
///   *negative* x on some physical arrangements.
/// - Separately, the frontmost app's active menu bar follows whichever
///   screen has focus under that same "separate Spaces" setting — it is
///   NOT always `NSScreen.screens.first` (documented as the screen with
///   the global coordinate origin, which is a different fact). Filtering
///   `statusRegionMinX` to a fixed screen while `frontmostAppMenuMaxX`
///   follows the focused one lets the two numbers describe two different
///   displays, producing a wildly wrong (in either direction) `freeWidth`
///   that is silently wrong rather than crashing.
///
/// The fix for both: derive which screen to use FROM the AX measurement
/// (`screenFrame(containing:screenFrames:)`), and use that same screen for
/// the status-item scan (`statusRegionMinX(in:)`) — never `screens.first`
/// as a fallback, which is exactly the mismatch this eliminates.
///
/// A status item's `kCGWindowOwnerPID` cannot be used to isolate other
/// apps' items from ours, because macOS proxies every application's status
/// item through Control Center: on this developer's machine, all on-screen
/// status items (Claude Usage's own included) report the same owning PID,
/// Control Center's. An earlier version of this probe filtered by owner
/// PID on the mistaken assumption that it isolated other apps' items; that
/// filter was a no-op that summed our own items into what it called
/// "foreignItemsWidth". Do not reintroduce PID-based attribution for
/// status items.
struct MenuBarSpaceProbe: MenuBarSpaceProbing {
    /// Bounds each individual Accessibility round-trip. Set once on the
    /// application element; per Apple's documentation it is inherited by
    /// every accessibility object subsequently obtained through it (its
    /// menu bar, that menu bar's children, ...).
    ///
    /// This bounds each MESSAGE, not the total work: reading N menu titles
    /// costs 2N round-trips, so a slow-but-not-hung application with many
    /// menus could still stall the main thread for seconds. See
    /// `axTotalBudgetSeconds`, which bounds the loop itself.
    private static let axMessagingTimeoutSeconds: Float = 0.25

    /// Wall-clock ceiling on reading the whole menu bar, enforced across
    /// the child loop. Without it the per-message timeout above multiplies
    /// by the number of menu titles — and this runs synchronously on the
    /// main thread from a debounced recompute that fires on every
    /// application switch, so an unbounded loop is a visible hang.
    ///
    /// Exceeding the budget yields a partial measurement rather than a
    /// wrong one: the caller treats a `nil` result as "unmeasurable" and
    /// shows every profile its own item.
    private static let axTotalBudgetSeconds: Double = 0.5

    private static var statusItemLayer: Int {
        Int(CGWindowLevelForKey(.statusWindow))
    }

    func makeLayoutInput(
        ourItemWidths: [CGFloat],
        overflowItemWidth: CGFloat,
        currentlyOnScreenWidth: CGFloat
    ) -> MenuBarLayoutInput? {
        guard MenuBarAccessibilityAccess.isTrusted(),
              let appMenuMaxX = Self.frontmostAppMenuMaxX(),
              let activeScreenFrame = Self.screenFrame(
                  containing: appMenuMaxX,
                  screenFrames: NSScreen.screens.map(\.frame)
              ),
              let statusRegionMinX = Self.statusRegionMinX(
                  in: activeScreenFrame
              )
        else {
            return nil
        }
        return MenuBarLayoutInput(
            appMenuMaxX: appMenuMaxX,
            statusRegionMinX: statusRegionMinX,
            ourItemWidths: ourItemWidths,
            overflowItemWidth: overflowItemWidth,
            currentlyOnScreenWidth: currentlyOnScreenWidth
        )
    }

    /// Pure decision logic, independent of `NSScreen`, for which physical
    /// display's frame contains a given global x-coordinate — modeled on
    /// `StatusItemPositionSanitizer.staleKeys(in:screenFrames:)` for the
    /// same reason: screen geometry is exactly the kind of real-hardware-
    /// only fact that must be testable with plain `CGRect` values, not
    /// real `NSScreen` instances (which cannot be fabricated in a test).
    ///
    /// Half-open on the upper bound so two contiguous screens sharing a
    /// boundary x-value are never both considered a match.
    ///
    /// Returns `nil` if no screen's frame contains `x` — deliberately no
    /// fallback to a default screen, since a fallback here is exactly the
    /// screen-mismatch bug this function exists to eliminate.
    ///
    /// Also returns `nil` when MORE than one screen contains `x`, which
    /// happens on vertically stacked or overlapping display arrangements
    /// where two screens share an x-range. Matching on x alone cannot
    /// distinguish them, and picking either one would resurrect the
    /// cross-display mismatch above. Disambiguating on y is deliberately
    /// NOT attempted: Accessibility reports a top-left origin with y
    /// increasing downward while `NSScreen.frame` uses a bottom-left origin
    /// with y increasing upward, so the conversion is easy to get subtly
    /// wrong and impossible to verify without stacked hardware. Declining
    /// to measure is the safe outcome — the caller shows every profile its
    /// own item rather than acting on a number that may describe the wrong
    /// display.
    static func screenFrame(
        containing x: CGFloat,
        screenFrames: [CGRect]
    ) -> CGRect? {
        let matches = screenFrames.filter { $0.minX <= x && x < $0.maxX }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Leftmost x of any on-screen status item whose x falls within
    /// `screenFrame`. See the type-level doc comment for why this must be
    /// restricted to one screen, and why that screen must be the same one
    /// `frontmostAppMenuMaxX` was measured on.
    static func statusRegionMinX(in screenFrame: CGRect) -> CGFloat? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        let layer = statusItemLayer
        var minX: CGFloat?
        for window in windows {
            guard let windowLayer = window[kCGWindowLayer as String] as? Int,
                  windowLayer == layer,
                  let boundsDict = window[kCGWindowBounds as String]
                    as? [String: CGFloat],
                  let x = boundsDict["X"],
                  isWithinScreen(x: x, screenFrame: screenFrame)
            else { continue }
            minX = minX.map { Swift.min($0, x) } ?? x
        }
        return minX
    }

    /// Pure decision logic behind `statusRegionMinX(in:)`'s screen filter,
    /// extracted so the exact regression this fixed (a status item at a
    /// screen's own negative-x copy of the set being mistaken for a
    /// same-screen item) is unit-testable with plain numbers.
    ///
    /// Half-open on the upper bound, matching `screenFrame(containing:)`.
    /// Both functions answer the same question — "which screen owns this
    /// x?" — so they must agree on which side owns a shared boundary. A
    /// closed upper bound here let a status item sitting exactly on the
    /// seam between two contiguous displays be claimed by both, which is a
    /// narrower form of the cross-screen contamination this file exists to
    /// prevent.
    static func isWithinScreen(x: CGFloat, screenFrame: CGRect) -> Bool {
        screenFrame.minX <= x && x < screenFrame.maxX
    }

    /// Right edge of the frontmost application's menu bar menus (File,
    /// Edit, View, ...), read from its Accessibility tree.
    static func frontmostAppMenuMaxX() -> CGFloat? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let axApp = AXUIElementCreateApplication(
            frontApp.processIdentifier
        )
        AXUIElementSetMessagingTimeout(axApp, axMessagingTimeoutSeconds)

        guard let menuBar = axElement(
            axApp,
            attribute: kAXMenuBarAttribute
        ) else {
            return nil
        }

        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            menuBar,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success,
              let children = childrenValue as? [AXUIElement]
        else {
            return nil
        }

        // Bound the whole loop, not just each message — see
        // `axTotalBudgetSeconds`. A slow frontmost application must degrade
        // to "unmeasurable", never to a multi-second main-thread stall.
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(axTotalBudgetSeconds * 1_000_000_000)
        var maxX: CGFloat?
        for child in children {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                // Out of budget with menus left unread. Any maxX gathered so
                // far is an UNDER-estimate of the true right edge, which
                // would overstate free space and under-collapse. Discard it.
                return nil
            }
            guard let frame = frame(of: child) else { continue }
            let rightEdge = frame.origin.x + frame.size.width
            maxX = maxX.map { Swift.max($0, rightEdge) } ?? rightEdge
        }
        return maxX
    }

    /// Reads an `AXUIElement`-typed attribute off `element`, or `nil` if
    /// the read fails or the attribute isn't actually an `AXUIElement`
    /// (both are routine — e.g. the frontmost app not exposing a menu bar).
    private static func axElement(
        _ element: AXUIElement,
        attribute: String
    ) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        // Safe: type-checked against AXUIElementGetTypeID() immediately
        // above.
        return (value as! AXUIElement)
    }

    /// Reads `kAXPosition`/`kAXSize` off an `AXUIElement` (a menu bar
    /// child, in practice) into a plain `CGRect`.
    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
              AXUIElementCopyAttributeValue(
                element,
                kAXSizeAttribute as CFString,
                &sizeValue
              ) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(
            // Safe: type-checked against AXValueGetTypeID() immediately
            // above.
            positionValue as! AXValue,
            .cgPoint,
            &position
        ),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }
}
