import SwiftUI
import AppKit
import UsageCore

// MARK: - Setup Mode (Auto-detect vs Manual)

enum SetupMode {
    case providerSelection
    case loading
    case cliDetected(credentials: String)
    case manualSetup
    case codexSetup
}

// MARK: - Wizard State Machine

enum SetupWizardStep: Int, Comparable {
    case enterKey = 1
    case selectOrg = 2
    case confirm = 3

    static func < (lhs: SetupWizardStep, rhs: SetupWizardStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct SetupWizardState {
    var currentStep: SetupWizardStep = .enterKey
    var sessionKey: String = ""
    var validationState: ValidationState = .idle
    var testedOrganizations: [ClaudeAPIService.AccountInfo] = []
    var selectedOrgId: String? = nil
    var autoStartSessionEnabled: Bool = false
    var showInstructions: Bool = false
    var showingAuthSheet: Bool = false
    var attempt = SessionKeyAttempt()
    var claudeSetupTarget: ClaudeManualSetupTarget? = nil
    var targetProfileName: String? = nil
    var launchedChromeProfileLabel: String? = nil
    var hasConfirmedChromeContext = false
}

@MainActor
private enum SetupTargetFreshness {
    static func isCurrent(
        _ target: ClaudeManualSetupTarget?,
        profileManager: ProfileManager
    ) -> Bool {
        guard let target else { return false }
        switch target {
        case .compatibilityCurrent:
            return false
        case .existing(let profileID):
            return profileManager.activeClaudeProfile?.id == profileID
                && profileManager.profiles.contains(where: {
                    $0.id == profileID && $0.providerID == .claude
                })
        case .createdProfile(let profileID):
            let claudeProfiles = profileManager.profiles.filter {
                $0.providerID == .claude
            }
            return claudeProfiles.map(\.id) == [profileID]
                && (profileManager.activeClaudeProfile == nil
                    || profileManager.activeClaudeProfile?.id == profileID)
        case .newProfile:
            return profileManager.activeClaudeProfile == nil
                && !profileManager.profiles.contains(where: {
                    $0.providerID == .claude
                })
        }
    }
}

/// Professional, native macOS setup wizard with 3-step flow
struct SetupWizardView: View {
    @Environment(\.dismiss) var dismiss
    @State private var wizardState = SetupWizardState()
    @State private var hasClaudeCodeCredentials = false
    @State private var detectedCLICredentials: String?
    @State private var isMigrating = false
    @State private var migrationMessage: String?
    @State private var setupMode: SetupMode = .providerSelection
    private let apiService = ClaudeAPIService()
    private let dependencies: ProviderUIDependencies
    private let completionOverride: (() -> Void)?

    init(
        dependencies: ProviderUIDependencies? = nil,
        completionOverride: (() -> Void)? = nil
    ) {
        self.dependencies =
            dependencies
            ?? ProviderUICompositionRoot.shared.dependencies
        self.completionOverride = completionOverride
    }

    var body: some View {
        switch setupMode {
        case .providerSelection:
            SetupProviderChoiceView(
                codexAvailable:
                    dependencies.availability.codexSupportEnabled,
                onSelectClaude: {
                    setupMode = .loading
                    detectCLICredentials()
                },
                onSelectCodex: {
                    setupMode = .codexSetup
                }
            )
        case .loading:
            VStack(spacing: 16) {
                ProgressView()
                Text("setup.cli_detecting".localized)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .frame(width: 580, height: 680)

        case .cliDetected(let credentials):
            CLIDetectedSetupView(
                credentials: credentials,
                onStartTracking: { startTrackingWithCLI(credentials: credentials) },
                onManualSetup: { setupMode = .manualSetup }
            )

        case .manualSetup:
            manualSetupBody
        case .codexSetup:
            CodexSetupWizardView(
                dependencies: dependencies,
                onBack: {
                    setupMode = .providerSelection
                },
                onComplete: {
                    if let completionOverride {
                        completionOverride()
                    } else {
                        dismiss()
                    }
                }
            )
        }
    }

    /// Detects CLI credentials and sets the appropriate setup mode
    private func detectCLICredentials() {
        Task {
            do {
                if let credentials = try ClaudeCodeSyncService.shared.readSystemCredentials(),
                   let _ = ClaudeCodeSyncService.shared.extractAccessToken(from: credentials),
                   !ClaudeCodeSyncService.shared.isTokenExpired(credentials) {
                    await MainActor.run {
                        hasClaudeCodeCredentials = true
                        detectedCLICredentials = credentials
                        setupMode = .cliDetected(credentials: credentials)
                    }
                    return
                }
            } catch { }

            await MainActor.run {
                setupMode = .manualSetup
            }
        }
    }

    /// Saves CLI credentials to the active profile and dismisses the wizard
    private func startTrackingWithCLI(credentials: String) {
        Task {
            do {
                _ = try await dependencies
                    .completeClaudeCLISetup(
                        credentials: credentials
                    )
                dismiss()
            } catch {
                LoggingService.shared.logError(
                    "Failed to sync CLI credentials: \(error)"
                )
                setupMode = .manualSetup
            }
        }
    }

    private var manualSetupBody: some View {
        VStack(spacing: 0) {
            // Header with logo and progress indicator
            VStack(spacing: 16) {
                // Logo and title
                HStack(spacing: 2) {
                    Image("WizardLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)

                    VStack(spacing: 8) {
                        Text("setup.welcome.title".localized)
                            .font(.system(size: 24, weight: .semibold))

                        Text("setup.welcome.subtitle".localized)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 32)

                // Step progress indicator
                HStack(spacing: 8) {
                    SetupStepCircle(number: 1, isCurrent: wizardState.currentStep == .enterKey, isCompleted: wizardState.currentStep > .enterKey)
                    SetupStepLine(isCompleted: wizardState.currentStep > .enterKey)
                    SetupStepCircle(number: 2, isCurrent: wizardState.currentStep == .selectOrg, isCompleted: wizardState.currentStep > .selectOrg)
                    SetupStepLine(isCompleted: wizardState.currentStep > .selectOrg)
                    SetupStepCircle(number: 3, isCurrent: wizardState.currentStep == .confirm, isCompleted: false)
                    Spacer()
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
            }

            Divider()

            // Claude Code info section - compact (only show if credentials exist)
            if hasClaudeCodeCredentials {
                HStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.system(size: 16))
                        .foregroundColor(.purple)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("wizard.claude_code_info_title".localized)
                            .font(.system(size: 12, weight: .medium))
                        Text("wizard.claude_code_info_description".localized)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    Button(action: {
                        if let detectedCLICredentials {
                            startTrackingWithCLI(
                                credentials: detectedCLICredentials
                            )
                        }
                    }) {
                        Text("wizard.claude_code_skip_setup".localized)
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.purple.opacity(0.08))

                Divider()
            }

            // Migration section - compact (only show if migration not completed yet)
            if MigrationService.shared.shouldShowMigrationOption() {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 16))
                        .foregroundColor(.blue)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("wizard.migrate_old_data".localized)
                            .font(.system(size: 12, weight: .medium))

                        if let message = migrationMessage {
                            Text(message)
                                .font(.system(size: 11))
                                .foregroundColor(.green)
                                .lineLimit(1)
                        } else {
                            Text("wizard.migrate_description_short".localized)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Button(action: migrateOldData) {
                            HStack {
                                if isMigrating {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                } else {
                                    Text("wizard.migrate_button".localized)
                                        .font(.system(size: 11))
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isMigrating)

                        Button(action: skipMigration) {
                            Text("wizard.skip_migration".localized)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .disabled(isMigrating)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.blue.opacity(0.08))

                Divider()
            }

            // Step content based on wizard state
            Group {
                switch wizardState.currentStep {
                case .enterKey:
                    EnterKeyStepSetup(
                        wizardState: $wizardState,
                        apiService: apiService,
                        dependencies: dependencies
                    )
                case .selectOrg:
                    SelectOrgStepSetup(wizardState: $wizardState)
                case .confirm:
                    ConfirmStepSetup(
                        wizardState: $wizardState,
                        apiService: apiService,
                        dismiss: dismiss,
                        dependencies: dependencies
                    )
                }
            }
            .animation(.easeInOut(duration: 0.3), value: wizardState.currentStep)
        }
        .frame(width: 580, height: 680)
        .onAppear {
            // Load auto-start preference from active profile
            if let activeProfile =
                dependencies.profileManager.activeProfile {
                wizardState.autoStartSessionEnabled = activeProfile.autoStartSessionEnabled
            }
        }
    }

    // MARK: - Migration Functions

    private func migrateOldData() {
        isMigrating = true
        migrationMessage = nil

        Task {
            do {
                let count = try MigrationService.shared.migrateFromAppGroup()
                // Imported v3 profiles and legacy credential/settings sources
                // must pass the verified provider-aware migration before the
                // wizard can consider setup complete.
                try ProfileMigrationService.shared.migrateIfNeededThrowing()
                await MainActor.run {
                    isMigrating = false
                    migrationMessage = String(format: "wizard.migration_success".localized, count)
                    // Reload profiles to reflect migrated data
                    dependencies.profileManager.loadProfiles()
                }

                // A legacy container can contain settings/credentials without
                // a profile. Preserve them for explicit provider choice and
                // never dismiss into a zero-profile state.
                let hasProfiles = await MainActor.run {
                    !dependencies.profileManager.profiles.isEmpty
                }
                if hasProfiles {
                    await MainActor.run {
                        dependencies.markSetupCompleted()
                    }
                    try? await Task.sleep(
                        nanoseconds: 1_500_000_000
                    )
                    await MainActor.run {
                        dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    isMigrating = false
                    migrationMessage = String(format: "wizard.migration_failed".localized, error.localizedDescription)
                }
            }
        }
    }

    private func skipMigration() {
        // Mark migration as completed (declined) so we don't ask again
        UserDefaults.standard.set(true, forKey: "HasMigratedFromAppGroup")
        migrationMessage = "wizard.migration_skipped".localized
    }
}

struct SetupProviderChoiceView: View {
    let codexAvailable: Bool
    let onSelectClaude: () -> Void
    let onSelectCodex: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)

            Image("WizardLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 180, height: 180)
                .padding(.bottom, 26)

            VStack(spacing: 10) {
                Text(
                    ProviderUILocalization.text(
                        "setup.provider.title",
                        fallback: "Choose a Usage Provider"
                    )
                )
                .font(.system(size: 27, weight: .semibold))
                Text(
                    ProviderUILocalization.text(
                        "setup.provider.subtitle",
                        fallback:
                            "Profiles keep provider accounts and usage separate. You can add both Claude and Codex profiles."
                    )
                )
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
            }
            .padding(.bottom, 30)

            HStack(spacing: 20) {
                providerButton(
                    title: ProviderUILocalization.text(
                        "setup.provider.claude_title",
                        fallback: "Claude"
                    ),
                    subtitle: ProviderUILocalization.text(
                        "setup.provider.claude_subtitle",
                        fallback:
                            "Connect Claude.ai, Console API, or Claude Code"
                    ),
                    icon: "sparkles",
                    enabled: true,
                    identifier:
                        ProviderUIAccessibility.providerChoiceClaude,
                    action: onSelectClaude
                )
                providerButton(
                    title: ProviderUILocalization.text(
                        "setup.provider.codex_title",
                        fallback: "Codex"
                    ),
                    subtitle: ProviderUILocalization.text(
                        "setup.provider.codex_subtitle",
                        fallback:
                            "Link CODEX_HOME and your ChatGPT subscription"
                    ),
                    icon:
                        "chevron.left.forwardslash.chevron.right",
                    enabled: codexAvailable,
                    identifier:
                        ProviderUIAccessibility.providerChoiceCodex,
                    action: onSelectCodex
                )
            }

            if !codexAvailable {
                Text(
                    ProviderUILocalization.text(
                        "codex.feature_unavailable",
                        fallback:
                            "Codex support is not available in this build."
                    )
                )
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.top, 16)
                .accessibilityIdentifier(
                    ProviderUIAccessibility.capabilityDisabled
                )
            }

            Spacer(minLength: 16)
        }
        .padding(.horizontal, 40)
        .frame(width: 580, height: 680)
    }

    private func providerButton(
        title: String,
        subtitle: String,
        icon: String,
        enabled: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        ProviderChoiceCard(
            title: title,
            subtitle: subtitle,
            icon: icon,
            enabled: enabled,
            identifier: identifier,
            action: action
        )
    }
}

/// One provider card in the setup wizard's provider-choice screen. A struct
/// rather than a builder function so each card can hold its own hover state.
private struct ProviderChoiceCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let enabled: Bool
    let identifier: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 36, weight: .medium))
                    .frame(height: 42)
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
            }
            .frame(width: 240, height: 210)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        Color.primary.opacity(
                            isHovering && enabled ? 0.10 : 0.05
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        Color.accentColor.opacity(
                            isHovering && enabled ? 0.8 : 0
                        ),
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .accessibilityIdentifier(identifier)
    }
}

