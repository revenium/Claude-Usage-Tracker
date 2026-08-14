//
//  UpdateManager.swift
//  Claude Usage
//
//  Sparkle update manager wrapper
//

import Foundation
import Combine
import Sparkle

/// Fail-closed validation for the distribution settings embedded in the app.
///
/// `Info.plist` contains build-setting placeholders rather than a fallback
/// feed or signing key. Only the credential-gated release workflow injects a
/// production configuration. Debug and ordinary local Release builds remain
/// update-disabled.
struct SparkleUpdateConfiguration: Equatable {
    static let legacyFeedOverrideDefaultsKey = "SUFeedURL"
    enum State: Equatable {
        case enabled(feedURL: URL)
        case disabled(reason: String)
    }

    static let productionChannel = "production"
    static let testingChannel = "testing"
    static let productionBundleIdentifier = "com.revenium.RevvyTach"
    static let productionFeedURL = URL(string: Constants.GitHub.appcastURL)!

    let state: State

    var isEnabled: Bool {
        if case .enabled = state {
            return true
        }
        return false
    }

    static func evaluate(infoDictionary: [String: Any]) -> SparkleUpdateConfiguration {
        let channel = normalizedString(infoDictionary["ReveniumUpdateChannel"])

        #if DEBUG
        if channel == testingChannel {
            return evaluateExplicitTestingConfiguration(infoDictionary)
        }
        #endif

        guard channel == productionChannel else {
            return SparkleUpdateConfiguration(
                state: .disabled(reason: "This build is not a production distribution build.")
            )
        }

        let bundleIdentifier = normalizedString(infoDictionary["CFBundleIdentifier"])
        guard bundleIdentifier == productionBundleIdentifier else {
            return SparkleUpdateConfiguration(
                state: .disabled(reason: "The application bundle identity is not release-compatible.")
            )
        }

        let feedValue = normalizedString(infoDictionary["SUFeedURL"])
        guard let feedURL = URL(string: feedValue),
              feedURL == productionFeedURL,
              feedURL.scheme == "https"
        else {
            return SparkleUpdateConfiguration(
                state: .disabled(reason: "The Revenium update feed is not configured.")
            )
        }

        let publicKey = normalizedString(infoDictionary["SUPublicEDKey"])
        guard let decodedKey = Data(base64Encoded: publicKey), decodedKey.count == 32 else {
            return SparkleUpdateConfiguration(
                state: .disabled(reason: "The Revenium Sparkle signing key is not configured.")
            )
        }

        return SparkleUpdateConfiguration(state: .enabled(feedURL: feedURL))
    }

    #if DEBUG
    /// Explicit Debug-only path for a controlled Sparkle smoke feed. Ordinary
    /// Debug builds use `development`; Release compilation removes this path.
    private static func evaluateExplicitTestingConfiguration(
        _ infoDictionary: [String: Any]
    ) -> SparkleUpdateConfiguration {
        let bundleIdentifier = normalizedString(infoDictionary["CFBundleIdentifier"])
        let feedValue = normalizedString(infoDictionary["SUFeedURL"])
        let publicKey = normalizedString(infoDictionary["SUPublicEDKey"])

        guard bundleIdentifier == productionBundleIdentifier,
              let feedURL = URL(string: feedValue),
              feedURL.scheme == "https",
              feedURL.host != nil,
              let decodedKey = Data(base64Encoded: publicKey),
              decodedKey.count == 32
        else {
            return SparkleUpdateConfiguration(
                state: .disabled(reason: "The controlled Debug update feed is not configured.")
            )
        }

        return SparkleUpdateConfiguration(state: .enabled(feedURL: feedURL))
    }
    #endif

    static func clearLegacyFeedOverride(in defaults: UserDefaults) {
        defaults.removeObject(forKey: legacyFeedOverrideDefaultsKey)
    }

