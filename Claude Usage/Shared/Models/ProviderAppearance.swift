import Foundation
import Combine
import UsageCore

/// Code-native, non-color identity for a usage provider.
struct ProviderAppearance: Equatable, Sendable {
    let providerID: ProviderID
    let displayName: String
    let compactBadge: String
    let symbolName: String

    static func forProvider(_ providerID: ProviderID) -> ProviderAppearance {
        switch providerID {
        case .claude:
            return ProviderAppearance(
                providerID: providerID,
                displayName: "Claude",
                compactBadge: "CL",
                symbolName: "sparkles"
            )
        case .codex:
            return ProviderAppearance(
                providerID: providerID,
                displayName: "Codex",
                compactBadge: "CX",
                symbolName: "chevron.left.forwardslash.chevron.right"
            )
        default:
            let safeName = providerID.rawValue
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
            return ProviderAppearance(
                providerID: providerID,
                displayName: safeName,
                compactBadge: String(safeName.prefix(2)).uppercased(),
                symbolName: "gauge.with.dots.needle.67percent"
            )
        }
    }

    static func canonicalProviderOrder(
        _ lhs: ProviderID,
        _ rhs: ProviderID
    ) -> Bool {
        func rank(_ providerID: ProviderID) -> Int {
            switch providerID {
            case .claude: return 0
            case .codex: return 1
            default: return 2
            }
        }
        let lhsRank = rank(lhs)
        let rhsRank = rank(rhs)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.rawValue < rhs.rawValue
    }
}

enum ProviderMetricDisplayState: String, Equatable, Sendable {
    case ready
    case loading
    case stale
    case degraded
    case error
    case noData

    var accessibilityText: String {
        switch self {
        case .ready: return "ready"
        case .loading: return "loading usage"
        case .stale: return "stale usage"
        case .degraded: return "degraded; showing cached usage"
        case .error: return "usage error"
        case .noData: return "no usage data"
        }
    }
}

struct ProviderMetricDescriptor: Equatable, Identifiable, Sendable {
    let id: MenuBarMetricID
    let providerID: ProviderID
    let groupName: String
    let metricName: String
    let resetAt: Date?
    let duration: TimeInterval?
    let usedPercentage: Double?
    let isUsable: Bool
    let unavailableReason: String?

    var accessibilityName: String {
        "\(ProviderAppearance.forProvider(providerID).displayName) "
            + "\(groupName), \(metricName)"
    }
}

struct ProviderMetricPresentation: Equatable, Identifiable, Sendable {
    let descriptor: ProviderMetricDescriptor
    let state: ProviderMetricDisplayState
    let usedPercentage: Double?
    let displayedPercentage: Double?
    let showRemaining: Bool
    let elapsedFraction: Double?
    let statusLevel: UsageStatusLevel
    let notice: String?

    var id: MenuBarMetricID { descriptor.id }

    var percentageText: String {
        guard let displayedPercentage else { return "—" }
        return "\(Int(displayedPercentage.rounded()))%"
    }

    var modeText: String {
        showRemaining ? "remaining" : "used"
    }

    var accessibilityLabel: String {
        let provider = ProviderAppearance.forProvider(
            descriptor.providerID
        )
        let stateText: String
        switch state {
        case .ready: stateText = ""
        case .loading: stateText = ", loading"
        case .stale: stateText = ", stale"
        case .degraded: stateText = ", degraded"
        case .error: stateText = ", error"
        case .noData: stateText = ", no data"
        }
        return "\(provider.displayName), \(descriptor.groupName), "
            + "\(descriptor.metricName), \(percentageText) \(modeText)"
            + stateText
    }
}

struct ProviderStatusItemIdentity: Hashable, Sendable {
    let profileID: UUID
    let providerID: ProviderID
    let providerRevision: UInt64
    let metricID: MenuBarMetricID?
}

enum ProviderMenuActionKind: Equatable, Sendable {
    case openPopover
    case activate
    case refresh
    case settings(SettingsNavigationDestination)
    case quit
}

struct ProviderMenuAction: Equatable, Identifiable, Sendable {
    let title: String
    let target: ProviderStatusItemIdentity
    let kind: ProviderMenuActionKind

