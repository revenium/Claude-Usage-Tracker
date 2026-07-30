//
//  MenuBarIconConfig.swift
//  Claude Usage
//
//  Created by Claude Code on 2025-12-27.
//

import Foundation
import UsageCore

/// A stable provider-neutral menu-bar metric identity.
///
/// Window identities deliberately include the provider, group, and window.
/// This prevents two providers (or two groups from one provider) from
/// overwriting each other's preferences as catalogs grow.
struct MenuBarMetricID: Hashable, Sendable, Codable, Identifiable {
    enum Kind: Hashable, Sendable {
        case usageWindow(
            providerID: ProviderID,
            groupID: UsageLimitGroupID,
            windowID: UsageWindowID
        )
        case claudeAPI
        case providerPlaceholder(providerID: ProviderID)
    }

    let kind: Kind

    var id: String { stableValue }
    var stableValue: String {
        switch kind {
        case .usageWindow(let providerID, let groupID, let windowID):
            return [
                "v1", "window",
                Self.encodeComponent(providerID.rawValue),
                Self.encodeComponent(groupID.rawValue),
                Self.encodeComponent(windowID.rawValue)
            ].joined(separator: ".")
        case .claudeAPI:
            return "v1.claude-api"
        case .providerPlaceholder(let providerID):
            return "v1.placeholder."
                + Self.encodeComponent(providerID.rawValue)
        }
    }

    init(
        providerID: ProviderID,
        groupID: UsageLimitGroupID,
        windowID: UsageWindowID
    ) {
        kind = .usageWindow(
            providerID: providerID,
            groupID: groupID,
            windowID: windowID
        )
    }

    private init(kind: Kind) {
        self.kind = kind
    }

    static let claudeSession = MenuBarMetricID(
        providerID: .claude,
        groupID: try! UsageLimitGroupID("claude.subscription"),
        windowID: try! UsageWindowID("claude.session")
    )
    static let claudeWeek = MenuBarMetricID(
        providerID: .claude,
        groupID: try! UsageLimitGroupID("claude.subscription"),
        windowID: try! UsageWindowID("claude.week")
    )
    static let claudeAPI = MenuBarMetricID(kind: .claudeAPI)
    static func providerPlaceholder(
        _ providerID: ProviderID
    ) -> MenuBarMetricID {
        MenuBarMetricID(
            kind: .providerPlaceholder(providerID: providerID)
        )
    }

    var legacyMetricType: MenuBarMetricType? {
        switch self {
        case .claudeSession:
            return .session
        case .claudeWeek:
            return .week
        case .claudeAPI:
            return .api
        default:
            return nil
        }
    }

    var providerID: ProviderID? {
        switch kind {
        case .usageWindow(let providerID, _, _):
            return providerID
        case .claudeAPI:
            return .claude
        case .providerPlaceholder(let providerID):
            return providerID
        }
    }

    var usageWindowComponents: (
        providerID: ProviderID,
        groupID: UsageLimitGroupID,
        windowID: UsageWindowID
    )? {
        guard case .usageWindow(
            let providerID,
            let groupID,
            let windowID
        ) = kind else {
            return nil
        }
        return (providerID, groupID, windowID)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let decoded = Self(stableValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid menu-bar metric identity"
            )
        }
        self = decoded
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stableValue)
    }

    init?(stableValue: String) {
        if stableValue == "v1.claude-api" {
            self = .claudeAPI
            return
        }
        let components = stableValue.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        if components.count == 3,
           components[0] == "v1",
           components[1] == "placeholder",
           let provider = Self.decodeComponent(String(components[2])),
           let providerID = try? ProviderID(provider) {
            self = .providerPlaceholder(providerID)
            return
        }
        guard components.count == 5,
              components[0] == "v1",
              components[1] == "window",
              let provider = Self.decodeComponent(String(components[2])),
              let group = Self.decodeComponent(String(components[3])),
              let window = Self.decodeComponent(String(components[4])),
              let providerID = try? ProviderID(provider),
              let groupID = try? UsageLimitGroupID(group),
              let windowID = try? UsageWindowID(window) else {
            return nil
        }
        self.init(
            providerID: providerID,
            groupID: groupID,
            windowID: windowID
        )
    }

    private static func encodeComponent(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeComponent(_ value: String) -> String? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum MenuBarMetricSelectionMode: String, Codable, Sendable {
    /// Select the first usable metric in the provider's canonical catalog.
    case automatic
    /// Respect the persisted enabled flags exactly, including all-disabled.
    case custom
}

/// Types of metrics that can be displayed in the menu bar
enum MenuBarMetricType: String, Codable, CaseIterable, Identifiable {
    case session
    case week
    case api

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .session:
            return "Session Usage"
        case .week:
            return "Week Usage"
        case .api:
            return "API Credits"
        }
    }

    var prefixText: String {
        switch self {
        case .session:
            return "S:"
        case .week:
            return "W:"
        case .api:
            return "API:"
        }
    }

    var description: String {
        switch self {
        case .session:
            return "5-hour rolling window usage"
        case .week:
            return "Weekly token usage (all models)"
        case .api:
            return "API Console billing credits"
        }
    }

    var icon: String {
        switch self {
        case .session:
            return "clock.fill"
        case .week:
            return "calendar.badge.clock"
        case .api:
            return "dollarsign.circle.fill"
        }
    }
}

