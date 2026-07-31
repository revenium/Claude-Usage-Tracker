import SwiftUI
import AppKit
import UsageCore

struct ProviderAccountSettingsView: View {
    let profileID: UUID?
    private let dependencies: ProviderUIDependencies
    @StateObject private var viewModel: ProviderAccountViewModel
    @State private var homePath = ""
    @State private var operationMessage: String?
    @State private var showingUnlinkConfirmation = false
    @FocusState private var homeFieldFocused: Bool

    init(
        profileID: UUID?,
        dependencies: ProviderUIDependencies
    ) {
        self.profileID = profileID
        self.dependencies = dependencies
        _viewModel = StateObject(
            wrappedValue: ProviderAccountViewModel(
                dependencies: dependencies
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(
                alignment: .leading,
                spacing: DesignTokens.Spacing.section
            ) {
                SettingsPageHeader(
                    title: text(
                        "codex.account.title",
                        "Codex Account"
                    ),
                    subtitle: text(
                        "codex.account.subtitle",
                        "Manage this profile's Codex home and ChatGPT subscription account."
                    )
                )

                if let profile {
                    providerIdentityCard(profile)
                    homeCard(profile)
                    accountCard(profile)
                } else {
                    capabilityMessage(
                        text(
                            "provider.profile_unavailable",
                            "This profile is no longer available."
                        )
                    )
                }

                if let operationMessage {
                    capabilityMessage(operationMessage, color: .red)
                }
            }
            .padding()
        }
        .onAppear {
            selectAndRefresh()
            if profile?.providerConfiguration.codexConfiguration?
                .linkedHome == nil {
                homeFieldFocused = true
            }
        }
        .onChange(of: profileID) { _, _ in
            selectAndRefresh()
        }
        .onChange(of: viewModel.loginState) { _, state in
            openChallengeIfNeeded(state)
        }
        .onDisappear {
            viewModel.dismiss()
        }
        .alert(
            text("codex.unlink.title", "Unlink Codex Home"),
            isPresented: $showingUnlinkConfirmation
        ) {
            Button("common.cancel".localized, role: .cancel) {}
                .accessibilityIdentifier(
                    ProviderUIAccessibility.unlinkCancel
                )
            Button(
                text("codex.unlink.action", "Unlink"),
                role: .destructive
            ) {
                unlink()
            }
            .accessibilityIdentifier(
                ProviderUIAccessibility.unlinkConfirmation
            )
        } message: {
            Text(
                text(
                    "codex.unlink.confirmation",
                    "This removes only the app's association. Codex credentials remain in the Codex home and Codex is not logged out."
                )
            )
        }
    }

    private var profile: Profile? {
        guard let profileID else { return nil }
        guard let profile = dependencies.profile(id: profileID),
              profile.providerID == .codex else {
            return nil
        }
        return profile
    }

    private func providerIdentityCard(
        _ profile: Profile
    ) -> some View {
        SettingsContentCard {
            HStack(spacing: DesignTokens.Spacing.medium) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 22))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name)
                        .font(DesignTokens.Typography.sectionTitle)
                    Text(
                        text(
                            "provider.immutable.codex",
                            "Provider: Codex (cannot be changed)"
                        )
                    )
                    .font(DesignTokens.Typography.caption)
                    .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
    }

    private func homeCard(_ profile: Profile) -> some View {
        SettingsSectionCard(
            title: text("codex.home.title", "Codex Home"),
            subtitle: text(
                "codex.home.subtitle",
                "Link the directory already used by Codex. Credentials stay owned by Codex."
            )
        ) {
            VStack(
                alignment: .leading,
                spacing: DesignTokens.Spacing.medium
            ) {
                if let linkedHome = profile.providerConfiguration
                    .codexConfiguration?.linkedHome {
                    let presentation =
                        ProviderProfilePresentation(
                            profile: profile
                        )
                    HStack(spacing: 8) {
                        Image(systemName: "link.circle.fill")
                            .foregroundColor(
                                presentation.isConnected
                                    ? .green : .orange
                            )
                        Text(linkedHome.path)
                            .font(DesignTokens.Typography.monospaced)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    if !presentation.isConnected {
                        capabilityMessage(
                            text(
                                "codex.home.relink_required",
                                "This link is unavailable or changed and must be verified again before Codex can be used."
                            ),
                            color: .orange
                        )
                    }
                }

                HStack {
                    TextField(
                        text(
                            "codex.home.placeholder",
                            "Choose a CODEX_HOME directory"
                        ),
                        text: $homePath
                    )
                    .textFieldStyle(.roundedBorder)
                    .focused($homeFieldFocused)
                    .accessibilityIdentifier(
                        ProviderUIAccessibility.homePath
                    )

                    Button {
                        chooseHome()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel(
                        text("codex.home.choose", "Choose Codex Home")
                    )
                    .accessibilityIdentifier(
                        ProviderUIAccessibility.homePicker
                    )

                    Button(
                        profile.providerConfiguration
                            .codexConfiguration?.linkedHome == nil
                            ? text("codex.home.link", "Link")
                            : text("codex.home.relink", "Relink")
                    ) {
                        link()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(homePath.isEmpty)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(
                        ProviderUIAccessibility.homeLink
                    )
                }

                if profile.providerConfiguration
                    .codexConfiguration?.linkedHome != nil {
                    Button(
                        text("codex.unlink.action", "Unlink"),
                        role: .destructive
                    ) {
                        showingUnlinkConfirmation = true
                    }
                    .accessibilityIdentifier(
                        ProviderUIAccessibility.unlink
                    )
                }
            }
        }
    }

    private func accountCard(_ profile: Profile) -> some View {
        SettingsSectionCard(
            title: text("codex.account.status_title", "Account & Health"),
            subtitle: text(
                "codex.account.status_subtitle",
                "Read-only status from the official Codex app server."
            )
        ) {
            VStack(
                alignment: .leading,
                spacing: DesignTokens.Spacing.medium
            ) {
                accountStateView

                HStack {
                    Button {
                        viewModel.refresh()
                    } label: {
                        Label(
                            "common.refresh".localized,
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(
                        profile.providerConfiguration
                            .codexConfiguration?.linkedHome == nil
                    )
                    .accessibilityIdentifier(
                        ProviderUIAccessibility.accountRefresh
                    )

                    if dependencies.codexCapabilities.supports(
                        .interactiveLogin
                    ) {
                        Button {
                            viewModel.startLogin(.browser)
                        } label: {
                            Label(
                                text(
                                    "codex.login.browser",
                                    "Sign In in Browser"
                                ),
                                systemImage: "safari"
                            )
                        }
                        .disabled(!canStartLogin)
                        .accessibilityIdentifier(
                            ProviderUIAccessibility.loginStartBrowser
                        )

                        Button {
                            viewModel.startLogin(.deviceCode)
                        } label: {
                            Label(
                                text(
                                    "codex.login.device",
                                    "Use Device Code"
                                ),
                                systemImage: "number.square"
                            )
                        }
                        .disabled(!canStartLogin)
                        .accessibilityIdentifier(
                            ProviderUIAccessibility.loginStartDevice
                        )
                    } else {
                        capabilityMessage(
                            text(
                                "provider.capability.login_unavailable",
                                "Interactive sign-in is unavailable for this provider."
                            )
                        )
                        .accessibilityIdentifier(
                            ProviderUIAccessibility.capabilityDisabled
                        )
                    }
                }

                loginStateView
            }
        }
    }

    @ViewBuilder
    private var accountStateView: some View {
        switch viewModel.accountState {
        case .idle:
            Text(
                text(
                    "codex.account.not_checked",
                    "Account status has not been checked."
                )
            )
            .foregroundColor(.secondary)
            .accessibilityIdentifier(
                ProviderUIAccessibility.accountStatus
            )
        case .loading:
            HStack {
                ProgressView()
                Text(text("codex.account.checking", "Checking Codex…"))
            }
            .accessibilityIdentifier(
                ProviderUIAccessibility.accountStatus
            )
        case .linked(let snapshot):
            VStack(alignment: .leading, spacing: 6) {
                statusRow(
                    title: text("codex.account.status", "Status"),
                    value: healthLabel(snapshot.health),
                    color: healthColor(snapshot.health.status)
                )
                if let displayName = snapshot.account.displayName {
                    statusRow(
                        title: text("codex.account.name", "Account"),
                        value: displayName
                    )
                }
                if let plan = snapshot.account.planName {
                    statusRow(
                        title: text("codex.account.plan", "Plan"),
                        value: plan
                    )
                }
                if let organization = snapshot.account.organizationName {
                    statusRow(
                        title: text(
                            "codex.account.organization",
                            "Organization"
                        ),
                        value: organization
                    )
                }
            }
            .accessibilityIdentifier(
                ProviderUIAccessibility.accountStatus
            )
        case .unauthenticated(let health):
            statusRow(
                title: text("codex.account.status", "Status"),
                value: text(
                    "codex.account.signed_out",
                    "Sign-in required"
                ),
                color: healthColor(health.status)
            )
            .accessibilityIdentifier(
                ProviderUIAccessibility.accountUnauthenticated
            )
        case .unsupported(let health):
            VStack(alignment: .leading, spacing: 6) {
                statusRow(
                    title: text("codex.account.status", "Status"),
                    value: text(
                        "codex.account.unsupported_short",
                        "Unsupported account"
                    ),
                    color: healthColor(health.status)
                )
                Text(
                    text(
                        "codex.account.unsupported",
                        "This account does not expose ChatGPT subscription usage. API-key and provider-hosted modes are not supported."
                    )
                )
                .font(DesignTokens.Typography.caption)
                .foregroundColor(.secondary)
            }
            .accessibilityIdentifier(
                ProviderUIAccessibility.accountUnsupported
            )
        case .unavailable(let message):
            capabilityMessage(message, color: .red)
                .accessibilityIdentifier(
                    ProviderUIAccessibility.accountUnavailable
                )
        }
    }

    @ViewBuilder
    private var loginStateView: some View {
        switch viewModel.loginState {
        case .idle:
            EmptyView()
        case .starting:
            HStack {
                ProgressView()
                Text(text("codex.login.starting", "Starting sign-in…"))
            }
        case .awaiting(let challenge):
            VStack(alignment: .leading, spacing: 8) {
                switch challenge {
                case .browser:
                    Text(
                        text(
                            "codex.login.browser_waiting",
                            "Complete sign-in in the browser. This app never receives or stores your Codex credentials."
                        )
                    )
                    .accessibilityIdentifier(
                        ProviderUIAccessibility.loginBrowserWaiting
                    )
                case .deviceCode(let verificationURL, let userCode):
                    Text(
                        text(
                            "codex.login.device_instructions",
                            "Open the verification page and enter this code:"
                        )
                    )
                    Text(userCode)
                        .font(.system(.title3, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityLabel(
                            text("codex.login.user_code", "Device code")
                        )
                        .accessibilityIdentifier(
                            ProviderUIAccessibility.loginDeviceCode
                        )
                    Button(
                        text(
                            "codex.login.open_verification",
                            "Open Verification Page"
                        )
                    ) {
                        NSWorkspace.shared.open(verificationURL)
                    }
                    .accessibilityIdentifier(
                        ProviderUIAccessibility.loginOpenVerification
                    )
                }
                Button(
                    text("codex.login.cancel", "Cancel Sign-In")
                ) {
                    viewModel.cancelLogin()
                }
                .accessibilityIdentifier(
                    ProviderUIAccessibility.loginCancel
                )
            }
            .font(DesignTokens.Typography.caption)
        case .cancelling:
            HStack {
                ProgressView()
                Text(text("codex.login.cancelling", "Canceling sign-in…"))
            }
        case .succeeded:
            Label(
                text("codex.login.succeeded", "Signed in with Codex"),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundColor(.green)
            .accessibilityIdentifier(
                ProviderUIAccessibility.loginSucceeded
            )
        case .failed(let message):
            capabilityMessage(message, color: .red)
        }
    }

    private var canStartLogin: Bool {
        guard profile?.providerConfiguration
            .codexConfiguration?.linkedHome != nil else {
            return false
        }
        switch viewModel.loginState {
        case .idle, .succeeded, .failed:
            return true
        case .starting, .awaiting, .cancelling:
            return false
        }
    }

    private func statusRow(
        title: String,
        value: String,
        color: Color = .primary
    ) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .foregroundColor(color)
        }
        .font(DesignTokens.Typography.body)
    }

    private func capabilityMessage(
        _ message: String,
        color: Color = .secondary
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
            Text(message)
        }
        .font(DesignTokens.Typography.caption)
        .foregroundColor(color)
    }

    private func selectAndRefresh() {
        viewModel.selectProfile(profileID)
        if let profile {
            homePath = profile.providerConfiguration
                .codexConfiguration?.linkedHome?.path ?? ""
            viewModel.refresh()
        }
    }

    private func chooseHome() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = text("codex.home.choose", "Choose Codex Home")
        if panel.runModal() == .OK, let url = panel.url {
            homePath = url.path
        }
    }

    private func link() {
        guard let profileID else { return }
        do {
            _ = try dependencies.linkCodexHome(
                homePath,
                profileID: profileID
            )
            operationMessage = nil
            viewModel.selectProfile(nil)
            viewModel.selectProfile(profileID)
            viewModel.refresh()
        } catch {
            operationMessage = ProviderAccountViewModel.message(for: error)
        }
    }

    private func unlink() {
        guard let profileID else { return }
        viewModel.dismiss()
        do {
            _ = try dependencies.unlinkCodexHome(profileID: profileID)
            homePath = ""
            operationMessage = nil
            viewModel.selectProfile(nil)
            viewModel.selectProfile(profileID)
        } catch {
            operationMessage = ProviderAccountViewModel.message(for: error)
        }
    }

    private func openChallengeIfNeeded(
        _ state: ProviderLoginViewState
    ) {
        guard case .awaiting(.browser(let url)) = state else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func healthLabel(_ health: ProviderHealth) -> String {
        switch health.status {
        case .healthy:
            return text("provider.health.healthy", "Healthy")
        case .degraded:
            return text("provider.health.degraded", "Degraded")
        case .unavailable:
            return text("provider.health.unavailable", "Unavailable")
        case .unauthenticated:
            return text(
                "provider.health.unauthenticated",
                "Sign-in required"
            )
        case .unsupported:
            return text("provider.health.unsupported", "Unsupported")
        }
    }

    private func healthColor(_ health: ProviderHealthStatus) -> Color {
        switch health {
        case .healthy:
            return .green
        case .degraded:
            return .orange
        case .unavailable, .unauthenticated, .unsupported:
            return .red
        }
    }

    private func text(_ key: String, _ fallback: String) -> String {
        ProviderUILocalization.text(key, fallback: fallback)
    }
}

enum ProviderUIAccessibility {
    static let providerChoiceClaude = "setup.provider.claude"
    static let providerChoiceCodex = "setup.provider.codex"
    static let homePath = "codex.home.path"
    static let profileName = "codex.profile.name"
    static let setupTitle = "codex.setup.title"
    static let setupBack = "codex.setup.back"
    static let homePicker = "codex.home.picker"
    static let homeLink = "codex.home.link"
    static let loginStartBrowser = "codex.login.browser.start"
    static let loginStartDevice = "codex.login.device.start"
    static let loginCancel = "codex.login.cancel"
    static let loginDeviceCode = "codex.login.device.code"
    static let loginOpenVerification =
        "codex.login.device.open_verification"
    static let loginBrowserWaiting =
        "codex.login.browser.waiting"
    static let loginSucceeded = "codex.login.succeeded"
    static let accountStatus = "codex.account.status"
    static let accountRefresh = "codex.account.refresh"
    static let unlink = "codex.home.unlink"
    static let unlinkConfirmation = "codex.home.unlink.confirm"
    static let unlinkCancel = "codex.home.unlink.cancel"
    static let accountUnauthenticated =
        "codex.account.unauthenticated"
    static let accountUnsupported = "codex.account.unsupported"
    static let accountUnavailable = "codex.account.unavailable"
    static let setupComplete = "codex.setup.start_tracking"
    static let historySurface = "history.surface"
    static let historyTimeScale = "history.time_scale"
    static let historyExport = "history.export"
    static let profileCreateOpen = "profile.create.open"
    static let profileCreateConfirmation = "profile.create.confirm"
    static let profileRename = "profile.rename"
    static let profileActivate = "profile.activate"
    static let profileDelete = "profile.delete"
    static let profileDeleteConfirmation = "profile.delete.confirm"
    static let profileDeleteCancel = "profile.delete.cancel"
    static let profileDeleteRetry = "profile.delete.retry"
    static let capabilityDisabled = "provider.capability.unavailable"
}
