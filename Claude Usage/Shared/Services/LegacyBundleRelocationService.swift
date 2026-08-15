//
//  LegacyBundleRelocationService.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-08-15.
//

import AppKit
import Foundation

/// Relocates the app bundle on disk when it is still installed under its
/// pre-rename filename.
///
/// Sparkle updates install to `host.bundlePath` — the location the app was
/// already running from — so a machine that updated in place from a 3.x
/// install keeps living at `/Applications/Claude Usage.app` forever.
/// Contents, icon, and bundle identifier are all correctly RevvyTach; only
/// the on-disk filename is stale, and Finder shows the filename, so those
/// users keep seeing the old name. Sparkle's own normalization reads the
/// OLD host's `CFBundleName` and cannot fix this, so the app relocates
/// itself once, with the user's consent.
///
/// While the running bundle identifier still equals the legacy identifier —
/// i.e. until the rename actually ships — `relocateIfNeeded()` returns
/// immediately and touches nothing, mirroring
/// `LegacyIdentityMigrationService`.
///
/// Every relocation step is fail-safe: any failure leaves the app running
/// normally from its current location. This app has a history of
/// launch-path regressions that green tests did not catch, so every
/// ambiguous case is biased toward "do nothing and keep running" rather
/// than toward completing the move.
/// `nonisolated` is load-bearing: under this target's MainActor default
/// isolation, test-created instances of an isolated class crash in the
/// synthesized deinit (malloc "pointer being freed was not allocated") —
/// the same trap `LegacyIdentityMigrationService`, `KeychainService`, and
/// `ProfileUsageFileStore` opt out of.
nonisolated final class LegacyBundleRelocationService {
    static let shared = LegacyBundleRelocationService()

    /// Recorded once relocation has actually moved the bundle and relaunched.
    static let relocationCompletedKey = "legacyBundleRelocationCompleted_v1"

    /// Recorded when the user checks "Don't ask again". Distinct from
    /// completion so a user who declines is never asked again, even though
    /// nothing moved.
    static let relocationDeferredPermanentlyKey =
        "legacyBundleRelocationDeferredPermanently_v1"

    /// Set just before the bundle moves, when launch-at-login was enabled, and
    /// consumed by the *relaunched* instance.
    ///
    /// Re-registering from the process that is about to terminate is not safe:
    /// `SMAppService.mainApp` resolves against the running bundle, whose path
    /// has just changed underneath it, so a registration made there can point
    /// at the location the app no longer occupies. Failing that way is silent —
    /// the user simply stops being launched at login and has no way to connect
    /// it to the rename — so the restore is deferred to the new instance, which
    /// registers a bundle that is genuinely where it claims to be.
    static let relocationRestoreLaunchAtLoginKey =
        "legacyBundleRelocationRestoreLaunchAtLogin_v1"

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let currentBundleIdentifier: String?
    private let legacyBundleIdentifier: String
    private let expectedAppFileName: String
    /// The one pre-rename filename this migration is allowed to act on.
    private let legacyAppFileName: String
    private let bundleURL: URL
    /// `CFBundleVersion` of the running bundle, used to refuse a downgrade
    /// when something already occupies the destination.
    private let runningBundleVersion: String?
    /// Injected as closures rather than the manager itself so tests can
    /// exercise the launch-at-login hand-off without touching the real
    /// `SMAppService`, which would register the *test host* as a login item.
    private let isLaunchAtLoginEnabled: () -> Bool
    private let setLaunchAtLoginEnabled: (Bool) -> Bool

    /// - Parameters:
    ///   - currentBundleIdentifier: Guards against acting while still
    ///     running under the legacy identity (mirrors
    ///     `LegacyIdentityMigrationService`).
    ///   - expectedAppFileName: The `.app` filename this bundle's own
    ///     `CFBundleName` implies — derived at runtime rather than
    ///     hardcoded, so it is automatically correct for both the release
    ///     and UAT build variants (`RevvyTach.app` vs `RevvyTach UAT.app`)
    ///     without any variant-specific branching here.
    ///   - bundleURL: The running bundle's on-disk location.
    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        legacyBundleIdentifier: String =
            AppIdentity.legacyBundleIdentifierBase
                + (AppBuildVariant.isUAT ? ".uat" : ""),
        expectedAppFileName: String = LegacyBundleRelocationService
            .expectedAppFileName(for: .main),
        legacyAppFileName: String = LegacyBundleRelocationService
            .legacyAppFileName(for: .main),
        bundleURL: URL = Bundle.main.bundleURL,
        runningBundleVersion: String? = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String,
        isLaunchAtLoginEnabled: @escaping () -> Bool = {
            LaunchAtLoginManager.shared.isEnabled
        },
        setLaunchAtLoginEnabled: @escaping (Bool) -> Bool = {
            LaunchAtLoginManager.shared.setEnabled($0)
        }
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.currentBundleIdentifier = currentBundleIdentifier
        self.legacyBundleIdentifier = legacyBundleIdentifier
        self.expectedAppFileName = expectedAppFileName
        self.legacyAppFileName = legacyAppFileName
        self.bundleURL = bundleURL
        self.runningBundleVersion = runningBundleVersion
        self.isLaunchAtLoginEnabled = isLaunchAtLoginEnabled
        self.setLaunchAtLoginEnabled = setLaunchAtLoginEnabled
    }

    /// `CFBundleName` (resolved from `PRODUCT_NAME` at build time) plus
    /// `.app`, read from the bundle itself rather than a literal, so a
    /// future rename or a build variant with a different product name
    /// needs no change here.
    static func expectedAppFileName(for bundle: Bundle) -> String {
        let name =
            (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? AppIdentity.appSupportFolderName
        return "\(name).app"
    }

    /// The pre-rename `.app` filename for this build variant, e.g.
    /// `Claude Usage.app` and `Claude Usage UAT.app`. Built from the same
    /// frozen legacy constant `LegacyIdentityMigrationService` uses, with the
    /// variant suffix taken from the current product name so the two stay in
    /// step if either changes.
    static func legacyAppFileName(for bundle: Bundle) -> String {
        let currentName =
            (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? AppIdentity.appSupportFolderName
        let variantSuffix = currentName.hasPrefix(
            AppIdentity.appSupportFolderName
        )
            ? String(
                currentName.dropFirst(
                    AppIdentity.appSupportFolderName.count
                )
            )
            : ""
        return "\(AppIdentity.legacyAppSupportFolderName)\(variantSuffix).app"
    }

    // MARK: - Decision

    /// Pure, side-effect-free decision of whether relocation should be
    /// offered. Kept separate from `relocateIfNeeded()` so it is directly
    /// unit-testable without touching the filesystem or presenting UI.
    func shouldOfferRelocation() -> Bool {
        guard let bundleIdentifier = currentBundleIdentifier,
            bundleIdentifier != legacyBundleIdentifier
        else {
            // Still shipping under the legacy identity; nothing to relocate.
            return false
        }
        guard bundleURL.lastPathComponent != expectedAppFileName else {
            // Already installed under the correct filename.
            return false
        }
        guard bundleURL.lastPathComponent == legacyAppFileName else {
            // Some other filename entirely. This migration exists to undo one
            // specific rename, not to normalize every bundle whose name has
            // been changed: a user who deliberately renamed a copy, or keeps a
            // second one alongside, should never be offered a move they did
            // not ask for.
            return false
        }
        guard !defaults.bool(forKey: Self.relocationCompletedKey) else {
            return false
        }
        guard
            !defaults.bool(forKey: Self.relocationDeferredPermanentlyKey)
        else {
            return false
        }
        return true
    }

    /// The destination this bundle would move to if relocation proceeds.
    var destinationURL: URL {
        bundleURL.deletingLastPathComponent()
            .appendingPathComponent(expectedAppFileName)
    }

    // MARK: - Entry point

    func relocateIfNeeded() {
        // Runs before the decision guard on purpose: the instance that has to
        // restore launch-at-login is the relaunched one, which by definition
        // already sits at the expected filename and so is not a relocation
        // candidate itself.
        restoreLaunchAtLoginIfPending()

        guard shouldOfferRelocation() else { return }
        promptAndRelocate()
    }

    /// Re-registers launch-at-login after a completed relocation. Best-effort:
    /// the flag is cleared either way, so a failure costs the user one login
    /// item rather than re-attempting on every launch forever.
    private func restoreLaunchAtLoginIfPending() {
        guard defaults.bool(forKey: Self.relocationRestoreLaunchAtLoginKey)
        else { return }

        defaults.set(false, forKey: Self.relocationRestoreLaunchAtLoginKey)

        if !setLaunchAtLoginEnabled(true) {
            LoggingService.shared.logError(
                "Legacy bundle relocation could not restore launch at login"
                    + " from the relocated bundle; the user may need to"
                    + " re-enable it in Settings",
                error: nil
            )
        }
    }

    // MARK: - Prompt

    private func promptAndRelocate() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "relocation.prompt.title".localized
        alert.informativeText = String(
            format: "relocation.prompt.body".localized,
            bundleURL.path,
            destinationURL.path
        )
        alert.showsSuppressionButton = true
        alert.addButton(withTitle: "relocation.prompt.finish".localized)
        alert.addButton(withTitle: "relocation.prompt.not_now".localized)

        let response = alert.runModal()
        let suppressed = alert.suppressionButton?.state == .on

        guard response == .alertFirstButtonReturn else {
            // Declined. Suppression only matters on this branch: "don't ask
            // again" describes future prompts, so honouring it ahead of the
            // button choice would silently swallow a "Finish Rename" click
            // from anyone who ticked the box meaning "and stop asking".
            if suppressed {
                defaults.set(
                    true,
                    forKey: Self.relocationDeferredPermanentlyKey
                )
                LoggingService.shared.logInfo(
                    "Legacy bundle relocation permanently deferred by user"
                )
            }
            // Otherwise "Not Now" — re-ask next launch, nothing recorded.
            return
        }

        performRelocation()
    }

    // MARK: - Relocation

    /// Every step here is fail-safe: on any error, the app keeps running
    /// from its current location and nothing is left half-done in a way
    /// that blocks either the old or new location from being runnable.
    private func performRelocation() {
        let destination = destinationURL

        var trashedOccupantURL: URL?
        if fileManager.fileExists(atPath: destination.path) {
            switch resolveOccupiedDestination(at: destination) {
            case .abort:
                // Unrelated app, or a NEWER copy of this one — touch nothing.
                return
            case .trashed(let restoreURL):
                trashedOccupantURL = restoreURL
            }
        }

        let wasLaunchAtLoginEnabled = isLaunchAtLoginEnabled()
        if wasLaunchAtLoginEnabled {
            // Best-effort: SMAppService registrations are keyed to the bundle
            // path, so the stale registration is dropped before the move and
            // re-made by the relaunched instance (see the restore key). A
            // failure here must never abort the relocation itself.
            _ = setLaunchAtLoginEnabled(false)
            defaults.set(true, forKey: Self.relocationRestoreLaunchAtLoginKey)
        }

        do {
            try fileManager.moveItem(at: bundleURL, to: destination)
        } catch {
            LoggingService.shared.logError(
                "Legacy bundle relocation could not move the app bundle;"
                    + " continuing to run from the current location",
                error: error
            )
            // The occupant was already trashed to clear the way. Put it back:
            // otherwise this failure leaves the user with no app at the
            // destination at all, only a stale-named copy and something in the
            // Trash they have no reason to connect to it.
            if let trashedOccupantURL {
                restoreTrashedOccupant(
                    from: trashedOccupantURL,
                    to: destination
                )
            }
            if wasLaunchAtLoginEnabled {
                // Nothing moved, so this process is still the right one to
                // hold the registration; drop the hand-off flag with it.
                defaults.set(
                    false,
                    forKey: Self.relocationRestoreLaunchAtLoginKey
                )
                _ = setLaunchAtLoginEnabled(true)
            }
            return
        }

        relaunch(from: destination)
    }

    enum OccupiedDestinationOutcome {
        /// Relocation must not proceed; nothing was touched.
        case abort
        /// The occupant was trashed. Carries the in-Trash URL so it can be
        /// put back if a later step fails.
        case trashed(restoreURL: URL?)
    }

    /// Decides what to do about a destination that already exists.
    ///
    /// Sharing a bundle identifier is not sufficient reason to discard the
    /// occupant: an install that is NEWER than the running copy is the one the
    /// user wants to keep, and replacing it with this older bundle would be a
    /// silent downgrade. Only a same-identity copy that is no newer than this
    /// one is treated as the stale duplicate this migration exists to clean up.
    private func resolveOccupiedDestination(
        at destination: URL
    ) -> OccupiedDestinationOutcome {
        guard let occupant = Bundle(url: destination),
            occupant.bundleIdentifier == currentBundleIdentifier
        else {
            LoggingService.shared.logError(
                "Legacy bundle relocation found an unrelated app already at"
                    + " \(destination.path); leaving both locations"
                    + " untouched",
                error: nil
            )
            presentAbortAlert(destination: destination)
            return .abort
        }

        guard occupantIsNoNewerThanRunningBundle(occupant) else {
            LoggingService.shared.logError(
                "Legacy bundle relocation found a newer copy of this app at"
                    + " \(destination.path); keeping it and leaving both"
                    + " locations untouched",
                error: nil
            )
            presentAbortAlert(destination: destination)
            return .abort
        }

        do {
            // Never removeItem: a stale duplicate is moved to the Trash,
            // never deleted outright, in case it turns out to matter.
            var restoreURL: NSURL?
            try fileManager.trashItem(
                at: destination,
                resultingItemURL: &restoreURL
            )
            return .trashed(restoreURL: restoreURL as URL?)
        } catch {
            LoggingService.shared.logError(
                "Legacy bundle relocation could not remove the stale"
                    + " duplicate at \(destination.path); leaving the app"
                    + " running from its current location",
                error: error
            )
            return .abort
        }
    }

    /// Compares `CFBundleVersion`, which this project guarantees increases on
    /// every release (it is Sparkle's comparison version). Anything that does
    /// not parse as a pair of integers is treated as "cannot prove it is
    /// older", so the occupant is kept — the conservative direction, since the
    /// cost of a wrong "keep" is one extra prompt and the cost of a wrong
    /// "trash" is the user's preferred install going to the Trash.
    private func occupantIsNoNewerThanRunningBundle(_ occupant: Bundle) -> Bool
    {
        func build(_ bundle: Bundle) -> Int? {
            (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
                .flatMap(Int.init)
        }

        guard let occupantBuild = build(occupant),
            let runningBuild = runningBundleVersion.flatMap(Int.init)
        else {
            return false
        }
        return occupantBuild <= runningBuild
    }

    /// Puts a trashed occupant back after a failed move, so a partial failure
    /// does not leave the destination empty.
    private func restoreTrashedOccupant(from trashURL: URL, to destination: URL)
    {
        do {
            try fileManager.moveItem(at: trashURL, to: destination)
            LoggingService.shared.logInfo(
                "Legacy bundle relocation restored the previous app to"
                    + " \(destination.path) after the move failed"
            )
        } catch {
            LoggingService.shared.logError(
                "Legacy bundle relocation could not restore the previous app"
                    + " to \(destination.path); it remains in the Trash",
                error: error
            )
        }
    }

    private func presentAbortAlert(destination: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "relocation.abort.title".localized
        alert.informativeText = String(
            format: "relocation.abort.body".localized,
            destination.path
        )
        alert.addButton(withTitle: "common.ok".localized)
        alert.runModal()
    }

    /// Hands the relaunch to a detached helper that waits for THIS process to
    /// exit, then opens the moved bundle.
    ///
    /// Relaunching directly and then calling `NSApp.terminate` does not work
    /// here, and fails in a way that looks like success: this app intercepts
    /// termination (`applicationShouldTerminate` returns `.terminateLater`
    /// while the menu bar tears down asynchronously, and `.terminateCancel`
    /// when a profile still holds an unsaved credential). The quit can
    /// therefore be deferred or refused outright, leaving the old instance
    /// alive and running from a bundle that no longer exists at that path,
    /// with the new instance racing it for the same menu bar and preferences.
    /// Observed exactly that in UAT: the move succeeded, the relaunch reported
    /// success, and the surviving process was still the old one.
    ///
    /// Waiting on process exit inverts that: the new instance starts only once
    /// the old one is genuinely gone, so there is never more than one, and the
    /// app's own termination policy is respected rather than fought. If the
    /// user cancels the quit to save a credential, the app simply keeps running
    /// from the moved bundle — which is intact and fully functional — and the
    /// new instance starts whenever they do quit.
    private func relaunch(from url: URL) {
        // Recorded now: the move is what completed. Tying this to the relaunch
        // would re-offer relocation on next launch even though the bundle is
        // already in the right place.
        defaults.set(true, forKey: Self.relocationCompletedKey)

        let watcher = Process()
        watcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        watcher.arguments = [
            "-c",
            // Poll rather than wait(1): the helper is not our child, and a
            // parent that exits mid-poll simply ends the loop.
            "while kill -0 \(ProcessInfo.processInfo.processIdentifier) "
                + "2>/dev/null; do sleep 0.2; done; "
                + "/usr/bin/open \(shellQuoted(url.path))",
        ]

        do {
            try watcher.run()
            LoggingService.shared.logInfo(
                "Legacy bundle relocation moved the app to \(url.path);"
                    + " relaunch armed for when this instance exits"
            )
        } catch {
            // Non-fatal: the bundle is already correctly in place, so the user
            // just has to launch it themselves next time.
            LoggingService.shared.logError(
                "Legacy bundle relocation could not arm the relaunch helper;"
                    + " the app is in place at \(url.path) but will not"
                    + " restart automatically",
                error: error
            )
        }

        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    /// Single-quotes a path for `/bin/sh`. App paths routinely contain spaces,
    /// and this one is attacker-irrelevant but user-controlled enough to get
    /// wrong by accident.
    private func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
