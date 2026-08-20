import SwiftUI

/// A lightweight invalidation token for one manual-key validation/save flow.
/// The token intentionally carries no credential or browser metadata.
nonisolated struct SessionKeyAttempt: Equatable, Sendable {
    private(set) var generation = UUID()

    mutating func invalidate() {
        generation = UUID()
    }

    func matches(_ candidate: UUID) -> Bool {
        generation == candidate
    }
}

nonisolated struct ChromeLaunchAttempt: Equatable, Sendable {
    let nonce: UUID
    let parentGeneration: UUID
}

/// Pure transition rules shared by the two manual Claude setup flows.
nonisolated enum SessionKeyAttemptPolicy {
    static func hasSelectableOrganization(_ count: Int) -> Bool {
        count > 0
    }

    static func acceptsCompletion(
        generation: UUID,
        currentGeneration: UUID,
        keyMatches: Bool,
        targetMatches: Bool = true
    ) -> Bool {
        generation == currentGeneration && keyMatches && targetMatches
    }

    static func acceptsChromeLaunch(
        _ launch: ChromeLaunchAttempt,
        currentNonce: UUID,
        currentGeneration: UUID
    ) -> Bool {
        launch.nonce == currentNonce
            && launch.parentGeneration == currentGeneration
    }

    static func acceptsSetupCompletion(
        generation: UUID,
        currentGeneration: UUID,
        keyMatches: Bool,
        capturedTarget: ClaudeManualSetupTarget?,
        completedProfileID: UUID,
        completedProfileIsClaude: Bool,
        activeClaudeProfileID: UUID?
    ) -> Bool {
        guard generation == currentGeneration,
              keyMatches,
              completedProfileIsClaude,
              capturedTarget != .compatibilityCurrent,
              activeClaudeProfileID == completedProfileID else {
            return false
        }
        switch capturedTarget {
        case .existing(let profileID), .createdProfile(let profileID):
            return profileID == completedProfileID
        case .newProfile:
            return true
        case .compatibilityCurrent, .none:
            return false
        }
    }

    static func retryTargetAfterFailedSetup(
        capturedTarget: ClaudeManualSetupTarget,
        claudeProfileIDs: [UUID]
    ) -> ClaudeManualSetupTarget {
        guard capturedTarget == .newProfile,
              claudeProfileIDs.count == 1,
              let createdProfileID = claudeProfileIDs.first else {
            return capturedTarget
        }
        return .createdProfile(createdProfileID)
    }

    static func permitsSave(
        validationSucceeded: Bool,
        isSessionOnlyRetry: Bool,
        selectedOrganizationID: String?,
        chromeProfileLabel: String?,
        chromeContextConfirmed: Bool,
        targetMatches: Bool = true
    ) -> Bool {
        (validationSucceeded || isSessionOnlyRetry)
            && selectedOrganizationID != nil
            && targetMatches
            && (chromeProfileLabel == nil || chromeContextConfirmed)
    }
}

/// The recommended, manual browser-assisted path for Claude session-key setup.
///
/// This deliberately reads only Chrome profile labels/directories via
/// `ChromeProfileDiscoverer` and hands the selected profile to the hardened
/// launcher. It never reads cookies, login databases, or a session key.
struct ChromeAssistedSessionKeyEntry: View {
    @Binding var sessionKey: String
    let validationState: ValidationState
    let onSessionKeyChanged: () -> Void
    let onValidationRequested: () -> Void
    /// Invalidates the parent attempt and returns its new generation.
    let onLaunchStarted: () -> UUID
    let isLaunchCurrent: (UUID) -> Bool
    let onChromeProfileLaunched: (String) -> Void