/// Color mode for menu bar icons
enum MenuBarColorMode: String, Codable, CaseIterable {
    case multiColor = "multiColor"
    case monochrome = "monochrome"
    case singleColor = "singleColor"

    var displayName: String {
        switch self {
        case .multiColor:
            return "Multi-Color"
        case .monochrome:
            return "Greyscale"
        case .singleColor:
            return "Single Color"
        }
    }

    var description: String {
        switch self {
        case .multiColor:
            return "Green, orange, red based on usage level"
        case .monochrome:
            return "Adapts to menu bar appearance"
        case .singleColor:
            return "Custom color of your choice"
        }
    }

    var icon: String {
        switch self {
        case .multiColor:
            return "paintpalette.fill"
        case .monochrome:
            return "circle.lefthalf.filled"
        case .singleColor:
            return "paintbrush.fill"
        }
    }
}

/// Display mode for API usage
enum APIDisplayMode: String, Codable, CaseIterable {
    case remaining
    case used
    case both

    var displayName: String {
        switch self {
        case .remaining:
            return "Remaining Credits"
        case .used:
            return "Used Amount"
        case .both:
            return "Both (Used / Total)"
        }
    }

    var description: String {
        switch self {
        case .remaining:
            return "Show only remaining credits"
        case .used:
            return "Show only amount spent"
        case .both:
            return "Show both used and total"
        }
    }
}

/// Display mode for week usage
enum WeekDisplayMode: String, Codable, CaseIterable {
    case percentage
    case tokens

    var displayName: String {
        switch self {
        case .percentage:
            return "Percentage"
        case .tokens:
            return "Token Count"
        }
    }

    var description: String {
        switch self {
        case .percentage:
            return "Show as percentage (e.g., 60%)"
        case .tokens:
            return "Show token numbers (e.g., 600K/1M)"
        }
    }
}

/// Configuration for a single metric icon
struct MetricIconConfig: Codable, Equatable {
    var metricID: MenuBarMetricID
    var isEnabled: Bool
    var iconStyle: MenuBarIconStyle
    var order: Int

    /// Week-specific configuration
    var weekDisplayMode: WeekDisplayMode

    /// API-specific configuration
    var apiDisplayMode: APIDisplayMode

    /// Session-specific configuration
    var showNextSessionTime: Bool

    /// Compatibility facade for existing Claude-only controls and rendering.
    /// Provider-neutral call sites should use `metricID`.
    var metricType: MenuBarMetricType {
        get { metricID.legacyMetricType ?? .session }
        set { metricID = Self.metricID(for: newValue) }
    }

    init(
        metricType: MenuBarMetricType,
        isEnabled: Bool = false,
        iconStyle: MenuBarIconStyle = .battery,
        order: Int = 0,
        weekDisplayMode: WeekDisplayMode = .percentage,
        apiDisplayMode: APIDisplayMode = .remaining,
        showNextSessionTime: Bool = false
    ) {
        self.metricID = Self.metricID(for: metricType)
        self.isEnabled = isEnabled
        self.iconStyle = iconStyle
        self.order = order
        self.weekDisplayMode = weekDisplayMode
        self.apiDisplayMode = apiDisplayMode
        self.showNextSessionTime = showNextSessionTime
    }

    init(
        metricID: MenuBarMetricID,
        isEnabled: Bool = false,
        iconStyle: MenuBarIconStyle = .battery,
        order: Int = 0,
        weekDisplayMode: WeekDisplayMode = .percentage,
        apiDisplayMode: APIDisplayMode = .remaining,
        showNextSessionTime: Bool = false
    ) {
        self.metricID = metricID
        self.isEnabled = isEnabled
        self.iconStyle = iconStyle
        self.order = order
        self.weekDisplayMode = weekDisplayMode
        self.apiDisplayMode = apiDisplayMode
        self.showNextSessionTime = showNextSessionTime
    }

