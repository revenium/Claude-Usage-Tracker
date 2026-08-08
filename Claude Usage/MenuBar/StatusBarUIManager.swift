//
//  StatusBarUIManager.swift
//  Claude Usage
//
//  Created by Claude Code on 2025-12-27.
//

import Cocoa
import Combine
import UsageCore

/// Manages multiple menu bar status items for different metrics
final class StatusBarUIManager {
    // Fixed UUID used as the dictionary key for the "no profiles selected" placeholder item.
    // Using a constant instead of UUID() prevents a new random key on every call to setupMultiProfile.
    private static let multiProfileDefaultPlaceholderID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// Above this many selected profiles, individual status items collapse
    /// into one overflow item so the menu bar doesn't fill up. At exactly
    /// this count every profile still gets its own item.
    static let overflowThreshold = 4

    /// Stable identifier so menu-bar managers (Bartender, Ice, ...) can
    /// track the overflow item the same way they track every other item.
    static let overflowAutosaveName = "claude-usage-tracker.overflow"

    /// Splits `profiles` (already filtered to those selected for display)
    /// into the ones that get their own status item and the ones that
    /// collapse into the single overflow item, using the app's original
    /// fixed threshold. Equivalent to
    /// `splitForOverflow(profiles, threshold: overflowThreshold)`; kept as
    /// its own overload because it's still the shape most call sites and
    /// tests want.
    static func splitForOverflow(
        _ profiles: [Profile]
    ) -> (individual: [Profile], overflow: [Profile]) {
        splitForOverflow(profiles, threshold: overflowThreshold)
    }

    /// Splits `profiles` using an arbitrary threshold — the pure logic
    /// behind `MenuBarOverflowMode.afterCount(_:)`. Above `threshold`
    /// selected profiles, individual status items collapse into one
    /// overflow item; the number that keep their own item scales with the
    /// threshold the same way the original fixed `4`/`3` pair did (one
    /// fewer than the threshold), so a user-configured threshold behaves
    /// exactly like the built-in default did at `4`.
    static func splitForOverflow(
        _ profiles: [Profile],
        threshold: Int
    ) -> (individual: [Profile], overflow: [Profile]) {
        guard profiles.count > threshold else {
            return (profiles, [])
        }
        let individualLimit = max(threshold - 1, 0)
        return (
            Array(profiles.prefix(individualLimit)),
            Array(profiles.dropFirst(individualLimit))
        )
    }

    /// Splits `profiles` according to `mode`, the single entry point every
    /// production call site should use. `.automatic` needs `spaceInput` (a
    /// measurement of real menu bar space) and `currentCollapsedCount` (for
    /// hysteresis, see `MenuBarSpaceCalculator`); both are ignored by the
    /// other two modes. A `nil` `spaceInput` in `.automatic` mode (no screen
    /// available to measure against) falls back to never collapsing, rather
    /// than guessing — the manual modes exist for exactly this situation.
    static func overflowPlan(
        for profiles: [Profile],
        mode: MenuBarOverflowMode,
        currentCollapsedCount: Int,
        spaceInput: MenuBarLayoutInput?
    ) -> (individual: [Profile], overflow: [Profile]) {
        switch mode {
        case .never:
            return (profiles, [])
        case .afterCount(let threshold):
            return splitForOverflow(profiles, threshold: threshold)
        case .automatic:
            guard let spaceInput else {
                return (profiles, [])
            }
            let collapsedCount = MenuBarSpaceCalculator.collapsedCount(
                for: spaceInput,
                currentCollapsedCount: currentCollapsedCount
            )
            let individualCount = max(
                profiles.count - collapsedCount,
                0
            )
            return (
                Array(profiles.prefix(individualCount)),
                Array(profiles.dropFirst(individualCount))
            )
        }
    }

    // Stable provider-neutral metric identity prevents dynamic windows from
    // colliding with the legacy Claude session/week buckets.
    private var statusItems: [MenuBarMetricID: NSStatusItem] = [:]
    private var singleMetricOrder: [MenuBarMetricID] = []
    private var statusItemIdentities:
        [ObjectIdentifier: ProviderStatusItemIdentity] = [:]

    // Dictionary to hold status items keyed by profile ID (multi-profile mode)
    private var multiProfileStatusItems: [UUID: NSStatusItem] = [:]

    // Once more than `overflowThreshold` profiles are selected for
    // multi-profile display, `splitForOverflow` keeps only the first
    // `overflowThreshold - 1` individual (one fewer profile than the
    // threshold, so the "+N" item itself effectively takes the last slot);
    // the rest collapse into this single overflow item so the menu bar
    // doesn't fill up with one item per profile.
    private var overflowStatusItem: NSStatusItem?
    private(set) var overflowProfileIDs: [UUID] = []

    /// Governs how (and whether) excess profiles collapse into the overflow
    /// item. Defaults to the pre-existing fixed-threshold behavior so
    /// nothing changes for a caller (or a test) that never sets this
    /// explicitly; `MenuBarManager` is the production caller that reads the
    /// persisted user setting — which itself defaults to `.automatic` — and
    /// assigns it here before every layout recompute.
    var overflowMode: MenuBarOverflowMode = .afterCount(
        StatusBarUIManager.overflowThreshold
    )

    /// Supplies live screen/foreign-item measurements for `.automatic`
    /// mode. Injectable so tests can supply a fake without touching real
    /// AppKit or window-server state.
    var spaceProbe: MenuBarSpaceProbing = MenuBarSpaceProbe()

    /// Estimated width for a profile item that has no `NSStatusItem` yet
    /// (e.g. a profile just added to the selection), so `.automatic` mode
    /// has *something* to measure before the item's real window exists.
    /// Sized to this app's typical rendered icon width.
    static let estimatedProfileItemWidth: CGFloat = 40

    /// Fallback difference between a status item's window width and its
    /// image width, used only before `calibratedButtonPadding()` has ever
    /// found a real item to measure (e.g. the very first cold layout pass).
    static let fallbackButtonPadding: CGFloat = 6

    /// Last padding value `calibratedButtonPadding()` measured from a real
    /// status item, kept around so a later cold pass (no item currently has
    /// both a window and an image) can still use a real measurement instead
    /// of falling all the way back to `fallbackButtonPadding`.
    private var lastKnownButtonPadding: CGFloat?

    // Current display mode
    private var isMultiProfileMode: Bool = false

    private var appearanceObservers: [NSKeyValueObservation] = []
    private var appearanceDebounceTimer: Timer?

    // Image cache to avoid redundant button.image assignments (which trigger KVO)
    private var lastImageData: [ObjectIdentifier: Data] = [:]

    // Icon renderer for creating menu bar images
    private let renderer = MenuBarIconRenderer()

    weak var delegate: StatusBarUIManagerDelegate?

    // MARK: - Initialization

    init() {}