struct CodexSetupWizardView: View {
    private enum FocusTarget: Hashable {
        case profileName
        case homePath
    }

    private let dependencies: ProviderUIDependencies
    let onBack: () -> Void
    let onComplete: () -> Void

    @StateObject private var viewModel: ProviderAccountViewModel
    @State private var profileName = ""
    @State private var homePath = ""
    @State private var isHomeVerified = false
    @State private var isCommitting = false
    @State private var operationMessage: String?
    @FocusState private var focusTarget: FocusTarget?

    init(
        dependencies: ProviderUIDependencies,
        onBack: @escaping () -> Void,
        onComplete: @escaping () -> Void
    ) {
        self.dependencies = dependencies
        self.onBack = onBack
        self.onComplete = onComplete
        _viewModel = StateObject(
            wrappedValue: ProviderAccountViewModel(
                dependencies: dependencies
            )
        )
        _homePath = State(
            initialValue: Self.prefillHomePath(dependencies: dependencies)
        )
    }

    /// There's no existing linked home to defer to here (this is initial
    /// setup for a brand-new profile), unlike the equivalent prefill in
    /// `ProviderAccountSettingsView`. See
    /// `CodexDefaultHomeResolver.prefillCandidate` for the prefill rule
    /// itself.
    private static func prefillHomePath(
        dependencies: ProviderUIDependencies
    ) -> String {
        CodexDefaultHomeResolver.prefillCandidate(
            profiles: dependencies.profileManager.profiles
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text(
                    ProviderUILocalization.text(
                        "codex.setup.title",
                        fallback: "Set Up Codex Usage"
                    )
                )
                .font(.system(size: 24, weight: .semibold))
                .accessibilityIdentifier(
                    ProviderUIAccessibility.setupTitle
                )
                Text(
                    ProviderUILocalization.text(
                        "codex.setup.subtitle",
                        fallback:
                            "Link an existing Codex home. Authentication files remain owned by Codex and are never read or copied by this app."
                    )
                )
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(28)

            Divider()

            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: 18
                ) {
                    TextField(
                        ProviderUILocalization.text(
                            "profiles.name_placeholder",
                            fallback: "Profile name (optional)"
                        ),
                        text: $profileName
                    )
                    .textFieldStyle(.roundedBorder)
                    .focused($focusTarget, equals: .profileName)
                    .accessibilityIdentifier(
                        ProviderUIAccessibility.profileName
                    )

                    HStack {
                        TextField(
                            ProviderUILocalization.text(
                                "codex.home.placeholder",
                                fallback:
                                    "Choose a CODEX_HOME directory"
                            ),
                            text: $homePath
                        )
                        .textFieldStyle(.roundedBorder)
                        .focused($focusTarget, equals: .homePath)
                        .accessibilityIdentifier(
                            ProviderUIAccessibility.homePath
                        )
                        Button {
                            chooseHome()
                        } label: {
                            Image(systemName: "folder")
                        }
                        .accessibilityIdentifier(
                            ProviderUIAccessibility.homePicker
                        )
                        Button(
                            !isHomeVerified
                                ? ProviderUILocalization.text(
                                    "codex.home.link",
                                    fallback: "Verify Home"
                                )
                                : ProviderUILocalization.text(
                                    "codex.home.relink",
                                    fallback: "Verify Again"
                                )
                        ) {
                            linkHome()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(homePath.isEmpty)
                        .accessibilityIdentifier(
                            ProviderUIAccessibility.homeLink
                        )
                    }

                    if let operationMessage {
                        WizardStatusBox(
                            message: operationMessage,
                            type: .error
                        )
                    }

                    if isHomeVerified {
                        accountSetup
                    }
                }
                .padding(32)
            }

            Divider()
            HStack {
                Button("common.back".localized) {
                    viewModel.dismiss()
                    onBack()
                }
                .accessibilityIdentifier(
                    ProviderUIAccessibility.setupBack
                )
                Spacer()
                Button(
                    ProviderUILocalization.text(
                        "codex.setup.start_tracking",
                        fallback: "Start Tracking"
                    )
                ) {
                    commitSetup()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canComplete || isCommitting)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(
                    ProviderUIAccessibility.setupComplete
                )
            }
            .padding(20)
        }
        .frame(width: 580, height: 680)
        .onChange(of: homePath) { _, _ in
            guard isHomeVerified else { return }
            isHomeVerified = false
            viewModel.invalidateDraft()
            operationMessage = ProviderUILocalization.text(
                "codex.home.reverify_after_edit",
                fallback:
                    "The Codex home changed. Verify it again before continuing."
            )
        }
        .onChange(of: viewModel.loginState) { _, state in
            if case .awaiting(.browser(let url)) = state {
                NSWorkspace.shared.open(url)
            }
        }
        .onAppear {
            focusTarget = .homePath
        }
        .onDisappear {
            viewModel.dismiss()
        }
    }

    @ViewBuilder
    private var accountSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text(
                ProviderUILocalization.text(
                    "codex.setup.account",
                    fallback: "Codex Account"
                )
            )
            .font(.system(size: 14, weight: .semibold))

            switch viewModel.accountState {
            case .linked(let snapshot):
                Label(
                    [
                        snapshot.account.displayName,
                        snapshot.account.planName
                    ]
                    .compactMap { $0 }
                    .joined(separator: " • "),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundColor(.green)
                .accessibilityIdentifier(
                    ProviderUIAccessibility.accountStatus
                )
            case .loading:
                HStack {
                    ProgressView()
                    Text(
                        ProviderUILocalization.text(
                            "codex.account.checking",
                            fallback: "Checking Codex…"
                        )
                    )
                }
            case .unauthenticated:
                Text(
                    ProviderUILocalization.text(
                        "codex.account.signed_out",
                        fallback: "Sign-in required"
                    )
                )
                    .foregroundColor(.secondary)
            case .unsupported:
                Text(
                    ProviderUILocalization.text(
                        "codex.account.unsupported",
                        fallback:
                            "This account does not expose ChatGPT subscription usage."
                    )
                )
                .foregroundColor(.red)
            case .unavailable(let message):
                Text(message).foregroundColor(.red)
            case .idle:
                EmptyView()
            }

            HStack {
                Button("common.refresh".localized) {
                    viewModel.refresh()
                }
                .accessibilityIdentifier(
                    ProviderUIAccessibility.accountRefresh
                )
                Button(
                    ProviderUILocalization.text(
                        "codex.login.browser",
                        fallback: "Sign In in Browser"
                    )
                ) {
                    viewModel.startLogin(.browser)
                }
                .accessibilityIdentifier(
                    ProviderUIAccessibility.loginStartBrowser
                )
                Button(
                    ProviderUILocalization.text(
                        "codex.login.device",
                        fallback: "Use Device Code"
                    )
                ) {
                    viewModel.startLogin(.deviceCode)
                }
                .accessibilityIdentifier(
                    ProviderUIAccessibility.loginStartDevice
                )
            }

            switch viewModel.loginState {
            case .awaiting(.deviceCode(
                let verificationURL,
                let userCode
            )):
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        ProviderUILocalization.text(
                            "codex.login.user_code",
                            fallback: "Device code"
                        )
                        + ": \(userCode)"
                    )
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier(
                            ProviderUIAccessibility.loginDeviceCode
                        )
                    Button(
                        ProviderUILocalization.text(
                            "codex.login.open_verification",
                            fallback: "Open Verification Page"
                        )
                    ) {
                        NSWorkspace.shared.open(verificationURL)
                    }
                    .accessibilityIdentifier(
                        ProviderUIAccessibility.loginOpenVerification
                    )
                    Button(
                        ProviderUILocalization.text(
                            "codex.login.cancel",
                            fallback: "Cancel Sign-In"
                        )
                    ) {
                        viewModel.cancelLogin()
                    }
                    .accessibilityIdentifier(
                        ProviderUIAccessibility.loginCancel
                    )
                }
            case .awaiting(.browser):
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        ProviderUILocalization.text(
                            "codex.login.browser_waiting",
                            fallback:
                                "Complete sign-in in the browser."
                        )
                    )
                    Button(
                        ProviderUILocalization.text(
                            "codex.login.cancel",
                            fallback: "Cancel Sign-In"
                        )
                    ) {
                        viewModel.cancelLogin()
                    }
                    .accessibilityIdentifier(
                        ProviderUIAccessibility.loginCancel
                    )
                }
            case .starting:
                ProgressView()
            case .cancelling:
                Text(
                    ProviderUILocalization.text(
                        "codex.login.cancelling",
                        fallback: "Canceling sign-in…"
                    )
                )
            case .succeeded:
                Label(
                    ProviderUILocalization.text(
                        "codex.login.succeeded",
                        fallback: "Signed in with Codex"
                    ),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundColor(.green)
            case .failed(let message):
                Text(message).foregroundColor(.red)
            case .idle:
                EmptyView()
            }
        }
        .font(.system(size: 12))
    }

    private var canComplete: Bool {
        if case .linked = viewModel.accountState {
            return true
        }
        return false
    }

    private func chooseHome() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            homePath = url.path
        }
    }

    private func linkHome() {
        do {
            try viewModel.selectDraftCodexHome(homePath)
            isHomeVerified = true
            operationMessage = nil
            viewModel.refresh()
        } catch {
            isHomeVerified = false
            operationMessage =
                ProviderAccountViewModel.message(for: error)
        }
    }

    /// Re-canonicalizes and duplicate-checks the home immediately before the
    /// only metadata write. Back, close, login failure, and cancellation leave
    /// a zero-profile first run untouched.
    private func commitSetup() {
        guard !isCommitting else { return }
        guard let verifiedIdentity =
                viewModel.verifiedDraftIdentity else {
            operationMessage = ProviderAccountViewModel.message(
                for: CodexHomeCanonicalizationError
                    .changedSinceVerification
            )
            return
        }
        isCommitting = true
        Task {
            do {
                _ = try await dependencies.completeCodexSetup(
                    name:
                        profileName.isEmpty
                        ? nil : profileName,
                    homePath: homePath,
                    verifiedIdentity: verifiedIdentity
                )
                isCommitting = false
                onComplete()
            } catch {
                isCommitting = false
                operationMessage =
                    ProviderAccountViewModel.message(for: error)
            }
        }
    }
}

