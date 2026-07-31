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
    static let codexProfileID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000101"
    )!
    static let claudeProfileID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000202"
    )!
    static let secondaryCodexProfileID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000102"
    )!

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

        let defaults = UITestInMemoryDefaultsStore()
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
            profileStore: profileStore
        )
        profileManager.loadProfiles()

        return ProviderUICompositionRoot(
            profileManager: profileManager,
            availability: .testing(),
            setupCompletionWriter: {
                defaults.set(
                    true,
                    forKey: "ui-testing.has-completed-setup"
                )
            },
            setupCompletionReader: {
                defaults.bool(
                    forKey: "ui-testing.has-completed-setup"
                )
            }
        )
    }

    private static func seed(
        configuration: UITestLaunchConfiguration,
        profileStore: ProfileStore
    ) {
        guard configuration.seed != .firstRun,
              let home = configuration.codexHomeURL else {
            return
        }
        do {
            let canonicalHome = try CodexHomeCanonicalizer()
                .canonicalize(home.path)
            let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
            let codex = Profile(
                id: codexProfileID,
                name: "Codex Pro",
                providerConfiguration: .codex(
                    .init(linkedHome: canonicalHome)
                ),
                createdAt: timestamp,
                lastUsedAt: timestamp
            )
            try profileStore.createInitialProfile(codex)
            if configuration.seed == .mixedProviders {
                let secondaryHome = configuration.rootURL
                    .appendingPathComponent(
                        "codex-home-secondary",
                        isDirectory: true
                    )
                try FileManager.default.createDirectory(
                    at: secondaryHome,
                    withIntermediateDirectories: true
                )
                let secondaryCanonicalHome =
                    try CodexHomeCanonicalizer().canonicalize(
                        secondaryHome.path,
                        existingProfiles: [codex]
                    )
                let secondaryCodex = Profile(
                    id: secondaryCodexProfileID,
                    name: "Codex Team",
                    providerConfiguration: .codex(
                        .init(linkedHome: secondaryCanonicalHome)
                    ),
                    createdAt: timestamp,
                    lastUsedAt: timestamp
                )
                try profileStore.appendProfile(
                    secondaryCodex,
                    expectedExistingIDs: [codex.id]
                )
                let claude = Profile(
                    id: claudeProfileID,
                    name: "Claude Team",
                    providerConfiguration: .claude,
                    createdAt: timestamp,
                    lastUsedAt: timestamp
                )
                try profileStore.appendProfile(
                    claude,
                    expectedExistingIDs: [
                        codex.id,
                        secondaryCodex.id,
                    ]
                )
                profileStore.saveDisplayMode(.multi)
            }
            profileStore.saveActiveProfileId(codex.id)
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
                size: CGSize(width: 580, height: 710),
                view: AnyView(
                    UITestSetupSurface(
                        compositionRoot: compositionRoot
                    )
                ),
                accessibilityIdentifier: "ui-testing.surface.setup"
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
                ),
                accessibilityIdentifier: "ui-testing.surface.popover"
            )
        case .menuStatus:
            let controller = UITestMenuStatusController(
                compositionRoot: compositionRoot
            )
            let size = CGSize(width: 640, height: 620)
            let window = NSWindow(
                contentRect: NSRect(
                    origin: .zero,
                    size: size
                ),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Claude Usage UI Tests — Menu & Status"
            install(
                contentViewController: controller,
                in: window,
                size: size
            )
            window.setAccessibilityIdentifier(
                "ui-testing.surface.menu-status"
            )
            return window
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
        view: AnyView,
        accessibilityIdentifier: String? = nil
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        install(
            contentViewController: NSHostingController(
                rootView: view
            ),
            in: window,
            size: size
        )
        if let accessibilityIdentifier {
            window.setAccessibilityIdentifier(accessibilityIdentifier)
        }
        return window
    }

    private static func install(
        contentViewController: NSViewController,
        in window: NSWindow,
        size: CGSize
    ) {
        contentViewController.view.frame = NSRect(
            origin: .zero,
            size: size
        )
        contentViewController.view.autoresizingMask = [
            .width,
            .height,
        ]
        window.contentViewController = contentViewController
        window.setContentSize(size)
        window.contentMinSize = size
        contentViewController.view.frame = NSRect(
            origin: .zero,
            size: size
        )
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

private final class UITestInMemoryDefaultsStore:
    ProfileDefaultsStore
{
    private var values: [String: Any] = [:]

    func data(forKey defaultName: String) -> Data? {
        values[defaultName] as? Data
    }

    func string(forKey defaultName: String) -> String? {
        values[defaultName] as? String
    }

    func set(_ value: Any?, forKey defaultName: String) {
        if let value {
            values[defaultName] = value
        } else {
            values.removeValue(forKey: defaultName)
        }
    }

    func removeObject(forKey defaultName: String) {
        values.removeValue(forKey: defaultName)
    }

    func bool(forKey defaultName: String) -> Bool {
        values[defaultName] as? Bool ?? false
    }
}

@MainActor
private final class UITestHistoryService: ProfileHistoryDeleting {
    func deleteHistoryThrowing(for profileId: UUID) throws {}
}

/// `NSStatusBarButton` delivers right-button tracking to its configured
/// target, while a plain `NSButton` in the regular UI-test host does not.
/// Preserve the production target/action and event-type routing contract.
private final class UITestStatusButton: NSButton {
    override func rightMouseUp(with event: NSEvent) {
        guard let action else {
            super.rightMouseUp(with: event)
            return
        }
        NSApp.sendAction(action, to: target, from: self)
    }
}

@MainActor
private final class UITestMenuStatusController:
    NSViewController,
    NSPopoverDelegate,
    NSWindowDelegate
{
    private enum Target {
        case fallback
        case identity(ProviderStatusItemIdentity)
    }

    private enum ReconciliationMode {
        case single
        case multi
    }

    private enum ArmedMutation {
        case revision
        case deletion
    }

    private let compositionRoot: ProviderUICompositionRoot
    private var targets: [ObjectIdentifier: Target] = [:]
    private var contextIdentity: ProviderStatusItemIdentity?
    private var armedMutation: ArmedMutation?
    private var popover: NSPopover?
    private var popoverIdentity: ProviderStatusItemIdentity?
    private weak var popoverButton: NSButton?
    private var detachedWindow: NSPanel?
    private var settingsControllers:
        [SettingsWindowNavigationController] = []
    private let actionLabel = NSTextField(labelWithString: "ready")
    private let activeProfileLabel = NSTextField(
        labelWithString: ""
    )

    init(compositionRoot: ProviderUICompositionRoot) {
        self.compositionRoot = compositionRoot
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: root.leadingAnchor,
                constant: 24
            ),
            stack.trailingAnchor.constraint(
                equalTo: root.trailingAnchor,
                constant: -24
            ),
            stack.topAnchor.constraint(
                equalTo: root.topAnchor,
                constant: 24
            ),
        ])

        stack.addArrangedSubview(
            NSTextField(labelWithString: "Single-profile status item")
        )
        addStatusButton(
            title: "Single · Codex Pro",
            identifier: "ui-testing.status.single.codex",
            profileID: UITestApplicationBootstrap.codexProfileID,
            reconciliationMode: .single,
            to: stack
        )

        stack.addArrangedSubview(
            NSTextField(labelWithString: "Multi-profile status items")
        )
        addStatusButton(
            title: "Multi · Codex Pro · active",
            identifier: "ui-testing.status.multi.codex.active",
            profileID: UITestApplicationBootstrap.codexProfileID,
            reconciliationMode: .multi,
            to: stack
        )
        addStatusButton(
            title: "Multi · Codex Team · inactive",
            identifier: "ui-testing.status.multi.codex.inactive",
            profileID:
                UITestApplicationBootstrap.secondaryCodexProfileID,
            reconciliationMode: .multi,
            to: stack
        )
        addStatusButton(
            title: "Multi · Claude Team · inactive",
            identifier: "ui-testing.status.multi.claude.inactive",
            profileID: UITestApplicationBootstrap.claudeProfileID,
            reconciliationMode: .multi,
            to: stack
        )

        stack.addArrangedSubview(
            NSTextField(labelWithString: "Fail-closed status targets")
        )
        addStatusButton(
            title: "No captured identity (active fallback)",
            identifier: "ui-testing.status.none",
            target: .fallback,
            to: stack
        )
        if let codex = profile(
            id: UITestApplicationBootstrap.codexProfileID
        ) {
            addStatusButton(
                title: "Stale provider revision",
                identifier: "ui-testing.status.stale.revision",
                target: .identity(
                    ProviderStatusItemIdentity(
                        profileID: codex.id,
                        providerID: codex.providerID,
                        providerRevision:
                            codex.providerRevision &+ 1,
                        metricID: nil
                    )
                ),
                to: stack
            )
            addStatusButton(
                title: "Deleted profile identity",
                identifier: "ui-testing.status.stale.deleted",
                target: .identity(
                    ProviderStatusItemIdentity(
                        profileID: UUID(
                            uuidString:
                                "00000000-0000-0000-0000-000000000303"
                        )!,
                        providerID: .codex,
                        providerRevision: 0,
                        metricID: nil
                    )
                ),
                to: stack
            )
        }

        let mutationRow = NSStackView()
        mutationRow.orientation = .horizontal
        mutationRow.spacing = 8
        let armRevision = NSButton(
            title: "Arm revision race",
            target: self,
            action: #selector(armRevisionRace)
        )
        armRevision.setAccessibilityIdentifier(
            "ui-testing.menu.arm-revision"
        )
        mutationRow.addArrangedSubview(armRevision)
        let armDeletion = NSButton(
            title: "Arm deletion race",
            target: self,
            action: #selector(armDeletionRace)
        )
        armDeletion.setAccessibilityIdentifier(
            "ui-testing.menu.arm-deletion"
        )
        mutationRow.addArrangedSubview(armDeletion)
        stack.addArrangedSubview(mutationRow)

        let stateRow = NSStackView()
        stateRow.orientation = .horizontal
        stateRow.spacing = 8
        for state in [
            ProviderMetricDisplayState.ready,
            .loading,
            .stale,
            .degraded,
            .error,
            .noData,
        ] {
            let label = NSTextField(
                labelWithString: state.accessibilityText
            )
            label.setAccessibilityIdentifier(
                "ui-testing.status.state.\(state.rawValue)"
            )
            stateRow.addArrangedSubview(label)
        }
        stack.addArrangedSubview(stateRow)

        actionLabel.setAccessibilityIdentifier(
            "ui-testing.menu.last-action"
        )
        actionLabel.maximumNumberOfLines = 2
        stack.addArrangedSubview(actionLabel)
        activeProfileLabel.setAccessibilityIdentifier(
            "ui-testing.menu.active-profile"
        )
        stack.addArrangedSubview(activeProfileLabel)
        updateActiveProfileLabel()
        view = root
    }

    private func addStatusButton(
        title: String,
        identifier: String,
        profileID: UUID,
        reconciliationMode: ReconciliationMode,
        to stack: NSStackView
    ) {
        guard let profile = profile(id: profileID) else { return }
        let presentation = syntheticPresentation(for: profile)
        let identity: ProviderStatusItemIdentity
        switch reconciliationMode {
        case .single:
            guard let entry =
                    ProviderStatusItemReconciliation.singleEntries(
                        for: presentation
                    ).first else {
                return
            }
            identity = entry.identity
        case .multi:
            identity =
                ProviderStatusItemReconciliation.multiIdentity(
                    for: presentation
                )
        }
        addStatusButton(
            title: title,
            identifier: identifier,
            target: .identity(identity),
            to: stack
        )
    }

    private func addStatusButton(
        title: String,
        identifier: String,
        target: Target,
        to stack: NSStackView
    ) {
        let button = UITestStatusButton(
            title: title,
            target: nil,
            action: nil
        )
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier(identifier)
        StatusBarUIManager.configureActionButton(
            button,
            target: self,
            action: #selector(statusItemClicked(_:))
        )
        targets[ObjectIdentifier(button)] = target
        stack.addArrangedSubview(button)
    }

    private func syntheticPresentation(
        for profile: Profile
    ) -> ProviderMenuPresentation {
        let metricID: MenuBarMetricID
        if profile.providerID == .claude {
            metricID = .claudeSession
        } else {
            metricID = MenuBarMetricID(
                providerID: profile.providerID,
                groupID: try! UsageLimitGroupID("subscription"),
                windowID: try! UsageWindowID("five-hour")
            )
        }
        let descriptor = ProviderMetricDescriptor(
            id: metricID,
            providerID: profile.providerID,
            groupName: "Subscription",
            metricName: "Five hour",
            resetAt: Date().addingTimeInterval(3_600),
            duration: 18_000,
            usedPercentage: 25,
            isUsable: true,
            unavailableReason: nil
        )
        let metric = ProviderMetricPresentation(
            descriptor: descriptor,
            state: .ready,
            usedPercentage: 25,
            displayedPercentage: 25,
            showRemaining: false,
            elapsedFraction: 0.2,
            statusLevel: .safe,
            notice: nil
        )
        let base = ProviderMenuPresentationBuilder.presentation(
            profile: profile,
            snapshot: nil,
            now: Date(),
            isActive:
                profile.id
                    == compositionRoot.profileManager.activeProfile?.id
        )
        return ProviderMenuPresentation(
            identity: ProviderStatusItemIdentity(
                profileID: profile.id,
                providerID: profile.providerID,
                providerRevision: profile.providerRevision,
                metricID: metricID
            ),
            profileName: profile.name,
            appearance: base.appearance,
            metrics: [metric],
            state: .ready,
            actions: base.actions,
            nextFreshnessDeadline: nil
        )
    }

    @objc private func statusItemClicked(_ sender: NSButton) {
        guard let target = targets[ObjectIdentifier(sender)] else {
            return
        }
        let captured: ProviderStatusItemIdentity?
        switch target {
        case .fallback:
            captured = nil
        case .identity(let identity):
            captured = identity
        }
        guard let identity =
                ProviderStatusItemReconciliation.resolvedIdentity(
                    captured: captured,
                    fallbackProfile:
                        compositionRoot.profileManager.activeProfile
                ) else {
            record("ignored.no-profile")
            return
        }
        if MenuBarManager.isContextMenuEvent(
            NSApp.currentEvent?.type
        ) {
            showContextMenu(for: identity, from: sender)
        } else {
            let routed = actionRouter(
                openPopover: { [weak self] target, _ in
                    self?.togglePopover(
                        for: target,
                        from: sender
                    )
                }
            ).route(.openPopover, target: identity)
            if !routed {
                recordStale(identity)
            }
        }
    }

    private func showContextMenu(
        for identity: ProviderStatusItemIdentity,
        from button: NSButton
    ) {
        guard let profile = actionRouter().currentProfile(
            for: identity
        ) else {
            recordStale(identity)
            return
        }
        contextIdentity = identity
        let presentation =
            ProviderMenuPresentationBuilder.presentation(
                profile: profile,
                snapshot: nil,
                now: Date(),
                isActive:
                    profile.id
                        == compositionRoot.profileManager
                            .activeProfile?.id
            )
        let menu: NSMenu
        if MenuBarManager.usesLegacyContextMenu(
            for: profile.providerID
        ) {
            menu = MenuBarManager.makeContextMenu(
                target: self,
                refreshAction: #selector(contextRefresh),
                settingsAction: #selector(contextLegacySettings),
                quitAction: #selector(contextQuit)
            )
        } else {
            menu = MenuBarManager.makeProviderContextMenu(
                presentation: presentation,
                target: self,
                activateAction: #selector(contextActivate),
                refreshAction: #selector(contextRefresh),
                accountSettingsAction: #selector(contextProviderAccount),
                appearanceAction: #selector(contextAppearance),
                manageProfilesAction: #selector(contextManageProfiles),
                quitAction: #selector(contextQuit)
            )
        }
        scheduleArmedMutation(for: identity)
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height),
            in: button
        )
    }

    private func togglePopover(
        for identity: ProviderStatusItemIdentity,
        from button: NSButton
    ) {
        if let popover, popover.isShown, popoverButton === button {
            popover.performClose(nil)
            popoverIdentity = nil
            record("popover.closed", target: identity)
            return
        }
        popover?.performClose(nil)
        let next = NSPopover()
        // A regular-window surrogate does not have the independent event
        // tracking of a real status item. Keep it interactive so an explicit
        // second anchor click reaches the production toggle/close route.
        next.behavior = .applicationDefined
        next.delegate = self
        next.contentSize = NSSize(width: 360, height: 560)
        next.contentViewController = NSHostingController(
            rootView: UITestPopoverSurface(
                compositionRoot: compositionRoot,
                selectedProfileID: identity.profileID,
                onRefreshOverride: { [weak self] in
                    self?.routePopover(.refresh, target: identity)
                },
                onManageProfilesOverride: { [weak self] in
                    self?.routePopover(
                        .manageProfiles,
                        target: identity
                    )
                },
                onPreferencesOverride: { [weak self] in
                    self?.routePopover(
                        .popoverSettings,
                        target: identity
                    )
                },
                onDetach: { [weak self, weak next] in
                    guard let self, let next else { return }
                    _ = self.detachableWindow(for: next)
                },
                onMutateRevision: { [weak self] in
                    self?.mutateRevision(target: identity)
                },
                onDeleteProfile: { [weak self] in
                    self?.mutateDeletion(target: identity)
                },
                onActiveProfileChanged: {
                    [weak self] profileID in
                    self?.handleProfileActivation(profileID)
                }
            )
        )
        next.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .maxY
        )
        popover = next
        popoverButton = button
        popoverIdentity = identity
        record("popover.open", target: identity)
    }

    @objc private func contextActivate() {
        routeContext(.activate)
    }

    @objc private func contextRefresh() {
        routeContext(.refresh)
    }

    @objc private func contextProviderAccount() {
        routeContext(.providerAccount)
    }

    @objc private func contextAppearance() {
        routeContext(.appearance)
    }

    @objc private func contextManageProfiles() {
        routeContext(.manageProfiles)
    }

    @objc private func contextLegacySettings() {
        routeContext(.legacySettings)
    }

    @objc private func contextQuit() {
        routeContext(.quit)
    }

    @objc private func armRevisionRace() {
        armedMutation = .revision
        record("armed.revision")
    }

    @objc private func armDeletionRace() {
        armedMutation = .deletion
        record("armed.deletion")
    }

    private func routeContext(
        _ action: ProviderCapturedTargetActionRouter.Action
    ) {
        guard let identity = contextIdentity else { return }
        if !actionRouter().route(action, target: identity) {
            recordStale(identity)
        }
    }

    private func routePopover(
        _ action: ProviderCapturedTargetActionRouter.Action,
        target: ProviderStatusItemIdentity
    ) {
        if !actionRouter().route(action, target: target) {
            recordStale(target)
        }
    }

    private func actionRouter(
        openPopover:
            ProviderCapturedTargetActionRouter.TargetSink? = nil,
        detachPopover:
            ProviderCapturedTargetActionRouter.TargetSink? = nil
    ) -> ProviderCapturedTargetActionRouter {
        ProviderCapturedTargetActionRouter(
            profiles: { [weak self] in
                guard let self else { return [] }
                let manager = self.compositionRoot.profileManager
                return MenuBarManager.capturedActionProfiles(
                    displayMode: manager.displayMode,
                    activeProfile: manager.activeProfile,
                    profiles: manager.profiles
                )
            },
            sinks: .init(
                openPopover: openPopover ?? { _, _ in },
                detachPopover: detachPopover ?? { _, _ in },
                refresh: { [weak self] target, profile in
                    ProviderManualRefreshDispatcher {
                        [weak self] profiles, trigger in
                        guard trigger == .manual,
                              let selected = profiles.first else {
                            return
                        }
                        self?.performRefresh(
                            target: target,
                            profile: selected
                        )
                    }.dispatch(profile: profile)
                },
                activate: { [weak self] target, _ in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.actionRouter().currentProfile(
                                for: target
                              ) != nil else {
                            return
                        }
                        await self.compositionRoot.profileManager
                            .activateProfile(target.profileID)
                        self.handleProfileActivation(
                            target.profileID
                        )
                        self.record("activate", target: target)
                    }
                },
                settings: {
                    [weak self] destination, target, _ in
                    self?.showSettings(
                        destination,
                        target: target
                    )
                },
                quit: { [weak self] target, _ in
                    self?.record("quit.requested", target: target)
                }
            )
        )
    }

    private func performRefresh(
        target: ProviderStatusItemIdentity,
        profile: Profile
    ) {
        if profile.providerID == .claude {
            record("refresh.legacy", target: target)
            return
        }
        guard let home = profile.providerConfiguration
            .codexConfiguration?.linkedHome else {
            record("refresh.failure.unlinked", target: target)
            return
        }
        record("refresh.started", target: target)
        Task { @MainActor [weak self] in
            guard let self,
                  self.actionRouter().currentProfile(
                    for: target
                  ) != nil else {
                return
            }
            do {
                let captured = try self.compositionRoot
                    .codexProviderFactory.capture(linkedHome: home)
                let provider = try self.compositionRoot
                    .codexProviderFactory.makeFreshProvider(captured)
                _ = try await provider.fetchUsage()
                guard self.actionRouter().currentProfile(
                    for: target
                ) != nil else {
                    return
                }
                self.record("refresh.success", target: target)
            } catch {
                guard self.actionRouter().currentProfile(
                    for: target
                ) != nil else {
                    return
                }
                self.record("refresh.failure", target: target)
            }
        }
    }

    private func showSettings(
        _ destination: SettingsNavigationDestination,
        target: ProviderStatusItemIdentity
    ) {
        let controller = SettingsWindowBuilder.makeController(
            size: CGSize(width: 920, height: 680),
            dependencies: compositionRoot.dependencies,
            destination: destination
        )
        controller.window.setAccessibilityIdentifier(
            "ui-testing.menu.settings"
        )
        controller.window.center()
        controller.window.makeKeyAndOrderFront(nil)
        settingsControllers.append(controller)
        let action: String
        switch destination {
        case .providerAccount:
            action = "settings.account"
        case .appearance:
            action = "settings.appearance"
        case .manageProfiles:
            action = "settings.profiles"
        case .defaultView:
            action = "settings.default"
        case .general:
            action = "settings.general"
        case .history:
            action = "settings.history"
        }
        record(action, target: target)
    }

    private func currentProfile(
        for identity: ProviderStatusItemIdentity
    ) -> Profile? {
        actionRouter().currentProfile(for: identity)
    }

    private func scheduleArmedMutation(
        for target: ProviderStatusItemIdentity
    ) {
        guard let mutation = armedMutation else { return }
        armedMutation = nil
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.15
        ) { [weak self] in
            switch mutation {
            case .revision:
                self?.mutateRevision(target: target)
            case .deletion:
                self?.mutateDeletion(target: target)
            }
        }
    }

    private func mutateRevision(
        target: ProviderStatusItemIdentity
    ) {
        do {
            _ = try compositionRoot.dependencies.unlinkCodexHome(
                profileID: target.profileID
            )
            record("mutated.revision", target: target)
        } catch {
            record("mutation.revision.failed", target: target)
        }
    }

    private func mutateDeletion(
        target: ProviderStatusItemIdentity
    ) {
        do {
            try compositionRoot.dependencies.deleteProfile(
                target.profileID
            )
            record("mutated.deletion", target: target)
        } catch {
            record("mutation.deletion.failed", target: target)
        }
    }

    func popoverShouldDetach(_ popover: NSPopover) -> Bool {
        ProviderPopoverDetachmentLifecycle.shouldDetach()
    }

    func detachableWindow(
        for popover: NSPopover
    ) -> NSWindow? {
        guard let target = popoverIdentity else { return nil }
        var created: NSPanel?
        let routed = actionRouter(
            detachPopover: { [weak self] target, _ in
                guard let self else { return }
                let controller = NSHostingController(
                    rootView: UITestPopoverSurface(
                        compositionRoot: self.compositionRoot,
                        selectedProfileID: target.profileID,
                        onActiveProfileChanged: {
                            [weak self] profileID in
                            self?.handleProfileActivation(profileID)
                        }
                    )
                )
                let window =
                    ProviderPopoverDetachmentLifecycle.makeWindow(
                        contentViewController: controller,
                        delegate: self
                    )
                window.setAccessibilityIdentifier(
                    "ui-testing.detached.popover"
                )
                self.detachedWindow = window
                created = window
                popover.performClose(nil)
                window.center()
                window.makeKeyAndOrderFront(nil)
                let contract =
                    window.collectionBehavior.contains(
                        .fullScreenAuxiliary
                    )
                    && !window.isRestorable
                self.record(
                    contract
                        ? "popover.detached.contract-ok"
                        : "popover.detached.contract-failed",
                    target: target
                )
            }
        ).route(.detachPopover, target: target)
        if !routed {
            recordStale(target)
        }
        return created
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        if ProviderPopoverDetachmentLifecycle.closedRetainedWindow(
            closing,
            retainedWindow: detachedWindow
        ) {
            let target = popoverIdentity
            detachedWindow = nil
            popoverIdentity = nil
            if let target {
                record("popover.detached.closed", target: target)
            } else {
                record("popover.detached.closed")
            }
        }
    }

    private func profile(id: UUID) -> Profile? {
        compositionRoot.profileManager.profiles.first {
            $0.id == id
        }
    }

    private func updateActiveProfileLabel() {
        activeProfileLabel.stringValue =
            compositionRoot.profileManager.activeProfile?
                .id.uuidString ?? "none"
    }

    private func handleProfileActivation(
        _ activatedProfileID: UUID?
    ) {
        updateActiveProfileLabel()
        guard let activatedProfileID,
              ProviderPopoverDetachmentLifecycle
                .shouldCloseDetachedWindow(
                    target: popoverIdentity,
                    profiles:
                        compositionRoot.profileManager.profiles,
                    activatedProfileID: activatedProfileID
                ) else {
            return
        }
        popover?.performClose(nil)
        if let detachedWindow {
            detachedWindow.close()
        } else {
            popoverIdentity = nil
        }
    }

    private func record(_ value: String) {
        actionLabel.stringValue = value
    }

    private func record(
        _ action: String,
        target: ProviderStatusItemIdentity
    ) {
        actionLabel.stringValue = [
            action,
            target.profileID.uuidString,
            target.providerID.rawValue,
            String(target.providerRevision),
            target.metricID?.stableValue ?? "no-metric",
        ].joined(separator: "|")
    }

    private func recordStale(
        _ target: ProviderStatusItemIdentity
    ) {
        record("ignored.stale", target: target)
    }
}