    var id: String {
        "\(target.profileID.uuidString):\(title):\(String(describing: kind))"
    }
}

struct ProviderMenuPresentation: Equatable, Identifiable, Sendable {
    let identity: ProviderStatusItemIdentity
    let profileName: String
    let appearance: ProviderAppearance
    let metrics: [ProviderMetricPresentation]
    let state: ProviderMetricDisplayState
    let actions: [ProviderMenuAction]
    let nextFreshnessDeadline: Date?

    var id: UUID { identity.profileID }
    var metric: ProviderMetricPresentation? { metrics.first }
}

/// Retains the last known provider catalog for settings. A transient missing,
/// stale, or failed snapshot must not make saved controls disappear while the
/// settings window is open.
@MainActor
final class ProviderMenuCatalogStore: ObservableObject {
    static let shared = ProviderMenuCatalogStore()

    @Published private(set) var catalogs:
        [UUID: [ProviderMetricDescriptor]] = [:]
    private var catalogProviders: [UUID: ProviderID] = [:]
    private var catalogRevisions: [UUID: UInt64] = [:]

    func publish(
        profiles: [Profile],
        snapshots: [UUID: PresentationSnapshot]
    ) {
        let liveProfileIDs = Set(profiles.map(\.id))
        catalogs = catalogs.filter {
            liveProfileIDs.contains($0.key)
        }
        catalogProviders = catalogProviders.filter {
            liveProfileIDs.contains($0.key)
        }
        catalogRevisions = catalogRevisions.filter {
            liveProfileIDs.contains($0.key)
        }
        for profile in profiles {
            if profile.deletionInProgress {
                invalidate(profileID: profile.id)
                continue
            }
            if catalogProviders[profile.id] != profile.providerID
                || catalogRevisions[profile.id]
                    != profile.providerRevision {
                catalogs.removeValue(forKey: profile.id)
            }
            catalogProviders[profile.id] = profile.providerID
            catalogRevisions[profile.id] = profile.providerRevision
            let discovered = ProviderMenuPresentationBuilder.catalog(
                profile: profile,
                snapshot: snapshots[profile.id]
            )
            // Claude compatibility metrics are statically known. For dynamic
            // providers retain the previous nonempty catalog through loading,
            // stale, error, and temporary no-snapshot states.
            if !discovered.isEmpty || profile.providerID == .claude {
                catalogs[profile.id] = discovered
            }
        }
    }

    func invalidate(profileID: UUID) {
        catalogs.removeValue(forKey: profileID)
        catalogProviders.removeValue(forKey: profileID)
        catalogRevisions.removeValue(forKey: profileID)
    }

    func catalog(
        for profile: Profile,
        configuration: MenuBarIconConfiguration
    ) -> [ProviderMetricDescriptor] {
        var result = catalogs[profile.id] ?? []
        var known = Set(result.map(\.id))
        for saved in configuration.metrics
        where saved.metricID.providerID == profile.providerID
            && known.insert(saved.metricID).inserted {
            guard let descriptor = Self.savedDescriptor(
                for: saved.metricID,
                providerID: profile.providerID
            ) else {
                continue
            }
            result.append(descriptor)
        }
        return result
    }

    func resetForTesting() {
        catalogs.removeAll()
        catalogProviders.removeAll()
        catalogRevisions.removeAll()
    }

    private static func savedDescriptor(
        for metricID: MenuBarMetricID,
        providerID: ProviderID
    ) -> ProviderMetricDescriptor? {
        if metricID == .claudeAPI {
            return ProviderMetricDescriptor(
                id: metricID,
                providerID: .claude,
                groupName: "API",
                metricName: "Credits",
                resetAt: nil,
                duration: nil,
                usedPercentage: nil,
                isUsable: false,
                unavailableReason:
                    "Saved metric is not in the latest provider response."
            )
        }
        guard let components = metricID.usageWindowComponents,
              components.providerID == providerID else {
            return nil
        }
        return ProviderMetricDescriptor(
            id: metricID,
            providerID: providerID,
            groupName: components.groupID.rawValue,
            metricName: components.windowID.rawValue,
            resetAt: nil,
            duration: nil,
            usedPercentage: nil,
            isUsable: false,
            unavailableReason:
                "Saved metric is not in the latest provider response."
        )
    }
}