    private enum CodingKeys: String, CodingKey {
        case metricID
        case metricType
        case isEnabled
        case iconStyle
        case order
        case weekDisplayMode
        case apiDisplayMode
        case showNextSessionTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stableID = try container.decodeIfPresent(
            MenuBarMetricID.self,
            forKey: .metricID
        ) {
            metricID = stableID
        } else {
            let legacy = try container.decode(
                MenuBarMetricType.self,
                forKey: .metricType
            )
            metricID = Self.metricID(for: legacy)
        }
        isEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .isEnabled
        ) ?? false
        iconStyle = try container.decodeIfPresent(
            MenuBarIconStyle.self,
            forKey: .iconStyle
        ) ?? .battery
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        weekDisplayMode = try container.decodeIfPresent(
            WeekDisplayMode.self,
            forKey: .weekDisplayMode
        ) ?? .percentage
        apiDisplayMode = try container.decodeIfPresent(
            APIDisplayMode.self,
            forKey: .apiDisplayMode
        ) ?? .remaining
        showNextSessionTime = try container.decodeIfPresent(
            Bool.self,
            forKey: .showNextSessionTime
        ) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(metricID, forKey: .metricID)
        // Dual-write the historical discriminator whenever it is lossless so
        // older app versions can still read existing Claude preferences.
        if let legacy = metricID.legacyMetricType {
            try container.encode(legacy, forKey: .metricType)
        }
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(iconStyle, forKey: .iconStyle)
        try container.encode(order, forKey: .order)
        try container.encode(weekDisplayMode, forKey: .weekDisplayMode)
        try container.encode(apiDisplayMode, forKey: .apiDisplayMode)
        try container.encode(
            showNextSessionTime,
            forKey: .showNextSessionTime
        )
    }

    private static func metricID(
        for metricType: MenuBarMetricType
    ) -> MenuBarMetricID {
        switch metricType {
        case .session:
            return .claudeSession
        case .week:
            return .claudeWeek
        case .api:
            return .claudeAPI
        }
    }

    /// Default config for session (enabled by default)
    static var sessionDefault: MetricIconConfig {
        MetricIconConfig(
            metricType: .session,
            isEnabled: true,
            iconStyle: .battery,
            order: 0,
            showNextSessionTime: false
        )
    }

    /// Default config for week (disabled by default)
    static var weekDefault: MetricIconConfig {
        MetricIconConfig(
            metricType: .week,
            isEnabled: false,
            iconStyle: .battery,
            order: 1,
            weekDisplayMode: .percentage
        )
    }

    /// Default config for API (disabled by default)
    static var apiDefault: MetricIconConfig {
        MetricIconConfig(
            metricType: .api,
            isEnabled: false,
            iconStyle: .battery,
            order: 2,
            apiDisplayMode: .remaining
        )
    }
}

/// Icon style for multi-profile display
enum MultiProfileIconStyle: String, Codable, CaseIterable {
    case concentric   // Concentric circles (session inner, week outer)
    case progressBar  // Horizontal progress bars stacked
    case compact      // Minimal dot indicators
    case percentage   // Percentage text (e.g. "30 · 4")

    var displayName: String {
        switch self {
        case .concentric:
            return "Concentric Circles"
        case .progressBar:
            return "Progress Bars"
        case .compact:
            return "Compact Dots"
        case .percentage:
            return "Percentage"
        }
    }

    /// Localization key for short segmented picker label
    var shortNameKey: String {
        switch self {
        case .concentric:
            return "multiprofile.style_circles"
        case .progressBar:
            return "multiprofile.style_bars"
        case .compact:
            return "multiprofile.style_dots"
        case .percentage:
            return "multiprofile.style_percent"
        }
    }

    var description: String {
        switch self {
        case .concentric:
            return "Session inside, week outside ring"
        case .progressBar:
            return "Horizontal bars stacked vertically"
        case .compact:
            return "Minimal colored dots"
        case .percentage:
            return "Session and week as colored numbers"
        }
    }

    var icon: String {
        switch self {
        case .concentric:
            return "circle.circle"
        case .progressBar:
            return "chart.bar.fill"
        case .compact:
            return "circle.fill"
        case .percentage:
            return "percent"
        }
    }
}

/// Configuration for multi-profile display mode
struct MultiProfileDisplayConfig: Codable, Equatable {
    var iconStyle: MultiProfileIconStyle
    var showWeek: Bool        // If false, only show session
    var showProfileLabel: Bool // Show profile name below icon
    var useSystemColor: Bool  // If true, use system accent color instead of status colors
    var showTimeMarker: Bool  // If true, show time-elapsed tick mark on progress indicators
    var showPaceMarker: Bool  // If true, color time marker by projected usage pace (6-tier)
    var usePaceColoring: Bool // If true, color indicators based on projected usage pace
    var showRemainingPercentage: Bool // If true, show remaining capacity instead of used percentage