// MARK: - Step 1: Enter Key

struct EnterKeyStepSetup: View {
    @Environment(\.dismiss) var dismiss
    @Binding var wizardState: SetupWizardState
    let apiService: ClaudeAPIService
    let dependencies: ProviderUIDependencies

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Step header
                    SetupStepHeader(stepNumber: 1, title: "setup.step.get_session_key".localized)

                    Text("setup.step.get_session_key.description".localized)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)

                    ChromeAssistedSessionKeyEntry(
                        sessionKey: $wizardState.sessionKey,
                        validationState: wizardState.validationState,
                        onSessionKeyChanged: retireAttemptForKeyEdit,
                        onValidationRequested: testConnection,
                        onLaunchStarted: beginChromeLaunch,
                        isLaunchCurrent: { generation in
                            wizardState.attempt.matches(generation)
                                && capturedTargetIsStillCurrent()
                        },
                        onChromeProfileLaunched: { label in
                            wizardState.launchedChromeProfileLabel = label
                            wizardState.hasConfirmedChromeContext = false
                        }
                    )

                    // Fallback: the hardened embedded sign-in remains an
                    // alternative to browser-assisted manual setup.
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
                            .frame(maxWidth: .infinity)
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
                                testConnection()
                            },
                            onCancel: {
                                wizardState.showingAuthSheet = false
                                retireAttempt(clearKey: false)
                            }
                        )
                    }

                    // Validation Status
                    if case .success(let message) = wizardState.validationState {
                        WizardStatusBox(message: message, type: .success)
                    } else if case .error(let message) = wizardState.validationState {
                        WizardStatusBox(message: message, type: .error)
                    }
                }
                .padding(32)
            }

            Divider()

            // Footer
            HStack {
                Button("common.cancel".localized) {
                    retireAttempt(clearKey: true)
                    dismiss()
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding(20)
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
        if wizardState.claudeSetupTarget == nil {
            captureNewTarget()
        }
        guard capturedTargetIsStillCurrent() else {
            wizardState.validationState = .error(
                "chrome_assisted.profile_changed".localized
            )
            return
        }
        let generation = wizardState.attempt.generation
        let key = wizardState.sessionKey
        wizardState.validationState = .validating

        Task {
            do {
                // READ-ONLY TEST - does NOT save to Keychain
                let organizations = try await apiService.testSessionKey(key)

                await MainActor.run {
                    guard isCurrent(generation: generation, key: key) else {
                        return
                    }
                    guard SessionKeyAttemptPolicy.hasSelectableOrganization(
                        organizations.count
                    ) else {
                        wizardState.validationState = .error(
                            "chrome_assisted.no_organizations".localized
                        )
                        return
                    }
                    wizardState.testedOrganizations = organizations
                    // Never start on a console/API organization: that is the
                    // choice that leaves the popover permanently unavailable.
                    wizardState.selectedOrgId =
                        ClaudeOrganizationClassifier.defaultSelection(
                            organizations
                        )
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
                    guard isCurrent(generation: generation, key: key) else {
                        return
                    }
                    let errorMessage = SetupErrorMessage.text(for: appError)
                    wizardState.validationState = .error(errorMessage)
                }
            }
        }
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

    private func beginEmbeddedAuth() {
        _ = beginChromeLaunch()
        wizardState.showingAuthSheet = true
    }

    private func beginChromeLaunch() -> UUID {
        retireAttempt(clearKey: false)
        captureNewTarget()
        return wizardState.attempt.generation
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
            wizardState.claudeSetupTarget = nil
            wizardState.targetProfileName = nil
        }
        if clearChromeContext {
            wizardState.launchedChromeProfileLabel = nil
            wizardState.hasConfirmedChromeContext = false
        }
        if clearKey { wizardState.sessionKey = "" }
    }

    private func isCurrent(generation: UUID, key: String) -> Bool {
        SessionKeyAttemptPolicy.acceptsCompletion(
            generation: generation,
            currentGeneration: wizardState.attempt.generation,
            keyMatches: wizardState.sessionKey == key,
            targetMatches: capturedTargetIsStillCurrent()
        )
    }

    private func captureNewTarget() {
        if let profile = dependencies.profileManager.activeClaudeProfile {
            wizardState.claudeSetupTarget = .existing(profile.id)
            wizardState.targetProfileName = profile.name
        } else {
            wizardState.claudeSetupTarget = .newProfile
            wizardState.targetProfileName =
                "chrome_assisted.new_claude_profile".localized
        }
    }

    private func capturedTargetIsStillCurrent() -> Bool {
        SetupTargetFreshness.isCurrent(
            wizardState.claudeSetupTarget,
            profileManager: dependencies.profileManager
        )
    }
}

