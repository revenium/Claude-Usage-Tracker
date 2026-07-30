//
//  Notification+Extensions.swift
//  Claude Usage
//
//  Created by Claude Code on 2025-12-20.
//

import Foundation

extension Notification.Name {
    /// Posted when the menu bar icon configuration changes (metrics enabled/disabled, order, styling, etc.)
    static let menuBarIconConfigChanged = Notification.Name("menuBarIconConfigChanged")

    /// Posted when credentials are added, removed, or changed (Claude.ai or API Console)
    static let credentialsChanged = Notification.Name("credentialsChanged")

    /// Posted after a verified provider link, relink, or unlink transaction.
    static let providerConfigurationChanged =
        Notification.Name("providerConfigurationChanged")

    static let profileDeletionStarted =
        Notification.Name("profileDeletionStarted")

    static let profileDeletionCompleted =
        Notification.Name("profileDeletionCompleted")

    /// Posted when the setup wizard should be shown manually (for testing)
    static let showSetupWizard = Notification.Name("showSetupWizard")

    /// Posted when the display mode changes (single/multi profile)
    static let displayModeChanged = Notification.Name("displayModeChanged")

    /// Posted when multi-profile selection or visual configuration changes.
    /// Retained status items are updated in place instead of being recreated.
    static let multiProfileConfigChanged = Notification.Name("multiProfileConfigChanged")

    /// Posted when auto-switch profile is triggered (for UI reactivity)
    static let autoSwitchProfileTriggered = Notification.Name("autoSwitchProfileTriggered")
}