/// Pure provider-neutral catalog and presentation construction.
///
/// It intentionally has no provider construction, process launch, fetching,
/// storage, or global singleton access. The menu layer passes an immutable
/// profile/snapshot pair and an explicit clock value.
enum ProviderMenuPresentationBuilder {
    static func catalog(
        profile: Profile,
        snapshot: PresentationSnapshot?
    ) -> [ProviderMetricDescriptor] {
        guard !profile.deletionInProgress else { return [] }
        if let snapshot,
           !snapshotMatches(profile: profile, snapshot: snapshot) {
            return []
        }
        if profile.providerID == .claude {
            return claudeCatalog(profile: profile, snapshot: snapshot)
        }
        return reportCatalog(
            providerID: profile.providerID,
            snapshot: snapshot
        )
    }

    static func snapshotMatches(
        profile: Profile,
        snapshot: PresentationSnapshot
    ) -> Bool {
        guard !profile.deletionInProgress,
              snapshot.profileID == profile.id,
              snapshot.providerID == profile.providerID,
              snapshot.providerRevision == profile.providerRevision else {
            return false
        }
        if let report = snapshot.report,
           report.providerID != profile.providerID {
            return false
        }
        return true
    }

    static func presentations(
        profiles: [Profile],
        snapshots: [UUID: PresentationSnapshot],
        now: Date,
        activeProfileID: UUID?
    ) -> [ProviderMenuPresentation] {
        profiles
            .sorted {
                if $0.providerID != $1.providerID {
                    return ProviderAppearance.canonicalProviderOrder(
                        $0.providerID,
                        $1.providerID
                    )
                }
                return $0.name.localizedStandardCompare($1.name)
                    == .orderedAscending
            }
            .map {
                presentation(
                    profile: $0,
                    snapshot: snapshots[$0.id],
                    now: now,
                    isActive: $0.id == activeProfileID
                )
            }
    }

    static func presentation(
        profile: Profile,
        snapshot: PresentationSnapshot?,
        now: Date,
        isActive: Bool
    ) -> ProviderMenuPresentation {
        let validSnapshot = snapshot.flatMap {
            snapshotMatches(profile: profile, snapshot: $0)
                ? $0
                : nil
        }
        let catalog = catalog(
            profile: profile,
            snapshot: validSnapshot
        )
        let configuration = profile.iconConfig.adaptedForProvider(
            profile.providerID
        )
        let selected = configuration.resolvedMetrics(catalog: catalog)
        let descriptors = selected.compactMap { selected in
            catalog.first { $0.id == selected.metricID }
        }
        let state = displayState(snapshot: validSnapshot, now: now)
        let metrics = descriptors.map {
            metricPresentation(
                descriptor: $0,
                state: state,
                showRemaining: configuration.showRemainingPercentage,
                snapshot: validSnapshot,
                now: now
            )
        }
        let identity = ProviderStatusItemIdentity(
            profileID: profile.id,
            providerID: profile.providerID,
            providerRevision: profile.providerRevision,
            metricID: descriptors.first?.id
        )
        var actions: [ProviderMenuAction] = [
            ProviderMenuAction(
                title: "Open \(profile.name)",
                target: identity,
                kind: .openPopover
            )
        ]
        if !isActive {
            actions.append(
                ProviderMenuAction(
                    title: "Make Active",
                    target: identity,
                    kind: .activate
                )
            )
        }
        actions.append(
            ProviderMenuAction(
                title: "Refresh",
                target: identity,
                kind: .refresh
            )
        )
        actions.append(
            ProviderMenuAction(
                title: "\(ProviderAppearance.forProvider(profile.providerID).displayName) Account…",
                target: identity,
                kind: .settings(.providerAccount(profileID: profile.id))
            )
        )
        actions.append(
            ProviderMenuAction(
                title: "Appearance…",
                target: identity,
                kind: .settings(.appearance(profileID: profile.id))
            )
        )
        actions.append(
            ProviderMenuAction(
                title: "Manage Profiles…",
                target: identity,
                kind: .settings(.manageProfiles)
            )
        )
        actions.append(
            ProviderMenuAction(
                title: "Quit",
                target: identity,
                kind: .quit
            )
        )
        return ProviderMenuPresentation(
            identity: identity,
            profileName: profile.name,
            appearance: .forProvider(profile.providerID),
            metrics: metrics,
            state: state,
            actions: actions,
            nextFreshnessDeadline: futureFreshnessDeadline(
                snapshot: validSnapshot,
                now: now
            )
        )
    }

