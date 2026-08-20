//
//  PersonalUsageView.swift
//  Claude Usage - Claude.ai Personal Usage Tracking
//
//  Created by Claude Code on 2025-12-20.
//

import SwiftUI
import UsageCore

// MARK: - Wizard State Machine

enum WizardStep: Int, Comparable {
    case enterKey = 1
    case selectOrg = 2
    case confirm = 3

    static func < (lhs: WizardStep, rhs: WizardStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct WizardState {
    var currentStep: WizardStep = .enterKey
    var sessionKey: String = ""
    var validationState: ValidationState = .idle
    var testedOrganizations: [ClaudeAPIService.AccountInfo] = []
    var selectedOrgId: String? = nil
    var originalSessionKey: String? = nil
    var originalOrgId: String? = nil
    var showingAuthSheet: Bool = false
    var sessionKeyExpiryDate: Date? = nil
    /// The profile selected when this authentication attempt began. This is
    /// intentionally transient: it never enters profile storage or defaults.
    var targetProfileID: UUID? = nil
    var targetProfileName: String? = nil
    var attempt = SessionKeyAttempt()
    /// A Chrome label is user-confirmed context only, never an account claim.
    var launchedChromeProfileLabel: String? = nil
    var hasConfirmedChromeContext = false
}

/// Claude.ai personal usage tracking (free tier)
struct PersonalUsageView: View {
    @StateObject private var profileManager = ProfileManager.shared
    @State private var wizardState = WizardState()
    @State private var currentCredentials: ProfileCredentials?
    private let apiService = ClaudeAPIService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                // Page Header
                SettingsPageHeader(
                    title: "personal.title".localized,
                    subtitle: "personal.subtitle".localized
                )

                // Professional Status Card
                HStack(spacing: DesignTokens.Spacing.medium) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: DesignTokens.StatusDot.standard, height: DesignTokens.StatusDot.standard)

                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                        Text(statusTitle)
                            .font(DesignTokens.Typography.bodyMedium)

                        if let creds = currentCredentials, creds.hasClaudeAI {
                            Text(
                                isActiveCredentialSessionOnly
                                    ? "personal.session_key_validated".localized
                                    : "personal.session_key_stored".localized
                            )
                                .font(DesignTokens.Typography.captionMono)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    // The credential works but is not in the Keychain, so it
                    // is lost at quit unless this succeeds.
                    if isActiveCredentialSessionOnly {
                        Button(action: retryCredentialSave) {
                            Text("personal.retry_save".localized)
                                .font(DesignTokens.Typography.body)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }

                    // Remove button integrated into status card
                    if currentCredentials?.hasClaudeAI == true {
                        Button(action: removeCredentials) {
                            HStack(spacing: DesignTokens.Spacing.extraSmall) {
                                Image(systemName: "trash")
                                    .font(.system(size: DesignTokens.Icons.small))
                                Text("common.remove".localized)
                                    .font(DesignTokens.Typography.body)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .foregroundColor(.red)
                    }
                }
                .padding(DesignTokens.Spacing.medium)
                .background(DesignTokens.Colors.cardBackground)
                .cornerRadius(DesignTokens.Radius.card)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                        .strokeBorder(DesignTokens.Colors.cardBorder, lineWidth: 1)
                )

                // Configuration Card Container
                VStack(alignment: .leading, spacing: 0) {
                    // Step Indicator Header
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                        Text("personal.configuration_title".localized)
                            .font(DesignTokens.Typography.sectionTitle)
                            .foregroundColor(.secondary)

                        HStack(spacing: DesignTokens.Spacing.small) {
                            ForEach(1...3, id: \.self) { step in
                                let stepEnum = WizardStep(rawValue: step)!
                                let isCurrent = wizardState.currentStep == stepEnum
                                let isCompleted = wizardState.currentStep > stepEnum

                                HStack(spacing: DesignTokens.Spacing.extraSmall) {
                                    ZStack {
                                        Circle()
                                            .fill(isCompleted ? Color.green : (isCurrent ? Color.accentColor : Color.secondary.opacity(0.2)))
                                            .frame(width: 20, height: 20)

                                        if isCompleted {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundColor(.white)
                                        } else {
                                            Text("\(step)")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(isCurrent ? .white : .secondary)
                                        }
                                    }

                                    if isCurrent {
                                        Text(stepTitle(for: step))
                                            .font(DesignTokens.Typography.body)
                                            .fontWeight(.medium)
                                            .foregroundColor(.primary)
                                    }
                                }

                                if step < 3 {
                                    Rectangle()
                                        .fill(isCompleted ? Color.green.opacity(0.3) : Color.secondary.opacity(0.2))
                                        .frame(height: 1)
                                }
                            }
                        }
                    }
                    .padding(DesignTokens.Spacing.cardPadding)
                    .padding(.bottom, DesignTokens.Spacing.extraSmall)

                    Divider()

                    // Step Content
                    Group {
                        switch wizardState.currentStep {
                        case .enterKey:
                            EnterKeyStep(wizardState: $wizardState, apiService: apiService)
                        case .selectOrg:
                            SelectOrgStep(wizardState: $wizardState)
                        case .confirm:
                            ConfirmStep(
                                wizardState: $wizardState,
                                apiService: apiService,
                                onSave: { loadCurrentCredentials() }
                            )
                        }
                    }
                    .padding(DesignTokens.Spacing.cardPadding)
                    .animation(.easeInOut(duration: 0.25), value: wizardState.currentStep)
                }
                .background(DesignTokens.Colors.cardBackground)
                .cornerRadius(DesignTokens.Radius.card)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                        .strokeBorder(DesignTokens.Colors.cardBorder, lineWidth: 1)
                )

                Spacer()
            }
            .padding()
        }
        .onAppear {
            loadExistingConfiguration()
            loadCurrentCredentials()
        }
        .onChange(of: profileManager.activeClaudeProfile?.id) { _, _ in
            // Reload when profile changes
            loadExistingConfiguration()
            loadCurrentCredentials()

            // Reset wizard state
            wizardState = WizardState()
        }
    }

    private func stepTitle(for step: Int) -> String {
        switch step {
        case 1: return "setup.step.enter_session_key".localized
        case 2: return "wizard.select_organization".localized
        case 3: return "wizard.review_config".localized
        default: return ""
        }
    }

    private func loadExistingConfiguration() {
        guard let profile = profileManager.activeClaudeProfile else { return }

        // Load existing credentials for comparison
        if let creds = try? ProfileStore.shared.loadProfileCredentials(profile.id) {
            wizardState.originalOrgId = creds.organizationId
            wizardState.originalSessionKey = creds.claudeSessionKey
        }
    }

    private func loadCurrentCredentials() {
        guard let profile = profileManager.activeClaudeProfile else { return }
        currentCredentials = try? ProfileStore.shared.loadProfileCredentials(profile.id)
    }

    /// True when the active Claude profile's credential is being held in
    /// memory because secure storage refused it.
    private var isActiveCredentialSessionOnly: Bool {
        guard let id = profileManager.activeClaudeProfile?.id else {
            return false
        }
        return profileManager.sessionOnlyCredentialProfileIDs.contains(id)
    }

    private var statusDotColor: Color {
        guard currentCredentials?.hasClaudeAI == true else {
            return Color.secondary.opacity(0.4)
        }
        return isActiveCredentialSessionOnly ? .orange : .green
    }

    private var statusTitle: String {
        guard currentCredentials?.hasClaudeAI == true else {
            return "general.not_connected".localized
        }
        return isActiveCredentialSessionOnly
            ? "personal.connected_not_saved".localized
            : "general.connected".localized
    }

    private func retryCredentialSave() {
        profileManager.retrySessionOnlyCredentialSave(
            profileID: profileManager.activeClaudeProfile?.id
        )
    }

    private func removeCredentials() {
        guard let profileId = profileManager.activeClaudeProfile?.id else {
            LoggingService.shared.logError("PersonalUsageView: No active profile for removal")
            return
        }

        LoggingService.shared.log("PersonalUsageView: Starting credential removal for profile \(profileId)")

        do {
            // Use ProfileManager's shared removal method
            try profileManager.removeClaudeAICredentials(for: profileId)

            // Reload UI to update the view
            loadCurrentCredentials()

            // Reset wizard
            wizardState = WizardState()

            LoggingService.shared.log("PersonalUsageView: Successfully removed Claude.ai credentials")

        } catch {
            let appError = AppError.wrap(error)
            ErrorLogger.shared.log(appError, severity: .error)
            ErrorPresenter.shared.showAlert(for: appError)
            LoggingService.shared.logError("PersonalUsageView: Failed to remove credentials - \(appError.message)")
        }
    }
}