    /// Applies the exact left/right action wiring shared by every production
    /// status item. Keeping this in one place also lets the isolated native UI
    /// suite exercise the same AppKit event contract without creating a
    /// second menu implementation.
    static func configureActionButton(
        _ button: NSButton,
        target: AnyObject,
        action: Selector
    ) {
        button.action = action
        button.target = target
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    static func profileAccessibilityLabel(
        _ baseLabel: String,
        isActive: Bool
    ) -> String {
        String(
            format: ProviderUILocalization.text(
                isActive
                    ? "menubar.accessibility.profile.active"
                    : "menubar.accessibility.profile.inactive",
                fallback: isActive
                    ? "%@, active profile"
                    : "%@, inactive profile"
            ),
            baseLabel
        )
    }

    static func usageModeText(showRemaining: Bool) -> String {
        ProviderUILocalization.text(
            showRemaining
                ? "popover.normalized.value.remaining"
                : "popover.normalized.value.used",
            fallback: showRemaining ? "remaining" : "used"
        )
    }

    static func autosaveName(
        for metricID: MenuBarMetricID,
        isLegacyPlaceholder: Bool = false
    ) -> String {
        if isLegacyPlaceholder {
            return "claude-usage-tracker.session"
        }
        if let legacy = metricID.legacyMetricType {
            return "claude-usage-tracker.\(legacy.rawValue)"
        }
        return "claude-usage-tracker.metric.\(metricID.stableValue)"
    }

    static func desiredProviderMetricIDs(
        for presentation: ProviderMenuPresentation
    ) -> [MenuBarMetricID] {
        ProviderStatusItemReconciliation.singleEntries(
            for: presentation
        ).map(\.statusMetricID)
    }

    /// A dynamic status item must remain identifiable without relying on
    /// color or the optional long-name setting. Include the provider and
    /// selected window; qualify duplicate window names with their group.
    static func providerMetricVisualLabel(
        for metric: ProviderMetricPresentation?,
        in presentation: ProviderMenuPresentation,
        showLongProviderName: Bool
    ) -> String {
        let provider = showLongProviderName
            ? presentation.appearance.displayName
            : presentation.appearance.compactBadge
        guard let metric else { return provider }
        let hasDuplicateWindowName = presentation.metrics.contains {
            $0.id != metric.id
                && $0.descriptor.metricName
                    == metric.descriptor.metricName
        }
        let window = hasDuplicateWindowName
            ? "\(metric.descriptor.groupName)/"
                + metric.descriptor.metricName
            : metric.descriptor.metricName
        return "\(provider)·\(window)"
    }

    // MARK: - Setup

    /// Sets up status bar items based on configuration
    func setup(target: AnyObject, action: Selector, config: MenuBarIconConfiguration) {
        // Remove all existing items first
        cleanup()

        // Check if there are any enabled metrics
        if config.enabledMetrics.isEmpty {
            // No credentials/metrics - show default app logo
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            // Stable identifier so Bartender and similar tools can reliably track this item
            statusItem.autosaveName = Self.autosaveName(
                for: .claudeSession,
                isLegacyPlaceholder: true
            )
            // Override a persisted hidden state from a prior Command-drag.
            statusItem.isVisible = true

            if let button = statusItem.button {
                Self.configureActionButton(
                    button,
                    target: target,
                    action: action
                )
                // Set a temporary placeholder - will be updated with actual logo
                button.title = ""
            } else {
                LoggingService.shared.logWarning("Status bar button is nil - screens: \(NSScreen.screens.count)")
            }

            // Use a special key to identify the default icon
            statusItems[.claudeSession] = statusItem
            LoggingService.shared.logUIEvent("Status bar initialized with default app logo (no credentials)")
        } else {
            // Create status items for enabled metrics
            for metricConfig in config.enabledMetrics {
                let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                // Stable identifier so Bartender and similar tools can reliably track this item
                statusItem.autosaveName = Self.autosaveName(
                    for: metricConfig.metricID
                )
                statusItem.isVisible = true

                if let button = statusItem.button {
                    Self.configureActionButton(
                        button,
                        target: target,
                        action: action
                    )
                } else {
                    LoggingService.shared.logWarning(
                        "Status bar button is nil for "
                            + "\(metricConfig.metricID.stableValue) - "
                            + "screens: \(NSScreen.screens.count)"
                    )
                }

                statusItems[metricConfig.metricID] = statusItem
            }

            LoggingService.shared.logUIEvent("Status bar initialized with \(config.enabledMetrics.count) metrics")
        }
        singleMetricOrder = config.enabledMetrics.isEmpty
            ? [.claudeSession]
            : config.enabledMetrics.map(\.metricID)

        observeAppearanceChanges()
    }

    /// Updates status bar items based on new configuration (incremental approach)
    func updateConfiguration(target: AnyObject, action: Selector, config: MenuBarIconConfiguration) {
        // Determine what the new set of items should be
        let newMetricTypes: Set<MenuBarMetricID>
        if config.enabledMetrics.isEmpty {
            // No credentials/metrics - show default app logo using .session as placeholder
            newMetricTypes = [.claudeSession]
        } else {
            newMetricTypes = Set(config.enabledMetrics.map(\.metricID))
        }

        let currentMetricTypes = Set(statusItems.keys)

        // Step 1: Remove items that are no longer needed
        let itemsToRemove = currentMetricTypes.subtracting(newMetricTypes)
        for metricType in itemsToRemove {
            if let statusItem = statusItems[metricType] {
                if let button = statusItem.button {
                    lastImageData.removeValue(
                        forKey: ObjectIdentifier(button)
                    )
                    statusItemIdentities.removeValue(
                        forKey: ObjectIdentifier(button)
                    )
                    button.image = nil
                    button.action = nil
                    button.target = nil
                }
                NSStatusBar.system.removeStatusItem(statusItem)
                LoggingService.shared.logUIEvent(
                    "Removed status item for \(metricType.stableValue)"
                )
            }
            statusItems.removeValue(forKey: metricType)
        }

        // Step 2: Add items that are new
        let itemsToAdd = newMetricTypes.subtracting(currentMetricTypes)
        for metricType in itemsToAdd {
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            // Stable identifier so Bartender and similar tools can reliably track this item
            statusItem.autosaveName = Self.autosaveName(
                for: metricType,
                isLegacyPlaceholder:
                    config.enabledMetrics.isEmpty
                        && metricType == .claudeSession
            )
            statusItem.isVisible = true

            if let button = statusItem.button {
                Self.configureActionButton(
                    button,
                    target: target,
                    action: action
                )
                if metricType == .claudeSession {
                    // Default logo placeholder
                    button.title = ""
                }
            }

            statusItems[metricType] = statusItem
            LoggingService.shared.logUIEvent(
                "Created status item for \(metricType.stableValue)"
            )
        }

        // Step 3: Items that already exist don't need recreation, just keep them
        // Their images will be updated by updateAllButtons() or updateButton()
        singleMetricOrder = config.enabledMetrics.isEmpty
            ? [.claudeSession]
            : config.enabledMetrics.map(\.metricID)

        LoggingService.shared.logUIEvent("Status bar configuration updated: removed=\(itemsToRemove.count), added=\(itemsToAdd.count), kept=\(currentMetricTypes.intersection(newMetricTypes).count)")
    }

    /// Reconciles and renders a provider-neutral single-profile catalog.
    /// Dynamic metrics are keyed exclusively by `MenuBarMetricID`; the legacy
    /// `metricType` compatibility facade is intentionally not used here.
    func updateProviderSingle(
        presentation: ProviderMenuPresentation,
        target: AnyObject,
        action: Selector,
        config: MenuBarIconConfiguration
    ) {
        // A display-mode transition must remove the one-item-per-profile
        // collection before reconciling the one-item-per-metric collection.
        if isMultiProfileMode {
            cleanup()
        }
        isMultiProfileMode = false
        let desiredMetricIDs = presentation.metrics.map(\.id)
        let reconciledEntries =
            ProviderStatusItemReconciliation.singleEntries(
                for: presentation
            )
        let reconciledIDs = reconciledEntries.map(\.statusMetricID)
        let identities = Dictionary(
            uniqueKeysWithValues: reconciledEntries.map {
                ($0.statusMetricID, $0.identity)
            }
        )
        let desiredIDs = Set(reconciledIDs)
        let currentIDs = Set(statusItems.keys)

        for metricID in currentIDs.subtracting(desiredIDs) {
            guard let item = statusItems.removeValue(forKey: metricID)
            else { continue }
            if let button = item.button {
                lastImageData.removeValue(forKey: ObjectIdentifier(button))
                statusItemIdentities.removeValue(
                    forKey: ObjectIdentifier(button)
                )
                button.image = nil
                button.action = nil
                button.target = nil
            }
            NSStatusBar.system.removeStatusItem(item)
        }

        let idsToAdd = desiredIDs.subtracting(currentIDs)
        for metricID in reconciledIDs where idsToAdd.contains(metricID) {
            let item = NSStatusBar.system.statusItem(
                withLength: NSStatusItem.variableLength
            )
            item.autosaveName = desiredMetricIDs.isEmpty
                ? "claude-usage-tracker.provider."
                    + "\(presentation.identity.profileID.uuidString).default"
                : Self.autosaveName(for: metricID)
            item.isVisible = true
            if let button = item.button {
                Self.configureActionButton(
                    button,
                    target: target,
                    action: action
                )
            }
            statusItems[metricID] = item
        }
        singleMetricOrder = reconciledIDs

        for (index, metricID) in (
            reconciledIDs
        ).enumerated() {
            guard let item = statusItems[metricID],
                  let button = item.button else {
                continue
            }
            item.autosaveName = desiredMetricIDs.isEmpty
                ? "claude-usage-tracker.provider."
                    + "\(presentation.identity.profileID.uuidString).default"
                : Self.autosaveName(for: metricID)
            let metric = presentation.metrics.first { $0.id == metricID }
            statusItemIdentities[ObjectIdentifier(button)] =
                identities[metricID]
            let menuBarIsDark = button.effectiveAppearance.bestMatch(
                from: [.darkAqua, .aqua]
            ) == .darkAqua
            let metricConfig = metric.flatMap {
                config.config(for: $0.id)
            } ?? MetricIconConfig(
                metricID: metricID,
                isEnabled: metric != nil
            )
            let renderedImage = renderer.createProviderMetricImage(
                metric,
                appearance: presentation.appearance,
                metricConfig: metricConfig,
                globalConfig: config,
                isDarkMode: menuBarIsDark,
                showProviderLabel: true,
                visualLabel: Self.providerMetricVisualLabel(
                    for: metric,
                    in: presentation,
                    showLongProviderName: config.showIconNames
                ),
                placeholderState: presentation.state
            )
            let badgeStyle = ProfileManager.shared.providerBadgeStyle
            let image = renderer.applyProviderBadge(
                to: renderedImage,
                providerID: presentation.identity.providerID,
                style: badgeStyle,
                isDarkMode: menuBarIsDark
            )
            image.isTemplate = config.colorMode == .monochrome
                && !config.showPaceMarker
                && !badgeStyle.showsTint
            setButtonImage(button, image: image)
            let accessibility = metric?.accessibilityLabel
                ?? "\(presentation.appearance.displayName), "
                    + presentation.state.accessibilityText
            let activeAccessibility =
                Self.profileAccessibilityLabel(
                    accessibility,
                    isActive: true
                )
            button.setAccessibilityLabel(activeAccessibility)
            button.toolTip = activeAccessibility
            button.tag = index
        }

        if appearanceObservers.isEmpty {
            observeAppearanceChanges()
        }
    }

    /// Associates characterized legacy Claude status items with their captured
    /// profile identity without changing their renderer or pixel output.
    func bindLegacySingleProfile(_ profile: Profile) {
        for (metricID, statusItem) in statusItems {
            guard let button = statusItem.button else { continue }
            statusItemIdentities[ObjectIdentifier(button)] =
                ProviderStatusItemIdentity(
                    profileID: profile.id,
                    providerID: profile.providerID,
                    providerRevision: profile.providerRevision,
                    metricID: metricID
                )
        }
    }

    func statusIdentity(
        for sender: NSStatusBarButton?
    ) -> ProviderStatusItemIdentity? {
        guard let sender else { return nil }
        return statusItemIdentities[ObjectIdentifier(sender)]
    }

    func autosaveName(
        for sender: NSStatusBarButton?
    ) -> String? {
        guard let sender else { return nil }
        return statusItems.values.first {
            $0.button === sender
        }?.autosaveName
            ?? multiProfileStatusItems.values.first {
                $0.button === sender
            }?.autosaveName
            ?? (overflowStatusItem?.button === sender
                ? overflowStatusItem?.autosaveName
                : nil)
    }

    var orderedSingleButtonsForTesting: [NSStatusBarButton] {
        singleMetricOrder.compactMap {
            statusItems[$0]?.button
        }
    }

    func cleanup() {
        appearanceObservers.forEach { $0.invalidate() }
        appearanceObservers.removeAll()
        appearanceDebounceTimer?.invalidate()
        appearanceDebounceTimer = nil

        // Clean up single profile status items
        for (_, statusItem) in statusItems {
            // Clear button references first
            if let button = statusItem.button {
                button.image = nil
                button.action = nil
                button.target = nil
            }
            // Then remove from status bar
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItems.removeAll()
        singleMetricOrder.removeAll()
        statusItemIdentities.removeAll()

        // Clean up multi-profile status items
        for (_, statusItem) in multiProfileStatusItems {
            if let button = statusItem.button {
                button.image = nil
                button.action = nil
                button.target = nil
            }
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        multiProfileStatusItems.removeAll()

        // Clean up the overflow status item, if any
        if let overflowItem = overflowStatusItem {
            if let button = overflowItem.button {
                lastImageData.removeValue(forKey: ObjectIdentifier(button))
                button.image = nil
                button.action = nil
                button.target = nil
            }
            NSStatusBar.system.removeStatusItem(overflowItem)
        }
        overflowStatusItem = nil
        overflowProfileIDs.removeAll()

        isMultiProfileMode = false

        LoggingService.shared.logUIEvent("Status bar cleaned up")
    }

    // MARK: - Multi-Profile Mode

    /// Sets up status bar for multi-profile display mode
    func setupMultiProfile(profiles: [Profile], target: AnyObject, action: Selector) {
        // Clean up existing items
        cleanup()

        isMultiProfileMode = true

        // Filter to only profiles selected for display
        let selectedProfiles = profiles.filter {
            $0.isSelectedForDisplay && !$0.deletionInProgress
        }

        if selectedProfiles.isEmpty {
            // No profiles selected - show default logo
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            // Stable identifier so Bartender and similar tools can reliably track this item
            statusItem.autosaveName = "claude-usage-tracker.multi.default"
            statusItem.isVisible = true
            if let button = statusItem.button {
                Self.configureActionButton(
                    button,
                    target: target,
                    action: action
                )
                button.title = ""
            } else {
                LoggingService.shared.logWarning("Multi-profile status bar button is nil - screens: \(NSScreen.screens.count)")
            }
            // Use a fixed placeholder UUID (stable across calls) for the default logo item
            multiProfileStatusItems[Self.multiProfileDefaultPlaceholderID] = statusItem
            LoggingService.shared.logUIEvent("Multi-profile: No profiles selected, showing default logo")
        } else {
            // Above the overflow threshold, only the first few profiles get
            // their own status item; the rest collapse into one overflow
            // item (see `overflowPlan(for:mode:currentCollapsedCount:spaceInput:)`).
            let plan = currentOverflowPlan(for: selectedProfiles)

            // Create one status item per individually-shown profile
            for profile in plan.individual {
                let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                // Stable identifier so Bartender and similar tools can reliably track this item
                statusItem.autosaveName = "claude-usage-tracker.profile.\(profile.id.uuidString)"
                statusItem.isVisible = true

                if let button = statusItem.button {
                    Self.configureActionButton(
                        button,
                        target: target,
                        action: action
                    )
                } else {
                    LoggingService.shared.logWarning("Multi-profile status bar button is nil for \(profile.name) - screens: \(NSScreen.screens.count)")
                }

                multiProfileStatusItems[profile.id] = statusItem
                if let button = statusItem.button {
                    statusItemIdentities[ObjectIdentifier(button)] =
                        ProviderStatusItemIdentity(
                            profileID: profile.id,
                            providerID: profile.providerID,
                            providerRevision: profile.providerRevision,
                            metricID: nil
                        )
                }
            }

            updateOverflowItem(
                for: plan.overflow,
                target: target,
                action: action
            )

            LoggingService.shared.logUIEvent(
                "Multi-profile: Created \(plan.individual.count) status items"
                    + (plan.overflow.isEmpty
                        ? ""
                        : " + overflow item (\(plan.overflow.count))")
            )
        }

        observeAppearanceChanges()
    }

    /// Updates the selected multi-profile status items without recreating retained items.
    /// This preserves macOS item identity and the ordering remembered by menu-bar tools.
    func updateMultiProfileConfiguration(profiles: [Profile], target: AnyObject, action: Selector) {
        guard isMultiProfileMode else {
            setupMultiProfile(profiles: profiles, target: target, action: action)
            return
        }

        let selectedProfiles = profiles.filter {
            $0.isSelectedForDisplay && !$0.deletionInProgress
        }
        let plan = currentOverflowPlan(for: selectedProfiles)
        let desiredIDs: Set<UUID> = selectedProfiles.isEmpty
            ? [Self.multiProfileDefaultPlaceholderID]
            : Set(plan.individual.map(\.id))
        let currentIDs = Set(multiProfileStatusItems.keys)

        let idsToRemove = currentIDs.subtracting(desiredIDs)
        for profileID in idsToRemove {
            if let statusItem = multiProfileStatusItems.removeValue(forKey: profileID) {
                if let button = statusItem.button {
                    lastImageData.removeValue(forKey: ObjectIdentifier(button))
                    statusItemIdentities.removeValue(
                        forKey: ObjectIdentifier(button)
                    )
                    button.image = nil
                    button.action = nil
                    button.target = nil
                }
                NSStatusBar.system.removeStatusItem(statusItem)
                LoggingService.shared.logUIEvent("Multi-profile: Removed status item for \(profileID)")
            }
        }

        let idsToAdd = desiredIDs.subtracting(currentIDs)
        if selectedProfiles.isEmpty, idsToAdd.contains(Self.multiProfileDefaultPlaceholderID) {
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.autosaveName = "claude-usage-tracker.multi.default"
            statusItem.isVisible = true
            if let button = statusItem.button {
                Self.configureActionButton(
                    button,
                    target: target,
                    action: action
                )
                button.title = ""
            }
            multiProfileStatusItems[Self.multiProfileDefaultPlaceholderID] = statusItem
            LoggingService.shared.logUIEvent("Multi-profile: Added default logo status item")
        } else {
            // Preserve profile order for first-time additions while retaining existing item identity.
            for profile in plan.individual where idsToAdd.contains(profile.id) {
                let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                statusItem.autosaveName = "claude-usage-tracker.profile.\(profile.id.uuidString)"
                statusItem.isVisible = true
                if let button = statusItem.button {
                    Self.configureActionButton(
                        button,
                        target: target,
                        action: action
                    )
                }
                multiProfileStatusItems[profile.id] = statusItem
                if let button = statusItem.button {
                    statusItemIdentities[ObjectIdentifier(button)] =
                        ProviderStatusItemIdentity(
                            profileID: profile.id,
                            providerID: profile.providerID,
                            providerRevision: profile.providerRevision,
                            metricID: nil
                        )
                }
                LoggingService.shared.logUIEvent("Multi-profile: Added status item for \(profile.name)")
            }
        }

        updateOverflowItem(
            for: plan.overflow,
            target: target,
            action: action
        )

        LoggingService.shared.logUIEvent(
            "Multi-profile config updated: removed=\(idsToRemove.count), added=\(idsToAdd.count), kept=\(currentIDs.intersection(desiredIDs).count)"
        )
    }

    /// Computes the individual/overflow split for `selectedProfiles`
    /// according to `overflowMode`, measuring current item widths via
    /// `spaceProbe` when `.automatic` is in effect. `.never` and
    /// `.afterCount` never touch the probe at all.
    private func currentOverflowPlan(
        for selectedProfiles: [Profile]
    ) -> (individual: [Profile], overflow: [Profile]) {
        let spaceInput: MenuBarLayoutInput?
        if case .automatic = overflowMode {
            let config = ProfileManager.shared.multiProfileConfig
            let activeProfileId = ProfileManager.shared.activeClaudeProfileID
            let ourItemWidths = selectedProfiles.map { profile -> CGFloat in
                guard profile.providerID == .claude else {
                    return itemWidth(for: multiProfileStatusItems[profile.id])
                        ?? Self.estimatedProfileItemWidth
                }
                return intendedItemWidth(
                    for: profile,
                    config: config,
                    isActive: profile.id == activeProfileId
                )
            }
            let overflowWidth = itemWidth(for: overflowStatusItem)
                ?? Self.estimatedProfileItemWidth
            // Only items ALREADY on the menu bar are baked into the status
            // region the probe is about to measure, so only those are added
            // back. `itemWidth(for:)` returning nil means "not rendered
            // yet" — an estimate must NOT be substituted here, or we would
            // credit ourselves space we do not occupy. See
            // `MenuBarLayoutInput.currentlyOnScreenWidth`.
            let currentlyOnScreenWidth =
                multiProfileStatusItems.values
                    .compactMap { itemWidth(for: $0) }
                    .reduce(0, +)
                + (itemWidth(for: overflowStatusItem) ?? 0)
            spaceInput = spaceProbe.makeLayoutInput(
                ourItemWidths: ourItemWidths,
                overflowItemWidth: overflowWidth,
                currentlyOnScreenWidth: currentlyOnScreenWidth
            )
        } else {
            spaceInput = nil
        }
        return Self.overflowPlan(
            for: selectedProfiles,
            mode: overflowMode,
            currentCollapsedCount: overflowProfileIDs.count,
            spaceInput: spaceInput
        )
    }

    /// The real, measured width of `item`'s button window, or its rendered
    /// image's width as a fallback for the brief window before AppKit
    /// finishes laying the button's own window out. `nil` when neither is
    /// available (most commonly: `item` is `nil`, because no status item
    /// has been created yet for that profile).
    private func itemWidth(for item: NSStatusItem?) -> CGFloat? {
        guard let button = item?.button else { return nil }
        if let window = button.window, window.frame.width > 0 {
            return window.frame.width
        }
        if let image = button.image {
            return image.size.width
        }
        return nil
    }

    /// Difference between a status item button's window width and the width
    /// of the image inside it. Calibrated from a real rendered item rather
    /// than hardcoded, so it stays correct if AppKit's status item metrics
    /// change. Scans every current profile item plus the overflow item for
    /// one that has both a laid-out window and an image; caches the last
    /// good value so a later cold pass (nothing currently qualifies) can
    /// still use a real measurement instead of `Self.fallbackButtonPadding`.
    func calibratedButtonPadding() -> CGFloat? {
        let candidates = Array(multiProfileStatusItems.values)
            + [overflowStatusItem].compactMap { $0 }
        for item in candidates {
            guard let button = item.button,
                  let window = button.window,
                  window.frame.width > 0,
                  let image = button.image else {
                continue
            }
            let padding = window.frame.width - image.size.width
            guard padding >= 0 else { continue }
            lastKnownButtonPadding = padding
            return padding
        }
        return lastKnownButtonPadding
    }

    /// The width a profile's status item WILL have once rendered with
    /// `config`, computed by calling the same rendering code the paint path
    /// (`updateMultiProfileButtons`/`renderProfileMenuBar`) uses — rather
    /// than reusing the previous render's measured width (one render
    /// behind) or a hardcoded estimate (off by −65% to +32% across real
    /// configs). Used only to plan the overflow split before a profile's
    /// status item necessarily exists yet.
    func intendedItemWidth(
        for profile: Profile,
        config: MultiProfileDisplayConfig,
        isActive: Bool
    ) -> CGFloat {
        // isDarkMode is always false here: light and dark render identically
        // at 34.5pt for the same config, since appearance only changes
        // colour, not geometry — verified against `renderProfileMenuBar`.
        let render = renderProfileMenuBar(
            for: profile,
            config: config,
            isDarkMode: false,
            isActive: isActive
        )
        return render.image.size.width
            + (calibratedButtonPadding() ?? Self.fallbackButtonPadding)
    }

    /// Reconciles the single overflow status item against the profiles
    /// that should currently collapse into it. Creates the item the first
    /// time there's overflow, removes it once there no longer is, and
    /// otherwise reuses the existing item (preserving its on-screen
    /// position) while refreshing its badge count and the profile list it
    /// represents.
    private func updateOverflowItem(
        for overflowProfiles: [Profile],
        target: AnyObject,
        action: Selector
    ) {
        guard !overflowProfiles.isEmpty else {
            guard let item = overflowStatusItem else {
                overflowProfileIDs = []
                return
            }
            if let button = item.button {
                lastImageData.removeValue(forKey: ObjectIdentifier(button))
                button.image = nil
                button.action = nil
                button.target = nil
            }
            NSStatusBar.system.removeStatusItem(item)
            overflowStatusItem = nil
            overflowProfileIDs = []
            LoggingService.shared.logUIEvent(
                "Multi-profile: Removed overflow status item"
            )
            return
        }

        overflowProfileIDs = overflowProfiles.map(\.id)

        if overflowStatusItem == nil {
            let item = NSStatusBar.system.statusItem(
                withLength: NSStatusItem.variableLength
            )
            item.autosaveName = Self.overflowAutosaveName
            item.isVisible = true
            if let button = item.button {
                Self.configureActionButton(
                    button,
                    target: target,
                    action: action
                )
            }
            overflowStatusItem = item
        }

        renderOverflowBadge(count: overflowProfiles.count)
    }

    /// Draws the "+N" badge for the overflow item directly, rather than
    /// routing through `MenuBarIconRenderer`'s much larger per-metric icon
    /// surface for one small combined-count glyph. Follows the same
    /// nil-safe font handling used throughout this app's icon drawing:
    /// `NSFont` factory methods are declared non-optional but can
    /// transiently bridge back `nil`, so both the preferred and the
    /// fallback font are captured through an explicit `NSFont?` before use
    /// — never insert a nil font into an attributes dictionary.
    private func renderOverflowBadge(count: Int) {
        guard let button = overflowStatusItem?.button else { return }
        let menuBarIsDark = button.effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua]
        ) == .darkAqua
        let foreground: NSColor = menuBarIsDark ? .white : .black
        let text = "+\(count)" as NSString

        let preferredFont: NSFont? = NSFont.monospacedDigitSystemFont(
            ofSize: 11,
            weight: .semibold
        )
        let fallbackFont: NSFont? = NSFont.systemFont(ofSize: 11)
        let image: NSImage
        if let font = preferredFont ?? fallbackFont {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: foreground
            ]
            let textSize = text.size(withAttributes: attributes)
            image = NSImage(
                size: NSSize(width: textSize.width + 6, height: 18)
            )
            image.lockFocus()
            text.draw(
                at: NSPoint(x: 3, y: (18 - textSize.height) / 2),
                withAttributes: attributes
            )
            image.unlockFocus()
        } else {
            // Even the system-font fallback is unavailable; skip the
            // glyph rather than crash rendering an unlabeled badge.
            image = NSImage(size: NSSize(width: 18, height: 18))
        }
        image.isTemplate = false
        setButtonImage(button, image: image)

        let label = String(
            format: ProviderUILocalization.text(
                "menubar.overflow.accessibility_label",
                fallback: "%@ more profiles"
            ),
            "\(count)"
        )
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    /// True when `sender` is the overflow status item's button — the "+N"
    /// item representing every profile past the first `overflowThreshold - 1`
    /// that `splitForOverflow` keeps individual.
    func isOverflowButton(_ sender: NSStatusBarButton?) -> Bool {
        guard let sender else { return false }
        return overflowStatusItem?.button === sender
    }

    /// The overflow status item's button, if it currently exists (used to
    /// position the overflow profile list popover).
    var overflowButton: NSStatusBarButton? {
        overflowStatusItem?.button
    }

    /// Adds a thin green underline to an image to indicate the active profile.
    /// The canvas is 2pts taller than the source so the icon shifted up by 2pts is
    /// not clipped. A 1.5pt rounded underline, inset 1pt per side, sits at the bottom.
    private func addGreenUnderline(to image: NSImage) -> NSImage {
        let newSize = NSSize(width: image.size.width, height: image.size.height + 2)
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        defer { newImage.unlockFocus() }
        // Draw source image shifted up by 2pts (creating a gap above the underline).
        // NSRect.zero passed as `from:` is AppKit's sentinel meaning "draw entire image".
        image.draw(at: NSPoint(x: 0, y: 2), from: NSRect(origin: .zero, size: image.size), operation: .copy, fraction: 1.0)
        NSColor.systemGreen.setFill()
        let underlineRect = NSRect(x: 1, y: 0, width: image.size.width - 2, height: 1.5)
        NSBezierPath(roundedRect: underlineRect, xRadius: 0.75, yRadius: 0.75).fill()
        return newImage
    }

    /// The rendered menu bar image for one profile, plus the session values
    /// needed to build its accessibility label. Returned together so the
    /// image and the label built from it can never drift apart.
    struct ProfileMenuBarRender {
        let image: NSImage
        let sessionDisplay: Double
        let showRemaining: Bool
    }

    /// Builds the exact image `updateMultiProfileButtons` paints for one
    /// profile's status item — usage percentages, statuses, time/pace
    /// markers, the icon-style-specific render, the provider badge, and the
    /// active-profile underline — without touching any button. Shared by
    /// the paint path and `intendedItemWidth(for:config:isActive:)`, which
    /// needs the same image's width before its status item exists, so the
    /// overflow-space calculation is never a render behind reality.
    func renderProfileMenuBar(
        for profile: Profile,
        config: MultiProfileDisplayConfig,
        isDarkMode: Bool,
        isActive: Bool
    ) -> ProfileMenuBarRender {
        // Get usage data for this profile
        let usage = profile.claudeUsage ?? ClaudeUsage.empty
        let showRemaining = config.showRemainingPercentage

        // Calculate percentages
        let sessionUsed = usage.effectiveSessionPercentage
        let weekUsed = usage.weeklyPercentage

        let sessionDisplay = UsageStatusCalculator.getDisplayPercentage(
            usedPercentage: sessionUsed,
            showRemaining: showRemaining
        )
        let weekDisplay = UsageStatusCalculator.getDisplayPercentage(
            usedPercentage: weekUsed,
            showRemaining: showRemaining
        )

        let sessionElapsed = UsageStatusCalculator.elapsedFraction(
            resetTime: usage.sessionResetTime,
            duration: Constants.sessionWindow,
            showRemaining: false
        )
        let weekElapsed = UsageStatusCalculator.elapsedFraction(
            resetTime: usage.weeklyResetTime,
            duration: Constants.weeklyWindow,
            showRemaining: false
        )
        let sessionStatus = UsageStatusCalculator.calculateStatus(
            usedPercentage: sessionUsed,
            showRemaining: showRemaining,
            elapsedFraction: config.usePaceColoring ? sessionElapsed : nil
        )
        let weekStatus = UsageStatusCalculator.calculateStatus(
            usedPercentage: weekUsed,
            showRemaining: showRemaining,
            elapsedFraction: config.usePaceColoring ? weekElapsed : nil
        )

        // Use multi-profile config's useSystemColor as monochrome mode
        // When useSystemColor is ON, icons will be white (like single-profile monochrome)
        let useMonochrome = config.useSystemColor

        // Calculate time marker fractions for multi-profile display
        let sessionMarker: CGFloat? = config.showTimeMarker
            ? sessionElapsed.map { CGFloat(showRemaining ? 1.0 - $0 : $0) }
            : nil
        let weekMarker: CGFloat? = config.showTimeMarker
            ? weekElapsed.map { CGFloat(showRemaining ? 1.0 - $0 : $0) }
            : nil

        // Compute pace status for multi-profile rendering
        let sessionPaceStatus: PaceStatus? = {
            guard config.showPaceMarker, let elapsed = sessionElapsed else { return nil }
            return PaceStatus.calculate(usedPercentage: sessionUsed, elapsedFraction: elapsed)
        }()
        let weekPaceStatus: PaceStatus? = {
            guard config.showPaceMarker, let elapsed = weekElapsed else { return nil }
            return PaceStatus.calculate(usedPercentage: weekUsed, elapsedFraction: elapsed)
        }()

        // Create icon based on selected style
        let image: NSImage
        switch config.iconStyle {
        case .concentric:
            if config.showProfileLabel {
                image = renderer.createConcentricIconWithLabel(
                    sessionPercentage: sessionDisplay,
                    weekPercentage: config.showWeek ? weekDisplay : 0,
                    sessionStatus: sessionStatus,
                    weekStatus: weekStatus,
                    profileName: profile.name,
                    monochromeMode: useMonochrome,
                    isDarkMode: isDarkMode,
                    useSystemColor: false,
                    sessionTimeMarker: sessionMarker,
                    weekTimeMarker: config.showWeek ? weekMarker : nil,
                    sessionPaceStatus: sessionPaceStatus,
                    weekPaceStatus: config.showWeek ? weekPaceStatus : nil,
                    showPaceMarker: config.showPaceMarker
                )
            } else {
                image = renderer.createConcentricIcon(
                    sessionPercentage: sessionDisplay,
                    weekPercentage: config.showWeek ? weekDisplay : 0,
                    sessionStatus: sessionStatus,
                    weekStatus: weekStatus,
                    profileInitial: String(profile.name.prefix(1)),
                    monochromeMode: useMonochrome,
                    isDarkMode: isDarkMode,
                    useSystemColor: false,
                    sessionTimeMarker: sessionMarker,
                    weekTimeMarker: config.showWeek ? weekMarker : nil,
                    sessionPaceStatus: sessionPaceStatus,
                    weekPaceStatus: config.showWeek ? weekPaceStatus : nil,
                    showPaceMarker: config.showPaceMarker
                )
            }
        case .progressBar:
            image = renderer.createMultiProfileProgressBar(
                sessionPercentage: sessionDisplay,
                weekPercentage: config.showWeek ? weekDisplay : nil,
                sessionStatus: sessionStatus,
                weekStatus: weekStatus,
                profileName: config.showProfileLabel ? profile.name : nil,
                monochromeMode: useMonochrome,
                isDarkMode: isDarkMode,
                useSystemColor: false,
                sessionTimeMarker: sessionMarker,
                weekTimeMarker: config.showWeek ? weekMarker : nil,
                sessionPaceStatus: sessionPaceStatus,
                weekPaceStatus: config.showWeek ? weekPaceStatus : nil,
                showPaceMarker: config.showPaceMarker
            )
        case .compact:
            image = renderer.createCompactDot(
                percentage: sessionDisplay,
                status: sessionStatus,
                profileInitial: config.showProfileLabel ? String(profile.name.prefix(1)) : nil,
                monochromeMode: useMonochrome,
                isDarkMode: isDarkMode,
                useSystemColor: false,
                paceStatus: sessionPaceStatus,
                showPaceMarker: config.showPaceMarker
            )
        case .percentage:
            image = renderer.createMultiProfilePercentage(
                sessionPercentage: sessionDisplay,
                weekPercentage: config.showWeek ? weekDisplay : nil,
                sessionStatus: sessionStatus,
                weekStatus: weekStatus,
                profileName: config.showProfileLabel ? profile.name : nil,
                monochromeMode: useMonochrome,
                isDarkMode: isDarkMode,
                useSystemColor: false,
                sessionPaceStatus: sessionPaceStatus,
                weekPaceStatus: config.showWeek ? weekPaceStatus : nil,
                showPaceMarker: config.showPaceMarker
            )
        }

        let badgeStyle = ProfileManager.shared.providerBadgeStyle
        let badgedImage = renderer.applyProviderBadge(
            to: image,
            providerID: .claude,
            style: badgeStyle,
            isDarkMode: isDarkMode
        )

        let finalImage: NSImage
        if isActive {
            let underlinedImage = addGreenUnderline(to: badgedImage)
            underlinedImage.isTemplate = false
            finalImage = underlinedImage
        } else {
            badgedImage.isTemplate = useMonochrome
                && !config.showPaceMarker
                && !badgeStyle.showsTint
            finalImage = badgedImage
        }

        return ProfileMenuBarRender(
            image: finalImage,
            sessionDisplay: sessionDisplay,
            showRemaining: showRemaining
        )
    }

    /// Updates all multi-profile status items
    func updateMultiProfileButtons(profiles: [Profile], config: MultiProfileDisplayConfig, activeProfileId: UUID? = nil) {
        guard isMultiProfileMode else { return }

        for profile in profiles
        where profile.isSelectedForDisplay
            && profile.providerID == .claude {
            guard let statusItem = multiProfileStatusItems[profile.id],
                  let button = statusItem.button else {
                continue
            }

            // Get actual menu bar appearance from the button (based on wallpaper, not system mode)
            let menuBarIsDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let isActive = profile.id == activeProfileId

            let render = renderProfileMenuBar(
                for: profile,
                config: config,
                isDarkMode: menuBarIsDark,
                isActive: isActive
            )
            button.image = render.image
            statusItemIdentities[ObjectIdentifier(button)] =
                ProviderStatusItemIdentity(
                    profileID: profile.id,
                    providerID: profile.providerID,
                    providerRevision: profile.providerRevision,
                    metricID: nil
                )
            let appearance = ProviderAppearance.forProvider(
                profile.providerID
            )
            let baseLabel = "\(appearance.displayName), \(profile.name), "
                + "\(Int(render.sessionDisplay.rounded()))% "
                + Self.usageModeText(showRemaining: render.showRemaining)
            let label = Self.profileAccessibilityLabel(
                baseLabel,
                isActive: isActive
            )
            button.setAccessibilityLabel(label)
            button.toolTip = label
        }
    }

    /// Resolves the up-to-two rendered metrics (primary/secondary window)
    /// shown by the shared compact two-row percentage icon, so the image
    /// renderer and the accessibility label are always built from the same
    /// data instead of drifting apart.
    static func compactPercentageMetrics(
        presentation: ProviderMenuPresentation,
        config: MultiProfileDisplayConfig
    ) -> (
        primary: ProviderMetricPresentation?,
        secondary: ProviderMetricPresentation?
    ) {
        let rendered = presentation.metrics.prefix(2).map {
            ProviderMenuPresentationBuilder.metric($0, applying: config)
        }
        let primary = rendered.first ?? nil
        let secondary = config.showWeek && rendered.count > 1 ? rendered[1] : nil
        return (primary, secondary)
    }

    /// Renders the shared compact two-row percentage image (top row: up to
    /// two window percentages separated by a dimmed " · "; bottom row: a
    /// 3-char profile label) for any provider's multi-profile status item.
    /// Claude's own `.percentage` style already calls the same renderer
    /// method directly from `updateMultiProfileButtons`.
    private static func compactPercentageImage(
        renderer: MenuBarIconRenderer,
        presentation: ProviderMenuPresentation,
        config: MultiProfileDisplayConfig,
        isDarkMode: Bool
    ) -> NSImage {
        let (primary, secondary) = compactPercentageMetrics(
            presentation: presentation,
            config: config
        )

        func paceStatus(
            for metric: ProviderMetricPresentation?
        ) -> PaceStatus? {
            guard config.showPaceMarker,
                  let metric,
                  let elapsed = metric.elapsedFraction,
                  let used = metric.usedPercentage else {
                return nil
            }
            return PaceStatus.calculate(
                usedPercentage: used,
                elapsedFraction: elapsed
            )
        }

        return renderer.createMultiProfilePercentage(
            sessionPercentage: primary?.displayedPercentage,
            weekPercentage: secondary?.displayedPercentage,
            sessionStatus: primary?.statusLevel ?? .safe,
            weekStatus: secondary?.statusLevel ?? .safe,
            profileName: config.showProfileLabel
                ? presentation.profileName
                : nil,
            monochromeMode: config.useSystemColor,
            isDarkMode: isDarkMode,
            useSystemColor: false,
            sessionPaceStatus: paceStatus(for: primary),
            weekPaceStatus: paceStatus(for: secondary),
            showPaceMarker: config.showPaceMarker
        )
    }

    /// Accessibility label for the compact two-row percentage icon. The icon
    /// packs up to two windows (e.g. session + weekly) into one image, but a
    /// label built from only the primary metric silently drops the second
    /// window from VoiceOver. Describe every window the icon actually shows.
    static func compactPercentageAccessibilityLabel(
        presentation: ProviderMenuPresentation,
        config: MultiProfileDisplayConfig
    ) -> String {
        let (primary, secondary) = compactPercentageMetrics(
            presentation: presentation,
            config: config
        )
        let parts = [primary, secondary].compactMap {
            metric -> String? in
            guard let metric else { return nil }
            let stateSuffix = metric.state == .ready
                ? ""
                : ", \(metric.state.accessibilityText)"
            return "\(metric.descriptor.metricName), "
                + "\(metric.percentageText) \(metric.modeText)"
                + stateSuffix
        }
        guard !parts.isEmpty else {
            return "\(presentation.appearance.displayName), "
                + presentation.state.accessibilityText
        }
        return "\(presentation.appearance.displayName), "
            + parts.joined(separator: ", ")
    }

    /// Overrides non-Claude multi-profile buttons with provider-neutral
    /// dynamic metrics while leaving characterized Claude icons untouched.
    /// `isActive` is resolved per-profile (via `ProfileManager.isActive(_:)`)
    /// since this spans both providers' independent active slots.
    func updateProviderMultiProfileButtons(
        presentations: [ProviderMenuPresentation],
        profiles: [Profile],
        config: MultiProfileDisplayConfig,
        activeClaudeProfileID: UUID?,
        isActive: (Profile) -> Bool
    ) {
        updateMultiProfileButtons(
            profiles: profiles,
            config: config,
            activeProfileId: activeClaudeProfileID
        )
        for presentation in presentations
        where presentation.identity.providerID != .claude {
            guard let item =
                    multiProfileStatusItems[presentation.identity.profileID],
                  let button = item.button else {
                continue
            }
            let menuBarIsDark = button.effectiveAppearance.bestMatch(
                from: [.darkAqua, .aqua]
            ) == .darkAqua
            let profile = profiles.first {
                $0.id == presentation.identity.profileID
            }
            var iconConfig = profile?.iconConfig.adaptedForProvider(
                presentation.identity.providerID
            ) ?? .default(
                for: presentation.identity.providerID
            )
            iconConfig.colorMode = config.useSystemColor
                ? .monochrome
                : .multiColor
            iconConfig.showRemainingPercentage =
                config.showRemainingPercentage
            iconConfig.showTimeMarker = config.showTimeMarker
            iconConfig.showPaceMarker = config.showPaceMarker
            iconConfig.usePaceColoring = config.usePaceColoring

            let image: NSImage
            if config.iconStyle == .percentage {
                // Compact two-row form shared with Claude: pack up to two
                // windows' integer percentages into one image per profile
                // instead of a single metric. Window display names stay
                // popover-only here, matching the Claude rendering this
                // mirrors.
                image = Self.compactPercentageImage(
                    renderer: renderer,
                    presentation: presentation,
                    config: config,
                    isDarkMode: menuBarIsDark
                )
            } else {
                let renderedMetric =
                    ProviderMenuPresentationBuilder.metric(
                        presentation.metric,
                        applying: config
                    )
                var metricConfig = renderedMetric.flatMap {
                    iconConfig.config(for: $0.id)
                } ?? MetricIconConfig(
                    metricID: renderedMetric?.id
                        ?? .providerPlaceholder(
                            presentation.identity.providerID
                        ),
                    isEnabled: renderedMetric != nil
                )
                switch config.iconStyle {
                case .concentric:
                    metricConfig.iconStyle = .icon
                case .progressBar:
                    metricConfig.iconStyle = .progressBar
                case .compact:
                    metricConfig.iconStyle = .compact
                case .percentage:
                    metricConfig.iconStyle = .percentageOnly
                }
                let profileInitial = config.showProfileLabel
                    ? String(presentation.profileName.prefix(1))
                        .uppercased()
                    : ""
                let renderAppearance = ProviderAppearance(
                    providerID: presentation.appearance.providerID,
                    displayName: presentation.appearance.displayName,
                    compactBadge:
                        presentation.appearance.compactBadge
                            + profileInitial,
                    symbolName: presentation.appearance.symbolName
                )
                let baseVisualLabel = Self.providerMetricVisualLabel(
                    for: renderedMetric,
                    in: presentation,
                    showLongProviderName: false
                )
                let visualLabel = profileInitial.isEmpty
                    ? baseVisualLabel
                    : baseVisualLabel.replacingOccurrences(
                        of: presentation.appearance.compactBadge,
                        with: presentation.appearance.compactBadge
                            + profileInitial,
                        options: [.anchored]
                    )
                image = renderer.createProviderMetricImage(
                    renderedMetric,
                    appearance: renderAppearance,
                    metricConfig: metricConfig,
                    globalConfig: iconConfig,
                    isDarkMode: menuBarIsDark,
                    showProviderLabel: true,
                    visualLabel: visualLabel,
                    placeholderState: presentation.state
                )
            }
            let badgeStyle = ProfileManager.shared.providerBadgeStyle
            let badgedImage = renderer.applyProviderBadge(
                to: image,
                providerID: presentation.identity.providerID,
                style: badgeStyle,
                isDarkMode: menuBarIsDark
            )
            badgedImage.isTemplate = config.useSystemColor
                && !iconConfig.showPaceMarker
                && !badgeStyle.showsTint
            if let profile, isActive(profile) {
                let underlined = addGreenUnderline(to: badgedImage)
                underlined.isTemplate = false
                setButtonImage(button, image: underlined)
            } else {
                setButtonImage(button, image: badgedImage)
            }
            statusItemIdentities[ObjectIdentifier(button)] =
                ProviderStatusItemReconciliation.multiIdentity(
                    for: presentation
                )
            let baseLabel = "\(presentation.profileName), "
                + (config.iconStyle == .percentage
                    ? Self.compactPercentageAccessibilityLabel(
                        presentation: presentation,
                        config: config
                    )
                    : presentation.metric?.accessibilityLabel
                        ?? "\(presentation.appearance.displayName), "
                            + presentation.state.accessibilityText)
            let label = Self.profileAccessibilityLabel(
                baseLabel,
                isActive: profile.map(isActive) ?? false
            )
            button.setAccessibilityLabel(label)
            button.toolTip = label
        }
    }

    /// Checks if currently in multi-profile mode
    var isInMultiProfileMode: Bool {
        return isMultiProfileMode
    }

    /// Checks if status bar has at least one valid button (for headless mode detection)
    var hasValidStatusBar: Bool {
        // Check single-profile status items
        for (_, statusItem) in statusItems {
            if statusItem.button != nil {
                return true
            }
        }
        // Check multi-profile status items
        for (_, statusItem) in multiProfileStatusItems {
            if statusItem.button != nil {
                return true
            }
        }
        if overflowStatusItem?.button != nil {
            return true
        }
        return false
    }

    /// Get button for a specific profile (multi-profile mode)
    func button(for profileId: UUID) -> NSStatusBarButton? {
        return multiProfileStatusItems[profileId]?.button
    }

    /// Find which profile ID owns the given button (multi-profile mode)
    func profileId(for sender: NSStatusBarButton?) -> UUID? {
        guard let sender = sender else { return nil }

        for (profileId, statusItem) in multiProfileStatusItems {
            if statusItem.button === sender {
                return profileId
            }
        }
        return nil
    }

    // MARK: - UI Updates

    /// Updates all status bar buttons based on current usage data
    func updateAllButtons(
        usage: ClaudeUsage,
        apiUsage: APIUsage?
    ) {
        // Get config from active profile
        let profile = ProfileManager.shared.activeClaudeProfile
        let config = profile?.iconConfig ?? .default

        // Check if we should show default logo (no usage credentials OR no enabled metrics)
        let hasUsageCredentials = profile?.hasUsageCredentials ?? false
        if !hasUsageCredentials || config.enabledMetrics.isEmpty {
            // Show default app logo
            if let statusItem = statusItems[.claudeSession],
               let button = statusItem.button {
                // Get actual menu bar appearance from the button
                let menuBarIsDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let logoImage = renderer.createDefaultAppLogo(isDarkMode: menuBarIsDark)
                logoImage.isTemplate = true  // Let macOS handle the color
                setButtonImage(button, image: logoImage)
            }
            return
        }

        // Normal metric display
        for metricConfig in config.enabledMetrics {
            guard let statusItem = statusItems[metricConfig.metricID],
                  let button = statusItem.button else {
                continue
            }

            // Get actual menu bar appearance from the button
            let menuBarIsDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

            // Create image directly using our renderer
            let renderedImage = renderer.createImage(
                for: metricConfig.metricType,
                config: metricConfig,
                globalConfig: config,
                usage: usage,
                apiUsage: apiUsage,
                isDarkMode: menuBarIsDark,
                colorMode: config.colorMode,
                singleColorHex: config.singleColorHex,
                showIconName: config.showIconNames,
                showNextSessionTime: metricConfig.showNextSessionTime
            )

            let badgeStyle = ProfileManager.shared.providerBadgeStyle
            let image = renderer.applyProviderBadge(
                to: renderedImage,
                providerID: .claude,
                style: badgeStyle,
                isDarkMode: menuBarIsDark
            )
            image.isTemplate = config.colorMode == .monochrome
                && !config.showPaceMarker
                && !badgeStyle.showsTint
            button.image = image
        }
    }

    /// Updates a specific metric's button
    func updateButton(
        for metricType: MenuBarMetricType,
        usage: ClaudeUsage,
        apiUsage: APIUsage?
    ) {
        let metricID: MenuBarMetricID
        switch metricType {
        case .session: metricID = .claudeSession
        case .week: metricID = .claudeWeek
        case .api: metricID = .claudeAPI
        }
        guard let statusItem = statusItems[metricID],
              let button = statusItem.button else {
            return
        }

        // Get config from active profile
        let config = ProfileManager.shared.activeClaudeProfile?.iconConfig ?? .default
        guard let metricConfig = config.config(for: metricType) else {
            return
        }

        // Get the actual menu bar appearance from the button's effective appearance
        let menuBarIsDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        // Create image directly using our renderer
        let renderedImage = renderer.createImage(
            for: metricType,
            config: metricConfig,
            globalConfig: config,
            usage: usage,
            apiUsage: apiUsage,
            isDarkMode: menuBarIsDark,
            colorMode: config.colorMode,
            singleColorHex: config.singleColorHex,
            showIconName: config.showIconNames,
            showNextSessionTime: metricConfig.showNextSessionTime
        )

        let badgeStyle = ProfileManager.shared.providerBadgeStyle
        let image = renderer.applyProviderBadge(
            to: renderedImage,
            providerID: .claude,
            style: badgeStyle,
            isDarkMode: menuBarIsDark
        )
        image.isTemplate = config.colorMode == .monochrome
            && !config.showPaceMarker
            && !badgeStyle.showsTint
        button.image = image
    }

    /// Get button for a specific metric (used for popover positioning)
    func button(for metricType: MenuBarMetricType) -> NSStatusBarButton? {
        let metricID: MenuBarMetricID
        switch metricType {
        case .session: metricID = .claudeSession
        case .week: metricID = .claudeWeek
        case .api: metricID = .claudeAPI
        }
        return statusItems[metricID]?.button
    }

    /// Get the first enabled metric's button (for backwards compatibility)
    var primaryButton: NSStatusBarButton? {
        let config = DataStore.shared.loadMenuBarIconConfiguration()
        if let firstMetric = config.enabledMetrics.first,
           let button = statusItems[firstMetric.metricID]?.button {
            return button
        }
        for metricID in singleMetricOrder {
            if let button = statusItems[metricID]?.button {
                return button
            }
        }
        return statusItems.values.compactMap(\.button).first
    }

    /// Find which metric type owns the given button (sender)
    func metricType(for sender: NSStatusBarButton?) -> MenuBarMetricType? {
        guard let sender = sender else { return nil }

        // Find which status item has this button
        for (metricID, statusItem) in statusItems {
            if statusItem.button === sender {
                return metricID.legacyMetricType
            }
        }
        return nil
    }

    // MARK: - Appearance Observation

    private var lastObservedAppearanceName: NSAppearance.Name?

    private func observeAppearanceChanges() {
        appearanceObservers.forEach { $0.invalidate() }
        appearanceObservers.removeAll()

        // IMPORTANT: Do NOT observe per-button effectiveAppearance.
        // Setting button.image triggers effectiveAppearance KVO on the button,
        // which causes an infinite redraw loop.
        let appObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, change in
            guard let self = self else { return }
            let newName = change.newValue?.name
            guard newName != self.lastObservedAppearanceName else { return }
            self.lastObservedAppearanceName = newName
            // Clear image cache so next update re-renders with new appearance
            self.lastImageData.removeAll()
            self.delegate?.statusBarAppearanceDidChange()
        }
        appearanceObservers.append(appObserver)
    }

