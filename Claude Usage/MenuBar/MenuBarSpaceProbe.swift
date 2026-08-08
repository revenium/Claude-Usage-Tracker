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
    func makeLayoutInput(
        ourItemWidths: [CGFloat],
        overflowItemWidth: CGFloat
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
/// Two independent measurements, both exact:
///
/// 1. `statusRegionMinX` — the leftmost x of any on-screen status item,
///    via `CGWindowListCopyWindowInfo` filtered to the status-item window
///    layer. This needs no permission (verified empirically: layer, owner,
///    and bounds are unrestricted; only `kCGWindowName`, which this probe
///    never reads, is gated behind Screen Recording). It is deliberately a
///    MINIMUM over every status item on screen, not a sum of "foreign"
///    ones — a status item's `kCGWindowOwnerPID` cannot be used to isolate
///    other apps' items from ours, because macOS proxies every
///    application's status item through Control Center: on this
///    developer's real machine, all on-screen status items (Claude Usage's
///    own included) report the same owning PID, Control Center's. An
///    earlier version of this probe filtered by owner PID on the mistaken
///    assumption that it isolated other apps' items; that filter was a
///    no-op that summed our own items into what it called
///    "foreignItemsWidth", which would have collapsed our own layout more
///    aggressively than actually needed. Do not reintroduce PID-based
///    attribution for status items.
///
/// 2. `frontmostAppMenuMaxX` — the right edge of the frontmost
///    application's menu bar menus, via its Accessibility tree
///    (`kAXMenuBarAttribute`). This DOES need the user's explicit
///    Accessibility grant (see `MenuBarAccessibilityAccess`), and is the
///    only reason this feature asks for one.
struct MenuBarSpaceProbe: MenuBarSpaceProbing {
    /// Bounds every Accessibility round-trip to a fraction of a second, so
    /// an unresponsive frontmost application can never hang our main
    /// thread waiting on its menu bar. Set once on the application element;
    /// per Apple's documentation it is inherited by every accessibility
    /// object subsequently obtained through it (its menu bar, that menu
    /// bar's children, ...).
    private static let axMessagingTimeoutSeconds: Float = 0.25

    private static var statusItemLayer: Int {
        Int(CGWindowLevelForKey(.statusWindow))
    }

    func makeLayoutInput(
        ourItemWidths: [CGFloat],
        overflowItemWidth: CGFloat
    ) -> MenuBarLayoutInput? {
        guard MenuBarAccessibilityAccess.isTrusted(),
              let statusRegionMinX = Self.statusRegionMinX(),
              let appMenuMaxX = Self.frontmostAppMenuMaxX()
        else {
            return nil
        }
        return MenuBarLayoutInput(
            appMenuMaxX: appMenuMaxX,
            statusRegionMinX: statusRegionMinX,
            ourItemWidths: ourItemWidths,
            overflowItemWidth: overflowItemWidth
        )
    }

    /// Leftmost x of any on-screen status item. See the type-level doc
    /// comment for why this is a minimum over every item rather than a sum
    /// of "foreign" ones.
    static func statusRegionMinX() -> CGFloat? {
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
                  let x = boundsDict["X"]
            else { continue }
            minX = minX.map { Swift.min($0, x) } ?? x
        }
        return minX
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

        var maxX: CGFloat?
        for child in children {
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
