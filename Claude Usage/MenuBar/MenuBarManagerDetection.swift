//
//  MenuBarManagerDetection.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-08-08.
//

import AppKit

/// Supplies the bundle identifiers of every currently running application,
/// behind a protocol so the manager-detection guard in
/// `StatusBarUIManager.overflowPlan(for:mode:currentCollapsedCount:spaceInput:runningBundleIdentifiers:)`
/// can be exercised in a unit test without touching real `NSWorkspace`
/// state. Mirrors `MenuBarSpaceProbing`'s injection pattern for the same
/// reason: the production implementation is a one-line AppKit call, but
/// nothing that calls it directly is testable without a live process list.
protocol RunningApplicationBundleIdentifiersProviding {
    var runningBundleIdentifiers: [String] { get }
}

/// Production `RunningApplicationBundleIdentifiersProviding`.
struct NSWorkspaceRunningApplications:
    RunningApplicationBundleIdentifiersProviding
{
    var runningBundleIdentifiers: [String] {
        NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
    }
}

/// Menu bar managers (Bartender, Ice, ...) solve the exact overflow problem
/// `.automatic` mode does, by reserving an expandable region of the menu bar
/// that items can be dragged into or revealed from. When one of these is
/// running, `.automatic` mode's own free-space measurement is not wrong —
/// the bar genuinely has no free space, because the manager is already
/// occupying it as designed. Collapsing our own items on top of that would
/// consume space the manager set aside for exactly this purpose and hide a
/// profile behind an extra click the manager exists to avoid. See
/// `StatusBarUIManager.overflowPlan(for:mode:currentCollapsedCount:spaceInput:runningBundleIdentifiers:)`,
/// which guards on this before ever looking at the space measurement.
enum MenuBarManagerDetection {
    struct KnownManager: Equatable {
        let bundleIdentifier: String
        let displayName: String
    }

    /// Every identifier below was read from a live source at the time this
    /// was written, never guessed from the app's display name — a wrong
    /// guess here would be a silent no-op that never fires the guard it's
    /// meant to.
    ///
    /// - Ice: `com.jordanbaird.Ice`, from `jordanbaird/Ice`'s own
    ///   `Ice.xcodeproj/project.pbxproj` (`PRODUCT_BUNDLE_IDENTIFIER`),
    ///   corroborated by Homebrew's `jordanbaird-ice` cask.
    /// - Thaw: `com.stonerl.Thaw`, from `thaw-app/Thaw`'s own
    ///   `Thaw.xcodeproj/project.pbxproj`, corroborated by Homebrew's
    ///   `thaw` cask (`uninstall quit:`/`zap trash:` both reference it).
    /// - Bartender: `com.surteesstudios.Bartender`, from Homebrew's
    ///   `bartender` cask, corroborated by the vendor's own support
    ///   documentation (`tccutil reset ... com.surteesstudios.Bartender`).
    /// - Hidden Bar: `com.dwarvesv.minimalbar`, from `dwarvesf/hidden`'s own
    ///   `Hidden Bar.xcodeproj/project.pbxproj`, corroborated by Homebrew's
    ///   `hiddenbar` cask.
    /// - Dozer: `com.mortennn.Dozer`, from `Mortennn/Dozer`'s own shipped
    ///   `Info.plist` (`CFBundleIdentifier`).
    /// - Vanilla: `net.matthewpalmer.Vanilla`, from Homebrew's `vanilla`
    ///   cask `zap trash:` entry, which names the app's own preferences
    ///   plist (`~/Library/Preferences/net.matthewpalmer.Vanilla.plist`) —
    ///   macOS names that file after the app's bundle identifier.
    static let knownManagers: [KnownManager] = [
        KnownManager(
            bundleIdentifier: "com.jordanbaird.Ice",
            displayName: "Ice"
        ),
        KnownManager(
            bundleIdentifier: "com.stonerl.Thaw",
            displayName: "Thaw"
        ),
        KnownManager(
            bundleIdentifier: "com.surteesstudios.Bartender",
            displayName: "Bartender"
        ),
        KnownManager(
            bundleIdentifier: "com.dwarvesv.minimalbar",
            displayName: "Hidden Bar"
        ),
        KnownManager(
            bundleIdentifier: "com.mortennn.Dozer",
            displayName: "Dozer"
        ),
        KnownManager(
            bundleIdentifier: "net.matthewpalmer.Vanilla",
            displayName: "Vanilla"
        )
    ]

    /// The first `knownManagers` entry currently running, or `nil` if none
    /// is. Fails safe by construction: an unrecognized manager (not on this
    /// list) is simply invisible here, so `.automatic` mode measures and
    /// collapses exactly as it did before this feature existed.
    static func detectedManager(
        runningBundleIdentifiers: [String]
    ) -> KnownManager? {
        let running = Set(runningBundleIdentifiers)
        return knownManagers.first {
            running.contains($0.bundleIdentifier)
        }
    }
}

