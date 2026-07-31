//
//  ManageProfilesView.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import SwiftUI
import AppKit
import UsageCore

struct ManageProfilesView: View {
    private let dependencies: ProviderUIDependencies
    @ObservedObject private var profileManager: ProfileManager
    @State private var showingCreateProfile = false
    @State private var newProfileName = ""
    @State private var newProfileProvider:
        ProfileProviderKind = .claude
    @State private var newCodexHomePath = ""
    @State private var errorMessage: String?

    init(
        dependencies: ProviderUIDependencies? = nil
    ) {
        let dependencies =
            dependencies
            ?? ProviderUICompositionRoot.shared.dependencies
        self.dependencies = dependencies
        _profileManager = ObservedObject(
            wrappedValue: dependencies.profileManager
        )
    }

    private var supportsAutomaticProfileSwitch: Bool {
        guard let activeProviderID =
                profileManager.activeProfile?.providerID else {
            return false
        }
        let activePolicy = ProviderFeatureSurfacePolicy(
            capabilities: dependencies.capabilities(
                for: activeProviderID
            )
        )
        guard activePolicy.supports(.automaticProfileSwitch) else {
            return false
        }
        return profileManager.profiles.lazy.filter {
            ProviderFeatureSurfacePolicy(
                capabilities: dependencies.capabilities(
                    for: $0.providerID
                )
            ).supports(.automaticProfileSwitch)
        }.count > 1
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                // Page Header
                SettingsPageHeader(
                    title: "profiles.title".localized,
                    subtitle: "profiles.subtitle".localized
                )

                // Profile List
                SettingsContentCard {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                        ForEach(profileManager.profiles) { profile in
                            ProfileRow(
                                profile: profile,
                                dependencies: dependencies
                            )
                                .padding(.vertical, DesignTokens.Spacing.extraSmall)

                            if profile.id != profileManager.profiles.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                // Create New Profile Button
                SettingsButton(
                    title: "profiles.create_new".localized,
                    icon: "plus.circle.fill"
                ) {
                    showingCreateProfile = true
                }

                // Multi-Profile Display Section
                SettingsSectionCard(
                    title: "multiprofile.title".localized,
                    subtitle: "multiprofile.subtitle".localized
                ) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
                        // Main toggle
                        SettingToggle(
                            title: "multiprofile.enable_title".localized,
                            description: "multiprofile.enable_description".localized,
                            badge: .new,
                            isOn: Binding(
                                get: { profileManager.displayMode == .multi },
                                set: { enabled in
                                    profileManager.updateDisplayMode(enabled ? .multi : .single)
                                    Self.enqueueMenuBarNotification(.displayModeChanged)
                                }
                            )
                        )

                        // Profile selection (visible when multi-profile is ON)
                        if profileManager.displayMode == .multi {
                            Divider()

                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                                Text("multiprofile.select_profiles".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)

                                ForEach(profileManager.profiles) { profile in
                                    ProfileSelectionRow(
                                        profile: profile,
                                        isSelected: profile.isSelectedForDisplay,
                                        isActive: profileManager.activeProfile?.id == profile.id,
                                        onToggle: {
                                            // Ensure at least one profile stays selected
                                            let selectedCount = profileManager.profiles.filter { $0.isSelectedForDisplay }.count
                                            if profile.isSelectedForDisplay && selectedCount <= 1 {
                                                // Can't deselect the last one
                                                return
                                            }
                                            profileManager.toggleProfileSelection(profile.id)
                                            Self.enqueueMenuBarNotification(.multiProfileConfigChanged)
                                        }
                                    )
                                }

                                // Warning if trying to deselect last profile
                                if profileManager.profiles.filter({ $0.isSelectedForDisplay }).count == 1 {
                                    HStack(alignment: .top, spacing: 6) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 10))
                                            .foregroundColor(.orange)
                                        Text("multiprofile.at_least_one".localized)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.top, 4)
                                }
                            }

                            Divider()
                                .padding(.vertical, DesignTokens.Spacing.small)

                            // Icon Style Picker
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                                Text("multiprofile.icon_style".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)

