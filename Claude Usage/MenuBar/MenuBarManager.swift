import Cocoa
import SwiftUI
import Combine

class MenuBarManager: NSObject, ObservableObject {
    private var statusItem: NSStatusItem?  // Legacy - kept for backwards compatibility
    private var statusBarUIManager: StatusBarUIManager?
    private var refreshTimer: Timer?
    @Published private(set) var usage: ClaudeUsage = .empty
    @Published private(set) var status: ClaudeStatus = .unknown
    @Published private(set) var apiUsage: APIUsage?
    @Published private(set) var isRefreshing: Bool = false

    // Error tracking for stale data / credential banners
    @Published private(set) var hasCredentialError: Bool = false
    @Published private(set) var consecutiveRefreshFailures: Int = 0
    @Published private(set) var lastRefreshError: String? = nil
    @Published private(set) var lastSuccessfulRefreshTime: Date? = nil

    // Multi-profile mode: track which profile's icon was clicked
    @Published private(set) var clickedProfileId: UUID?
    @Published private(set) var clickedProfileUsage: ClaudeUsage?
    @Published private(set) var clickedProfileAPIUsage: APIUsage?

    // Track when refresh was last triggered (for distinguishing user vs auto refresh)
    private var lastRefreshTriggerTime: Date = .distantPast

    // Track last known reset times for history recording
    private var lastKnownSessionResetTime: [UUID: Date] = [:]
    private var lastKnownWeeklyResetTime: [UUID: Date] = [:]
    private var lastKnownAPIResetTime: [UUID: Date] = [:]

    // Track if a reset was just recorded to prevent duplicate periodic snapshots
    private var resetJustRecorded: [UUID: (session: Bool, weekly: Bool)] = [:]

    // Popover for beautiful SwiftUI interface
    private var popover: NSPopover?

    // Event monitor for closing popover on outside click
    private var eventMonitor: Any?

    // Debounce the status-item click that also dismisses a transient popover.
    private var lastPopoverCloseDate: Date = .distantPast
    private weak var lastPopoverCloseButton: NSStatusBarButton?

    // Detached window reference (when popover is detached)
    private var detachedWindow: NSWindow?

    // Settings window reference
    private var settingsWindow: NSWindow?

    // GitHub star prompt window reference
    private var githubPromptWindow: NSWindow?

    // Feedback prompt window reference
    private var feedbackWindow: NSWindow?

    // Track which button is currently showing the popover
    private weak var currentPopoverButton: NSStatusBarButton?

    private let apiService = ClaudeAPIService()
    private let statusService = ClaudeStatusService()
    private let dataStore = DataStore.shared
    private let networkMonitor = NetworkMonitor.shared
    private let profileManager = ProfileManager.shared
    private let autoStartService = AutoStartSessionService.shared

    private lazy var refreshSideEffectSink = RefreshSideEffectSink(
        hooks: .init(
            isProfileWritable: { [weak self] profileID in
                self?.isRefreshProfileWritable(profileID) ?? false
            },
            recordClaude: { [weak self] plan, usage in
                self?.recordClaudeRefresh(plan: plan, usage: usage)
            },
            saveClaude: { [weak self] plan, usage, shouldPresent in
                self?.saveClaudeRefresh(
                    plan: plan,
                    usage: usage,
                    shouldPresent: shouldPresent
                ) ?? false
            },
            publishClaude: { [weak self] _, usage in
                self?.usage = usage
            },
            writeStatusline: { [weak self] plan, usage in
                self?.writeStatuslineRefresh(plan: plan, usage: usage)
            },
            notify: { [weak self] plan, usage in
                self?.notifyForRefresh(plan: plan, usage: usage)
            },
            isAutoSwitchPresentationCurrent: { [weak self] plan in
                guard let self else { return false }
                return Self.autoSwitchProfile(
                    for: plan,
                    profiles: self.profileManager.profiles,
                    activeProfileID:
                        self.profileManager.activeProfile?.id,
                    presentationIdentity:
                        self.currentRefreshPresentationIdentity
                ) != nil
            },
            autoSwitch: { [weak self] plan, usage in
                guard let self,
                      let capturedProfile =
                        Self.autoSwitchProfile(
                            for: plan,
                            profiles: self.profileManager.profiles,
                            activeProfileID:
                                self.profileManager.activeProfile?.id,
                            presentationIdentity:
                                self.currentRefreshPresentationIdentity
                        ) else {
                    return
                }
                self.checkAutoSwitchIfNeeded(
                    usage: usage,
                    currentProfile: capturedProfile,
                    expectedPresentationIdentity:
                        plan.presentationIdentity
                )
            },
            recordAPI: { [weak self] plan, usage in
                self?.recordAPIRefresh(plan: plan, usage: usage)
            },
            saveAPI: { [weak self] plan, usage, shouldPresent in
                self?.saveAPIRefresh(
                    plan: plan,
                    usage: usage,
                    shouldPresent: shouldPresent
                ) ?? false
            },
            publishAPI: { [weak self] _, usage in
                self?.apiUsage = usage
            },
            claudeFailed: { [weak self] plan, error, shouldPresent in
                self?.handleClaudeRefreshFailure(
                    plan: plan,
                    error: error,
                    shouldPresent: shouldPresent
                )
            },
            apiFailed: { [weak self] plan, error, _ in
                self?.handleAPIRefreshFailure(plan: plan, error: error)
            },
            presentStatus: { [weak self] status in
                self?.status = status
            },
            statusFailed: { error in
                let appError = AppError.wrap(error)
                ErrorLogger.shared.log(appError, severity: .info)
                LoggingService.shared.log(
                    "MenuBarManager: Failed to fetch status - [\(appError.code.rawValue)] \(appError.message)"
                )
            },
            batchFinalized: { [weak self] result in
                self?.finalizeRefreshBatch(result)
            },
            batchSucceeded: { [weak self] result in
                self?.recordSuccessfulRefreshBatch(result)
            }
        )
    )

    private lazy var refreshExecutor = TransitionalRefreshExecutor(
        hooks: TransitionalRefreshExecutor.Hooks(
            currentPresentationIdentity: { [weak self] in
                self?.currentRefreshPresentationIdentity
            },
            isProfileWritable: { [weak self] profileID in
                self?.refreshSideEffectSink
                    .isProfileWritable(profileID) ?? false
            },
            setLoading: { [weak self] isLoading in
                self?.isRefreshing = isLoading
            },
            fetchClaude: { [weak self] request in
                guard let self else {
                    throw CancellationError()
                }
                return try await self.apiService.fetchUsageData(
                    using: request
                )
            },
            fetchAPI: { [weak self] request in
                guard let self else {
                    throw CancellationError()
                }
                return try await self.apiService.fetchAPIUsageData(
                    using: request
                )
            },
            fetchStatus: { [weak self] in
                guard let self else {
                    throw CancellationError()
                }
                return try await self.statusService.fetchStatus()
            },
            commitClaude: { [weak self] plan, newUsage, shouldPresent in
                self?.refreshSideEffectSink.commitClaude(
                    plan,
                    usage: newUsage,
                    shouldPresent: shouldPresent
                ) ?? false
            },
            presentClaude: { [weak self] plan, newUsage in
                self?.refreshSideEffectSink.presentClaude(
                    plan,
                    usage: newUsage
                )
            },
            commitAPI: { [weak self] plan, newUsage, shouldPresent in
                self?.refreshSideEffectSink.commitAPI(
                    plan,
                    usage: newUsage,
                    shouldPresent: shouldPresent
                ) ?? false
            },
            presentAPI: { [weak self] plan, newUsage in
                self?.refreshSideEffectSink.presentAPI(
                    plan,
                    usage: newUsage
                )
            },
            claudeFailed: { [weak self] plan, error, shouldPresent in
                self?.refreshSideEffectSink.claudeFailed(
                    plan,
                    error: error,
                    shouldPresent: shouldPresent
                )
            },
            apiFailed: { [weak self] plan, error, shouldPresent in
                self?.refreshSideEffectSink.apiFailed(
                    plan,
                    error: error,
                    shouldPresent: shouldPresent
                )
            },
            presentStatus: { [weak self] status in
                self?.refreshSideEffectSink.presentStatus(status)
            },
            statusFailed: { [weak self] error in
                self?.refreshSideEffectSink.statusFailed(error)
            },
            batchFinished: { [weak self] result in
                self?.refreshSideEffectSink.finishBatch(result)
            }
        )
    )