// MARK: - Step 1: Enter Key

struct EnterKeyStep: View {
    @Binding var wizardState: WizardState
    let apiService: ClaudeAPIService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ChromeAssistedSessionKeyEntry(
                sessionKey: $wizardState.sessionKey,
                validationState: wizardState.validationState,
                onSessionKeyChanged: retireAttemptForKeyEdit,
                onValidationRequested: testConnection,
                onLaunchStarted: beginChromeLaunch,
                isLaunchCurrent: { generation in
                    wizardState.attempt.matches(generation)
                },
                onChromeProfileLaunched: { label in
                    wizardState.launchedChromeProfileLabel = label
                    wizardState.hasConfirmedChromeContext = false
                }
            )

            // Fallback: embedded sign-in remains available for users who
            // prefer it. Browser-assisted setup above never reads a cookie.
            VStack(alignment: .leading, spacing: 8) {
                Text("chrome_assisted.embedded_fallback".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Button(action: beginEmbeddedAuth) {
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                            .font(.system(size: 12))
                        Text("personal.signin_button".localized)
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(wizardState.validationState == .validating)
            }
            .sheet(isPresented: $wizardState.showingAuthSheet) {
                ConsoleAuthSheet(
                    title: "personal.signin_sheet_title".localized,
                    loginURL: URL(string: "https://claude.ai/login")!,
                    cookieDomain: "claude.ai",
                    onSuccess: { result in
                        wizardState.showingAuthSheet = false
                        replaceSessionKey(
                            result.sessionKey,
                            preserveCapturedTarget: true
                        )
                        wizardState.sessionKeyExpiryDate = result.expiryDate
                        testConnection()
                    },
                    onCancel: {
                        wizardState.showingAuthSheet = false
                        retireAttempt(clearKey: false)
                    }
                )
            }

            // Validation status
            if case .success(let message) = wizardState.validationState {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 14))
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.08))
                .cornerRadius(6)
            } else if case .error(let message) = wizardState.validationState {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 14))
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08))
                .cornerRadius(6)
            }
        }
    }

    private func testConnection() {
        let validator = SessionKeyValidator()
        let validationResult = validator.validationStatus(wizardState.sessionKey)

        guard validationResult.isValid else {
            wizardState.validationState = .error(validationResult.errorMessage ?? "Invalid")
            return
        }

        retireAttempt(
            clearKey: false,
            clearChromeContext: false,
            clearTarget: false
        )
        guard let target = capturedTargetIfStillCurrent() else { return }
        let generation = wizardState.attempt.generation
        let key = wizardState.sessionKey
        wizardState.validationState = .validating

        Task {
            do {
                // READ-ONLY TEST - does NOT save to Keychain
                let organizations = try await apiService.testSessionKey(key)

                await MainActor.run {
                    guard isCurrent(
                        targetID: target.id,
                        generation: generation,
                        key: key
                    ) else { return }
                    guard SessionKeyAttemptPolicy.hasSelectableOrganization(
                        organizations.count
                    ) else {
                        wizardState.validationState = .error(
                            "chrome_assisted.no_organizations".localized
                        )
                        return
                    }
                    wizardState.testedOrganizations = organizations
                    wizardState.validationState = .success(
                        String(
                            format: "chrome_assisted.validation_success".localized,
                            organizations.count
                        )
                    )

                    // Auto-advance to next step
                    withAnimation {
                        wizardState.currentStep = .selectOrg
                    }
                }

            } catch {
                let appError = AppError.wrap(error)
                ErrorLogger.shared.log(appError, severity: .error)

                await MainActor.run {
                    guard isCurrent(
                        targetID: target.id,
                        generation: generation,
                        key: key
                    ) else { return }
                    let errorMessage = SetupErrorMessage.text(for: appError)
                    wizardState.validationState = .error(errorMessage)
                }
            }
        }
    }

    private func beginChromeLaunch() -> UUID {
        guard let target = ProfileManager.shared.activeClaudeProfile else {
            retireAttempt(clearKey: false)
            wizardState.validationState = .error(
                "chrome_assisted.no_active_profile".localized
            )
            return wizardState.attempt.generation
        }
        retireAttempt(clearKey: false)
        wizardState.targetProfileID = target.id
        wizardState.targetProfileName = target.name
        return wizardState.attempt.generation
    }

    private func beginEmbeddedAuth() {
        _ = beginChromeLaunch()
        wizardState.showingAuthSheet = true
    }

    private func replaceSessionKey(
        _ key: String,
        preserveCapturedTarget: Bool = false
    ) {
        wizardState.sessionKey = key
        retireAttempt(
            clearKey: false,
            clearTarget: !preserveCapturedTarget
        )
    }

    private func retireAttemptForKeyEdit() {
        retireAttempt(
            clearKey: false,
            clearChromeContext: false,
            clearTarget: false
        )
    }

    private func retireAttempt(
        clearKey: Bool,
        clearChromeContext: Bool = true,
        clearTarget: Bool = true
    ) {
        wizardState.attempt.invalidate()
        wizardState.validationState = .idle
        wizardState.testedOrganizations = []
        wizardState.selectedOrgId = nil
        if clearTarget {
            wizardState.targetProfileID = nil
            wizardState.targetProfileName = nil
        }
        if clearChromeContext {
            wizardState.launchedChromeProfileLabel = nil
            wizardState.hasConfirmedChromeContext = false
        }
        if clearKey { wizardState.sessionKey = "" }
    }

    private func isCurrent(targetID: UUID, generation: UUID, key: String) -> Bool {
        SessionKeyAttemptPolicy.acceptsCompletion(
            generation: generation,
            currentGeneration: wizardState.attempt.generation,
            keyMatches: wizardState.sessionKey == key,
            targetMatches: wizardState.targetProfileID == targetID
                && ProfileManager.shared.activeClaudeProfile?.id == targetID
        )
    }

    private func capturedTargetIfStillCurrent() -> Profile? {
        if let targetID = wizardState.targetProfileID {
            guard targetIsStillCurrent(), let target = ProfileManager.shared.profiles.first(where: {
                $0.id == targetID && $0.providerID == .claude
            }) else {
                wizardState.validationState = .error(
                    "chrome_assisted.profile_changed".localized
                )
                return nil
            }
            return target
        }
        guard let target = ProfileManager.shared.activeClaudeProfile else {
            wizardState.validationState = .error(
                "chrome_assisted.no_active_profile".localized
            )
            return nil
        }
        wizardState.targetProfileID = target.id
        wizardState.targetProfileName = target.name
        return target
    }

    private func targetIsStillCurrent() -> Bool {
        guard let targetID = wizardState.targetProfileID else { return false }
        return ProfileManager.shared.activeClaudeProfile?.id == targetID
            && ProfileManager.shared.profiles.contains(where: {
                $0.id == targetID && $0.providerID == .claude
            })
    }
}