                                Picker("", selection: Binding(
                                    get: { profileManager.multiProfileConfig.iconStyle },
                                    set: { newStyle in
                                        var config = profileManager.multiProfileConfig
                                        config.iconStyle = newStyle
                                        profileManager.updateMultiProfileConfig(config)
                                        Self.enqueueMenuBarNotification(.multiProfileConfigChanged)
                                    }
                                )) {
                                    ForEach(MultiProfileIconStyle.allCases, id: \.self) { style in
                                        Text(style.shortNameKey.localized).tag(style)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            // Show Week Toggle
                            SettingToggle(
                                title: "multiprofile.show_week".localized,
                                description: "multiprofile.show_week_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showWeek },
                                    set: { showWeek in
                                        var config = profileManager.multiProfileConfig
                                        config.showWeek = showWeek
                                        profileManager.updateMultiProfileConfig(config)
                                        Self.enqueueMenuBarNotification(.multiProfileConfigChanged)
                                    }
                                )
                            )

                            // Show Profile Label Toggle
                            SettingToggle(
                                title: "multiprofile.show_label".localized,
                                description: "multiprofile.show_label_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showProfileLabel },
                                    set: { showLabel in
                                        var config = profileManager.multiProfileConfig
                                        config.showProfileLabel = showLabel
                                        profileManager.updateMultiProfileConfig(config)
                                        Self.enqueueMenuBarNotification(.multiProfileConfigChanged)
                                    }
                                )
                            )