    // Combine cancellables for profile observation
    private var cancellables = Set<AnyCancellable>()

    // Track if we've handled the first profile switch (to allow returning to initial profile)
    private var hasHandledFirstProfileSwitch = false

    // Track which profiles have already triggered auto-switch (prevents repeated firing)
    private var autoSwitchedProfileIds: Set<UUID> = []

    // Observer for refresh interval changes
    private var refreshIntervalObserver: NSKeyValueObservation?

    // Observer for icon style changes
    private var iconStyleObserver: NSObjectProtocol?

    // Observer for icon configuration changes
    private var iconConfigObserver: NSObjectProtocol?

    // Observer for credential changes (add, remove, update)
    private var credentialsObserver: NSObjectProtocol?

    // Observer for display mode changes (single/multi profile)
    private var displayModeObserver: NSObjectProtocol?

    // Observer for multi-profile selection and visual configuration changes
    private var multiProfileConfigObserver: NSObjectProtocol?

    // Observer for screen/display changes (headless mode support)
    private var screenObserver: NSObjectProtocol?

    // Observer for wake-from-sleep
    private var wakeObserver: NSObjectProtocol?
    private var lastAutoRefreshTime: Date = .distantPast

    // MARK: - Image Caching (CPU Optimization)
    private var cachedImage: NSImage?
    private var cachedImageKey: String = ""
    private var updateDebounceTimer: Timer?
    private var cachedIsDarkMode: Bool = false

    func setup() {
        // Initialize cached appearance to avoid layout recursion
        cachedIsDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        // Observe profile changes - CRITICAL: Set up before anything else
        observeProfileChanges()

        // Initialize status bar UI manager
        statusBarUIManager = StatusBarUIManager()
        statusBarUIManager?.delegate = self

        // Check if we should use multi-profile mode
        if profileManager.displayMode == .multi {
            // Multi-profile mode - setup with selected profiles
            setupMultiProfileMode()
        } else {
            // Single profile mode - setup with active profile's config
            let config = profileManager.activeProfile?.iconConfig ?? .default
            let hasUsageCredentials = profileManager.activeProfile?.hasUsageCredentials ?? false

            // If no usage credentials, create empty config to show default logo
            let displayConfig: MenuBarIconConfiguration
            if !hasUsageCredentials {
                displayConfig = MenuBarIconConfiguration(
                    colorMode: config.colorMode,
                    singleColorHex: config.singleColorHex,
                    showIconNames: config.showIconNames,
                    metrics: config.metrics.map { metric in
                        var updatedMetric = metric
                        updatedMetric.isEnabled = false
                        return updatedMetric
                    }
                )
            } else {
                displayConfig = config
            }

            statusBarUIManager?.setup(target: self, action: #selector(togglePopover), config: displayConfig)
        }

        // Setup popover
        setupPopover()

        // Load saved data from active profile first (provides immediate feedback)
        // BUT only if profile has usage credentials - CLI alone can't show usage
        if let profile = profileManager.activeProfile {
            if profile.hasUsageCredentials {
                // Profile has usage credentials - show saved usage data if available
                if let savedUsage = profile.claudeUsage {
                    usage = savedUsage
                }
                if let savedAPIUsage = profile.apiUsage {
                    apiUsage = savedAPIUsage
                }
            } else {
                // No usage credentials - clear any old usage data and show default logo
                usage = .empty
                apiUsage = nil
                LoggingService.shared.log("MenuBarManager: Profile has no usage credentials, showing default logo")
            }
            updateAllStatusBarIcons()
        }

        // Start network monitoring - fetch data when network is available
        networkMonitor.onNetworkAvailable = { [weak self] in
            // Only refresh if we haven't refreshed recently (avoid duplicate on startup)
            guard let self = self else { return }

            // Skip if profile has no usage credentials (CLI alone can't be used)
            guard let profile = self.profileManager.activeProfile, profile.hasUsageCredentials else {
                LoggingService.shared.log("Skipping network-available refresh (no usage credentials)")
                return
            }

            let timeSinceLastRefresh = Date().timeIntervalSince(self.lastRefreshTriggerTime)
            if timeSinceLastRefresh > 2.0 {  // At least 2 seconds since last refresh
                self.refreshUsage()
            } else {
                LoggingService.shared.log("Skipping network-available refresh (too soon after last refresh)")
            }
        }
        networkMonitor.startMonitoring()

        // Initial data fetch (with small delay for launch-at-login scenarios)
        // Only if profile has usage credentials (not just CLI)
        if let profile = profileManager.activeProfile, profile.hasUsageCredentials {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.refreshUsage()
            }
        } else {
            LoggingService.shared.log("Skipping initial refresh (no usage credentials)")
        }

        // Start auto-refresh timer with active profile's interval
        startAutoRefresh()

        // Start auto-start session service (5-minute cycle for all profiles)
        autoStartService.start()

        // Observe icon configuration changes
        observeIconConfigChanges()

        // Observe session key updates
        observeCredentialChanges()

        // Observe display mode changes (single/multi profile)
        observeDisplayModeChanges()
        observeMultiProfileConfigChanges()

        // Setup headless mode observer if enabled (for Remote Desktop support)
        setupHeadlessModeObserver()

        // Setup wake-from-sleep observer for auto-refresh
        setupWakeObserver()

        // Setup global keyboard shortcuts
        setupShortcuts()
    }

    private func setupShortcuts() {
        let shortcutManager = ShortcutManager.shared
        shortcutManager.onTogglePopover = { [weak self] in
            self?.togglePopover(nil)
        }
        shortcutManager.onRefresh = { [weak self] in
            self?.refreshUsage()
        }
        shortcutManager.onOpenSettings = { [weak self] in
            self?.preferencesClicked()
        }
        shortcutManager.onNextProfile = { [weak self] in
            self?.switchToNextProfile()
        }
        shortcutManager.startListening()
    }

    func cleanup() {
        ShortcutManager.shared.stopListening()
        refreshTimer?.invalidate()
        refreshTimer = nil
        networkMonitor.stopMonitoring()
        autoStartService.stop()
        cancellables.removeAll()  // Clean up Combine subscriptions
        refreshIntervalObserver?.invalidate()
        refreshIntervalObserver = nil
        if let iconStyleObserver = iconStyleObserver {
            NotificationCenter.default.removeObserver(iconStyleObserver)
            self.iconStyleObserver = nil
        }
        if let iconConfigObserver = iconConfigObserver {
            NotificationCenter.default.removeObserver(iconConfigObserver)
            self.iconConfigObserver = nil
        }
        if let credentialsObserver = credentialsObserver {
            NotificationCenter.default.removeObserver(credentialsObserver)
            self.credentialsObserver = nil
        }
        if let displayModeObserver = displayModeObserver {
            NotificationCenter.default.removeObserver(displayModeObserver)
            self.displayModeObserver = nil
        }
        if let multiProfileConfigObserver = multiProfileConfigObserver {
            NotificationCenter.default.removeObserver(multiProfileConfigObserver)
            self.multiProfileConfigObserver = nil
        }
        if let screenObserver = screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let wakeObserver = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        detachedWindow?.close()
        detachedWindow = nil
        statusItem = nil
        statusBarUIManager?.cleanup()
        statusBarUIManager = nil

        // Clean up history tracking dictionaries to prevent memory leaks
        lastKnownSessionResetTime.removeAll()
        lastKnownWeeklyResetTime.removeAll()
        lastKnownAPIResetTime.removeAll()
        resetJustRecorded.removeAll()
    }

    /// Cleans up tracking data for a specific profile (called when profile is deleted)
    func cleanupProfile(_ profileId: UUID) {
        lastKnownSessionResetTime.removeValue(forKey: profileId)
        lastKnownWeeklyResetTime.removeValue(forKey: profileId)
        lastKnownAPIResetTime.removeValue(forKey: profileId)
        resetJustRecorded.removeValue(forKey: profileId)
        autoSwitchedProfileIds.remove(profileId)
    }

    // MARK: - Profile Observation