    static func isStillCurrent(
        _ target: ProviderStatusItemIdentity,
        profiles: [Profile]
    ) -> Bool {
        profiles.contains {
            $0.id == target.profileID
                && $0.providerID == target.providerID
                && $0.providerRevision == target.providerRevision
                && !$0.deletionInProgress
        }
    }

    static func nextFreshnessDeadline(
        presentations: [ProviderMenuPresentation]
    ) -> Date? {
        presentations.compactMap(\.nextFreshnessDeadline).min()
    }

    static func metric(
        _ metric: ProviderMetricPresentation?,
        applying config: MultiProfileDisplayConfig
    ) -> ProviderMetricPresentation? {
        guard let metric else { return nil }
        let displayed = metric.usedPercentage.map {
            config.showRemainingPercentage ? max(0, 100 - $0) : $0
        }
        let elapsedForStatus = config.usePaceColoring
            ? metric.elapsedFraction
            : nil
        return ProviderMetricPresentation(
            descriptor: metric.descriptor,
            state: metric.state,
            usedPercentage: metric.usedPercentage,
            displayedPercentage: displayed,
            showRemaining: config.showRemainingPercentage,
            elapsedFraction: metric.elapsedFraction,
            statusLevel: UsageStatusCalculator.calculateStatus(
                usedPercentage: metric.usedPercentage ?? 0,
                showRemaining: config.showRemainingPercentage,
                elapsedFraction: elapsedForStatus
            ),
            notice: metric.notice
        )
    }

    private static func claudeCatalog(
        profile: Profile,
        snapshot: PresentationSnapshot?
    ) -> [ProviderMetricDescriptor] {
        let usage = snapshot?.claudeUsage ?? profile.claudeUsage
        let apiUsage = snapshot?.claudeAPIUsage ?? profile.apiUsage
        return [
            ProviderMetricDescriptor(
                id: .claudeSession,
                providerID: .claude,
                groupName: "Subscription",
                metricName: "Session",
                resetAt: usage?.sessionResetTime,
                duration: Constants.sessionWindow,
                usedPercentage: sanitize(
                    usage?.effectiveSessionPercentage
                ),
                isUsable: usage != nil,
                unavailableReason: usage == nil
                    ? "Session usage is not available yet."
                    : nil
            ),
            ProviderMetricDescriptor(
                id: .claudeWeek,
                providerID: .claude,
                groupName: "Subscription",
                metricName: "Week",
                resetAt: usage?.weeklyResetTime,
                duration: Constants.weeklyWindow,
                usedPercentage: sanitize(usage?.weeklyPercentage),
                isUsable: usage != nil,
                unavailableReason: usage == nil
                    ? "Weekly usage is not available yet."
                    : nil
            ),
            ProviderMetricDescriptor(
                id: .claudeAPI,
                providerID: .claude,
                groupName: "API",
                metricName: "Credits",
                resetAt: apiUsage?.resetsAt,
                duration: nil,
                usedPercentage: sanitize(apiUsage?.usagePercentage),
                isUsable: apiUsage != nil,
                unavailableReason: apiUsage == nil
                    ? "API billing is not linked for this profile."
                    : nil
            )
        ]
    }