                            // Use System Color Toggle
                            SettingToggle(
                                title: "multiprofile.use_system_color".localized,
                                description: "multiprofile.use_system_color_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.useSystemColor },
                                    set: { useSystemColor in
                                        var config = profileManager.multiProfileConfig
                                        config.useSystemColor = useSystemColor
                                        profileManager.updateMultiProfileConfig(config)
                                        Self.enqueueMenuBarNotification(.multiProfileConfigChanged)
                                    }
                                )
                            )

                            // Show Time Marker Toggle
                            SettingToggle(
                                title: "appearance.show_time_marker_title".localized,
                                description: "appearance.show_time_marker_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showTimeMarker },
                                    set: { showMarker in
                                        var config = profileManager.multiProfileConfig
                                        config.showTimeMarker = showMarker
                                        profileManager.updateMultiProfileConfig(config)
                                        Self.enqueueMenuBarNotification(.multiProfileConfigChanged)
                                    }
                                )
                            )

                            // Pace Marker Toggle
                            SettingToggle(
                                title: "appearance.show_pace_marker_title".localized,
                                description: "appearance.show_pace_marker_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showPaceMarker },
                                    set: { showPace in
                                        var config = profileManager.multiProfileConfig
                                        config.showPaceMarker = showPace
                                        profileManager.updateMultiProfileConfig(config)
                                        Self.enqueueMenuBarNotification(.multiProfileConfigChanged)
                                    }
                                )
                            )

                            // Pace-Aware Bar Colors Toggle
                            SettingToggle(
                                title: "appearance.pace_coloring_title".localized,
                                description: "appearance.pace_coloring_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.usePaceColoring },
                                    set: { usePace in
                                        var config = profileManager.multiProfileConfig
                                        config.usePaceColoring = usePace
                                        profileManager.updateMultiProfileConfig(config)
                                        Self.enqueueMenuBarNotification(.multiProfileConfigChanged)
                                    }
                                )
                            )

                            // Show Remaining Percentage Toggle
                            SettingToggle(
                                title: "appearance.show_remaining_title".localized,
                                description: "appearance.show_remaining_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showRemainingPercentage },
                                    set: { showRemaining in
                                        var config = profileManager.multiProfileConfig
                                        config.showRemainingPercentage = showRemaining
                                        profileManager.updateMultiProfileConfig(config)
                                        Self.enqueueMenuBarNotification(.multiProfileConfigChanged)
                                    }
                                )
                            )

                            // Info message
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "info.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.blue)
                                Text("multiprofile.info".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, DesignTokens.Spacing.small)
                        }
                    }
                }

                if supportsAutomaticProfileSwitch {
                    // Auto-Switch Profile Section
                    SettingsSectionCard(
                        title: "auto_switch.title".localized,
                        subtitle: "auto_switch.subtitle".localized
                    ) {
                        SettingToggle(
                            title: "auto_switch.enable_title".localized,
                            description: "auto_switch.enable_description".localized,
                            badge: .new,
                            isOn: Binding(
                                get: { SharedDataStore.shared.loadAutoSwitchProfileEnabled() },
                                set: { enabled in
                                    SharedDataStore.shared.saveAutoSwitchProfileEnabled(enabled)
                                }
                            )
                        )
                    }
                }

                // Info Card
                SettingsContentCard {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                        HStack(spacing: DesignTokens.Spacing.small) {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.blue)
                                .font(.system(size: DesignTokens.Icons.standard))
                            Text("profiles.about_title".localized)
                                .font(DesignTokens.Typography.sectionTitle)
                        }

                        Text("profiles.about_description".localized)
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                            BulletPoint("profiles.about_credentials".localized)
                            BulletPoint("profiles.about_api".localized)
                            BulletPoint("profiles.about_cli".localized)
                            BulletPoint("profiles.about_appearance".localized)
                            BulletPoint("profiles.about_notifications".localized)
                            BulletPoint("profiles.about_refresh".localized)
                            BulletPoint("profiles.about_cli_switching".localized)
                        }
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, DesignTokens.Spacing.small)
                    }
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.system(size: 11))
                }
            }
            .padding()
        }
        .sheet(isPresented: $showingCreateProfile) {
            CreateProfileSheet(
                profileName: $newProfileName,
                provider: $newProfileProvider,
                codexHomePath: $newCodexHomePath,
                codexAvailable:
                    dependencies.availability.codexSupportEnabled,
                onSave: {
                    createNewProfile()
                },
                onCancel: {
                    showingCreateProfile = false
                    newProfileName = ""
                    newProfileProvider = .claude
                    newCodexHomePath = ""
                }
            )
        }
    }

    /// ProfileManager deliberately publishes settings on the next main-queue turn.
    /// Enqueueing the notification after its mutation preserves FIFO ordering so
    /// MenuBarManager always reads the newly persisted state.
    static func enqueueMenuBarNotification(
        _ name: Notification.Name,
        queue: DispatchQueue = .main,
        center: NotificationCenter = .default
    ) {
        queue.async {
            center.post(name: name, object: nil)
        }
    }

    private func createNewProfile() {
        let name = newProfileName.isEmpty ? nil : newProfileName
        do {
            _ = try dependencies.createProfile(
                name: name,
                provider: newProfileProvider,
                linkedCodexHome:
                    newProfileProvider == .codex
                    ? newCodexHomePath : nil
            )
        } catch {
            errorMessage =
                ProviderAccountViewModel.message(for: error)
            return
        }
        errorMessage = nil
        showingCreateProfile = false
        newProfileName = ""
        newProfileProvider = .claude
        newCodexHomePath = ""
    }
}

// MARK: - Profile Row

struct ProfileRow: View {
    let profile: Profile
    private let dependencies: ProviderUIDependencies
    @ObservedObject private var profileManager: ProfileManager
    @State private var isEditing = false
    @State private var editedName: String = ""
    @State private var deletionAlert: ProfileDeletionAlert?
    @State private var renameAlert: ProfileRenameAlert?

    init(
        profile: Profile,
        dependencies: ProviderUIDependencies
    ) {
        self.profile = profile
        self.dependencies = dependencies
        _profileManager = ObservedObject(
            wrappedValue: dependencies.profileManager
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            // Profile Icon
            Image(systemName: profileIcon)
                .font(.system(size: 24))
                .foregroundColor(profileManager.activeProfile?.id == profile.id ? .accentColor : .secondary)
                .accessibilityLabel(profileAccessibilityLabel)

            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    TextField("Profile Name", text: $editedName, onCommit: {
                        saveProfileName()
                    })
                    .textFieldStyle(.roundedBorder)
                } else {
                    HStack(spacing: 8) {
                        Text(profile.name)
                            .font(.system(size: 14, weight: .medium))

                        if profileManager.activeProfile?.id == profile.id {
                            Text("profiles.active_badge".localized)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor)
                                .cornerRadius(4)
                        }
                    }
                }