// MARK: - Step 2: Select Organization

struct SelectOrgStepSetup: View {
    @Binding var wizardState: SetupWizardState

    /// Chat-capable organizations first, server order preserved within each
    /// group. Shared with the credentials pane's picker so the two cannot
    /// drift.
    private var organizations: [ClaudeAPIService.AccountInfo] {
        ClaudeOrganizationClassifier.pickerOrder(wizardState.testedOrganizations)
    }

    private var hasSelectableOrganization: Bool {
        ClaudeOrganizationClassifier.hasSelectableOrganization(
            wizardState.testedOrganizations
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Step header
                    SetupStepHeader(stepNumber: 2, title: "wizard.select_organization".localized)

                    Text("wizard.select_org_title".localized)
                        .font(.system(size: 13))

                    Text("wizard.select_org_subtitle".localized)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    // Organization list with radio buttons. Chat-capable
                    // organizations come first; console/API ones stay visible
                    // with an explanation but cannot be chosen.
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(organizations, id: \.uuid) { org in
                            let isSelectable = ClaudeOrganizationClassifier
                                .isChatCapable(org)
                            let isSelected = wizardState.selectedOrgId == org.uuid
                            HStack(spacing: 12) {
                                Image(systemName: isSelected ? "circle.fill" : "circle")
                                    .foregroundColor(isSelected ? .accentColor : .secondary)
                                    .font(.system(size: 14))

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(org.name)
                                        .font(.system(size: 13, weight: .medium))
                                    Text(ClaudeOrganizationClassifier.descriptor(org))
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    // Several organizations can share both a
                                    // name and a kind; the id prefix is the
                                    // last thing that separates them.
                                    Text(String(org.uuid.prefix(8)))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 1)
                            )
                            .opacity(isSelectable ? 1 : 0.5)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard isSelectable else { return }
                                wizardState.selectedOrgId = org.uuid
                            }
                            .accessibilityIdentifier("wizard.org_row.\(org.uuid)")
                        }
                    }

                    // An account can hold nothing but console organizations.
                    // Say so, rather than leaving every row dimmed and Next
                    // dead with no explanation.
                    if !hasSelectableOrganization {
                        WizardStatusBox(
                            message: "wizard.no_claude_organizations".localized,
                            type: .error
                        )
                    }
                }
                .padding(32)
            }

            Divider()

            // Footer
            HStack {
                Button("common.back".localized) {
                    withAnimation {
                        wizardState.currentStep = .enterKey
                    }
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("common.next".localized) {
                    withAnimation {
                        wizardState.currentStep = .confirm
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(wizardState.selectedOrgId == nil)
            }
            .padding(20)
        }
    }
}