    /// Only sets button.image if the image data actually changed.
    /// This prevents triggering effectiveAppearance KVO when the image is identical.
    private func setButtonImage(_ button: NSStatusBarButton, image: NSImage) {
        let buttonId = ObjectIdentifier(button)
        guard let newData = Self.imageFingerprint(image) else {
            button.image = image
            return
        }
        if lastImageData[buttonId] == newData { return }
        lastImageData[buttonId] = newData
        button.image = image
    }

    /// Returns stable pixel bytes without invoking NSImage.tiffRepresentation, whose
    /// TIFF error-handler initialization crashes under the macOS 26 SDK.
    static func imageFingerprint(_ image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cgImage.dataProvider?.data else {
            return nil
        }
        let length = CFDataGetLength(data)
        guard length > 0, let bytes = CFDataGetBytePtr(data) else {
            return Data()
        }
        // `CGDataProvider.data` may be backed by provider-owned storage.
        // Copy the bytes so the cache never outlives that provider.
        return Data(bytes: bytes, count: length)
    }

    /// Debounces appearance change notifications so multiple displays/buttons
    /// coalesce into a single delegate callback
    private func scheduleAppearanceUpdate() {
        appearanceDebounceTimer?.invalidate()
        appearanceDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            self?.delegate?.statusBarAppearanceDidChange()
        }
    }
}

// MARK: - Delegate Protocol

protocol StatusBarUIManagerDelegate: AnyObject {
    func statusBarAppearanceDidChange()
}