                Text(profileInfo)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Actions
            HStack(spacing: 8) {
                if !isEditing {
                    // Rename Button
                    Button(action: {
                        editedName = profile.name
                        isEditing = true
                    }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .help("profiles.rename".localized)
                    .accessibilityIdentifier(
                        ProviderUIAccessibility.profileRename
                    )

                    // Activate Button (if not active)
                    if profileManager.activeProfile?.id != profile.id {
                        Button(action: {
                            Task {
                                await dependencies.activateProfile(
                                    profile.id
                                )
                            }
                        }) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .help("profiles.activate".localized)
                        .accessibilityIdentifier(
                            ProviderUIAccessibility.profileActivate
                        )
                    }

                    // Delete Button (if not the last profile)
                    if profileManager.profiles.count > 1 {
                        Button(action: {
                            deletionAlert = .confirmation
                        }) {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .help("profiles.delete".localized)
                        .accessibilityIdentifier(
                            ProviderUIAccessibility.profileDelete
                        )
                    }
                } else {
                    // Save Button
                    Button(action: {
                        saveProfileName()
                    }) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)

                    // Cancel Button
                    Button(action: {
                        isEditing = false
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "profile.row.\(profile.providerID.rawValue)."
                + profile.id.uuidString.lowercased()
        )
        .alert(item: $deletionAlert) { alert in
            switch alert {
            case .confirmation:
                return Alert(
                    title: Text("profiles.delete_title".localized),
                    message: Text(
                        String(format: "profiles.delete_confirm".localized, profile.name)
                    ),
                    primaryButton: .destructive(Text("common.delete".localized)) {
                        deleteProfile()
                    },
                    secondaryButton: .cancel(Text("common.cancel".localized))
                )
            case .failure(let presentation):
                return Alert(
                    title: Text("profiles.delete_title".localized),
                    message: Text(presentation.message),
                    primaryButton: .default(Text("common.retry".localized)) {
                        deleteProfile()
                    },
                    secondaryButton: .cancel(Text("common.cancel".localized))
                )
            }
        }
        .alert(item: $renameAlert) { alert in
            Alert(
                title: Text(
                    ProviderUILocalization.text(
                        "profiles.rename_failed_title",
                        fallback: "Unable to Rename Profile"
                    )
                ),
                message: Text(alert.message),
                primaryButton: .default(
                    Text("common.retry".localized)
                ) {
                    editedName = alert.attemptedName
                    saveProfileName()
                },
                secondaryButton: .cancel(
                    Text("common.cancel".localized)
                )
            )
        }
    }

    private var profileInfo: String {
        let presentation =
            ProviderProfilePresentation(profile: profile)
        var parts = [presentation.detailText]
        parts.append("\("profiles.created".localized) \(profile.createdAt.formatted(date: .abbreviated, time: .omitted))")

        return parts.joined(separator: " • ")
    }

    private var profileIcon: String {
        ProviderProfilePresentation(
            profile: profile
        ).systemImage
    }

    private var profileAccessibilityLabel: String {
        let active =
            profileManager.activeProfile?.id == profile.id
            ? "active" : "inactive"
        return "\(profile.name), \(profileInfo), \(active)"
    }

    private func saveProfileName() {
        if !editedName.isEmpty && editedName != profile.name {
            do {
                try ProfileRowMutation.rename(
                    editedName
                ).perform(
                    profileID: profile.id,
                    dependencies: dependencies
                )
            } catch {
                renameAlert = ProfileRenameAlert(
                    attemptedName: editedName,
                    message: ProfileRenameErrorPresentation(
                        error: error
                    ).message
                )
                return
            }
        }
        isEditing = false
    }

    private func deleteProfile() {
        do {
            try ProfileRowMutation.delete.perform(
                profileID: profile.id,
                dependencies: dependencies
            )
        } catch {
            let presentation = ProfileDeletionErrorPresentation(error: error)

            // Alert actions dismiss the current alert after invoking their
            // closure. Enqueue the failure state so it persists after that
            // dismissal and remains available for retry or cancellation.
            DispatchQueue.main.async {
                deletionAlert = .failure(presentation)
            }
        }
    }
}

struct ProfileRenameAlert: Identifiable {
    let id = UUID()
    let attemptedName: String
    let message: String
}

enum ProfileRowMutation: Equatable {
    case rename(String)
    case delete

    @MainActor
    func perform(
        profileID: UUID,
        dependencies: ProviderUIDependencies
    ) throws {
        switch self {
        case .rename(let name):
            try dependencies.updateName(
                name,
                profileID: profileID
            )
        case .delete:
            try dependencies.deleteProfile(profileID)
        }
    }
}

struct ProfileRenameErrorPresentation: Equatable {
    static let genericMessage =
        "Unable to rename this profile. Please try again."

    let message: String

    init(error: Error) {
        if let localizedError = error as? any LocalizedError,
           let description = localizedError.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            message = description
        } else {
            message = Self.genericMessage
        }
    }
}

enum ProfileDeletionAlert: Identifiable {
    case confirmation
    case failure(ProfileDeletionErrorPresentation)

    var id: String {
        switch self {
        case .confirmation:
            return "confirmation"
        case .failure:
            return "failure"
        }
    }
}

struct ProfileDeletionErrorPresentation: Equatable {
    static let genericMessage = "Unable to delete this profile. Please try again."

    let message: String

    init(error: Error) {
        // Only use an intentionally authored LocalizedError description. Do not
        // bridge arbitrary Error/NSError payloads through localizedDescription:
        // those may include an underlying message or credential material.
        if let localizedError = error as? any LocalizedError,
           let description = localizedError.errorDescription?.trimmingCharacters(
               in: .whitespacesAndNewlines
           ),
           !description.isEmpty {
            message = description
        } else {
            message = Self.genericMessage
        }
    }
}

// MARK: - Create Profile Sheet

struct CreateProfileSheet: View {
    @Binding var profileName: String
    @Binding var provider: ProfileProviderKind
    @Binding var codexHomePath: String
    let codexAvailable: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("profiles.create_title".localized)
                .font(.system(size: 18, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("profiles.name_label".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                TextField("profiles.name_placeholder".localized, text: $profileName)
                    .textFieldStyle(.roundedBorder)

                Text("profiles.name_hint".localized)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Text(
                    ProviderUILocalization.text(
                        "profiles.provider_label",
                        fallback: "Provider"
                    )
                )
                .font(.system(size: 12))
                .foregroundColor(.secondary)

                Picker("", selection: $provider) {
                    Text("Claude").tag(ProfileProviderKind.claude)
                    Text("Codex").tag(ProfileProviderKind.codex)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("profile.create.provider")
                .onChange(of: provider) { _, newProvider in
                    if newProvider == .codex && !codexAvailable {
                        provider = .claude
                    }
                }

                if provider == .codex {
                    HStack {
                        TextField(
                            ProviderUILocalization.text(
                                "codex.home.placeholder",
                                fallback:
                                    "Choose a CODEX_HOME directory"
                            ),
                            text: $codexHomePath
                        )
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(
                            ProviderUIAccessibility.homePath
                        )

                        Button {
                            chooseCodexHome()
                        } label: {
                            Image(systemName: "folder")
                        }
                        .accessibilityIdentifier(
                            ProviderUIAccessibility.homePicker
                        )
                    }

                    Text(
                        ProviderUILocalization.text(
                            "codex.credentials.owned_by_codex",
                            fallback:
                                "Credentials remain in this directory and are managed only by Codex."
                        )
                    )
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                }

                if !codexAvailable {
                    Text(
                        ProviderUILocalization.text(
                            "codex.feature_unavailable",
                            fallback:
                                "Codex support is not available in this build."
                        )
                    )
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier(
                        ProviderUIAccessibility.capabilityDisabled
                    )
                }
            }

            HStack(spacing: 12) {
                Button("common.cancel".localized) {
                    onCancel()
                }
                .buttonStyle(.plain)

                Button("common.create".localized) {
                    onSave()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    provider == .codex
                        && (!codexAvailable
                            || codexHomePath.isEmpty)
                )
                .accessibilityIdentifier(
                    ProviderUIAccessibility.profileCreate
                )
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func chooseCodexHome() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            codexHomePath = url.path
        }
    }
}