@MainActor
private struct UITestSetupSurface: View {
    let compositionRoot: ProviderUICompositionRoot
    @ObservedObject private var profileManager: ProfileManager
    @State private var didComplete = false

    init(compositionRoot: ProviderUICompositionRoot) {
        self.compositionRoot = compositionRoot
        _profileManager = ObservedObject(
            wrappedValue: compositionRoot.profileManager
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            SetupWizardView(
                dependencies: compositionRoot.dependencies,
                completionOverride: {
                    // Production completion dismisses its setup window. The
                    // isolated host reloads from its durable fixture store and
                    // exposes success only after the production coordinator
                    // has marked setup complete and invoked its callback.
                    profileManager.loadProfiles()
                    didComplete = true
                }
            )
            if didComplete,
               let activeProfile = profileManager.activeProfile,
               activeProfile.providerID == .codex {
                Text(activeProfile.name)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .accessibilityIdentifier(
                        "ui-testing.setup.active-codex-profile"
                    )
            } else {
                Color.clear.frame(height: 30)
            }
        }
    }
}

/// Popover coverage is hosted in a regular window because XCUITest cannot
/// reliably address a status-item NSPopover. The production normalized header,
/// content, settings actions, provider factory, and process path remain intact.
@MainActor
private struct UITestPopoverSurface: View {
    let compositionRoot: ProviderUICompositionRoot
    var selectedProfileID: UUID? = nil
    var onRefreshOverride: (() -> Void)? = nil
    var onManageProfilesOverride: (() -> Void)? = nil
    var onPreferencesOverride: (() -> Void)? = nil
    var onDetach: (() -> Void)? = nil
    var onMutateRevision: (() -> Void)? = nil
    var onDeleteProfile: (() -> Void)? = nil
    var onActiveProfileChanged: ((UUID?) -> Void)? = nil
    @ObservedObject private var profileManager: ProfileManager
    @State private var presentation:
        NormalizedUsagePresentation?
    @State private var isRefreshing = false
    @State private var refreshGeneration: UInt64 = 0
    @State private var settingsController:
        SettingsWindowNavigationController?