    init(
        iconStyle: MultiProfileIconStyle = .concentric,
        showWeek: Bool = true,
        showProfileLabel: Bool = true,
        useSystemColor: Bool = false,
        showTimeMarker: Bool = true,
        showPaceMarker: Bool = true,
        usePaceColoring: Bool = true,
        showRemainingPercentage: Bool = false
    ) {
        self.iconStyle = iconStyle
        self.showWeek = showWeek
        self.showProfileLabel = showProfileLabel
        self.useSystemColor = useSystemColor
        self.showTimeMarker = showTimeMarker
        self.showPaceMarker = showPaceMarker
        self.usePaceColoring = usePaceColoring
        self.showRemainingPercentage = showRemainingPercentage
    }

    // MARK: - Codable (Custom decoder for backwards compatibility)

    enum CodingKeys: String, CodingKey {
        case iconStyle
        case showWeek
        case showProfileLabel
        case useSystemColor
        case showTimeMarker
        case showPaceMarker
        case usePaceColoring
        case showRemainingPercentage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        iconStyle = try container.decode(MultiProfileIconStyle.self, forKey: .iconStyle)
        showWeek = try container.decode(Bool.self, forKey: .showWeek)
        showProfileLabel = try container.decode(Bool.self, forKey: .showProfileLabel)
        // New properties - provide default values if missing (backwards compatibility)
        useSystemColor = try container.decodeIfPresent(Bool.self, forKey: .useSystemColor) ?? false
        showTimeMarker = try container.decodeIfPresent(Bool.self, forKey: .showTimeMarker) ?? true
        showPaceMarker = try container.decodeIfPresent(Bool.self, forKey: .showPaceMarker) ?? false
        usePaceColoring = try container.decodeIfPresent(Bool.self, forKey: .usePaceColoring) ?? false
        showRemainingPercentage = try container.decodeIfPresent(Bool.self, forKey: .showRemainingPercentage) ?? false
    }

    static var `default`: MultiProfileDisplayConfig {
        MultiProfileDisplayConfig()
    }
}

/// Global menu bar icon configuration
struct MenuBarIconConfiguration: Codable, Equatable {
    var colorMode: MenuBarColorMode
    var singleColorHex: String
    var showIconNames: Bool
    var showRemainingPercentage: Bool
    var showTimeMarker: Bool
    var showPaceMarker: Bool
    var usePaceColoring: Bool
    var metricSelectionMode: MenuBarMetricSelectionMode
    var metrics: [MetricIconConfig]

    init(
        colorMode: MenuBarColorMode = .multiColor,
        singleColorHex: String = "#00BFFF",
        showIconNames: Bool = true,
        showRemainingPercentage: Bool = false,
        showTimeMarker: Bool = true,
        showPaceMarker: Bool = true,
        usePaceColoring: Bool = true,
        metricSelectionMode: MenuBarMetricSelectionMode = .custom,
        metrics: [MetricIconConfig] = [
            .sessionDefault,
            .weekDefault,
            .apiDefault
        ]
    ) {
        self.colorMode = colorMode
        self.singleColorHex = singleColorHex
        self.showIconNames = showIconNames
        self.showRemainingPercentage = showRemainingPercentage
        self.showTimeMarker = showTimeMarker
        self.showPaceMarker = showPaceMarker
        self.usePaceColoring = usePaceColoring
        self.metricSelectionMode = metricSelectionMode
        self.metrics = Self.firstConfigurationPerMetric(metrics)
    }

    // MARK: - Codable (Custom decoder for backwards compatibility)

    enum CodingKeys: String, CodingKey {
        case monochromeMode  // Legacy key for backwards compatibility
        case colorMode
        case singleColorHex
        case showIconNames
        case showRemainingPercentage
        case showTimeMarker
        case showPaceMarker
        case usePaceColoring
        case metricSelectionMode
        case metrics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Handle backwards compatibility: if old monochromeMode exists, convert it
        if let monochromeMode = try container.decodeIfPresent(Bool.self, forKey: .monochromeMode) {
            colorMode = monochromeMode ? .monochrome : .multiColor
        } else {
            colorMode = try container.decodeIfPresent(MenuBarColorMode.self, forKey: .colorMode) ?? .multiColor
        }