    private func observeProfileChanges() {
        // Store the initial profile ID to skip only the very first startup update
        let initialProfileId = profileManager.activeProfile?.id

        // Observe active profile changes
        profileManager.$activeProfile
            .removeDuplicates { oldProfile, newProfile in
                // Only trigger if the profile ID actually changed
                let result = oldProfile?.id == newProfile?.id
                if !result {
                    LoggingService.shared.log("MenuBarManager: Profile ID changed from \(oldProfile?.id.uuidString ?? "nil") to \(newProfile?.id.uuidString ?? "nil")")
                }
                return result
            }
            .dropFirst()  // Skip the initial value
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newProfile in
                guard let self else { return }
                self.refreshExecutor.presentationIdentityDidChange(
                    to: newProfile.map {
                        TransitionalRefreshExecutor.PresentationIdentity(
                            profileID: $0.id,
                            generation:
                                self.profileManager
                                    .activeProfileIdentityGeneration
                        )
                    }
                )
                guard let profile = newProfile else { return }

                // Skip ONLY if this is the startup profile AND we haven't switched yet
                if !self.hasHandledFirstProfileSwitch && profile.id == initialProfileId {
                    LoggingService.shared.log("MenuBarManager: Skipping initial startup profile update to: \(profile.name)")
                    self.hasHandledFirstProfileSwitch = true
                    return
                }

                // Mark that we've handled at least one profile switch
                self.hasHandledFirstProfileSwitch = true

                Task { @MainActor in
                    await self.handleProfileSwitch(to: profile)
                }
            }
            .store(in: &cancellables)

