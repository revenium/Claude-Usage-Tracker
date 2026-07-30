#if UI_TESTING
import AppKit
import SwiftUI
import UsageCore
import CodexUsageProvider

/// The native UI-test host uses production views and the production Codex
/// provider/process stack while isolating every app-owned persistence surface.
///
/// This file does not compile into Debug or Release. An enabled configuration
/// additionally requires both explicit runtime gates parsed by
/// `UITestLaunchConfiguration`.
@MainActor
enum UITestApplicationBootstrap {
    static let evaluation = UITestLaunchConfiguration.evaluate(
        arguments: CommandLine.arguments,
        environment: ProcessInfo.processInfo.environment,
        compilationEnabled: true
    )

    static let compositionRoot: ProviderUICompositionRoot = {
        let configuration: UITestLaunchConfiguration
        switch evaluation {
        case .enabled(let enabled):
            configuration = enabled
        case .disabled, .rejected:
            configuration = fallbackConfiguration()
        }
        return makeCompositionRoot(configuration: configuration)
    }()

    static func launch(
        compositionRoot: ProviderUICompositionRoot
    ) -> NSWindow {
        NSApp.setActivationPolicy(.regular)

        let window: NSWindow
        switch evaluation {
        case .disabled:
            window = makeErrorWindow(
                message:
                    "The UI-testing configuration is disabled."
            )
        case .rejected(let reason):
            window = makeErrorWindow(message: reason)
        case .enabled(let configuration):
            window = makeSurfaceWindow(
                configuration: configuration,
                compositionRoot: compositionRoot
            )
        }
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    private static func makeCompositionRoot(
        configuration: UITestLaunchConfiguration
    ) -> ProviderUICompositionRoot {
        let fileManager = FileManager.default
        let appDataURL = configuration.rootURL.appendingPathComponent(
            "app-data",
            isDirectory: true
        )
        try? fileManager.createDirectory(
            at: appDataURL,
            withIntermediateDirectories: true
        )

        let suiteName =
            "com.revenium.Claude-Usage.UITests."
            + configuration.sessionID
        let defaults = UserDefaults(suiteName: suiteName)
            ?? UserDefaults.standard
        let usageStore = ProfileUsageFileStore(
            baseURL: appDataURL.appendingPathComponent(
                "profile-data",
                isDirectory: true
            )
        )
        let profileStore = ProfileStore(
            defaults: defaults,
            secretStore: UITestNoopSecretStore(),
            usageFileStore: usageStore
        )
        let history = UITestHistoryService()
        let profileManager = ProfileManager(
            profileStore: profileStore,
            historyService: history,
            activationClaudeEffects: ProfileActivationClaudeEffects(
                resyncBeforeSwitching: { _ in },
                applyProfileCredentials: { _ in },
                switchAccountAndSync: { _ in },
                updateStatuslineScripts: {},
                updateStatuslineProfileName: { _ in }
            ),
            lifecycleEventSink: ProfileLifecycleEventSink(
                deletionStarted: { _ in },
                deletionCleanup: { _ in },
                deletionCompleted: { _ in }
            ),
            postClaudeCreationMigration: { profileID in
                guard let profile = profileStore.loadProfiles()
                    .first(where: { $0.id == profileID }) else {
                    throw ProfileStoreError.profileNotFound(
                        profileID
                    )
                }
                return profile
            }
        )
        seed(
            configuration: configuration,
            profileManager: profileManager
        )
        profileManager.loadProfiles()

        return ProviderUICompositionRoot(
            profileManager: profileManager,
            availability: .testing()
        )
    }

    private static func seed(
        configuration: UITestLaunchConfiguration,
        profileManager: ProfileManager
    ) {
        guard configuration.seed != .firstRun,
              let home = configuration.codexHomeURL else {
            return
        }
        do {
            _ = try profileManager.createInitialCodexProfile(
                name: "Codex Pro",
                linkedHomePath: home.path
            )
            if configuration.seed == .mixedProviders {
                _ = try profileManager.createProfileThrowing(
                    name: "Claude Team",
                    providerConfiguration: .claude
                )
            }
        } catch {
            assertionFailure(
                "Unable to seed isolated UI-test profiles: \(error)"
            )
        }
    }

    private static func makeSurfaceWindow(
        configuration: UITestLaunchConfiguration,
        compositionRoot: ProviderUICompositionRoot
    ) -> NSWindow {
        let dependencies = compositionRoot.dependencies
        switch configuration.surface {
        case .setup:
            return makeHostingWindow(
                title: "Claude Usage UI Tests — Setup",
                size: CGSize(width: 580, height: 680),
                view: AnyView(
                    SetupWizardView(dependencies: dependencies)
                        .accessibilityIdentifier(
                            "ui-testing.surface.setup"
                        )
                )
            )
        case .account:
            return settingsWindow(
                dependencies: dependencies,
                destination: .providerAccount(
                    profileID:
                        requiredActiveProfileID(
                            compositionRoot.profileManager
                        )
                )
            )
        case .profiles:
            return settingsWindow(
                dependencies: dependencies,
                destination: .manageProfiles
            )
        case .settings:
            return settingsWindow(
                dependencies: dependencies,
                destination: .defaultView
            )
        case .history:
            return makeHostingWindow(
                title: "Claude Usage UI Tests — History",
                size: CGSize(width: 920, height: 680),
                view: AnyView(
                    UsageHistoryView(
                        dependencies: dependencies,
                        historyLoader: { _, _ in
                            UsageHistoryData()
                        }
                    )
                )
            )
        case .popover:
            return makeHostingWindow(
                title: "Claude Usage UI Tests — Popover",
                size: CGSize(width: 360, height: 620),
                view: AnyView(
                    UITestPopoverSurface(
                        compositionRoot: compositionRoot
                    )
                )
            )
        }
    }

    private static func settingsWindow(
        dependencies: ProviderUIDependencies,
        destination: SettingsNavigationDestination
    ) -> NSWindow {
        let controller = SettingsWindowBuilder.makeController(
            size: CGSize(width: 920, height: 680),
            dependencies: dependencies,
            destination: destination
        )
        controller.window.title = "Claude Usage UI Tests — Settings"
        controller.window.setAccessibilityIdentifier(
            "ui-testing.surface.settings"
        )
        return controller.window
    }

    private static func makeErrorWindow(
        message: String
    ) -> NSWindow {
        makeHostingWindow(
            title: "Claude Usage UI Test Configuration Error",
            size: CGSize(width: 560, height: 240),
            view: AnyView(
                VStack(spacing: 12) {
                    Image(
                        systemName:
                            "exclamationmark.triangle.fill"
                    )
                    Text(message)
                }
                .padding(30)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(
                    "ui-testing.configuration.error"
                )
            )
        )
    }

    private static func makeHostingWindow(
        title: String,
        size: CGSize,
        view: AnyView
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentViewController = NSHostingController(
            rootView: view
        )
        return window
    }

    private static func requiredActiveProfileID(
        _ profileManager: ProfileManager
    ) -> UUID {
        profileManager.activeProfile?.id
            ?? UUID(
                uuid: (
                    0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0
                )
            )
    }

    private static func fallbackConfiguration()
        -> UITestLaunchConfiguration {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "claude-usage-ui-tests-invalid",
                isDirectory: true
            )
        return UITestLaunchConfiguration(
            rootURL: root,
            sessionID: "invalid-configuration",
            codexHomeURL: nil,
            seed: .firstRun,
            surface: .setup,
            locale: "en"
        )
    }
}