    private static func reportCatalog(
        providerID: ProviderID,
        snapshot: PresentationSnapshot?
    ) -> [ProviderMetricDescriptor] {
        guard let report = snapshot?.report else { return [] }
        return report.limitGroups.flatMap { group in
            group.windows.map { window in
                let used = sanitize(
                    window.usedPercentage
                        ?? window.quantity?.calculatedUsedPercentage
                )
                return ProviderMetricDescriptor(
                    id: MenuBarMetricID(
                        providerID: providerID,
                        groupID: group.id,
                        windowID: window.id
                    ),
                    providerID: providerID,
                    groupName: nonempty(
                        group.displayName,
                        fallback: group.id.rawValue
                    ),
                    metricName: nonempty(
                        window.displayName,
                        fallback: window.id.rawValue
                    ),
                    resetAt: window.resetsAt,
                    duration: window.duration,
                    usedPercentage: used,
                    isUsable: used != nil,
                    unavailableReason: used == nil
                        ? "This limit has no percentage or finite quantity."
                        : nil
                )
            }
        }
    }

    private static func displayState(
        snapshot: PresentationSnapshot?,
        now: Date
    ) -> ProviderMetricDisplayState {
        guard let snapshot else { return .noData }
        let hasCachedData = snapshot.report != nil
            || snapshot.claudeUsage != nil
            || snapshot.claudeAPIUsage != nil
        if snapshot.activity.isInFlight && !hasCachedData {
            return .loading
        }
        if snapshot.currentFailure != nil {
            return hasCachedData ? .degraded : .error
        }
        switch snapshot.configurationState {
        case .ready:
            break
        case .disabled, .unlinked, .dependencyMissing, .unauthenticated,
             .unsupported, .invalid, .deleting:
            return hasCachedData ? .degraded : .error
        }
        if let report = snapshot.report {
            if report.isStale(at: now) { return .stale }
            switch report.health.status {
            case .healthy:
                break
            case .degraded:
                return .degraded
            case .unavailable, .unauthenticated, .unsupported:
                return hasCachedData ? .degraded : .error
            }
        }
        if snapshot.activity.isInFlight { return .loading }
        return hasCachedData ? .ready : .noData
    }

    private static func metricPresentation(
        descriptor: ProviderMetricDescriptor,
        state: ProviderMetricDisplayState,
        showRemaining: Bool,
        snapshot: PresentationSnapshot?,
        now: Date
    ) -> ProviderMetricPresentation {
        let used = sanitize(descriptor.usedPercentage)
        let displayed = used.map {
            showRemaining ? max(0, 100 - $0) : $0
        }
        let status = UsageStatusCalculator.calculateStatus(
            usedPercentage: used ?? 0,
            showRemaining: showRemaining,
            elapsedFraction: nil
        )
        let notice: String?
        switch state {
        case .ready:
            notice = nil
        case .loading:
            notice = used == nil
                ? "Loading usage."
                : "Refreshing; showing the last value."
        case .stale:
            notice = "Showing stale usage."
        case .degraded:
            notice = used == nil
                ? "Usage is temporarily unavailable."
                : "Provider degraded; showing the last value."
        case .error:
            notice = snapshot?.currentFailure.map {
                "Usage error: \(String(describing: $0.kind))."
            } ?? "Usage is unavailable."
        case .noData:
            notice = descriptor.unavailableReason ?? "No usage data."
        }
        return ProviderMetricPresentation(
            descriptor: descriptor,
            state: state,
            usedPercentage: used,
            displayedPercentage: displayed,
            showRemaining: showRemaining,
            elapsedFraction: elapsedFraction(
                descriptor: descriptor,
                now: now
            ),
            statusLevel: status,
            notice: notice
        )
    }

    private static func futureFreshnessDeadline(
        snapshot: PresentationSnapshot?,
        now: Date
    ) -> Date? {
        guard let staleAt = snapshot?.report?.staleAt,
              staleAt > now else {
            return nil
        }
        return staleAt
    }

    private static func elapsedFraction(
        descriptor: ProviderMetricDescriptor,
        now: Date
    ) -> Double? {
        guard let resetAt = descriptor.resetAt,
              let duration = descriptor.duration,
              duration.isFinite,
              duration > 0 else {
            return nil
        }
        if resetAt <= now { return 1 }
        return min(
            max((duration - resetAt.timeIntervalSince(now)) / duration, 0),
            1
        )
    }

    private static func sanitize(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return min(value, 100)
    }

    private static func nonempty(
        _ value: String?,
        fallback: String
    ) -> String {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty else {
            return fallback
        }
        return value
    }
}