        LoggingService.shared.log("MenuBarManager: Observing profile changes (initial: \(initialProfileId?.uuidString ?? "nil"))")
    }

    private func handleProfileSwitch(to profile: Profile) async {
        LoggingService.shared.log("MenuBarManager: Handling profile switch to: \(profile.name)")

        // 1. Load saved data from new profile (for immediate display)
        await MainActor.run {
            if let savedUsage = profile.claudeUsage {
                self.usage = savedUsage
            } else {
                self.usage = .empty
            }

            if let savedAPIUsage = profile.apiUsage {
                self.apiUsage = savedAPIUsage
            } else {
                self.apiUsage = nil
            }
        }

        // 2. Update refresh interval with profile's setting
        restartAutoRefreshWithInterval(profile.refreshInterval)

        // 3. Update menu bar based on current display mode
        if profileManager.displayMode == .multi {
            // Multi-profile mode: update button images in-place — do NOT call setupMultiProfileMode()
            // here because that tears down and recreates all NSStatusItems, which causes macOS to
            // assign new internal window IDs even when autosaveNames are identical.  Tools like
            // Bartender / Ice track items by those IDs, so rebuilding defeats the static-ID goal.
            // The set of displayed profiles hasn't changed; only the data needs refreshing.
            let config = profileManager.multiProfileConfig
            // Use profile.id (the parameter) rather than profileManager.activeProfile?.id to
            // avoid a TOCTOU race where the published activeProfile may not yet reflect the switch.
            statusBarUIManager?.updateMultiProfileButtons(profiles: profileManager.profiles, config: config, activeProfileId: profile.id)
        } else {
            // Single profile mode - update menu bar configuration
            updateMenuBarDisplay(with: profile.iconConfig)
        }

        // 4. Recreate popover with new profile data
        recreatePopover()

        // 5. Trigger immediate refresh ONLY if profile has usage credentials
        if profile.hasUsageCredentials {
            self.lastRefreshTriggerTime = Date()
            refreshUsage()
        } else {
            LoggingService.shared.log("MenuBarManager: Skipping refresh for profile without usage credentials")
        }
    }

    private func recreatePopover() {
        // Close existing popover if open
        if popover?.isShown == true {
            closePopover()
        }

        // Recreate popover with fresh content
        let newPopover = NSPopover()
        newPopover.contentSize = Constants.WindowSizes.popoverSize
        newPopover.behavior = .semitransient
        // Native animated resizing recurses indefinitely with preferredContentSize
        // on macOS 26/27. PopoverContentView provides a fixed-size content animation.
        newPopover.animates = false
        newPopover.delegate = self
        newPopover.contentViewController = createContentViewController()

        self.popover = newPopover

        LoggingService.shared.log("MenuBarManager: Popover recreated for profile switch")
    }

    private func updateMenuBarDisplay(with config: MenuBarIconConfiguration) {
        // Skip if in multi-profile mode - this method is for single profile mode only
        guard profileManager.displayMode == .single else {
            LoggingService.shared.log("MenuBarManager: Skipping updateMenuBarDisplay (in multi-profile mode)")
            return
        }

        // Check if active profile has usage credentials (not just CLI)
        let hasUsageCredentials = profileManager.activeProfile?.hasUsageCredentials ?? false

        // If no usage credentials, use an empty config (will show default logo)
        let displayConfig: MenuBarIconConfiguration
        if !hasUsageCredentials {
            // Create config with no enabled metrics (will trigger default logo)
            displayConfig = MenuBarIconConfiguration(
                colorMode: config.colorMode,
                singleColorHex: config.singleColorHex,
                showIconNames: config.showIconNames,
                metrics: config.metrics.map { metric in
                    var updatedMetric = metric
                    updatedMetric.isEnabled = false
                    return updatedMetric
                }
            )
        } else {
            displayConfig = config
        }

        statusBarUIManager?.updateConfiguration(
            target: self,
            action: #selector(togglePopover),
            config: displayConfig
        )

        // Defer icon update to next run loop iteration to let NSStatusBar finalize layout
        DispatchQueue.main.async { [weak self] in
            self?.updateAllStatusBarIcons()
        }
    }

    private func restartAutoRefreshWithInterval(_ interval: TimeInterval) {
        refreshTimer?.invalidate()
        refreshTimer = nil

        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshUsage()
        }

        LoggingService.shared.log("Updated refresh interval to \(interval)s")
    }

    private func setupPopover() {
        let popover = NSPopover()
        popover.contentSize = Constants.WindowSizes.popoverSize
        popover.behavior = .semitransient  // Changed to allow detaching
        popover.animates = false
        popover.delegate = self

        popover.contentViewController = createContentViewController()
        self.popover = popover
    }

    private func createContentViewController() -> NSHostingController<PopoverContentView> {
        // Create SwiftUI content view
        let contentView = PopoverContentView(
            manager: self,
            onRefresh: { [weak self] in
                self?.refreshUsage()
            },
            onPreferences: { [weak self] in
                self?.closePopoverOrWindow()
                self?.preferencesClicked()
            }
        )

        let hostingController = NSHostingController(rootView: contentView)
        hostingController.preferredContentSize = Constants.WindowSizes.popoverSize
        hostingController.sizingOptions = .preferredContentSize
        return hostingController
    }

    @objc private func togglePopover(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(for: sender as? NSStatusBarButton)
            return
        }

        // Determine which button was clicked
        let clickedButton: NSStatusBarButton?
        if let button = sender as? NSStatusBarButton {
            clickedButton = button
        } else if statusBarUIManager?.isInMultiProfileMode == true,
                  let activeId = profileManager.activeProfile?.id,
                  let activeButton = statusBarUIManager?.button(for: activeId) {
            // Multi-profile mode: use the active profile's button
            clickedButton = activeButton
        } else {
            // Single profile mode: fallback to primary button
            clickedButton = statusBarUIManager?.primaryButton
        }

        guard let button = clickedButton else { return }

        // In multi-profile mode, determine which profile was clicked
        if statusBarUIManager?.isInMultiProfileMode == true,
           let profileId = statusBarUIManager?.profileId(for: button),
           let profile = profileManager.profiles.first(where: { $0.id == profileId }) {
            // Set the clicked profile data
            clickedProfileId = profileId
            clickedProfileUsage = profile.claudeUsage ?? .empty
            clickedProfileAPIUsage = profile.apiUsage
            LoggingService.shared.log("Multi-profile popover: showing data for '\(profile.name)'")
        } else {
            // Single profile mode - use active profile
            clickedProfileId = profileManager.activeProfile?.id
            clickedProfileUsage = nil  // Will use manager.usage
            clickedProfileAPIUsage = nil  // Will use manager.apiUsage
        }

        // If there's a detached window, close it
        if let window = detachedWindow {
            window.close()
            detachedWindow = nil
            currentPopoverButton = nil
            return
        }

        // Otherwise toggle the popover
        if let popover = popover {
            if popover.isShown {
                // Check if clicking the same button or a different one
                if currentPopoverButton === button {
                    // Same button - close the popover
                    closePopover()
                } else {
                    // Different button - close current and show at new position
                    // Close synchronously. Replacing the hosting controller while an
                    // asynchronous close is in progress can trigger BAD_ACCESS.
                    popover.close()
                    stopMonitoringForOutsideClicks()
                    NSApp.activate(ignoringOtherApps: true)
                    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                    currentPopoverButton = button
                    startMonitoringForOutsideClicks()
                }
            } else {
                // Treat the status-item click that dismissed this same popover as
                // a close, rather than immediately bouncing the popover open again.
                if Self.shouldSuppressPopoverOpen(
                    button: button,
                    lastButton: lastPopoverCloseButton,
                    lastCloseDate: lastPopoverCloseDate
                ) {
                    return
                }

                // Stop any existing monitor first
                stopMonitoringForOutsideClicks()
                // Update content view controller for current profile data
                popover.contentViewController = createContentViewController()
                NSApp.activate(ignoringOtherApps: true)
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                currentPopoverButton = button
                startMonitoringForOutsideClicks()
            }
        }
    }

    static func shouldSuppressPopoverOpen(
        button: AnyObject,
        lastButton: AnyObject?,
        lastCloseDate: Date,
        now: Date = Date()
    ) -> Bool {
        guard let lastButton, button === lastButton else { return false }
        return now.timeIntervalSince(lastCloseDate) < 0.25
    }

    static func makeContextMenu(
        target: AnyObject,
        refreshAction: Selector,
        settingsAction: Selector,
        quitAction: Selector
    ) -> NSMenu {
        let menu = NSMenu()

        let refreshItem = NSMenuItem(
            title: "common.refresh".localized,
            action: refreshAction,
            keyEquivalent: ""
        )
        refreshItem.target = target
        menu.addItem(refreshItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "common.settings".localized,
            action: settingsAction,
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = target
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(
            title: "common.quit".localized,
            action: quitAction,
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = target
        menu.addItem(quitItem)

        return menu
    }

    private func showContextMenu(for button: NSStatusBarButton?) {
        guard let button, let window = button.window else { return }

        let menu = Self.makeContextMenu(
            target: self,
            refreshAction: #selector(contextMenuRefresh),
            settingsAction: #selector(preferencesClicked),
            quitAction: #selector(quitClicked)
        )
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = window.convertToScreen(buttonRect)
        menu.popUp(positioning: nil, at: screenRect.origin, in: nil)
    }

    @objc private func contextMenuRefresh() {
        refreshUsage()
    }

    private func closePopover() {
        popover?.performClose(nil)
        stopMonitoringForOutsideClicks()
        lastPopoverCloseButton = currentPopoverButton
        currentPopoverButton = nil
        lastPopoverCloseDate = Date()
    }

    private func startMonitoringForOutsideClicks() {
        // Only monitor when popover is shown (not detached)
        // Stop monitoring if popover gets detached
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self,
                  let popover = self.popover,
                  popover.isShown,
                  self.detachedWindow == nil else { return }
            self.closePopover()
        }
    }

    private func stopMonitoringForOutsideClicks() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func closePopoverOrWindow() {
        if let window = detachedWindow {
            window.close()
            detachedWindow = nil
        } else {
            popover?.performClose(nil)
        }
    }

    // MARK: - Status Bar Icon Updates

    /// Updates all enabled status bar icons
    private func updateAllStatusBarIcons() {
        // Check if in multi-profile mode
        if profileManager.displayMode == .multi {
            // Update multi-profile icons using profiles from profileManager
            let config = profileManager.multiProfileConfig
            statusBarUIManager?.updateMultiProfileButtons(
                profiles: profileManager.profiles,
                config: config,
                activeProfileId: profileManager.activeProfile?.id
            )
        } else {
            // Single profile mode - use the standard update
            statusBarUIManager?.updateAllButtons(
                usage: usage,
                apiUsage: apiUsage
            )
        }
    }

    /// Updates a specific metric's status bar icon
    private func updateStatusBarIcon(for metricType: MenuBarMetricType) {
        statusBarUIManager?.updateButton(
            for: metricType,
            usage: usage,
            apiUsage: apiUsage
        )
    }

    // Legacy method kept for backwards compatibility (now uses new system)
    private func updateStatusButton(_ button: NSStatusBarButton, usage: ClaudeUsage) {
        // This method is deprecated but kept for any remaining references
        // The new system handles updates through updateAllStatusBarIcons()
        updateAllStatusBarIcons()
    }

    // MARK: - Icon Style: Battery (Classic)

    private func startAutoRefresh() {
        let interval = profileManager.activeProfile?.refreshInterval ?? 30.0
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.lastAutoRefreshTime = Date()
            self?.refreshUsage()
        }
        refreshTimer?.tolerance = interval * 0.1  // 10% tolerance for energy efficiency
        LoggingService.shared.log("Started auto-refresh with interval: \(interval)s")
    }

    private func setupWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            // Debounce: only refresh if at least 10 seconds since last auto-refresh
            let timeSinceLastRefresh = Date().timeIntervalSince(self.lastAutoRefreshTime)
            guard timeSinceLastRefresh > 10 else {
                LoggingService.shared.log("MenuBarManager: Skipping wake refresh (debounce)")
                return
            }
            LoggingService.shared.log("MenuBarManager: Wake from sleep detected, refreshing after delay")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.lastAutoRefreshTime = Date()
                self?.refreshUsage()
            }
        }
    }

    private func restartAutoRefresh() {
        // Invalidate existing timer
        refreshTimer?.invalidate()
        refreshTimer = nil

        // Start new timer with updated interval
        startAutoRefresh()
    }

    private func observeRefreshIntervalChanges() {
        // Observe the same UserDefaults instance that DataStore uses
        refreshIntervalObserver = dataStore.userDefaults.observe(\.refreshInterval, options: [.new]) { [weak self] _, change in
            if let newValue = change.newValue, newValue > 0 {
                DispatchQueue.main.async {
                    self?.restartAutoRefresh()
                }
            }
        }
    }

    private func observeIconStyleChanges() {
        // Observe icon style changes from settings (now consolidated with menuBarIconConfigChanged)
        iconStyleObserver = NotificationCenter.default.addObserver(
            forName: .menuBarIconConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            // Clear cache to force redraw with new style
            self.cachedImageKey = ""
            self.updateAllStatusBarIcons()
        }
    }

    private func observeCredentialChanges() {
        // Observe credential changes (add, remove, or update)
        credentialsObserver = NotificationCenter.default.addObserver(
            forName: .credentialsChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            let changedProfileID = Self.credentialChangeProfileID(
                from: notification
            )

            // The observer is explicitly delivered on the main queue. Keep
            // invalidation synchronous with the notification so an already
            // completed fetch cannot win a later actor scheduling race.
            let routing = MainActor.assumeIsolated {
                let routing = Self.credentialChangeRouting(
                    changedProfileID: changedProfileID,
                    activeProfileID: self.profileManager.activeProfile?.id,
                    selectedProfileIDs: Set(
                        self.profileManager.profiles.lazy
                            .filter(\.isSelectedForDisplay)
                            .map(\.id)
                    ),
                    isMultiProfileMode:
                        self.profileManager.displayMode == .multi
                )
                switch routing.invalidation {
                case .profile(let profileID):
                    self.refreshExecutor.invalidate(profileID: profileID)
                case .allCapturedProfiles:
                    self.refreshExecutor.invalidateAllCapturedProfiles()
                }
                return routing
            }

            guard routing.shouldRefreshVisibleProfiles else {
                LoggingService.shared.logInfo(
                    "Credentials changed for an inactive profile - captured work invalidated without refreshing visible profiles"
                )
                return
            }

            Task { @MainActor in
                let selectedProfileIDs = Set(
                    self.profileManager.profiles.lazy
                        .filter(\.isSelectedForDisplay)
                        .map(\.id)
                )
                guard Self.shouldExecuteCredentialRefresh(
                    routing,
                    activeProfileID: self.profileManager.activeProfile?.id,
                    selectedProfileIDs: selectedProfileIDs,
                    isMultiProfileMode:
                        self.profileManager.displayMode == .multi
                ) else {
                    LoggingService.shared.logInfo(
                        "Credential refresh became stale before execution - skipping visible profile work"
                    )
                    return
                }

                if self.profileManager.displayMode == .multi {
                    LoggingService.shared.logInfo(
                        "Credentials changed for a visible profile - refreshing selected profiles"
                    )
                    self.updateMultiProfileDisplay()
                    self.lastRefreshTriggerTime = Date()
                    self.refreshUsage()
                    return
                }

                // Check if active profile has usage credentials
                guard let profile = self.profileManager.activeProfile, profile.hasUsageCredentials else {
                    LoggingService.shared.logInfo("Credentials changed but no usage credentials - showing default logo")

                    // Reconfigure menu bar to show default logo
                    let config = self.profileManager.activeProfile?.iconConfig ?? .default
                    self.updateMenuBarDisplay(with: config)
                    return
                }

                LoggingService.shared.logInfo("Credentials changed - triggering immediate refresh")

                // Reconfigure menu bar to show metrics (in case we were showing default logo)
                let config = profile.iconConfig
                self.updateMenuBarDisplay(with: config)

                // Mark this as user-triggered
                self.lastRefreshTriggerTime = Date()

                self.refreshUsage()
            }
        }
    }

    struct CredentialChangeRouting: Equatable, Sendable {
        enum Invalidation: Equatable, Sendable {
            case profile(UUID)
            case allCapturedProfiles
        }

        enum RefreshScope: Equatable, Sendable {
            case none
            case activeProfile(UUID)
            case selectedProfile(UUID)
            case conservative
        }

        let invalidation: Invalidation
        let refreshScope: RefreshScope

        var shouldRefreshVisibleProfiles: Bool {
            refreshScope != .none
        }
    }

    static func credentialChangeRouting(
        changedProfileID: UUID?,
        activeProfileID: UUID?,
        selectedProfileIDs: Set<UUID>,
        isMultiProfileMode: Bool
    ) -> CredentialChangeRouting {
        guard let changedProfileID else {
            return CredentialChangeRouting(
                invalidation: .allCapturedProfiles,
                refreshScope: .conservative
            )
        }

        let refreshScope: CredentialChangeRouting.RefreshScope
        if isMultiProfileMode {
            refreshScope =
                selectedProfileIDs.contains(changedProfileID)
                ? .selectedProfile(changedProfileID)
                : .none
        } else {
            refreshScope =
                activeProfileID == changedProfileID
                ? .activeProfile(changedProfileID)
                : .none
        }
        return CredentialChangeRouting(
            invalidation: .profile(changedProfileID),
            refreshScope: refreshScope
        )
    }

    static func shouldExecuteCredentialRefresh(
        _ routing: CredentialChangeRouting,
        activeProfileID: UUID?,
        selectedProfileIDs: Set<UUID>,
        isMultiProfileMode: Bool
    ) -> Bool {
        switch routing.refreshScope {
        case .none:
            return false
        case .activeProfile(let profileID):
            return !isMultiProfileMode && activeProfileID == profileID
        case .selectedProfile(let profileID):
            return isMultiProfileMode
                && selectedProfileIDs.contains(profileID)
        case .conservative:
            return true
        }
    }

    nonisolated static func credentialChangeProfileID(
        from notification: Notification
    ) -> UUID? {
        if let profileID = notification.object as? UUID {
            return profileID
        }
        for key in ["profileID", "profileId"] {
            if let profileID = notification.userInfo?[key] as? UUID {
                return profileID
            }
            if let value = notification.userInfo?[key] as? String,
               let profileID = UUID(uuidString: value) {
                return profileID
            }
        }
        return nil
    }

    private func observeIconConfigChanges() {
        // Observe configuration changes (metrics enabled/disabled, order changes, etc.)
        iconConfigObserver = NotificationCenter.default.addObserver(
            forName: .menuBarIconConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            // Reload configuration from active profile (already on main queue)
            Task { @MainActor in
                // Handle differently based on display mode
                if self.profileManager.displayMode == .multi {
                    self.updateMultiProfileDisplay()
                } else {
                    // Single profile mode
                    let newConfig = self.profileManager.activeProfile?.iconConfig ?? .default
                    self.updateMenuBarDisplay(with: newConfig)
                }
            }
        }
    }

    private func observeMultiProfileConfigChanges() {
        multiProfileConfigObserver = NotificationCenter.default.addObserver(
            forName: .multiProfileConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.updateMultiProfileDisplay()
            }
        }
    }

    private func observeDisplayModeChanges() {
        // Observe display mode changes (single/multi profile)
        displayModeObserver = NotificationCenter.default.addObserver(
            forName: .displayModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            Task { @MainActor in
                self.handleDisplayModeChange()
            }
        }
    }

    private func handleDisplayModeChange() {
        let displayMode = profileManager.displayMode

        LoggingService.shared.log("MenuBarManager: Display mode changed to \(displayMode.rawValue)")

        if displayMode == .multi {
            // Switch to multi-profile mode
            setupMultiProfileMode()
        } else {
            // Switch back to single profile mode
            setupSingleProfileMode()
        }
    }

    // MARK: - Headless Mode (Remote Desktop Support)

    private func setupHeadlessModeObserver() {
        // Always observe screen changes to support headless Mac setups (Remote Desktop)
        LoggingService.shared.log("MenuBarManager: Setting up screen change observer for headless support")

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenChange()
        }
    }

    private func handleScreenChange() {
        // Only proceed if we have screens now
        guard !NSScreen.screens.isEmpty else { return }

        // Check if status bar needs retry (button is nil means it failed on headless startup)
        guard let uiManager = statusBarUIManager else { return }

        if !uiManager.hasValidStatusBar {
            LoggingService.shared.log("MenuBarManager: Headless mode - display connected, retrying status bar setup (screens: \(NSScreen.screens.count))")
            setup()
        }
    }

    /// Returns whether the status bar has at least one valid button
    func hasValidStatusBar() -> Bool {
        return statusBarUIManager?.hasValidStatusBar ?? false
    }

    private func setupMultiProfileMode() {
        let selectedProfiles = profileManager.getSelectedProfiles()
        let config = profileManager.multiProfileConfig

        statusBarUIManager?.setupMultiProfile(
            profiles: selectedProfiles,
            target: self,
            action: #selector(togglePopover)
        )

        // Defer icon update to next run loop iteration to let NSStatusBar finalize layout
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusBarUIManager?.updateMultiProfileButtons(profiles: self.profileManager.profiles, config: config, activeProfileId: self.profileManager.activeProfile?.id)
        }

        LoggingService.shared.log("MenuBarManager: Multi-profile mode enabled with \(selectedProfiles.count) profiles, style=\(config.iconStyle.rawValue)")

        // Refresh data for all selected profiles that have credentials
        refreshAllSelectedProfiles()
    }

    /// Applies multi-profile selection and visual changes without recreating
    /// retained NSStatusItems, preserving their macOS and third-party ordering.
    private func updateMultiProfileDisplay() {
        let config = profileManager.multiProfileConfig

        statusBarUIManager?.updateMultiProfileConfiguration(
            profiles: profileManager.profiles,
            target: self,
            action: #selector(togglePopover)
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusBarUIManager?.updateMultiProfileButtons(
                profiles: self.profileManager.profiles,
                config: config,
                activeProfileId: self.profileManager.activeProfile?.id
            )
        }

        LoggingService.shared.log("MenuBarManager: Multi-profile display updated incrementally")
    }

    /// Refreshes usage data for all profiles selected for multi-profile display
    private func refreshAllSelectedProfiles() {
        let selectedProfiles = profileManager.profiles.filter { $0.isSelectedForDisplay && $0.hasUsageCredentials }

        guard !selectedProfiles.isEmpty else {
            LoggingService.shared.log("MenuBarManager: No selected profiles with usage credentials to refresh")
            updateAllStatusBarIcons()
            return
        }

        let generation = profileManager.activeProfileIdentityGeneration
        let plans = selectedProfiles.map { profile in
            TransitionalRefreshExecutor.Plan.capture(
                profile: profile,
                mode: .multi,
                presentationGeneration: generation,
                apiService: apiService
            )
        }

        LoggingService.shared.log("MenuBarManager: Refreshing \(selectedProfiles.count) selected profiles for multi-profile mode")
        refreshExecutor.start(
            plans,
            loadingIdentity: currentRefreshPresentationIdentity
        )
    }

    private func setupSingleProfileMode() {
        guard let profile = profileManager.activeProfile else { return }

        let hasUsageCredentials = profile.hasUsageCredentials
        let config = profile.iconConfig

        // If no usage credentials, create empty config to show default logo
        let displayConfig: MenuBarIconConfiguration
        if !hasUsageCredentials {
            displayConfig = MenuBarIconConfiguration(
                colorMode: config.colorMode,
                singleColorHex: config.singleColorHex,
                showIconNames: config.showIconNames,
                metrics: config.metrics.map { metric in
                    var updatedMetric = metric
                    updatedMetric.isEnabled = false
                    return updatedMetric
                }
            )
        } else {
            displayConfig = config
        }

        statusBarUIManager?.setup(target: self, action: #selector(togglePopover), config: displayConfig)

        // Defer icon update to next run loop iteration to let NSStatusBar finalize layout
        DispatchQueue.main.async { [weak self] in
            self?.updateAllStatusBarIcons()
        }

        LoggingService.shared.log("MenuBarManager: Single profile mode enabled")
    }

    func refreshUsage() {
        // In multi-profile mode, refresh ALL selected profiles
        if profileManager.displayMode == .multi {
            refreshAllSelectedProfiles()
            return
        }

        // Single profile mode - refresh only active profile
        guard let profile = profileManager.activeProfile else {
            LoggingService.shared.log("MenuBarManager.refreshUsage: No active profile")
            return
        }

        // Detailed logging
        LoggingService.shared.log("MenuBarManager.refreshUsage called:")
        LoggingService.shared.log("  - Profile: '\(profile.name)'")
        LoggingService.shared.log("  - hasUsageCredentials: \(profile.hasUsageCredentials)")

        // Check for usage credentials (Claude.ai or API Console, not just CLI)
        guard profile.hasUsageCredentials else {
            LoggingService.shared.log("MenuBarManager: Skipping refresh - no usage credentials")
            // Update icons to show default logo if needed
            updateAllStatusBarIcons()
            return
        }

        LoggingService.shared.log("MenuBarManager: Proceeding with refresh")
        let plan = TransitionalRefreshExecutor.Plan.capture(
            profile: profile,
            mode: .single,
            presentationGeneration:
                profileManager.activeProfileIdentityGeneration,
            apiService: apiService
        )
        refreshExecutor.start(plan)
    }

    private var currentRefreshPresentationIdentity:
        TransitionalRefreshExecutor.PresentationIdentity? {
        profileManager.activeProfile.map {
            TransitionalRefreshExecutor.PresentationIdentity(
                profileID: $0.id,
                generation: profileManager.activeProfileIdentityGeneration
            )
        }
    }

    static func autoSwitchProfile(
        for plan: TransitionalRefreshExecutor.Plan,
        profiles: [Profile],
        activeProfileID: UUID?,
        presentationIdentity:
            TransitionalRefreshExecutor.PresentationIdentity?
    ) -> Profile? {
        guard activeProfileID == plan.profileID,
              presentationIdentity == plan.presentationIdentity else {
            return nil
        }
        return profiles.first { $0.id == plan.profileID }
    }

    private func isRefreshProfileWritable(_ profileID: UUID) -> Bool {
        profileManager.profiles.contains {
            $0.id == profileID && !$0.deletionInProgress
        }
    }

    private func recordClaudeRefresh(
        plan: TransitionalRefreshExecutor.Plan,
        usage newUsage: ClaudeUsage
    ) {
        checkAndRecordSessionReset(
            profileId: plan.profileID,
            previousUsage: plan.previousClaudeUsage,
            newUsage: newUsage
        )
        checkAndRecordWeeklyReset(
            profileId: plan.profileID,
            previousUsage: plan.previousClaudeUsage,
            newUsage: newUsage
        )

        switch plan.mode {
        case .single:
            UsageHistoryService.shared.recordSessionPeriodic(
                for: plan.profileID,
                usage: newUsage
            )
            UsageHistoryService.shared.recordWeeklyPeriodic(
                for: plan.profileID,
                usage: newUsage
            )
        case .multi:
            let flags = resetJustRecorded[plan.profileID]
                ?? (session: false, weekly: false)
            if !flags.session {
                UsageHistoryService.shared.recordSessionPeriodic(
                    for: plan.profileID,
                    usage: newUsage
                )
            }
            if !flags.weekly {
                UsageHistoryService.shared.recordWeeklyPeriodic(
                    for: plan.profileID,
                    usage: newUsage
                )
            }
            resetJustRecorded[plan.profileID] = (
                session: false,
                weekly: false
            )
        }
    }

    private func saveClaudeRefresh(
        plan: TransitionalRefreshExecutor.Plan,
        usage newUsage: ClaudeUsage,
        shouldPresent: Bool
    ) -> Bool {
        guard isRefreshProfileWritable(plan.profileID) else {
            return false
        }
        guard profileManager.saveClaudeUsage(
            newUsage,
            for: plan.profileID,
            publishToActiveProfile: shouldPresent
        ) else {
            return false
        }
        LoggingService.shared.log(
            "MenuBarManager: Saved usage for profile '\(plan.profileName)' - session: \(newUsage.sessionPercentage)%"
        )
        return true
    }

    private func writeStatuslineRefresh(
        plan: TransitionalRefreshExecutor.Plan,
        usage newUsage: ClaudeUsage
    ) {
        if StatuslineService.shared.isInstalled {
            StatuslineService.shared.writeUsageCache(
                usage: newUsage,
                profileName: plan.profileName
            )
        }
        updateAllStatusBarIcons()
    }

    private func notifyForRefresh(
        plan: TransitionalRefreshExecutor.Plan,
        usage newUsage: ClaudeUsage
    ) {
        NotificationManager.shared.checkAndNotify(
            usage: newUsage,
            profileName: plan.profileName,
            settings: plan.notificationSettings
        )
    }

    private func recordAPIRefresh(
        plan: TransitionalRefreshExecutor.Plan,
        usage newUsage: APIUsage
    ) {
        checkAndRecordBillingCycleReset(
            profileId: plan.profileID,
            previousUsage: plan.previousAPIUsage,
            newUsage: newUsage
        )
    }

    private func saveAPIRefresh(
        plan: TransitionalRefreshExecutor.Plan,
        usage newUsage: APIUsage,
        shouldPresent: Bool
    ) -> Bool {
        guard isRefreshProfileWritable(plan.profileID) else {
            return false
        }
        guard profileManager.saveAPIUsage(
            newUsage,
            for: plan.profileID,
            publishToActiveProfile: shouldPresent
        ) else {
            return false
        }
        return true
    }

    private func handleClaudeRefreshFailure(
        plan: TransitionalRefreshExecutor.Plan,
        error: Error,
        shouldPresent: Bool
    ) {
        switch plan.mode {
        case .multi:
            LoggingService.shared.logError(
                "Failed to refresh profile '\(plan.profileName)': \(error.localizedDescription)"
            )
        case .single:
            let appError = AppError.wrap(error)
            ErrorLogger.shared.log(appError, severity: .error)
            guard shouldPresent else { return }

            ErrorRecovery.shared.recordFailure(for: .api)
            consecutiveRefreshFailures += 1
            lastRefreshError = appError.message
            if appError.code == .apiUnauthorized
                || appError.code == .sessionKeyExpired {
                hasCredentialError = true
            }
            if abs(lastRefreshTriggerTime.timeIntervalSinceNow) < 5 {
                ErrorPresenter.shared.showAlert(for: appError)
            } else {
                LoggingService.shared.logError(
                    "MenuBarManager: Failed to fetch usage - [\(appError.code.rawValue)] \(appError.message)"
                )
            }
        }
    }

    private func handleAPIRefreshFailure(
        plan: TransitionalRefreshExecutor.Plan,
        error: Error
    ) {
        switch plan.mode {
        case .multi:
            LoggingService.shared.logError(
                "Failed to refresh API usage for profile '\(plan.profileName)': \(error.localizedDescription)"
            )
        case .single:
            let appError = AppError.wrap(error)
            ErrorLogger.shared.log(appError, severity: .info)
            LoggingService.shared.log(
                "MenuBarManager: Failed to fetch API usage - [\(appError.code.rawValue)] \(appError.message)"
            )
        }
    }

    private func finalizeRefreshBatch(
        _ result: TransitionalRefreshExecutor.BatchResult
    ) {
        guard let first = result.outcomes.first,
              case .multi = first.plan.mode else {
            return
        }
        let config = profileManager.multiProfileConfig
        statusBarUIManager?.updateMultiProfileButtons(
            profiles: profileManager.profiles,
            config: config,
            activeProfileId: profileManager.activeProfile?.id
        )
    }

    private func recordSuccessfulRefreshBatch(
        _ result: TransitionalRefreshExecutor.BatchResult
    ) {
        guard let first = result.outcomes.first else { return }
        switch first.plan.mode {
        case .single:
            ErrorRecovery.shared.recordSuccess(for: .api)
            consecutiveRefreshFailures = 0
            lastRefreshError = nil
            hasCredentialError = false
            lastSuccessfulRefreshTime = Date()
            if abs(lastRefreshTriggerTime.timeIntervalSinceNow) < 5 {
                showSuccessNotification()
            }
        case .multi:
            consecutiveRefreshFailures = 0
            lastRefreshError = nil
            hasCredentialError = false
            lastSuccessfulRefreshTime = Date()

            guard let activeProfile = profileManager.activeProfile,
                  let activeOutcome = result.outcomes.first(where: {
                      $0.plan.profileID == activeProfile.id
                          && $0.claude == .success
                  }),
                  activeOutcome.plan.presentationIdentity
                    == currentRefreshPresentationIdentity,
                  let activeUsage = activeProfile.claudeUsage else {
                return
            }
            checkAutoSwitchIfNeeded(
                usage: activeUsage,
                currentProfile: activeProfile,
                expectedPresentationIdentity:
                    activeOutcome.plan.presentationIdentity
            )
        }
    }

    /// Shows a brief success notification for user-triggered refreshes
    private func showSuccessNotification() {
        NotificationManager.shared.sendSuccessNotification()
    }

    // MARK: - Auto-Switch Profile on Session Limit

    /// Checks if the current profile hit 100% and switches to the next available one
    private func checkAutoSwitchIfNeeded(
        usage: ClaudeUsage,
        currentProfile: Profile,
        expectedPresentationIdentity:
            TransitionalRefreshExecutor.PresentationIdentity
    ) {
        guard currentRefreshPresentationIdentity
                == expectedPresentationIdentity,
              currentProfile.id
                == expectedPresentationIdentity.profileID else {
            return
        }

        // Guard: feature must be enabled
        guard SharedDataStore.shared.loadAutoSwitchProfileEnabled() else { return }

        // Guard: need more than 1 profile
        let profiles = profileManager.profiles
        guard profiles.count > 1 else { return }

        let profileId = currentProfile.id

        // If usage dropped below 100%, clear the flag (session reset)
        if usage.effectiveSessionPercentage < 100.0 {
            autoSwitchedProfileIds.remove(profileId)
            return
        }

        // Guard: usage must be >= 100%
        guard usage.effectiveSessionPercentage >= 100.0 else { return }

        // Guard: don't re-trigger for this profile
        guard !autoSwitchedProfileIds.contains(profileId) else { return }

        // Mark as triggered
        autoSwitchedProfileIds.insert(profileId)

        // Find the next available profile
        guard let nextProfile = findNextAvailableProfile(after: currentProfile) else {
            LoggingService.shared.log("AutoSwitch: All profiles at 100% or unavailable, staying on '\(currentProfile.name)'")
            return
        }

        LoggingService.shared.log("AutoSwitch: Switching from '\(currentProfile.name)' to '\(nextProfile.name)'")

        // Activate the next profile
        let fromName = currentProfile.name
        let toName = nextProfile.name
        Task { @MainActor [weak self] in
            guard let self,
                  self.currentRefreshPresentationIdentity
                    == expectedPresentationIdentity else {
                self?.autoSwitchedProfileIds.remove(profileId)
                return
            }
            await profileManager.activateProfile(nextProfile.id)

            await MainActor.run {
                // Send notification
                NotificationManager.shared.sendAutoSwitchNotification(fromProfile: fromName, toProfile: toName)

                // Post notification for UI reactivity
                NotificationCenter.default.post(name: .autoSwitchProfileTriggered, object: nil)
            }
        }
    }

    /// Finds the next profile with available session capacity, wrapping around
    private func findNextAvailableProfile(after currentProfile: Profile) -> Profile? {
        let profiles = profileManager.profiles
        guard let currentIndex = profiles.firstIndex(where: { $0.id == currentProfile.id }) else { return nil }

        let count = profiles.count
        for offset in 1..<count {
            let index = (currentIndex + offset) % count
            let candidate = profiles[index]

            // Must have usage credentials
            guard candidate.hasUsageCredentials else { continue }

            // If no saved usage data, treat as available
            guard let candidateUsage = candidate.claudeUsage else { return candidate }

            // Must be below 100%
            if candidateUsage.effectiveSessionPercentage < 100.0 {
                return candidate
            }
        }

        return nil
    }

    // MARK: - Reset Detection for History Recording

    /// Normalizes a date to minute precision for comparison (ignores seconds)
    private func normalizeToMinute(_ date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return calendar.date(from: components) ?? date
    }

    /// Checks if a session reset occurred and records a snapshot if so
    private func checkAndRecordSessionReset(
        profileId: UUID,
        previousUsage: ClaudeUsage?,
        newUsage: ClaudeUsage
    ) {
        let lastKnown = lastKnownSessionResetTime[profileId]
        let newResetTime = normalizeToMinute(newUsage.sessionResetTime)

        // First time seeing this profile - just record the reset time
        if lastKnown == nil {
            lastKnownSessionResetTime[profileId] = newResetTime
            return
        }

        // Normalize the last known time for comparison
        let normalizedLastKnown = normalizeToMinute(lastKnown!)

        // Check if reset time changed (indicates a reset occurred)
        // Use != instead of > to handle clock changes and backward time jumps
        if newResetTime != normalizedLastKnown {
            // Reset detected! Record snapshot of the previous usage
            LoggingService.shared.log("History: Session reset detected for profile \(profileId.uuidString.prefix(8)). Old: \(normalizedLastKnown), New: \(newResetTime)")
            if let prevUsage = previousUsage {
                Task { @MainActor in
                    UsageHistoryService.shared.recordSessionReset(
                        for: profileId,
                        previousUsage: prevUsage,
                        resetTime: prevUsage.sessionResetTime  // Use original reset time, not normalized
                    )
                }
            }

            // Mark that session reset was just recorded to prevent duplicate periodic snapshot
            var flags = resetJustRecorded[profileId] ?? (session: false, weekly: false)
            flags.session = true
            resetJustRecorded[profileId] = flags
        }

        // Update the last known reset time
        lastKnownSessionResetTime[profileId] = newResetTime
    }

    /// Checks if a weekly reset occurred and records a snapshot if so
    private func checkAndRecordWeeklyReset(
        profileId: UUID,
        previousUsage: ClaudeUsage?,
        newUsage: ClaudeUsage
    ) {
        let lastKnown = lastKnownWeeklyResetTime[profileId]
        let newResetTime = normalizeToMinute(newUsage.weeklyResetTime)

        // First time seeing this profile - just record the reset time
        if lastKnown == nil {
            lastKnownWeeklyResetTime[profileId] = newResetTime
            LoggingService.shared.log("History: Initial weekly reset time for profile \(profileId.uuidString.prefix(8)): \(newResetTime)")
            return
        }

        // Normalize the last known time for comparison
        let normalizedLastKnown = normalizeToMinute(lastKnown!)

        // Check if reset time changed (indicates a reset occurred)
        // Use != instead of > to handle clock changes and backward time jumps
        if newResetTime != normalizedLastKnown {
            // Reset detected! Record snapshot of the previous usage
            LoggingService.shared.log("History: Weekly reset detected for profile \(profileId.uuidString.prefix(8)). Old: \(normalizedLastKnown), New: \(newResetTime)")
            if let prevUsage = previousUsage {
                Task { @MainActor in
                    UsageHistoryService.shared.recordWeeklyReset(
                        for: profileId,
                        previousUsage: prevUsage,
                        resetTime: prevUsage.weeklyResetTime  // Use original reset time, not normalized
                    )
                }
            }

            // Mark that weekly reset was just recorded to prevent duplicate periodic snapshot
            var flags = resetJustRecorded[profileId] ?? (session: false, weekly: false)
            flags.weekly = true
            resetJustRecorded[profileId] = flags
        }

        // Update the last known reset time
        lastKnownWeeklyResetTime[profileId] = newResetTime
    }

    /// Checks if a billing cycle reset occurred and records a snapshot if so
    private func checkAndRecordBillingCycleReset(
        profileId: UUID,
        previousUsage: APIUsage?,
        newUsage: APIUsage
    ) {
        let lastKnown = lastKnownAPIResetTime[profileId]
        let newResetTime = normalizeToMinute(newUsage.resetsAt)

        // First time seeing this profile - just record the reset time
        if lastKnown == nil {
            lastKnownAPIResetTime[profileId] = newResetTime
            LoggingService.shared.log("History: Initial API reset time for profile \(profileId.uuidString.prefix(8)): \(newResetTime)")
            return
        }

        // Normalize the last known time for comparison
        let normalizedLastKnown = normalizeToMinute(lastKnown!)

        // Check if reset time changed (indicates a reset occurred)
        // Use != instead of > to handle clock changes and backward time jumps
        if newResetTime != normalizedLastKnown {
            // Reset detected! Record snapshot of the previous usage
            LoggingService.shared.log("History: Billing cycle reset detected for profile \(profileId.uuidString.prefix(8)). Old: \(normalizedLastKnown), New: \(newResetTime)")
            if let prevUsage = previousUsage {
                Task { @MainActor in
                    UsageHistoryService.shared.recordBillingCycleReset(
                        for: profileId,
                        previousUsage: prevUsage,
                        resetTime: prevUsage.resetsAt  // Use original reset time, not normalized
                    )
                }
            }
        }

        // Update the last known reset time
        lastKnownAPIResetTime[profileId] = newResetTime
    }

    @objc private func preferencesClicked() {
        // Close the popover or detached window first
        closePopoverOrWindow()

        // If settings window already exists, just bring it to front
        if let existingWindow = settingsWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Small delay to ensure smooth transition
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // Temporarily show dock icon for the settings window (like setup wizard)
            NSApp.setActivationPolicy(.regular)

            // Create and show the settings window
            let window = SettingsWindowBuilder.makeWindow(size: Constants.WindowSizes.settingsWindow)
            window.title = "Claude Usage - Settings"
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self

            self.settingsWindow = window

            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func switchToNextProfile() {
        let profiles = profileManager.profiles
        guard profiles.count > 1,
              let currentId = profileManager.activeProfile?.id,
              let currentIndex = profiles.firstIndex(where: { $0.id == currentId }) else {
            return
        }

        let nextIndex = (profiles.index(after: currentIndex)) % profiles.count
        let nextProfile = profiles[nextIndex]

        Task {
            await profileManager.activateProfile(nextProfile.id)
        }
    }

    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
    }

    /// Shows the GitHub star prompt window
    func showGitHubStarPrompt() {
        // If window already exists, just bring it to front
        if let existingWindow = githubPromptWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Temporarily show dock icon for the prompt window
        NSApp.setActivationPolicy(.regular)

        // Create the GitHub star prompt view
        let promptView = GitHubStarPromptView(
            onStar: { [weak self] in
                self?.handleGitHubStarClick()
            },
            onMaybeLater: { [weak self] in
                self?.handleMaybeLaterClick()
            },
            onDontAskAgain: { [weak self] in
                self?.handleDontAskAgainClick()
            }
        )

        let hostingController = NSHostingController(rootView: promptView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = ""
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 300, height: 145))
        window.center()
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.level = .floating
        window.delegate = self

        // Store reference
        githubPromptWindow = window

        // Mark that we've shown the prompt
        dataStore.saveLastGitHubStarPromptDate(Date())

        // Show the window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleGitHubStarClick() {
        // Open GitHub repository
        if let url = URL(string: Constants.githubRepoURL) {
            NSWorkspace.shared.open(url)
        }

        // Mark as starred
        dataStore.saveHasStarredGitHub(true)

        // Close the prompt window
        githubPromptWindow?.close()
        githubPromptWindow = nil

        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)
    }

    private func handleMaybeLaterClick() {
        // Just close the window - the prompt will show again after the reminder interval
        githubPromptWindow?.close()
        githubPromptWindow = nil

        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)
    }

    private func handleDontAskAgainClick() {
        // Mark to never show again
        dataStore.saveNeverShowGitHubPrompt(true)

        // Close the prompt window
        githubPromptWindow?.close()
        githubPromptWindow = nil

        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Feedback Prompt

    /// Shows the feedback collection prompt window
    func showFeedbackPrompt() {
        if let existingWindow = feedbackWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        NSApp.setActivationPolicy(.regular)

        let promptView = FeedbackPromptView(
            onSubmit: { [weak self] _, _, _, _ in
                SharedDataStore.shared.saveHasSubmittedFeedback(true)
                // Close after a brief delay to show the thanks state
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self?.closeFeedbackWindow()
                }
            },
            onRemindLater: { [weak self] in
                SharedDataStore.shared.saveLastFeedbackPromptDate(Date())
                self?.closeFeedbackWindow()
            },
            onDontAskAgain: { [weak self] in
                SharedDataStore.shared.saveNeverShowFeedbackPrompt(true)
                self?.closeFeedbackWindow()
            }
        )

        let hostingController = NSHostingController(rootView: promptView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = ""
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 380, height: 420))
        window.center()
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.level = .floating
        window.delegate = self

        feedbackWindow = window
        SharedDataStore.shared.saveLastFeedbackPromptDate(Date())

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeFeedbackWindow() {
        feedbackWindow?.close()
        feedbackWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - NSPopoverDelegate
extension MenuBarManager: NSPopoverDelegate {
    func popoverShouldDetach(_ popover: NSPopover) -> Bool {
        // Allow popover to be detached by dragging
        return true
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverCloseDate = Date()
        lastPopoverCloseButton = currentPopoverButton
    }

    func detachableWindow(for popover: NSPopover) -> NSWindow? {
        // Stop monitoring for outside clicks when detaching
        stopMonitoringForOutsideClicks()

        // Use a controller without the popover's preferredContentSize options;
        // those constraints conflict with a detached window's content sizing.
        let contentView = PopoverContentView(
            manager: self,
            onRefresh: { [weak self] in
                self?.refreshUsage()
            },
            onPreferences: { [weak self] in
                self?.closePopoverOrWindow()
                self?.preferencesClicked()
            }
        )
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 600),
            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 280, height: 600))
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.isRestorable = false
        window.delegate = self
        window.backgroundColor = .clear

        // Store reference to the detached window
        detachedWindow = window

        return window
    }
}

// MARK: - StatusBarUIManagerDelegate
extension MenuBarManager: StatusBarUIManagerDelegate {
    func statusBarAppearanceDidChange() {
        // Safe from infinite loops: StatusBarUIManager's observer deduplicates by
        // appearance name, and setButtonImage() only assigns button.image when the
        // rendered CGImage data actually changes — so even if setting button.image
        // triggers effectiveAppearance KVO, the cycle stops immediately.
        cachedIsDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        cachedImageKey = ""
        updateAllStatusBarIcons()
    }
}

// MARK: - NSWindowDelegate
extension MenuBarManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            if window == settingsWindow {
                // Hide dock icon again when settings window closes
                NSApp.setActivationPolicy(.accessory)
                settingsWindow = nil
            } else if window == detachedWindow {
                // Clear detached window reference when closed
                detachedWindow = nil
            } else if window == githubPromptWindow {
                // Hide dock icon again when GitHub prompt window closes
                NSApp.setActivationPolicy(.accessory)
                githubPromptWindow = nil
            }
        }
    }
}
