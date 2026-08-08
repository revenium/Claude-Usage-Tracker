//
//  AppSettingsView.swift
//  Claude Usage
//
//  App-wide settings (launch at login, etc.)
//

import SwiftUI

struct AppSettingsView: View {
    @State private var launchAtLogin = LaunchAtLoginManager.shared.isEnabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                SettingsPageHeader(
                    title: "section.app_settings_title".localized,
                    subtitle: "section.app_settings_desc".localized
                )

                Divider()

                // Rendered as a bare labelled row rather than wrapped in a
                // `SettingsSectionCard`, matching `APISettingsView`. A card
                // header names a *group* and the rows inside name the
                // individual settings (see `general.autostart_title` vs
                // `general.autostart_toggle`), which needs four strings.
                // Launch-at-login has only its own title and description, so
                // wrapping it in a card forced the same two strings to be
                // used as both the group header and the row — which is
                // exactly how it came to render twice.
                SettingToggle(
                    title: "general.launch_at_login".localized,
                    description: "general.launch_at_login.description".localized,
                    isOn: $launchAtLogin
                )
            }
            .padding()
        }
        .onChange(of: launchAtLogin) { _, newValue in
            LaunchAtLoginManager.shared.setEnabled(newValue)
        }
    }
}

#Preview {
    AppSettingsView()
        .frame(width: 520, height: 400)
}
