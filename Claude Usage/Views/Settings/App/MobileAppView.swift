//
//  MobileAppView.swift
//  Claude Usage
//
//  "Painted door" interest-collection view for a potential mobile app.
//
//  Created by Claude Code on 2026-02-25.
//

import SwiftUI

/// Mobile app "coming soon" painted-door view.
/// Opens a reviewable feature-request draft in the Revenium repository.
struct MobileAppView: View {
    @State private var hasNotified = UserDefaults.standard.bool(forKey: "mobileApp.notifyMe")
    @State private var isSubmitting = false
    @State private var showError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                SettingsPageHeader(
                    title: "mobile.title".localized,
                    subtitle: "mobile.subtitle".localized
                )

                // Coming Soon badge + icon
                HStack {
                    Spacer()
                    VStack(spacing: DesignTokens.Spacing.medium) {
                        Image(systemName: "iphone")
                            .font(.system(size: 28))
                            .foregroundColor(.accentColor)

                        Text("mobile.coming_soon_badge".localized)
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(1)
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.1))
                            )
                    }
                    Spacer()
                }

                Divider()

                // Notify Me / Already notified
                if hasNotified {
                    HStack(spacing: DesignTokens.Spacing.medium) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: DesignTokens.Icons.standard))
                            .foregroundColor(SettingsColors.success)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("mobile.notified".localized)
                                .font(DesignTokens.Typography.bodyMedium)
                            Text("mobile.notified_desc".localized)
                                .font(DesignTokens.Typography.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(DesignTokens.Spacing.medium)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                            .fill(SettingsColors.lightOverlay(.green))
                    )
                } else {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                        Text("mobile.cta_message".localized)
                            .font(DesignTokens.Typography.body)
                            .foregroundColor(.secondary)

                        SettingsButton.primary(
                            title: isSubmitting ? "mobile.submitting".localized : "mobile.notify_me".localized,
                            icon: isSubmitting ? nil : "bell",
                            action: submitInterest
                        )
                        .disabled(isSubmitting)
                    }
                }

                // Privacy note
                HStack(spacing: DesignTokens.Spacing.small) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: DesignTokens.Icons.tiny))
                        .foregroundColor(.secondary)
                    Text("mobile.privacy_note".localized)
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(28)
        }
        .alert("mobile.error_title".localized, isPresented: $showError) {
            Button("common.ok".localized, role: .cancel) {}
        } message: {
            Text("mobile.error_message".localized)
        }
    }

    private func submitInterest() {
        guard !isSubmitting, !hasNotified else { return }
        isSubmitting = true

        guard var components = URLComponents(
            string: Constants.GitHub.newFeedbackIssueURL
        ) else {
            showError = true
            isSubmitting = false
            return
        }

        components.queryItems = [
            URLQueryItem(name: "title", value: "Interest in a mobile companion"),
            URLQueryItem(
                name: "body",
                value: "I am interested in a mobile companion for Claude Usage Tracker."
            )
        ]

        guard let url = components.url, NSWorkspace.shared.open(url) else {
            showError = true
            isSubmitting = false
            return
        }

        hasNotified = true
        UserDefaults.standard.set(true, forKey: "mobileApp.notifyMe")
        isSubmitting = false
    }
}

#Preview {
    MobileAppView()
        .frame(width: 520, height: 600)
}