/// Reconciles a freshly-sampled process list against the bundle identifier
/// carried by the `NSWorkspace` notification that triggered the sample, so
/// a genuine launch or quit is never missed to a resample race.
///
/// `NSWorkspace.didLaunchApplicationNotification` /
/// `didTerminateApplicationNotification` fire *at* the moment an app
/// launches or quits, but `NSWorkspace.shared.runningApplications` is a
/// separate, independently-timed snapshot: resampling it in the handler can
/// still miss the app that just launched (not yet reflected) or still
/// include the app that just quit (not yet removed). Either miss means
/// `MenuBarManagerTransitionTracker.update(runningBundleIdentifiers:)` sees
/// no change and skips the replan the notification exists to trigger — the
/// menu bar profiles stay stuck (collapsed or uncollapsed) until some
/// unrelated event happens to fire a recompute. Folding the notification's
/// own payload into the sample before it reaches the tracker makes
/// correctness independent of that timing. See
/// `MenuBarManager.handleMenuBarManagerActivityChange(launched:terminated:)`
/// for the production caller.
enum MenuBarManagerActivityReconciler {
    /// - Parameters:
    ///   - sample: A freshly-sampled running-application bundle identifier
    ///     list (typically `NSWorkspaceRunningApplications().runningBundleIdentifiers`).
    ///   - launched: The bundle identifier from a
    ///     `didLaunchApplicationNotification`'s
    ///     `NSWorkspace.applicationUserInfoKey` payload, or `nil` if this
    ///     call originates from a termination (or the identifier was
    ///     unavailable — some processes have none).
    ///   - terminated: The mirror of `launched`, from a
    ///     `didTerminateApplicationNotification`.
    /// - Returns: `sample` with `launched` appended if it was missing, and
    ///   every occurrence of `terminated` removed. A `nil` argument leaves
    ///   that side of the reconciliation untouched.
    static func reconciled(
        sample: [String],
        launched: String?,
        terminated: String?
    ) -> [String] {
        var reconciled = sample
        if let terminated {
            reconciled.removeAll { $0 == terminated }
        }
        if let launched, !reconciled.contains(launched) {
            reconciled.append(launched)
        }
        return reconciled
    }
}

/// Tracks the detected menu bar manager across successive process-list
/// snapshots and reports whether the latest snapshot actually changed it.
/// `NSWorkspace`'s `didLaunchApplicationNotification` /
/// `didTerminateApplicationNotification` fire for every application on the
/// system, not just menu bar managers, so a caller wired directly to those
/// notifications needs this to avoid recomputing anything on every launch
/// or quit — only a genuine transition (nil -> X, X -> nil, X -> Y) should
/// do that. Isolating the decision here (plain `[String]` in, `Bool` out,
/// no `NSWorkspace` or `MenuBarManager` involved) is what makes it testable
/// without a real running process list. See
/// `MenuBarManager.handleMenuBarManagerActivityChange(launched:terminated:)`
/// for the production caller.
///
/// `nonisolated` is required, not stylistic: this project defaults every
/// declaration to `@MainActor` isolation, and under that default this
/// class's synthesized deinit crashed every test that deallocated an
/// instance (`___BUG_IN_CLIENT_OF_LIBMALLOC_POINTER_BEING_FREED_WAS_NOT_ALLOCATED`
/// inside `swift_task_deinitOnExecutorMainActorBackDeploy`) — a toolchain
/// bug in MainActor-isolated deinit, not a bug in this type. It holds no
/// actor-isolated state and needs none, so opting out is also correct on
/// the merits.
nonisolated final class MenuBarManagerTransitionTracker {
    private(set) var lastDetected: MenuBarManagerDetection.KnownManager?

    init(initialRunningBundleIdentifiers: [String] = []) {
        lastDetected = MenuBarManagerDetection.detectedManager(
            runningBundleIdentifiers: initialRunningBundleIdentifiers
        )
    }

    /// Re-evaluates `runningBundleIdentifiers` against
    /// `MenuBarManagerDetection.knownManagers` and returns whether the
    /// detected manager changed since the last call (or since `init`, on
    /// the first call). Always updates `lastDetected`, even when
    /// unchanged, so the next call compares against this snapshot rather
    /// than an earlier one.
    @discardableResult
    func update(runningBundleIdentifiers: [String]) -> Bool {
        let detected = MenuBarManagerDetection.detectedManager(
            runningBundleIdentifiers: runningBundleIdentifiers
        )
        let changed = detected != lastDetected
        lastDetected = detected
        return changed
    }
}