// MARK: - Step 2: Select Organization

struct SelectOrgStep: View {
    @Binding var wizardState: WizardState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("wizard.select_organization".localized)
                    .font(.system(size: 13, weight: .medium))
                Text("wizard.choose_organization".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            // Balanced organization list
            VStack(alignment: .leading, spacing: 8) {
                ForEach(wizardState.testedOrganizations, id: \.uuid) { org in
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            wizardState.selectedOrgId = org.uuid
                        }
                    }) {
                        HStack(spacing: 10) {
                            // Radio button
                            ZStack {
                                Circle()
                                    .strokeBorder(
                                        wizardState.selectedOrgId == org.uuid
                                            ? Color.accentColor
                                            : Color.secondary.opacity(0.3),
                                        lineWidth: 1.5
                                    )
                                    .frame(width: 16, height: 16)

                                if wizardState.selectedOrgId == org.uuid {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 8, height: 8)
                                }
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(org.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.primary)
                                Text(org.uuid)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            if wizardState.selectedOrgId == org.uuid {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(10)
                        .background(
                            wizardState.selectedOrgId == org.uuid
                                ? Color.accentColor.opacity(0.06)
                                : Color.primary.opacity(0.04)
                        )
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(
                                    wizardState.selectedOrgId == org.uuid
                                        ? Color.accentColor.opacity(0.3)
                                        : Color.primary.opacity(0.08),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            // Navigation buttons
            HStack(spacing: 10) {
                Button(action: {
                    withAnimation {
                        wizardState.currentStep = .enterKey
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11))
                        Text("common.back".localized)
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Spacer()

                Button(action: {
                    withAnimation {
                        wizardState.currentStep = .confirm
                    }
                }) {
                    HStack(spacing: 6) {
                        Text("common.next".localized)
                            .font(.system(size: 12))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(wizardState.selectedOrgId == nil)
            }
        }
    }
}

// MARK: - Step 3: Confirm & Save

struct ConfirmStep: View {
    @Binding var wizardState: WizardState
    let apiService: ClaudeAPIService
    let onSave: () -> Void
    @State private var isSaving = false
    /// Set only when the save failed because secure storage refused the
    /// credential, which is the one case the user can knowingly accept.
    @State private var offerSessionOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("wizard.review_config".localized)
                    .font(.system(size: 13, weight: .medium))
                Text("wizard.confirm_settings".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            // Balanced summary card
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "key")
                        .font(.system(size: 14))
                        .foregroundColor(.accentColor)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("wizard.session_key".localized)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("personal.session_key_validated".localized)
                            .font(.system(size: 12))
                            .foregroundColor(.primary)
                    }
                }

                if let selectedOrg = wizardState.testedOrganizations.first(where: { $0.uuid == wizardState.selectedOrgId }) {
                    Divider()

                    HStack(spacing: 10) {
                        Image(systemName: "building.2")
                            .font(.system(size: 14))
                            .foregroundColor(.accentColor)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("wizard.organization".localized)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            Text(selectedOrg.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.primary)
                            Text(selectedOrg.uuid)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if keyHasChanged() {
                    Divider()

                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                        Text("wizard.key_will_update".localized)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                if let chromeLabel = wizardState.launchedChromeProfileLabel,
                   let targetName = wizardState.targetProfileName {
                    Divider()

                    Toggle(
                        isOn: $wizardState.hasConfirmedChromeContext
                    ) {
                        Text(
                            String(
                                format: "chrome_assisted.confirm_context".localized,
                                chromeLabel,
                                targetName
                            )
                        )
                        .font(.system(size: 11))
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("chrome.context_confirmation")
                }
            }
            .padding(12)
            .background(DesignTokens.Colors.cardBackground)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(DesignTokens.Colors.cardBorder, lineWidth: 1)
            )

            // Saving is the only thing that can fail on this step, and the
            // failure had nowhere to surface: the button simply stopped
            // spinning and the credential was never stored.
            if case .error(let message) = wizardState.validationState {
                WizardStatusBox(message: message, type: .error)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if offerSessionOnly {
                    Button(action: { saveConfiguration(acceptSessionOnly: true) }) {
                        Text("setup.use_session_only".localized)
                            .font(DesignTokens.Typography.body)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSaving)
                    .accessibilityIdentifier("setup.use_session_only")
                }
            }

            // Navigation buttons
            HStack(spacing: 10) {
                Button(action: {
                    withAnimation {
                        // A save failure belongs to the attempt that produced
                        // it. Leaving the step retires it, so returning here
                        // does not accuse a save that never ran.
                        if case .error = wizardState.validationState {
                            wizardState.validationState = .idle
                        }
                        wizardState.currentStep = .selectOrg
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11))
                        Text("common.back".localized)
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(isSaving)

                Spacer()

                Button(action: { saveConfiguration() }) {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 12))
                        }
                        Text(isSaving ? "wizard.saving".localized : "wizard.save_configuration".localized)
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isSaving || !canSave)
            }
        }
    }

    private func keyHasChanged() -> Bool {
        guard let originalKey = wizardState.originalSessionKey else { return true }
        return originalKey != wizardState.sessionKey
    }

    private func saveConfiguration(acceptSessionOnly: Bool = false) {
        guard isSaveAllowed(acceptSessionOnly: acceptSessionOnly),
              let profileId = wizardState.targetProfileID,
              let target = ProfileManager.shared.profiles.first(where: {
                  $0.id == profileId && $0.providerID == .claude
              }),
              ProfileManager.shared.activeClaudeProfile?.id == profileId else {
            wizardState.validationState = .error(
                "chrome_assisted.profile_changed".localized
            )
            return
        }
        let generation = wizardState.attempt.generation
        let key = wizardState.sessionKey
        let organizationID = wizardState.selectedOrgId

        isSaving = true

        Task {
            do {
                // Re-check on the actor immediately before the synchronous
                // Keychain mutation; a queued profile switch must not write
                // this attempt into a different active profile.
                guard await MainActor.run(body: {
                    isCurrent(
                        targetID: target.id,
                        generation: generation,
                        key: key
                    )
                }) else {
                    await MainActor.run { isSaving = false }
                    return
                }
                // Save to profile-specific Keychain
                var creds = try ProfileManager.shared.loadCredentials(for: target.id)
                creds.claudeSessionKey = key
                creds.organizationId = organizationID
                try ProfileManager.shared.saveCredentials(
                    for: target.id,
                    credentials: creds,
                    acceptingSessionOnly: acceptSessionOnly
                )

                await MainActor.run {
                    guard wizardState.attempt.matches(generation),
                          wizardState.targetProfileID == target.id,
                          wizardState.sessionKey == key,
                          ProfileManager.shared.activeClaudeProfile?.id == target.id
                    else {
                        isSaving = false
                        return
                    }
                    // Reset circuit breaker on successful credential save
                    ErrorRecovery.shared.recordSuccess(for: .api)

                    // Reload credentials display
                    onSave()

                    // Reset wizard to start
                    withAnimation {
                        wizardState = WizardState()
                    }
                    isSaving = false
                }

            } catch {
                let appError = AppError.wrap(error)
                ErrorLogger.shared.log(appError, severity: .error)

                await MainActor.run {
                    guard wizardState.attempt.matches(generation),
                          wizardState.targetProfileID == target.id,
                          wizardState.sessionKey == key else {
                        isSaving = false
                        return
                    }
                    wizardState.validationState = .error(
                        SetupErrorMessage.text(for: appError)
                    )
                    offerSessionOnly =
                        !acceptSessionOnly
                        && SetupErrorMessage.isCredentialStorageFailure(
                            appError
                        )
                    isSaving = false
                }
            }
        }
    }

    private var canSave: Bool {
        isSaveAllowed(acceptSessionOnly: false)
    }

    private func isSaveAllowed(acceptSessionOnly: Bool) -> Bool {
        SessionKeyAttemptPolicy.permitsSave(
            validationSucceeded: wizardState.validationState.isSuccess,
            isSessionOnlyRetry: acceptSessionOnly && offerSessionOnly,
            selectedOrganizationID: wizardState.selectedOrgId,
            chromeProfileLabel: wizardState.launchedChromeProfileLabel,
            chromeContextConfirmed: wizardState.hasConfirmedChromeContext,
            targetMatches: targetIsStillCurrent()
        )
    }

    private func isCurrent(
        targetID: UUID,
        generation: UUID,
        key: String
    ) -> Bool {
        SessionKeyAttemptPolicy.acceptsCompletion(
            generation: generation,
            currentGeneration: wizardState.attempt.generation,
            keyMatches: wizardState.sessionKey == key,
            targetMatches: wizardState.targetProfileID == targetID
                && targetIsStillCurrent()
        )
    }

    private func targetIsStillCurrent() -> Bool {
        guard let targetID = wizardState.targetProfileID else { return false }
        return ProfileManager.shared.activeClaudeProfile?.id == targetID
            && ProfileManager.shared.profiles.contains(where: {
                $0.id == targetID && $0.providerID == .claude
            })
    }
}

// MARK: - Visual Components (kept minimal)

// MARK: - Previews

#Preview {
    PersonalUsageView()
        .frame(width: 520, height: 600)
}
