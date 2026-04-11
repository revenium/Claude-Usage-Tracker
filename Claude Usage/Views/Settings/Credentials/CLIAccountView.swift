//
//  CLIAccountView.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import SwiftUI
import AppKit

struct CLIAccountView: View {
    @StateObject private var profileManager = ProfileManager.shared
    @State private var isSyncing = false
    @State private var syncError: String?
    @State private var cliAccountInfo: CLIAccountInfo?

    // Linking flow state
    @State private var showLinkConfirmation = false
    @State private var linkingInProgress = false
    @State private var credentialCheckResult: CredentialCheckResult = .notFound
    @State private var showUnlinkConfirmation = false
    @State private var showShellIntegration = false
    @State private var showSetupGuide = false
    @State private var copiedToClipboard = false
    @State private var copiedShellSnippet = false

    // MCP sync state
    @State private var mcpSyncResult: McpSyncResult?
    @State private var mcpSyncInProgress = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                SettingsPageHeader(
                    title: "cli.title".localized,
                    subtitle: "cli.subtitle".localized
                )

                if let profile = profileManager.activeProfile {
                    if profileManager.displayMode == .multi {
                        // Multi-profile mode: show linking flow
                        cliAccountLinkingSection(profile: profile)
                    } else {
                        // Single-profile mode: show note to enable multi-profile
                        multiProfileRequiredCard
                    }

                    // Account details (shown when credentials exist, regardless of mode)
                    if profile.hasCliAccount {
                        accountDetailsCard(profile: profile)
                    }

                    // MCP Server Sync (only in multi-profile mode)
                    if profileManager.displayMode == .multi {
                        mcpSyncSection
                    }

                    // Error display
                    if let error = syncError {
                        errorCard(message: error)
                    }

                    // Info card
                    infoCard
                }
            }
            .padding()
        }
        .onAppear {
            loadCLIAccountInfo()
            if let accountName = profileManager.activeProfile?.cliAccountName {
                credentialCheckResult = ClaudeSwitchService.shared.checkForCredentials(directoryName: accountName)
            }
        }
        .onChange(of: profileManager.activeProfile?.id) { _, _ in
            loadCLIAccountInfo()
            syncError = nil
            if let accountName = profileManager.activeProfile?.cliAccountName {
                credentialCheckResult = ClaudeSwitchService.shared.checkForCredentials(directoryName: accountName)
            } else {
                credentialCheckResult = .notFound
            }
        }
        // Link confirmation alert
        .alert("cli.link_confirm_title".localized, isPresented: $showLinkConfirmation) {
            Button("common.cancel".localized, role: .cancel) {}
            Button("cli.link_confirm_action".localized) {
                performLinkAccount()
            }
        } message: {
            Text(String(format: "cli.link_confirm_message".localized, sanitizedName))
        }
        // Unlink confirmation alert
        .alert("cli.unlink_title".localized, isPresented: $showUnlinkConfirmation) {
            Button("common.cancel".localized, role: .cancel) {}
            Button("cli.unlink_action".localized, role: .destructive) {
                performUnlinkAccount()
            }
        } message: {
            if let name = profileManager.activeProfile?.cliAccountName {
                Text(String(format: "cli.unlink_confirm".localized, name))
            }
        }
    }

    // MARK: - Multi-Profile Required Card

    private var multiProfileRequiredCard: some View {
        SettingsContentCard {
            HStack(spacing: DesignTokens.Spacing.small) {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.blue)
                    .font(.system(size: DesignTokens.Icons.standard))
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                    Text("cli.multi_profile_required_title".localized)
                        .font(DesignTokens.Typography.sectionTitle)
                    Text("cli.multi_profile_required".localized)
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - CLI Account Linking Section

    @ViewBuilder
    private func cliAccountLinkingSection(profile: Profile) -> some View {
        if let accountName = profile.cliAccountName {
            // Linked state
            linkedStatusCard(accountName: accountName, hasCredentials: profile.hasCliAccount)

            if !profile.hasCliAccount || !credentialCheckResult.hasCredentials {
                // Linked but no credentials yet — show setup instructions
                postSetupCard(accountName: accountName)
            }

            // Shell integration card (shown once after first successful credential detection)
            if showShellIntegration {
                shellIntegrationCard
            }

            // Action buttons for linked state
            linkedActionsCard(profile: profile)
        } else {
            // Not linked — show link button
            notLinkedStatusCard
            linkButtonCard
        }
    }

    // MARK: - Status Cards

    private var notLinkedStatusCard: some View {
        HStack(spacing: DesignTokens.Spacing.medium) {
            Circle()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: DesignTokens.StatusDot.standard, height: DesignTokens.StatusDot.standard)

            Text("cli.status_not_linked".localized)
                .font(DesignTokens.Typography.bodyMedium)

            Spacer()
        }
        .padding(DesignTokens.Spacing.medium)
        .background(DesignTokens.Colors.cardBackground)
        .cornerRadius(DesignTokens.Radius.card)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                .strokeBorder(DesignTokens.Colors.cardBorder, lineWidth: 1)
        )
    }

    private func linkedStatusCard(accountName: String, hasCredentials: Bool) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            HStack(spacing: DesignTokens.Spacing.medium) {
                Circle()
                    .fill(hasCredentials ? Color.green : Color.orange)
                    .frame(width: DesignTokens.StatusDot.standard, height: DesignTokens.StatusDot.standard)

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                    Text(hasCredentials ? "cli.status_linked".localized : "cli.status_linked_pending".localized)
                        .font(DesignTokens.Typography.bodyMedium)

                    Text("~/.claude-accounts/\(accountName)")
                        .font(DesignTokens.Typography.monospaced)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            if hasCredentials {
                Divider()

                HStack(spacing: DesignTokens.Spacing.small) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: DesignTokens.Icons.standard))
                    Text("cli.switching_enabled".localized)
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(DesignTokens.Spacing.medium)
        .background(DesignTokens.Colors.cardBackground)
        .cornerRadius(DesignTokens.Radius.card)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                .strokeBorder(DesignTokens.Colors.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Link Button Card

    private var linkButtonCard: some View {
        SettingsSectionCard(
            title: "cli.link_title".localized,
            subtitle: "cli.link_subtitle".localized
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                    BulletPoint("cli.link_benefit_1".localized)
                    BulletPoint("cli.link_benefit_2".localized)
                    BulletPoint("cli.link_benefit_3".localized)
                }
                .font(DesignTokens.Typography.caption)
                .foregroundColor(.secondary)

                Button(action: { showLinkConfirmation = true }) {
                    HStack(spacing: DesignTokens.Spacing.extraSmall) {
                        if linkingInProgress {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: DesignTokens.Icons.small, height: DesignTokens.Icons.small)
                        } else {
                            Image(systemName: "link.badge.plus")
                                .font(.system(size: DesignTokens.Icons.small))
                        }
                        Text("cli.link_button".localized)
                            .font(DesignTokens.Typography.body)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(linkingInProgress)
            }
        }
    }

    // MARK: - Post-Setup Card (login instructions)

    private func postSetupCard(accountName: String) -> some View {
        SettingsSectionCard(
            title: "cli.setup_complete_title".localized,
            subtitle: "cli.setup_complete_subtitle".localized
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
                // Step 1
                HStack(alignment: .top, spacing: DesignTokens.Spacing.small) {
                    Text("1.")
                        .font(DesignTokens.Typography.bodyMedium)
                        .foregroundColor(.accentColor)
                        .frame(width: 20, alignment: .trailing)
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                        Text("cli.setup_step1".localized)
                            .font(DesignTokens.Typography.body)
                            .foregroundColor(.secondary)

                        // Command display
                        HStack {
                            Text("CLAUDE_CONFIG_DIR=~/.claude-accounts/\(accountName) claude")
                                .font(DesignTokens.Typography.monospaced)
                                .foregroundColor(.primary)
                                .padding(DesignTokens.Spacing.small)

                            Spacer()

                            Button(action: {
                                copyToClipboard("CLAUDE_CONFIG_DIR=~/.claude-accounts/\(accountName) claude")
                            }) {
                                HStack(spacing: DesignTokens.Spacing.extraSmall) {
                                    Image(systemName: copiedToClipboard ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: DesignTokens.Icons.small))
                                    Text(copiedToClipboard ? "cli.copied".localized : "cli.copy_command".localized)
                                        .font(DesignTokens.Typography.caption)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .padding(.trailing, DesignTokens.Spacing.small)
                        }
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(DesignTokens.Radius.small)
                    }
                }

                // Step 2
                HStack(alignment: .top, spacing: DesignTokens.Spacing.small) {
                    Text("2.")
                        .font(DesignTokens.Typography.bodyMedium)
                        .foregroundColor(.accentColor)
                        .frame(width: 20, alignment: .trailing)
                    Text("cli.setup_step2".localized)
                        .font(DesignTokens.Typography.body)
                        .foregroundColor(.secondary)
                }

                // Step 3
                HStack(alignment: .top, spacing: DesignTokens.Spacing.small) {
                    Text("3.")
                        .font(DesignTokens.Typography.bodyMedium)
                        .foregroundColor(.accentColor)
                        .frame(width: 20, alignment: .trailing)
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                        Text("cli.setup_step3".localized)
                            .font(DesignTokens.Typography.body)
                            .foregroundColor(.secondary)

                        HStack(spacing: DesignTokens.Spacing.iconText) {
                            Button(action: checkCredentials) {
                                HStack(spacing: DesignTokens.Spacing.extraSmall) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: DesignTokens.Icons.small))
                                    Text("cli.check_credentials".localized)
                                        .font(DesignTokens.Typography.body)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)

                            if credentialCheckResult.hasCredentials {
                                HStack(spacing: DesignTokens.Spacing.extraSmall) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                        .font(.system(size: DesignTokens.Icons.small))
                                    Text("cli.credentials_found".localized)
                                        .font(DesignTokens.Typography.caption)
                                        .foregroundColor(.green)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Linked Actions Card

    private func linkedActionsCard(profile: Profile) -> some View {
        HStack(spacing: DesignTokens.Spacing.iconText) {
            Button(action: syncFromCLI) {
                HStack(spacing: DesignTokens.Spacing.extraSmall) {
                    if isSyncing {
                        ProgressView()
                            .scaleEffect(0.8)
                            .frame(width: DesignTokens.Icons.small, height: DesignTokens.Icons.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: DesignTokens.Icons.small))
                    }
                    Text(profile.hasCliAccount ? "cli.resync".localized : "cli.sync_from_code".localized)
                        .font(DesignTokens.Typography.body)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(isSyncing)

            Button(action: { showUnlinkConfirmation = true }) {
                HStack(spacing: DesignTokens.Spacing.extraSmall) {
                    Image(systemName: "link.badge.minus")
                        .font(.system(size: DesignTokens.Icons.small))
                    Text("cli.unlink".localized)
                        .font(DesignTokens.Typography.body)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .foregroundColor(.red)

            Spacer()
        }
        .padding(.horizontal, DesignTokens.Spacing.small)
    }

    // MARK: - Shell Integration Card

    private var shellIntegrationCard: some View {
        SettingsContentCard {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                HStack(spacing: DesignTokens.Spacing.small) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundColor(.yellow)
                        .font(.system(size: DesignTokens.Icons.standard))
                    Text("cli.shell_integration_title".localized)
                        .font(DesignTokens.Typography.sectionTitle)
                }

                Text(String(format: "cli.shell_integration_explain".localized, shellConfigFile))
                    .font(DesignTokens.Typography.caption)
                    .foregroundColor(.secondary)

                // Shell snippet
                Text(shellSnippet)
                    .font(DesignTokens.Typography.monospaced)
                    .foregroundColor(.primary)
                    .padding(DesignTokens.Spacing.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(DesignTokens.Radius.small)

                HStack(spacing: DesignTokens.Spacing.iconText) {
                    Button(action: {
                        copyShellSnippet()
                    }) {
                        HStack(spacing: DesignTokens.Spacing.extraSmall) {
                            Image(systemName: copiedShellSnippet ? "checkmark" : "doc.on.doc")
                                .font(.system(size: DesignTokens.Icons.small))
                            Text(copiedShellSnippet ? "cli.copied".localized : "cli.shell_integration_copy".localized)
                                .font(DesignTokens.Typography.body)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Button(action: {
                        SharedDataStore.shared.markCLIShellIntegrationShown()
                        showShellIntegration = false
                    }) {
                        HStack(spacing: DesignTokens.Spacing.extraSmall) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: DesignTokens.Icons.small))
                            Text("cli.shell_integration_dismiss".localized)
                                .font(DesignTokens.Typography.body)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
        }
    }

    // MARK: - Account Details Card

    private func accountDetailsCard(profile: Profile) -> some View {
        SettingsSectionCard(
            title: "cli.account_details".localized,
            subtitle: "cli.credentials_synced".localized
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                if let json = profile.cliCredentialsJSON {
                    if let sessionKey = extractSessionKey(from: json) {
                        HStack(spacing: DesignTokens.Spacing.iconText) {
                            Image(systemName: "key")
                                .font(.system(size: DesignTokens.Icons.standard))
                                .foregroundColor(.accentColor)
                                .frame(width: DesignTokens.Spacing.iconFrame)

                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                                Text("cli.access_token".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.secondary)
                                Text(maskCredential(sessionKey))
                                    .font(DesignTokens.Typography.monospaced)
                                    .foregroundColor(.primary)
                            }
                        }
                    }

                    if let info = cliAccountInfo {
                        Divider()

                        HStack(spacing: DesignTokens.Spacing.iconText) {
                            Image(systemName: "person.badge.key")
                                .font(.system(size: DesignTokens.Icons.standard))
                                .foregroundColor(.accentColor)
                                .frame(width: DesignTokens.Spacing.iconFrame)

                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                                Text("cli.subscription".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.secondary)
                                Text(info.subscriptionType)
                                    .font(DesignTokens.Typography.body)
                                    .foregroundColor(.primary)
                            }
                        }

                        if !info.scopes.isEmpty {
                            HStack(spacing: DesignTokens.Spacing.iconText) {
                                Image(systemName: "checkmark.shield")
                                    .font(.system(size: DesignTokens.Icons.standard))
                                    .foregroundColor(.accentColor)
                                    .frame(width: DesignTokens.Spacing.iconFrame)

                                VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                                    Text("cli.scopes".localized)
                                        .font(DesignTokens.Typography.caption)
                                        .fontWeight(.medium)
                                        .foregroundColor(.secondary)
                                    Text(info.scopes.joined(separator: ", "))
                                        .font(DesignTokens.Typography.body)
                                        .foregroundColor(.primary)
                                }
                            }
                        }
                    }

                    if let syncedAt = profile.cliAccountSyncedAt {
                        Divider()
                        HStack(spacing: DesignTokens.Spacing.extraSmall) {
                            Text("cli.last_synced".localized)
                                .font(DesignTokens.Typography.caption)
                                .foregroundColor(.secondary)
                            Text(syncedAt, style: .relative)
                                .font(DesignTokens.Typography.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Error Card

    private func errorCard(message: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.system(size: DesignTokens.Icons.standard))
            Text(message)
                .font(DesignTokens.Typography.body)
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignTokens.Spacing.iconText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .cornerRadius(DesignTokens.Radius.small)
    }

    // MARK: - MCP Server Sync

    private var mcpSyncSection: some View {
        SettingsSectionCard(
            title: "cli.mcp_sync_title".localized,
            subtitle: "cli.mcp_sync_subtitle".localized
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                SettingToggle(
                    title: "cli.mcp_auto_sync_title".localized,
                    description: "cli.mcp_auto_sync_description".localized,
                    badge: .new,
                    isOn: Binding(
                        get: { SharedDataStore.shared.loadAutoSyncMCPEnabled() },
                        set: { enabled in
                            SharedDataStore.shared.saveAutoSyncMCPEnabled(enabled)
                        }
                    )
                )

                Divider()

                HStack {
                    Button(action: {
                        mcpSyncInProgress = true
                        mcpSyncResult = nil
                        // Run sync off the main thread to keep UI responsive
                        DispatchQueue.global(qos: .userInitiated).async {
                            let result = ClaudeSwitchService.shared.bidirectionalMcpSync()
                            DispatchQueue.main.async {
                                mcpSyncResult = result
                                mcpSyncInProgress = false
                            }
                        }
                    }) {
                        HStack(spacing: DesignTokens.Spacing.small) {
                            if mcpSyncInProgress {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text("cli.mcp_sync_button".localized)
                        }
                    }
                    .disabled(mcpSyncInProgress)

                    Spacer()
                }

                // Results display (shown after manual sync)
                if let result = mcpSyncResult {
                    if result.hasChanges {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                            ForEach(result.changes) { change in
                                HStack(spacing: DesignTokens.Spacing.small) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                        .font(.system(size: DesignTokens.Icons.small))
                                    Text("\(change.addedServers.joined(separator: ", ")) \u{2192} \(change.accountName)")
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)
                                }
                            }
                        }
                    } else {
                        HStack(spacing: DesignTokens.Spacing.small) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: DesignTokens.Icons.small))
                            Text("cli.mcp_sync_no_changes".localized)
                                .font(DesignTokens.Typography.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Setup Guide Button & Sheet

    private var infoCard: some View {
        Button(action: { showSetupGuide = true }) {
            HStack(spacing: DesignTokens.Spacing.small) {
                Image(systemName: "book.pages")
                    .font(.system(size: DesignTokens.Icons.standard))
                    .foregroundColor(.accentColor)
                Text("cli.guide_button".localized)
                    .font(DesignTokens.Typography.body)
                    .foregroundColor(.accentColor)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: DesignTokens.Icons.small))
                    .foregroundColor(.secondary)
            }
            .padding(DesignTokens.Spacing.medium)
            .background(DesignTokens.Colors.cardBackground)
            .cornerRadius(DesignTokens.Radius.card)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                    .strokeBorder(DesignTokens.Colors.cardBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSetupGuide) {
            setupGuideSheet
        }
    }

    private var setupGuideSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                        Text("cli.guide_title".localized)
                            .font(DesignTokens.Typography.pageTitle)
                        Text("cli.guide_subtitle".localized)
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: { showSetupGuide = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                // How it works
                SettingsSectionCard(
                    title: "cli.guide_how_title".localized,
                    subtitle: "cli.guide_how_subtitle".localized
                ) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                        guideStep(number: "1", text: "cli.guide_step1".localized)
                        guideStep(number: "2", text: "cli.guide_step2".localized)
                        guideStep(number: "3", text: "cli.guide_step3".localized)
                        guideStep(number: "4", text: "cli.guide_step4".localized)
                    }
                }

                // Shell integration
                SettingsSectionCard(
                    title: "cli.shell_integration_title".localized,
                    subtitle: String(format: "cli.shell_integration_explain".localized, shellConfigFile)
                ) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                        Text(shellSnippet)
                            .font(DesignTokens.Typography.monospaced)
                            .foregroundColor(.primary)
                            .padding(DesignTokens.Spacing.small)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.06))
                            .cornerRadius(DesignTokens.Radius.small)

                        Button(action: { copyShellSnippet() }) {
                            HStack(spacing: DesignTokens.Spacing.extraSmall) {
                                Image(systemName: copiedShellSnippet ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: DesignTokens.Icons.small))
                                Text(copiedShellSnippet ? "cli.copied".localized : "cli.shell_integration_copy".localized)
                                    .font(DesignTokens.Typography.body)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)

                        Text("cli.guide_shell_note".localized)
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.orange)
                            .padding(DesignTokens.Spacing.small)
                            .background(Color.orange.opacity(0.08))
                            .cornerRadius(DesignTokens.Radius.tiny)
                    }
                }

                // Important notes
                SettingsContentCard {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                        HStack(spacing: DesignTokens.Spacing.small) {
                            Image(systemName: "lightbulb.fill")
                                .foregroundColor(.yellow)
                                .font(.system(size: DesignTokens.Icons.standard))
                            Text("cli.guide_notes_title".localized)
                                .font(DesignTokens.Typography.sectionTitle)
                        }

                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                            BulletPoint("cli.guide_note1".localized)
                            BulletPoint("cli.guide_note2".localized)
                            BulletPoint("cli.guide_note3".localized)
                            BulletPoint("cli.guide_note4".localized)
                        }
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 500)
    }

    private func guideStep(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.small) {
            Text(number)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor)
                .clipShape(Circle())
            Text(text)
                .font(DesignTokens.Typography.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Computed Properties

    private var sanitizedName: String {
        guard let name = profileManager.activeProfile?.name else { return "" }
        return ClaudeSwitchService.shared.previewDirectoryName(for: name)
    }

    /// Detects the user's shell and returns the appropriate config file name
    private var shellConfigFile: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if shell.contains("zsh") {
            return "~/.zshrc"
        } else if shell.contains("bash") {
            // macOS uses .bash_profile for login shells, .bashrc for non-login
            return "~/.bashrc or ~/.bash_profile"
        } else if shell.contains("fish") {
            return "~/.config/fish/config.fish"
        }
        return "your shell configuration file"
    }

    private var shellSnippet: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if shell.contains("fish") {
            return """
            # Claude CLI account auto-switch (one-time setup, applies to all accounts)
            if test -f ~/.claude-tokens/.last-account
                set -gx CLAUDE_CONFIG_DIR "$HOME/.claude-accounts/"(cat ~/.claude-tokens/.last-account)
            end
            """
        }
        return """
        # Claude CLI account auto-switch (one-time setup, applies to all accounts)
        if [ -f ~/.claude-tokens/.last-account ]; then
          export CLAUDE_CONFIG_DIR="$HOME/.claude-accounts/$(cat ~/.claude-tokens/.last-account)"
        fi
        """
    }

    // MARK: - Actions

    private func performLinkAccount() {
        guard let profile = profileManager.activeProfile else { return }
        linkingInProgress = true
        syncError = nil

        do {
            let result = try ClaudeSwitchService.shared.linkAccount(profileName: profile.name)

            var updated = profile
            updated.cliAccountName = result.directoryName
            profileManager.updateProfile(updated)

            LoggingService.shared.log("CLIAccountView: Linked account '\(result.directoryName)' (\(result.symlinkCount) symlinks)")
        } catch {
            syncError = error.localizedDescription
            LoggingService.shared.logError("CLIAccountView: Link failed - \(error.localizedDescription)")
        }

        linkingInProgress = false
    }

    private func performUnlinkAccount() {
        guard let profile = profileManager.activeProfile,
              let accountName = profile.cliAccountName else { return }

        do {
            try ClaudeSwitchService.shared.unlinkAccount(directoryName: accountName)

            var updated = profile
            updated.cliAccountName = nil
            updated.hasCliAccount = false
            updated.cliAccountSyncedAt = nil
            updated.cliCredentialsJSON = nil
            profileManager.updateProfile(updated)

            cliAccountInfo = nil
            credentialCheckResult = .notFound
        } catch {
            syncError = "Failed to remove account directory: \(error.localizedDescription)"
            LoggingService.shared.logError("CLIAccountView: Unlink directory removal failed: \(error.localizedDescription)")
        }
    }

    private func checkCredentials() {
        guard let accountName = profileManager.activeProfile?.cliAccountName else { return }

        credentialCheckResult = ClaudeSwitchService.shared.checkForCredentials(directoryName: accountName)

        if credentialCheckResult.hasCredentials {
            // Read and store credentials for usage data
            if let json = ClaudeSwitchService.shared.readLinkedAccountCredentials(directoryName: accountName) {
                if var updated = profileManager.activeProfile {
                    updated.cliCredentialsJSON = json
                    updated.hasCliAccount = true
                    updated.cliAccountSyncedAt = Date()
                    profileManager.updateProfile(updated)
                    loadCLIAccountInfo()
                }
                // Show shell integration instructions on first success
                if !SharedDataStore.shared.hasShownCLIShellIntegration() {
                    showShellIntegration = true
                }
            } else {
                syncError = "cli.credentials_unreadable".localized
            }
        }
    }

    private func syncFromCLI() {
        guard let profile = profileManager.activeProfile else { return }

        isSyncing = true
        syncError = nil

        // Try linked account directory first, then fall back to system keychain
        if let accountName = profile.cliAccountName,
           let json = ClaudeSwitchService.shared.readLinkedAccountCredentials(directoryName: accountName) {
            var updated = profile
            updated.cliCredentialsJSON = json
            updated.hasCliAccount = true
            updated.cliAccountSyncedAt = Date()
            profileManager.updateProfile(updated)
            loadCLIAccountInfo()
            LoggingService.shared.log("CLIAccountView: Re-synced from linked account directory")
        } else {
            // Fall back to system keychain (works for both linked and unlinked profiles)
            do {
                try ClaudeCodeSyncService.shared.syncToProfile(profile.id)
                profileManager.loadProfiles()

                if var updated = profileManager.activeProfile {
                    updated.hasCliAccount = true
                    updated.cliAccountSyncedAt = Date()
                    profileManager.updateProfile(updated)
                }
                loadCLIAccountInfo()
                LoggingService.shared.log("CLIAccountView: Re-synced from system keychain")
            } catch {
                syncError = error.localizedDescription
                LoggingService.shared.logError("CLIAccountView: CLI sync failed - \(error.localizedDescription)")
            }
        }

        isSyncing = false
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedToClipboard = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedToClipboard = false
        }
    }

    private func copyShellSnippet() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shellSnippet, forType: .string)
        copiedShellSnippet = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedShellSnippet = false
        }
    }

    // MARK: - Helpers

    private func loadCLIAccountInfo() {
        guard let profile = profileManager.activeProfile,
              let json = profile.cliCredentialsJSON else {
            cliAccountInfo = nil
            return
        }
        cliAccountInfo = parseCLIInfo(from: json)
    }

    private func parseCLIInfo(from json: String) -> CLIAccountInfo? {
        let info = ClaudeCodeSyncService.shared.extractSubscriptionInfo(from: json)
        guard let info = info else { return nil }
        return CLIAccountInfo(subscriptionType: info.type, scopes: info.scopes)
    }

    private func extractSessionKey(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = parsed["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String else {
            return nil
        }
        return accessToken
    }

    private func maskCredential(_ credential: String) -> String {
        guard credential.count > 20 else { return "•••••••••" }
        let prefix = String(credential.prefix(12))
        let suffix = String(credential.suffix(4))
        return "\(prefix)•••••\(suffix)"
    }
}

struct CLIAccountInfo {
    let subscriptionType: String
    let scopes: [String]
}