    @State private var profiles: [ChromeProfile] = []
    @State private var selectedDirectoryName: String?
    @State private var isLaunching = false
    @State private var launchError: String?
    @State private var launchedProfileLabel: String?
    @State private var launchNonce = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "chrome_assisted.recommended".localized,
                    systemImage: "sparkles"
                )
                .font(.system(size: 13, weight: .semibold))

                Text("chrome_assisted.description".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                if profiles.isEmpty {
                    Text("chrome_assisted.no_profiles".localized)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else {
                    Picker(
                        "chrome_assisted.profile_picker".localized,
                        selection: $selectedDirectoryName
                    ) {
                        Text("chrome_assisted.choose_profile".localized)
                            .tag(String?.none)
                        ForEach(profiles, id: \.directoryName) { profile in
                            Text(profile.label).tag(Optional(profile.directoryName))
                        }
                    }
                    .accessibilityIdentifier("chrome.profile_picker")
                }

                Button(action: launchSelectedProfile) {
                    HStack(spacing: 6) {
                        if isLaunching {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "globe")
                                .font(.system(size: 12))
                        }
                        Text("chrome_assisted.launch".localized)
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    selectedDirectoryName == nil
                        || isLaunching
                        || validationState == .validating
                )
                .accessibilityIdentifier("chrome.launch")

                if let launchError {
                    Text(launchError)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }

                if let launchedProfileLabel {
                    Text(
                        String(
                            format: "chrome_assisted.verify_account".localized,
                            launchedProfileLabel
                        )
                    )
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                }

                Text("chrome_assisted.no_extraction".localized)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.07))
            .cornerRadius(8)

            VStack(alignment: .leading, spacing: 8) {
                Text("personal.label_session_key".localized)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)

                SecureField(
                    "personal.placeholder_session_key".localized,
                    text: Binding(
                        get: { sessionKey },
                        set: { newValue in
                            guard newValue != sessionKey else { return }
                            sessionKey = newValue
                            onSessionKeyChanged()
                        }
                    )
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(10)
                .background(DesignTokens.Colors.inputBackground)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            DesignTokens.Colors.cardBorder,
                            lineWidth: 1
                        )
                )
                .accessibilityIdentifier("session_key.secure_field")

                Text("personal.help_session_key".localized)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                HStack {
                    Spacer()
                    Button(action: onValidationRequested) {
                        HStack(spacing: 6) {
                            if validationState == .validating {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 12))
                            }
                            Text(
                                validationState == .validating
                                    ? "wizard.testing".localized
                                    : "wizard.test_connection".localized
                            )
                            .font(.system(size: 12))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sessionKey.isEmpty || validationState == .validating)
                    .accessibilityIdentifier("session_key.validate")
                }
            }
        }
        .task { refreshProfiles() }
    }

    private func refreshProfiles() {
        profiles = ChromeProfileDiscoverer().discoverProfiles()
        selectedDirectoryName = nil
    }

    private func launchSelectedProfile() {
        guard let directoryName = selectedDirectoryName,
              let profile = profiles.first(where: {
                  $0.directoryName == directoryName
              }) else {
            return
        }

        // A user must choose a profile again for every browser launch.
        selectedDirectoryName = nil
        launchError = nil
        launchedProfileLabel = nil
        let parentGeneration = onLaunchStarted()
        let attempt = ChromeLaunchAttempt(
            nonce: UUID(),
            parentGeneration: parentGeneration
        )
        launchNonce = attempt.nonce
        isLaunching = true

        Task {
            let didLaunch = await ChromeProfileLauncher(
                discoverer: ChromeProfileDiscoverer()
            ).launch(profile: profile)
            await MainActor.run {
                guard SessionKeyAttemptPolicy.acceptsChromeLaunch(
                    attempt,
                    currentNonce: launchNonce,
                    currentGeneration: parentGeneration
                ), isLaunchCurrent(parentGeneration) else {
                    if attempt.nonce == launchNonce { isLaunching = false }
                    return
                }
                isLaunching = false
                guard didLaunch else {
                    launchError = "chrome_assisted.launch_failed".localized
                    return
                }
                launchedProfileLabel = profile.label
                onChromeProfileLaunched(profile.label)
            }
        }
    }
}