// MARK: - Step 3: Confirm & Save

struct ConfirmStepSetup: View {
    @Binding var wizardState: SetupWizardState
    let apiService: ClaudeAPIService
    let dismiss: DismissAction
    let dependencies: ProviderUIDependencies
    @State private var isSaving = false
    /// Set only when the save failed because secure storage refused the
    /// credential, which is the one case the user can knowingly accept.
    @State private var offerSessionOnly = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Step header
                    SetupStepHeader(stepNumber: 3, title: "wizard.review_config".localized)

                    // Summary Card
                    VStack(alignment: .leading, spacing: 16) {
                        Text("wizard.config_summary".localized)
                            .font(.system(size: 14, weight: .semibold))

                        // The key itself is never shown after entry.
                        VStack(alignment: .leading, spacing: 6) {
                            Text("wizard.session_key".localized)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            Text("personal.session_key_validated".localized)
                                .font(.system(size: 11))
                        }

                        if let chromeLabel = wizardState.launchedChromeProfileLabel {
                            Divider()
                            Toggle(
                                isOn: $wizardState.hasConfirmedChromeContext
                            ) {
                                Text(
                                    String(
                                        format:
                                            "chrome_assisted.confirm_context"
                                                .localized,
                                        chromeLabel,
                                        targetProfileName
                                    )
                                )
                                .font(.system(size: 11))
                            }
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("chrome.context_confirmation")
                        }

                        Divider()

                        // Selected Organization
                        VStack(alignment: .leading, spacing: 6) {
                            Text("wizard.organization".localized)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            if let selectedOrg = wizardState.testedOrganizations.first(where: { $0.uuid == wizardState.selectedOrgId }) {
                                Text(selectedOrg.name)
                                    .font(.system(size: 13))
                                Text(String(format: "wizard.organization_id".localized, selectedOrg.uuid))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(16)
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(10)

                    // Auto-start session option
                    VStack(alignment: .leading, spacing: 10) {
                        Divider()

                        HStack(spacing: 6) {
                            Text("setup.auto_start_session".localized)
                                .font(.system(size: 13, weight: .semibold))

                            Text("session.beta_badge".localized)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.orange)
                                )
                        }

                        Text("setup.auto_start_session.description".localized)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Toggle(isOn: $wizardState.autoStartSessionEnabled) {
                            Text("setup.enable_auto_start".localized)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .toggleStyle(.switch)
                    }

                    // Saving is the only thing that can fail on this step, so
                    // the failure belongs here rather than back on step 1
                    // where it reads as a rejected session key.
                    if case .error(let message) = wizardState.validationState {
                        WizardStatusBox(message: message, type: .error)

                        if offerSessionOnly {
                            Button(action: { saveConfiguration(acceptSessionOnly: true) }) {
                                Text("setup.use_session_only".localized)
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.bordered)
                            .disabled(isSaving)
                            .accessibilityIdentifier("setup.use_session_only")
                        }
                    }
                }
                .padding(32)
            }