    init(
        compositionRoot: ProviderUICompositionRoot,
        selectedProfileID: UUID? = nil,
        onRefreshOverride: (() -> Void)? = nil,
        onManageProfilesOverride: (() -> Void)? = nil,
        onPreferencesOverride: (() -> Void)? = nil,
        onDetach: (() -> Void)? = nil,
        onMutateRevision: (() -> Void)? = nil,
        onDeleteProfile: (() -> Void)? = nil,
        onActiveProfileChanged: ((UUID?) -> Void)? = nil
    ) {
        self.compositionRoot = compositionRoot
        self.selectedProfileID = selectedProfileID
        self.onRefreshOverride = onRefreshOverride
        self.onManageProfilesOverride = onManageProfilesOverride
        self.onPreferencesOverride = onPreferencesOverride
        self.onDetach = onDetach
        self.onMutateRevision = onMutateRevision
        self.onDeleteProfile = onDeleteProfile
        self.onActiveProfileChanged = onActiveProfileChanged
        _profileManager = ObservedObject(
            wrappedValue: compositionRoot.profileManager
        )
    }

    var body: some View {
        let current = presentation ?? missingPresentation
        VStack(alignment: .leading, spacing: 0) {
            ProviderPopoverHeader(
                profileManager: profileManager,
                presentation: current,
                claudeStatus: .unknown,
                isRefreshing: isRefreshing,
                onRefresh: onRefreshOverride ?? refresh,
                onManageProfiles: {
                    if let onManageProfilesOverride {
                        onManageProfilesOverride()
                    } else {
                        showSettings(destination: .manageProfiles)
                    }
                },
                onPreferences: {
                    if let onPreferencesOverride {
                        onPreferencesOverride()
                    } else {
                        showSettings(
                            destination:
                                MenuBarManager
                                    .popoverSettingsDestination(
                                        for:
                                            ProviderStatusItemIdentity(
                                                profileID:
                                                    activeProfile.id,
                                                providerID:
                                                    activeProfile
                                                        .providerID,
                                                providerRevision:
                                                    activeProfile
                                                        .providerRevision,
                                                metricID: nil
                                            )
                                    )
                            )
                    }
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
            Text(activeProfile.id.uuidString)
                .font(.system(size: 8))
                .accessibilityIdentifier(
                    "ui-testing.popover.profile-id"
                )
            if let onDetach {
                Button("Detach", action: onDetach)
                    .accessibilityIdentifier(
                        "ui-testing.popover.detach"
                    )
            }
            if let onMutateRevision {
                Button(
                    "Mutate provider revision",
                    action: onMutateRevision
                )
                .accessibilityIdentifier(
                    "ui-testing.popover.mutate-revision"
                )
            }
            if let onDeleteProfile {
                Button(
                    "Delete selected profile",
                    action: onDeleteProfile
                )
                .accessibilityIdentifier(
                    "ui-testing.popover.delete-profile"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            refresh()
        }
        .onChange(
            of: profileManager.activeProfile?.id
        ) { _, profileID in
            onActiveProfileChanged?(profileID)
            guard selectedProfileID == nil else { return }
            presentation = nil
            refreshGeneration &+= 1
            refresh()
        }
    }

    private var activeProfile: Profile {
        selectedProfileID.flatMap { selectedID in
            profileManager.profiles.first {
                $0.id == selectedID
            }
        }
            ?? profileManager.activeProfile
            ?? Profile(
                name: "Codex",
                providerConfiguration: .codex(.init())
            )
    }

    private var expectedProfile: NormalizedUsageExpectedProfile {
        expectedProfile(for: activeProfile)
    }

    private func expectedProfile(
        for profile: Profile
    ) -> NormalizedUsageExpectedProfile {
        NormalizedUsageExpectedProfile(
            id: profile.id,
            name: profile.name,
            providerID: profile.providerID,
            providerRevision: profile.providerRevision
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
        let targetProfile = expectedProfile
        let generation = refreshGeneration
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
                    profile: targetProfile,
                    report: report,
                    failure: nil
                )
            } catch {
                snapshot = makeSnapshot(
                    profile: targetProfile,
                    report: nil,
                    failure: ProviderRefreshFailure(
                        kind: .transport,
                        occurredAt: Date(),
                        isRecoverable: true,
                        consecutiveCount: 1
                    )
                )
            }
            let currentHome = activeProfile.providerConfiguration
                .codexConfiguration?.linkedHome
            let targetIsCurrent =
                refreshGeneration == generation
                && expectedProfile == targetProfile
                && currentHome == home
            isRefreshing = false
            guard targetIsCurrent else {
                refresh()
                return
            }
            presentation =
                NormalizedUsagePresentationBuilder.make(
                    snapshot: snapshot,
                    expectedProfile: targetProfile,
                    now: Date()
                )
        }
    }

    private func makeSnapshot(
        profile: NormalizedUsageExpectedProfile,
        report: UsageReport?,
        failure: ProviderRefreshFailure?
    ) -> PresentationSnapshot {
        PresentationSnapshot(
            profileID: profile.id,
            profileName: profile.name,
            providerID: profile.providerID,
            providerRevision: profile.providerRevision,
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
        if let settingsController {
            settingsController.navigate(to: destination)
            settingsController.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

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
        controller.window.isReleasedWhenClosed = false
        controller.window.center()
        controller.window.makeKeyAndOrderFront(nil)
        settingsController = controller
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