private nonisolated final class UITestNoopSecretStore:
    ProfileSecretStore
{
    func read(
        _ locator: ProfileSecretLocator
    ) throws -> ProfileSecretReadResult {
        .absent
    }

    func write(
        _ value: String,
        to locator: ProfileSecretLocator
    ) throws {}

    func delete(_ locator: ProfileSecretLocator) throws {}
}

@MainActor
private final class UITestHistoryService: ProfileHistoryDeleting {
    func deleteHistoryThrowing(for profileId: UUID) throws {}
}

/// Popover coverage is hosted in a regular window because XCUITest cannot
/// reliably address a status-item NSPopover. The production normalized header,
/// content, settings actions, provider factory, and process path remain intact.
@MainActor
private struct UITestPopoverSurface: View {
    let compositionRoot: ProviderUICompositionRoot
    @State private var presentation:
        NormalizedUsagePresentation?
    @State private var isRefreshing = false
    @State private var settingsController:
        SettingsWindowNavigationController?

    var body: some View {
        let current = presentation ?? missingPresentation
        VStack(alignment: .leading, spacing: 0) {
            ProviderPopoverHeader(
                profileManager: compositionRoot.profileManager,
                presentation: current,
                claudeStatus: .unknown,
                isRefreshing: isRefreshing,
                onRefresh: refresh,
                onManageProfiles: {
                    showSettings(destination: .manageProfiles)
                },
                onPreferences: {
                    showSettings(destination: .defaultView)
                }
            )
            PopoverDivider()
            ScrollView {
                NormalizedUsageView(
                    presentation: current,
                    displayPreferences:
                        NormalizedUsageDisplayPreferences(
                            showRemainingPercentage: false,
                            showTimeMarker: true,
                            showPaceMarker: true,
                            usePaceColoring: true
                        ),
                    timeDisplay: .both,
                    now: Date()
                )
            }
            .frame(maxHeight: 540)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("ui-testing.surface.popover")
        .onAppear {
            refresh()
        }
    }

    private var activeProfile: Profile {
        compositionRoot.profileManager.activeProfile
            ?? Profile(
                name: "Codex",
                providerConfiguration: .codex(.init())
            )
    }

    private var expectedProfile: NormalizedUsageExpectedProfile {
        NormalizedUsageExpectedProfile(
            id: activeProfile.id,
            name: activeProfile.name,
            providerID: activeProfile.providerID,
            providerRevision: activeProfile.providerRevision
        )
    }

    private var missingPresentation:
        NormalizedUsagePresentation {
        NormalizedUsagePresentationBuilder.make(
            snapshot: nil,
            expectedProfile: expectedProfile,
            now: Date()
        )
    }

    private func refresh() {
        guard !isRefreshing,
              let home = activeProfile.providerConfiguration
                .codexConfiguration?.linkedHome else {
            return
        }
        isRefreshing = true
        Task {
            let snapshot: PresentationSnapshot
            do {
                let captured = try compositionRoot
                    .codexProviderFactory.capture(
                        linkedHome: home
                    )
                let provider = try compositionRoot
                    .codexProviderFactory.makeFreshProvider(
                        captured
                    )
                let report = try await provider.fetchUsage()
                snapshot = makeSnapshot(
                    report: report,
                    failure: nil
                )
            } catch {
                snapshot = makeSnapshot(
                    report: nil,
                    failure: ProviderRefreshFailure(
                        kind: .transport,
                        occurredAt: Date(),
                        isRecoverable: true,
                        consecutiveCount: 1
                    )
                )
            }
            presentation =
                NormalizedUsagePresentationBuilder.make(
                    snapshot: snapshot,
                    expectedProfile: expectedProfile,
                    now: Date()
                )
            isRefreshing = false
        }
    }

    private func makeSnapshot(
        report: UsageReport?,
        failure: ProviderRefreshFailure?
    ) -> PresentationSnapshot {
        PresentationSnapshot(
            profileID: activeProfile.id,
            profileName: activeProfile.name,
            providerID: activeProfile.providerID,
            providerRevision: activeProfile.providerRevision,
            presentationEpoch: 1,
            capabilities:
                compositionRoot.codexProviderFactory.capabilities,
            configurationState: .ready,
            report: report,
            claudeUsage: nil,
            claudeAPIUsage: nil,
            activity: .idle,
            lastSuccessfulAt: report == nil ? nil : Date(),
            currentFailure: failure
        )
    }

    private func showSettings(
        destination: SettingsNavigationDestination
    ) {
        let controller = SettingsWindowBuilder.makeController(
            size: CGSize(width: 920, height: 680),
            dependencies: compositionRoot.dependencies,
            destination: destination
        )
        controller.window.title =
            "Claude Usage UI Tests — Popover Settings"
        controller.window.setAccessibilityIdentifier(
            "ui-testing.surface.popover-settings"
        )
        controller.window.center()
        controller.window.makeKeyAndOrderFront(nil)
        settingsController = controller
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