            Divider()

            // Footer
            HStack {
                Button("common.back".localized) {
                    withAnimation {
                        // A save failure belongs to the attempt that produced
                        // it. Leaving the step retires it, so returning here
                        // does not accuse a save that never ran.
                        if case .error = wizardState.validationState {
                            wizardState.validationState = .idle
                        }
                        wizardState.currentStep = .selectOrg
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isSaving)

                Spacer()

                Button(action: { saveConfiguration() }) {
                    if isSaving {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 100)
                    } else {
                        Text("common.done".localized)
                            .frame(width: 100)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || !canSave)
            }
            .padding(20)
        }
    }

    private func saveConfiguration(acceptSessionOnly: Bool = false) {
        guard isSaveAllowed(acceptSessionOnly: acceptSessionOnly),
              let target = wizardState.claudeSetupTarget,
              capturedTargetIsStillCurrent() else {
            wizardState.validationState = .error(
                "chrome_assisted.profile_changed".localized
            )
            return
        }
        let generation = wizardState.attempt.generation
        let key = wizardState.sessionKey
        let organizationID = wizardState.selectedOrgId
        // Captured up front so the profile records the same organization name
        // and personal/shared classification an auto-selected organization
        // would get.
        let selectedOrganization = wizardState.testedOrganizations.first(
            where: { $0.uuid == organizationID }
        )
        isSaving = true

        Task {
            do {
                let completedProfile = try await dependencies
                    .completeClaudeManualSetup(
                        sessionKey: key,
                        organizationID: organizationID,
                        autoStartSessionEnabled:
                            wizardState
                                .autoStartSessionEnabled,
                        acceptSessionOnlyStorage: acceptSessionOnly,
                        target: target
                    )
                LoggingService.shared.log(
                    "SetupWizard: Updated profile setup preferences"
                )

                await MainActor.run {
                    guard isSuccessfulCompletionCurrent(
                        generation: generation,
                        key: key,
                        target: target,
                        completedProfile: completedProfile
                    ) else {
                        isSaving = false
                        return
                    }
                    // Reset circuit breaker on successful credential save
                    ErrorRecovery.shared.recordSuccess(for: .api)

                    if let selectedOrganization {
                        dependencies.profileManager.updateOrganizationName(
                            selectedOrganization.name,
                            for: completedProfile.id
                        )
                        // Written even when indeterminate: a stale `true`
                        // left over from a previously bound organization
                        // would mislabel this one's figures.
                        dependencies.profileManager.updateOrganizationIsPersonal(
                            ClaudeOrganizationClassifier.isPersonal(
                                selectedOrganization
                            ),
                            for: completedProfile.id
                        )
                    }

                    isSaving = false
                    dismiss()
                }

            } catch {
                let appError = AppError.wrap(error)
                ErrorLogger.shared.log(appError, severity: .error)

                await MainActor.run {
                    guard isAttemptCurrent(
                        generation: generation,
                        key: key,
                        target: target
                    ) else {
                        isSaving = false
                        return
                    }
                    let retryTarget = SessionKeyAttemptPolicy
                        .retryTargetAfterFailedSetup(
                            capturedTarget: target,
                            claudeProfileIDs: dependencies.profileManager
                                .profiles.filter {
                                    $0.providerID == .claude
                                }.map(\.id)
                        )
                    if retryTarget != target {
                        wizardState.claudeSetupTarget = retryTarget
                        if case .createdProfile(let profileID) = retryTarget {
                            wizardState.targetProfileName = dependencies
                                .profileManager.profiles.first {
                                    $0.id == profileID
                                }?.name
                        }
                    }
                    wizardState.validationState = .error(
                        SetupErrorMessage.text(for: appError)
                    )
                    // Only a storage refusal is something the user can
                    // knowingly accept; every other failure needs fixing.
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

    private var targetProfileName: String {
        wizardState.targetProfileName
            ?? "chrome_assisted.new_claude_profile".localized
    }

    private var canSave: Bool {
        isSaveAllowed(acceptSessionOnly: false)
    }

    private func isSaveAllowed(acceptSessionOnly: Bool) -> Bool {
        // Last line of defence: a console/API organization must never be
        // persisted, whatever the picker did or did not disable.
        guard ClaudeOrganizationClassifier.permitsSelection(
            of: wizardState.selectedOrgId,
            from: wizardState.testedOrganizations
        ) else { return false }
        return SessionKeyAttemptPolicy.permitsSave(
            validationSucceeded: wizardState.validationState.isSuccess,
            isSessionOnlyRetry: acceptSessionOnly && offerSessionOnly,
            selectedOrganizationID: wizardState.selectedOrgId,
            chromeProfileLabel: wizardState.launchedChromeProfileLabel,
            chromeContextConfirmed: wizardState.hasConfirmedChromeContext,
            targetMatches: capturedTargetIsStillCurrent()
        )
    }

    private func isSuccessfulCompletionCurrent(
        generation: UUID,
        key: String,
        target: ClaudeManualSetupTarget,
        completedProfile: Profile
    ) -> Bool {
        SessionKeyAttemptPolicy.acceptsSetupCompletion(
            generation: generation,
            currentGeneration: wizardState.attempt.generation,
            keyMatches: wizardState.sessionKey == key,
            capturedTarget: wizardState.claudeSetupTarget == target
                ? target : nil,
            completedProfileID: completedProfile.id,
            completedProfileIsClaude: completedProfile.providerID == .claude,
            activeClaudeProfileID:
                dependencies.profileManager.activeClaudeProfile?.id
        )
    }

    private func isAttemptCurrent(
        generation: UUID,
        key: String,
        target: ClaudeManualSetupTarget
    ) -> Bool {
        SessionKeyAttemptPolicy.acceptsCompletion(
            generation: generation,
            currentGeneration: wizardState.attempt.generation,
            keyMatches: wizardState.sessionKey == key,
            targetMatches: wizardState.claudeSetupTarget == target
        )
    }

    private func capturedTargetIsStillCurrent() -> Bool {
        SetupTargetFreshness.isCurrent(
            wizardState.claudeSetupTarget,
            profileManager: dependencies.profileManager
        )
    }
}

// MARK: - Visual Components

struct SetupStepHeader: View {
    let stepNumber: Int
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Text("\(stepNumber)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor))

            Text(title)
                .font(.system(size: 16, weight: .semibold))
        }
    }
}

struct SetupStepCircle: View {
    let number: Int
    let isCurrent: Bool
    let isCompleted: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor)
                .frame(width: 24, height: 24)

            if isCompleted {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            } else {
                Text("\(number)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(textColor)
            }
        }
    }

    private var backgroundColor: Color {
        if isCompleted { return .green }
        if isCurrent { return .accentColor }
        return Color.gray.opacity(0.3)
    }

    private var textColor: Color {
        isCurrent ? .white : .secondary
    }
}