    private static func normalizedString(_ value: Any?) -> String {
        guard let string = value as? String else {
            return ""
        }
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Makes the validated Revenium URL authoritative at the instant Sparkle asks
/// for a feed. This prevents a feed persisted by an older Sparkle integration
/// from winning even during the startup cycle.
final class ReveniumUpdateFeedDelegate: NSObject, SPUUpdaterDelegate {
    private let feedURL: URL

    init(feedURL: URL) {
        self.feedURL = feedURL
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        feedURL.absoluteString
    }
}

/// User driver delegate for Sparkle gentle reminders
final class UpdateUserDriver: NSObject, SPUStandardUserDriverDelegate {
    // REQUIRED: Enable gentle reminders for background apps
    var supportsGentleScheduledUpdateReminders: Bool {
        return true
    }

    // Handle showing scheduled updates
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // For background/menu bar apps, always show updates
        return true
    }

    // Customize how updates are shown
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate {
            LoggingService.shared.logInfo("Showing update alert for version \(update.displayVersionString)")
        }
    }

    // Optional: Handle when user interacts with update
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        LoggingService.shared.logInfo("User attended to update: \(update.displayVersionString)")
    }

    // Optional: Cleanup when update session finishes
    func standardUserDriverWillFinishUpdateSession() {
        LoggingService.shared.logInfo("Update session finished")
    }
}

/// Manages automatic updates using Sparkle framework
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    private let updaterController: SPUStandardUpdaterController
    private let userDriver: UpdateUserDriver // Keep strong reference
    private let feedDelegate: ReveniumUpdateFeedDelegate?

    @Published private(set) var canCheckForUpdates: Bool = false
    @Published private(set) var automaticChecksEnabled: Bool
    @Published private(set) var configurationMessage: String?

    private init() {
        let configuration = SparkleUpdateConfiguration.evaluate(
            infoDictionary: Bundle.main.infoDictionary ?? [:]
        )

        // Create user driver delegate for gentle reminders
        userDriver = UpdateUserDriver()

        if case .enabled(let feedURL) = configuration.state {
            feedDelegate = ReveniumUpdateFeedDelegate(feedURL: feedURL)
        } else {
            feedDelegate = nil
        }

        // Clear the key used by Sparkle's deprecated persisted feed API before
        // the controller is even constructed. The strongly held delegate above
        // then supplies the validated feed for every update request.
        SparkleUpdateConfiguration.clearLegacyFeedOverride(in: .standard)

        // Construct the controller without starting it. Starting a
        // misconfigured standard controller presents an end-user alert, so
        // validate our release-owned feed and key first.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: feedDelegate,
            userDriverDelegate: userDriver
        )

        automaticChecksEnabled = false
        configurationMessage = nil

        switch configuration.state {
        case .enabled(let feedURL):
            updaterController.startUpdater()

            // Sparkle versions before 2.4 could persist a programmatically
            // selected feed in this app's existing preference domain. Clear
            // it immediately after startup so the signed bundle's Revenium
            // feed remains authoritative across upgrades.
            updaterController.updater.clearFeedURLFromUserDefaults()

            automaticChecksEnabled = updaterController.updater.automaticallyChecksForUpdates
            canCheckForUpdates = updaterController.updater.canCheckForUpdates
            LoggingService.shared.logInfo(
                "Update manager enabled for Revenium feed: \(feedURL.absoluteString)"
            )

        case .disabled(let reason):
            configurationMessage = reason
            LoggingService.shared.logInfo("Automatic updates disabled: \(reason)")
        }
    }

    /// Manually check for updates
    func checkForUpdates() {
        guard canCheckForUpdates else {
            LoggingService.shared.logInfo(
                "Manual update check ignored: \(configurationMessage ?? "updater unavailable")"
            )
            return
        }
        updaterController.checkForUpdates(nil)
        LoggingService.shared.logInfo("Manual update check triggered")
    }

    /// Toggle automatic update checks
    func setAutomaticChecksEnabled(_ enabled: Bool) {
        guard configurationMessage == nil else {
            automaticChecksEnabled = false
            return
        }
        updaterController.updater.automaticallyChecksForUpdates = enabled
        automaticChecksEnabled = enabled
        DataStore.shared.userDefaults.set(enabled, forKey: "SUEnableAutomaticChecks")
        LoggingService.shared.logInfo("Automatic updates: \(enabled)")
    }

    /// Get last update check date
    var lastUpdateCheckDate: Date? {
        return updaterController.updater.lastUpdateCheckDate
    }
}