        singleColorHex = try container.decodeIfPresent(String.self, forKey: .singleColorHex) ?? "#00BFFF"
        showIconNames = try container.decodeIfPresent(
            Bool.self,
            forKey: .showIconNames
        ) ?? true
        showRemainingPercentage = try container.decodeIfPresent(Bool.self, forKey: .showRemainingPercentage) ?? false
        showTimeMarker = try container.decodeIfPresent(Bool.self, forKey: .showTimeMarker) ?? true
        showPaceMarker = try container.decodeIfPresent(Bool.self, forKey: .showPaceMarker) ?? false
        usePaceColoring = try container.decodeIfPresent(Bool.self, forKey: .usePaceColoring) ?? false
        metricSelectionMode = try container.decodeIfPresent(
            MenuBarMetricSelectionMode.self,
            forKey: .metricSelectionMode
        ) ?? .custom
        metrics = Self.firstConfigurationPerMetric(
            try container.decodeIfPresent(
                [MetricIconConfig].self,
                forKey: .metrics
            ) ?? [
                .sessionDefault,
                .weekDefault,
                .apiDefault
            ]
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(colorMode, forKey: .colorMode)
        try container.encode(singleColorHex, forKey: .singleColorHex)
        try container.encode(showIconNames, forKey: .showIconNames)
        try container.encode(showRemainingPercentage, forKey: .showRemainingPercentage)
        try container.encode(showTimeMarker, forKey: .showTimeMarker)
        try container.encode(showPaceMarker, forKey: .showPaceMarker)
        try container.encode(usePaceColoring, forKey: .usePaceColoring)
        try container.encode(
            metricSelectionMode,
            forKey: .metricSelectionMode
        )
        try container.encode(metrics, forKey: .metrics)
        // Note: We don't encode monochromeMode anymore - it's only for reading legacy data
    }

    /// Get enabled metrics sorted by order
    var enabledMetrics: [MetricIconConfig] {
        Self.firstConfigurationPerMetric(metrics)
            .enumerated()
            .filter { $0.element.isEnabled }
            .sorted {
                if $0.element.order != $1.element.order {
                    return $0.element.order < $1.element.order
                }
                return $0.offset < $1.offset
            }
            .map(\.element)
    }

    /// Get config for specific metric type
    func config(for metricType: MenuBarMetricType) -> MetricIconConfig? {
        metrics.first { $0.metricID.legacyMetricType == metricType }
    }

    func config(for metricID: MenuBarMetricID) -> MetricIconConfig? {
        metrics.first { $0.metricID == metricID }
    }

    /// Update config for specific metric
    mutating func updateConfig(_ config: MetricIconConfig) {
        metricSelectionMode = .custom
        if let index = metrics.firstIndex(
            where: { $0.metricID == config.metricID }
        ) {
            metrics[index] = config
        } else {
            metrics.append(config)
        }
    }

    /// Default configuration (session only, like current behavior)
    static var `default`: MenuBarIconConfiguration {
        MenuBarIconConfiguration()
    }

    static func `default`(
        for providerID: ProviderID
    ) -> MenuBarIconConfiguration {
        guard providerID != .claude else { return .default }
        return MenuBarIconConfiguration(
            metricSelectionMode: .automatic,
            metrics: []
        )
    }

    /// Converts the untouched legacy Claude default into the correct default
    /// for a newly created provider profile. Explicit custom choices, including
    /// all-disabled, are never changed.
    func adaptedForProvider(
        _ providerID: ProviderID
    ) -> MenuBarIconConfiguration {
        guard providerID != .claude, self == .default else { return self }
        return .default(for: providerID)
    }

    func resolvedMetrics(
        catalog: [ProviderMetricDescriptor]
    ) -> [MetricIconConfig] {
        switch metricSelectionMode {
        case .automatic:
            guard let first = catalog.first(where: \.isUsable) else {
                return []
            }
            var config = self.config(for: first.id)
                ?? MetricIconConfig(metricID: first.id)
            config.isEnabled = true
            config.order = 0
            return [config]
        case .custom:
            return enabledMetrics.filter { configured in
                catalog.contains {
                    $0.id == configured.metricID && $0.isUsable
                }
            }
        }
    }

    /// Malformed persisted arrays are sanitized deterministically: the first
    /// occurrence wins, matching the user's visible ordering and preventing
    /// duplicate NSStatusItems for one stable metric identity.
    private static func firstConfigurationPerMetric(
        _ configurations: [MetricIconConfig]
    ) -> [MetricIconConfig] {
        var seen = Set<MenuBarMetricID>()
        return configurations.filter { seen.insert($0.metricID).inserted }
    }
}