struct SetupStepLine: View {
    let isCompleted: Bool

    var body: some View {
        Rectangle()
            .fill(isCompleted ? Color.green : Color.gray.opacity(0.3))
            .frame(width: 40, height: 2)
    }
}

// MARK: - Supporting Views

struct InstructionRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Renders a setup failure so it says what to do next, not just what broke.
///
/// The error code stays for support conversations, but it is no longer the
/// only actionable thing in the box.
enum SetupErrorMessage {
    /// True when the credential itself was fine and only storing it failed,
    /// which the user can accept for the session.
    static func isCredentialStorageFailure(_ error: AppError) -> Bool {
        error.code == .credentialStorageUnavailable
            || error.code == .credentialStorageFailed
    }

    static func text(for error: AppError) -> String {
        var text = error.message
        if let suggestion = error.recoverySuggestion,
           !suggestion.isEmpty,
           suggestion != error.message {
            text += "\n\n\(suggestion)"
        }
        return text + "\n\nError Code: \(error.code.rawValue)"
    }
}

struct WizardStatusBox: View {
    let message: String
    let type: StatusType

    enum StatusType {
        case success, error

        var color: Color {
            switch self {
            case .success: return .green
            case .error: return .red
            }
        }

        var icon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .error: return "xmark.circle.fill"
            }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: type.icon)
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 12))
        }
        .foregroundColor(type.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(type.color.opacity(0.1))
        )
    }
}

// MARK: - CLI Detected Setup View
struct CLIDetectedSetupView: View {
    let credentials: String
    let onStartTracking: () -> Void
    let onManualSetup: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                // Terminal icon
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.12))
                        .frame(width: 80, height: 80)

                    Image(systemName: "terminal.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.green)
                }

                // Title
                Text("setup.cli_detected.title".localized)
                    .font(.system(size: 24, weight: .bold))

                // Description
                Text("setup.cli_detected.description".localized)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)

                // Start tracking button
                Button(action: onStartTracking) {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.bar.fill")
                        Text("setup.cli_detected.start".localized)
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                // Manual setup link
                Button(action: onManualSetup) {
                    Text("setup.cli_detected.manual".localized)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .frame(width: 580, height: 680)
    }
}

#Preview {
    SetupWizardView()
}
