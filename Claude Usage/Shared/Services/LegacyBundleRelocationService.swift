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

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let currentBundleIdentifier: String?
    private let legacyBundleIdentifier: String
    private let expectedAppFileName: String
    private let bundleURL: URL
    private let launchAtLoginManager: LaunchAtLoginManager

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
        bundleURL: URL = Bundle.main.bundleURL,
        launchAtLoginManager: LaunchAtLoginManager = .shared
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.currentBundleIdentifier = currentBundleIdentifier
        self.legacyBundleIdentifier = legacyBundleIdentifier
        self.expectedAppFileName = expectedAppFileName
        self.bundleURL = bundleURL
        self.launchAtLoginManager = launchAtLoginManager
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
        guard shouldOfferRelocation() else { return }
        promptAndRelocate()
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

        if alert.suppressionButton?.state == .on {
            defaults.set(true, forKey: Self.relocationDeferredPermanentlyKey)
            LoggingService.shared.logInfo(
                "Legacy bundle relocation permanently deferred by user"
            )
            return
        }

        guard response == .alertFirstButtonReturn else {
            // "Not Now" — re-ask next launch, nothing recorded.
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

        if fileManager.fileExists(atPath: destination.path) {
            guard resolveOccupiedDestination(at: destination) else {
                // Not the same app — abort, touch nothing else.
                return
            }
        }

        let wasLaunchAtLoginEnabled = launchAtLoginManager.isEnabled
        if wasLaunchAtLoginEnabled {
            // Best-effort: SMAppService registrations are keyed to the
            // bundle path, so unregistering before the move (and
            // re-registering after) keeps the login item pointed at a
            // location that still exists. A failure here must never abort
            // the relocation itself.
            launchAtLoginManager.setEnabled(false)
        }

        do {
            try fileManager.moveItem(at: bundleURL, to: destination)
        } catch {
            LoggingService.shared.logError(
                "Legacy bundle relocation could not move the app bundle;"
                    + " continuing to run from the current location",
                error: error
            )
            if wasLaunchAtLoginEnabled {
                launchAtLoginManager.setEnabled(true)
            }
            return
        }

        relaunch(
            from: destination,
            reregisterLaunchAtLogin: wasLaunchAtLoginEnabled
        )
    }

    /// Handles a destination that already exists. Returns `true` when it is
    /// safe to proceed (the occupant was a stale duplicate of this exact
    /// app and has been trashed), `false` when relocation must abort.
    private func resolveOccupiedDestination(at destination: URL) -> Bool {
        let occupantIdentifier = Bundle(url: destination)?.bundleIdentifier

        guard occupantIdentifier == currentBundleIdentifier else {
            LoggingService.shared.logError(
                "Legacy bundle relocation found an unrelated app already at"
                    + " \(destination.path); leaving both locations"
                    + " untouched",
                error: nil
            )
            presentAbortAlert(destination: destination)
            return false
        }

        do {
            // Never removeItem: a stale duplicate is moved to the Trash,
            // never deleted outright, in case it turns out to matter.
            try fileManager.trashItem(at: destination, resultingItemURL: nil)
            return true
        } catch {
            LoggingService.shared.logError(
                "Legacy bundle relocation could not remove the stale"
                    + " duplicate at \(destination.path); leaving the app"
                    + " running from its current location",
                error: error
            )
            return false
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

    private func relaunch(from url: URL, reregisterLaunchAtLogin: Bool) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(
            at: url,
            configuration: configuration
        ) { [defaults] _, error in
            if let error {
                LoggingService.shared.logError(
                    "Legacy bundle relocation moved the app but could not"
                        + " relaunch it from the new location; the app"
                        + " remains runnable from \(url.path)",
                    error: error
                )
                return
            }

            defaults.set(true, forKey: Self.relocationCompletedKey)
            LoggingService.shared.logInfo(
                "Legacy bundle relocation completed; relaunched from"
                    + " \(url.path)"
            )

            if reregisterLaunchAtLogin {
                self.launchAtLoginManager.setEnabled(true)
            }

            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}
