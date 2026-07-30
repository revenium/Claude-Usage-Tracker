import SwiftUI
import UsageCore

struct NormalizedUsageExpectedProfile: Equatable {
    let id: UUID
    let name: String
    let providerID: ProviderID
    let providerRevision: UInt64
}

struct NormalizedUsageDisplayPreferences: Equatable {
    let showRemainingPercentage: Bool
    let showTimeMarker: Bool
    let showPaceMarker: Bool
    let usePaceColoring: Bool

    init(
        showRemainingPercentage: Bool,
        showTimeMarker: Bool,
        showPaceMarker: Bool,
        usePaceColoring: Bool
    ) {
        self.showRemainingPercentage = showRemainingPercentage
        self.showTimeMarker = showTimeMarker
        self.showPaceMarker = showPaceMarker
        self.usePaceColoring = usePaceColoring
    }

    init(iconConfiguration: MenuBarIconConfiguration) {
        showRemainingPercentage =
            iconConfiguration.showRemainingPercentage
        showTimeMarker = iconConfiguration.showTimeMarker
        showPaceMarker = iconConfiguration.showPaceMarker
        usePaceColoring = iconConfiguration.usePaceColoring
    }

    init(multiProfileConfiguration: MultiProfileDisplayConfig) {
        showRemainingPercentage =
            multiProfileConfiguration.showRemainingPercentage
        showTimeMarker = multiProfileConfiguration.showTimeMarker
        showPaceMarker = multiProfileConfiguration.showPaceMarker
        usePaceColoring =
            multiProfileConfiguration.usePaceColoring
    }

    static func make(
        displayMode: ProfileDisplayMode,
        displayedProfile: Profile?,
        multiProfileConfiguration: MultiProfileDisplayConfig
    ) -> NormalizedUsageDisplayPreferences {
        switch displayMode {
        case .single:
            return NormalizedUsageDisplayPreferences(
                iconConfiguration:
                    displayedProfile?.iconConfig ?? .default
            )
        case .multi:
            return NormalizedUsageDisplayPreferences(
                multiProfileConfiguration:
                    multiProfileConfiguration
            )
        }
    }
}

struct ProviderProfileRowPresentation: Equatable, Identifiable {
    let id: UUID
    let name: String
    let providerName: String
    let connectionDescription: String
    let systemImage: String
    let isActive: Bool

    var accessibilityIdentifier: String {
        "popover.profile.switcher.\(id.uuidString)"
    }

    static func make(
        profiles: [Profile],
        activeProfileID: UUID?
    ) -> [ProviderProfileRowPresentation] {
        profiles.map { profile in
            switch profile.providerConfiguration {
            case .claude:
                return ProviderProfileRowPresentation(
                    id: profile.id,
                    name: profile.name,
                    providerName: "Claude",
                    connectionDescription:
                        claudeConnectionDescription(profile),
                    systemImage: "sparkles",
                    isActive: profile.id == activeProfileID
                )
            case .codex(let configuration):
                let connectionDescription: String
                if let linkedHome = configuration.linkedHome {
                    connectionDescription =
                        linkedHome.filesystemIdentity == nil
                            ? NormalizedUsageStrings.localized(
                                "popover.normalized.profile.relink_required",
                                default: "Relink required"
                            )
                            : NormalizedUsageStrings.localized(
                                "popover.normalized.profile.linked",
                                default: "Linked"
                            )
                } else {
                    connectionDescription =
                        NormalizedUsageStrings.localized(
                            "popover.normalized.profile.not_linked",
                            default: "Not linked"
                        )
                }
                return ProviderProfileRowPresentation(
                    id: profile.id,
                    name: profile.name,
                    providerName: "Codex",
                    connectionDescription: connectionDescription,
                    systemImage:
                        "chevron.left.forwardslash.chevron.right",
                    isActive: profile.id == activeProfileID
                )
            }
        }
    }

    private static func claudeConnectionDescription(
        _ profile: Profile
    ) -> String {
        if profile.cliAccountName != nil || profile.hasCliAccount
            || profile.cliCredentialsJSON != nil {
            return NormalizedUsageStrings.localized(
                "popover.normalized.profile.cli_linked",
                default: "CLI linked"
            )
        }
        if profile.claudeSessionKey != nil {
            return NormalizedUsageStrings.localized(
                "popover.normalized.profile.account_linked",
                default: "Account linked"
            )
        }
        if profile.apiSessionKey != nil {
            return NormalizedUsageStrings.localized(
                "popover.normalized.profile.api_linked",
                default: "API linked"
            )
        }
        return NormalizedUsageStrings.localized(
            "popover.normalized.profile.not_connected",
            default: "Not connected"
        )
    }
}

struct NormalizedUsageNotice: Equatable, Identifiable {
    enum Kind: String, Equatable, Hashable {
        case loading
        case stale
        case degraded
        case refreshFailed = "refresh-failed"
        case unavailable
        case unauthenticated
        case unsupported
    }

    let kind: Kind
    let localizationKey: String
    let defaultMessage: String

    var id: Kind { kind }
    var accessibilityIdentifier: String {
        "popover.notice.\(kind.rawValue)"
    }
}

enum NormalizedUsageEmptyState: String, Equatable {
    case missingSnapshot = "missing-snapshot"
    case loading
    case empty
    case disabled
    case unlinked
    case dependencyMissing = "dependency-missing"
    case unauthenticated
    case unsupportedAccount = "unsupported-account"
    case unsupportedUsage = "unsupported-usage"
    case invalidConfiguration = "invalid-configuration"
    case unavailable
    case deleting

    var accessibilityIdentifier: String {
        "popover.state.\(rawValue)"
    }
}

struct NormalizedUsageWindowPresentation: Equatable, Identifiable {
    struct ID: Hashable {
        let providerID: ProviderID
        let groupID: UsageLimitGroupID
        let windowID: UsageWindowID

        var accessibilityComponent: String {
            [
                providerID.rawValue,
                groupID.rawValue,
                windowID.rawValue
            ]
            .map(NormalizedUsageAccessibility.safeComponent)
            .joined(separator: ".")
        }
    }

    let id: ID
    let title: String
    let usedPercentage: Double?
    let quantity: UsageQuantity?
    let resetsAt: Date?
    let duration: TimeInterval?

    var accessibilityIdentifier: String {
        "popover.usage.window.\(id.accessibilityComponent)"
    }
}

struct NormalizedUsageGroupPresentation: Equatable, Identifiable {
    struct ID: Hashable {
        let providerID: ProviderID
        let groupID: UsageLimitGroupID

        var accessibilityComponent: String {
            [
                providerID.rawValue,
                groupID.rawValue
            ]
            .map(NormalizedUsageAccessibility.safeComponent)
            .joined(separator: ".")
        }
    }

    let id: ID
    let title: String
    let windows: [NormalizedUsageWindowPresentation]

    var accessibilityIdentifier: String {
        "popover.usage.group.\(id.accessibilityComponent)"
    }
}

struct NormalizedUsageSummaryPresentation: Equatable {
    let metrics: [UsageMetric]
    let periodStartedAt: Date?
    let periodEndsAt: Date?
    let dailyBuckets: [UsageDailyBucket]?
}

struct NormalizedUsagePresentation: Equatable {
    let profileID: UUID
    let profileName: String
    let providerID: ProviderID
    let providerName: String
    let accountName: String?
    let planName: String?
    let organizationName: String?
    let healthStatus: ProviderHealthStatus?
    let groups: [NormalizedUsageGroupPresentation]
    let summary: NormalizedUsageSummaryPresentation?
    let credits: [UsageCredit]
    let notices: [NormalizedUsageNotice]
    let emptyState: NormalizedUsageEmptyState?
    let legacyClaudeUsage: ClaudeUsage?
    let legacyClaudeAPIUsage: APIUsage?

    var providerHeaderAccessibilityIdentifier: String {
        "popover.provider.header."
            + NormalizedUsageAccessibility.safeComponent(
                providerID.rawValue
            )
    }

    var accountAccessibilityIdentifier: String {
        "popover.provider.account."
            + NormalizedUsageAccessibility.safeComponent(
                providerID.rawValue
            )
    }
}

enum NormalizedUsagePresentationBuilder {
    static func make(
        snapshot: PresentationSnapshot?,
        expectedProfile: NormalizedUsageExpectedProfile,
        now: Date
    ) -> NormalizedUsagePresentation {
        guard let snapshot else {
            return missingPresentation(for: expectedProfile)
        }
        let reportProviderMatches = snapshot.report.map {
            $0.providerID == expectedProfile.providerID
        } ?? true
        guard snapshot.profileID == expectedProfile.id,
              snapshot.providerID == expectedProfile.providerID,
              snapshot.providerRevision
                == expectedProfile.providerRevision,
              reportProviderMatches else {
            return missingPresentation(for: expectedProfile)
        }

        let report = snapshot.report
        var notices: [NormalizedUsageNotice] = []
        if snapshot.activity.isInFlight {
            notices.append(
                notice(
                    .loading,
                    key: "popover.normalized.notice.refreshing",
                    default: report == nil
                        ? "Refreshing usage…"
                        : "Refreshing usage; showing the last update."
                )
            )
        }
        if let report, report.isStale(at: now) {
            notices.append(
                notice(
                    .stale,
                    key: "popover.normalized.notice.stale",
                    default: "Usage may be out of date."
                )
            )
        }
        if let report {
            appendHealthNotice(report.health, to: &notices)
        }
        if snapshot.currentFailure != nil {
            notices.append(
                notice(
                    .refreshFailed,
                    key: "popover.normalized.notice.refresh_failed",
                    default: report == nil
                        ? "Usage could not be refreshed."
                        : "The latest refresh failed; showing cached usage."
                )
            )
        }
        if report != nil {
            appendConfigurationNotice(
                snapshot.configurationState,
                to: &notices
            )
        }
        notices = deduplicated(notices)

        let groups: [NormalizedUsageGroupPresentation]
        if snapshot.capabilities[.usageLimits] == .unavailable {
            groups = []
        } else {
            groups = makeGroups(from: report)
        }
        let summary: NormalizedUsageSummaryPresentation?
        if snapshot.capabilities[.usageSummary] == .unavailable {
            summary = nil
        } else {
            summary = report?.usageSummary.map {
                NormalizedUsageSummaryPresentation(
                    metrics: $0.metrics,
                    periodStartedAt: $0.periodStartedAt,
                    periodEndsAt: $0.periodEndsAt,
                    dailyBuckets: $0.dailyBuckets
                )
            }
        }
        let credits: [UsageCredit]
        if snapshot.capabilities[.credits] == .unavailable {
            credits = []
        } else {
            credits = report?.credits ?? []
        }

        let hasContent = !groups.isEmpty
            || summary != nil
            || !credits.isEmpty
            || snapshot.legacyDisplayHasContent
        let emptyState = hasContent
            ? nil
            : emptyState(
                for: snapshot,
                report: report
            )

        return NormalizedUsagePresentation(
            profileID: snapshot.profileID,
            profileName: expectedProfile.name,
            providerID: snapshot.providerID,
            providerName: providerName(snapshot.providerID),
            accountName: report?.account?.displayName,
            planName: report?.account?.planName,
            organizationName: report?.account?.organizationName,
            healthStatus:
                report?.health.status
                ?? headerHealthStatus(for: emptyState),
            groups: groups,
            summary: summary,
            credits: credits,
            notices: notices,
            emptyState: emptyState,
            legacyClaudeUsage: snapshot.providerID == .claude
                ? snapshot.claudeUsage
                : nil,
            legacyClaudeAPIUsage: snapshot.providerID == .claude
                ? snapshot.claudeAPIUsage
                : nil
        )
    }

    private static func makeGroups(
        from report: UsageReport?
    ) -> [NormalizedUsageGroupPresentation] {
        guard let report else { return [] }
        return report.limitGroups.map { group in
            let groupID = NormalizedUsageGroupPresentation.ID(
                providerID: report.providerID,
                groupID: group.id
            )
            return NormalizedUsageGroupPresentation(
                id: groupID,
                title: displayName(
                    group.displayName,
                    fallback: group.id.rawValue
                ),
                windows: group.windows.map { window in
                    NormalizedUsageWindowPresentation(
                        id: .init(
                            providerID: report.providerID,
                            groupID: group.id,
                            windowID: window.id
                        ),
                        title: displayName(
                            window.displayName,
                            fallback: window.id.rawValue
                        ),
                        usedPercentage: sanitizedPercentage(
                            window.usedPercentage
                                ?? window.quantity?
                                    .calculatedUsedPercentage
                        ),
                        quantity: window.quantity,
                        resetsAt: window.resetsAt,
                        duration: window.duration
                    )
                }
            )
        }
    }

    private static func sanitizedPercentage(
        _ percentage: Double?
    ) -> Double? {
        guard let percentage, percentage.isFinite,
              percentage >= 0 else {
            return nil
        }
        return min(percentage, 100)
    }

    private static func emptyState(
        for snapshot: PresentationSnapshot,
        report: UsageReport?
    ) -> NormalizedUsageEmptyState {
        switch snapshot.configurationState {
        case .ready:
            break
        case .disabled:
            return .disabled
        case .unlinked:
            return .unlinked
        case .dependencyMissing:
            return .dependencyMissing
        case .unauthenticated:
            return .unauthenticated
        case .unsupported:
            return .unsupportedAccount
        case .invalid:
            return .invalidConfiguration
        case .deleting:
            return .deleting
        }
        if snapshot.activity.isInFlight {
            return .loading
        }
        if let failure = snapshot.currentFailure {
            switch failure.kind {
            case .disabled:
                return .disabled
            case .unlinked:
                return .unlinked
            case .dependencyMissing:
                return .dependencyMissing
            case .unauthenticated:
                return .unauthenticated
            case .unsupportedAccount:
                return .unsupportedAccount
            case .invalidConfiguration:
                return .invalidConfiguration
            case .transport, .protocolMismatch, .malformedResponse,
                 .timedOut, .persistence, .unknown:
                return .unavailable
            }
        }
        switch report?.health.status {
        case .unauthenticated:
            return .unauthenticated
        case .unsupported:
            return .unsupportedAccount
        case .unavailable:
            return .unavailable
        case .healthy, .degraded:
            break
        case nil:
            return .unavailable
        }
        if snapshot.capabilities[.usageLimits] == .unavailable,
           snapshot.capabilities[.usageSummary] == .unavailable,
           snapshot.capabilities[.credits] == .unavailable {
            return .unsupportedUsage
        }
        return .empty
    }

    private static func appendHealthNotice(
        _ health: ProviderHealth,
        to notices: inout [NormalizedUsageNotice]
    ) {
        switch health.status {
        case .healthy:
            return
        case .degraded:
            notices.append(
                notice(
                    .degraded,
                    key: "popover.normalized.notice.degraded",
                    default: "Some usage details are unavailable."
                )
            )
        case .unavailable:
            notices.append(
                notice(
                    .unavailable,
                    key: "popover.normalized.notice.unavailable",
                    default: "The provider is currently unavailable."
                )
            )
        case .unauthenticated:
            notices.append(
                notice(
                    .unauthenticated,
                    key: "popover.normalized.notice.unauthenticated",
                    default: "Sign in again to refresh usage."
                )
            )
        case .unsupported:
            notices.append(
                notice(
                    .unsupported,
                    key: "popover.normalized.notice.unsupported_account",
                    default: "This account does not expose subscription usage."
                )
            )
        }
    }

    private static func appendConfigurationNotice(
        _ state: ProviderConfigurationState,
        to notices: inout [NormalizedUsageNotice]
    ) {
        switch state {
        case .ready:
            return
        case .unauthenticated:
            notices.append(
                notice(
                    .unauthenticated,
                    key: "popover.normalized.notice.unauthenticated",
                    default: "Sign in again to refresh usage."
                )
            )
        case .unsupported:
            notices.append(
                notice(
                    .unsupported,
                    key: "popover.normalized.notice.unsupported_account",
                    default: "This account does not expose subscription usage."
                )
            )
        case .disabled, .unlinked, .dependencyMissing, .invalid, .deleting:
            notices.append(
                notice(
                    .unavailable,
                    key: "popover.normalized.notice.configuration",
                    default: "This profile needs attention before it can refresh."
                )
            )
        }
    }

    private static func notice(
        _ kind: NormalizedUsageNotice.Kind,
        key: String,
        default defaultMessage: String
    ) -> NormalizedUsageNotice {
        NormalizedUsageNotice(
            kind: kind,
            localizationKey: key,
            defaultMessage: defaultMessage
        )
    }

    private static func deduplicated(
        _ notices: [NormalizedUsageNotice]
    ) -> [NormalizedUsageNotice] {
        var kinds = Set<NormalizedUsageNotice.Kind>()
        return notices.filter { kinds.insert($0.kind).inserted }
    }

    private static func missingPresentation(
        for profile: NormalizedUsageExpectedProfile
    ) -> NormalizedUsagePresentation {
        NormalizedUsagePresentation(
            profileID: profile.id,
            profileName: profile.name,
            providerID: profile.providerID,
            providerName: providerName(profile.providerID),
            accountName: nil,
            planName: nil,
            organizationName: nil,
            healthStatus: nil,
            groups: [],
            summary: nil,
            credits: [],
            notices: [],
            emptyState: .missingSnapshot,
            legacyClaudeUsage: nil,
            legacyClaudeAPIUsage: nil
        )
    }

    private static func providerName(_ providerID: ProviderID) -> String {
        switch providerID {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        default:
            return displayName(nil, fallback: providerID.rawValue)
        }
    }

    private static func displayName(
        _ explicitName: String?,
        fallback: String
    ) -> String {
        if let explicitName,
           !explicitName.trimmingCharacters(
               in: .whitespacesAndNewlines
           ).isEmpty {
            return explicitName
        }
        return fallback
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func headerHealthStatus(
        for emptyState: NormalizedUsageEmptyState?
    ) -> ProviderHealthStatus? {
        switch emptyState {
        case .unauthenticated:
            return .unauthenticated
        case .unsupportedAccount:
            return .unsupported
        case .disabled, .unlinked, .dependencyMissing,
             .unsupportedUsage, .invalidConfiguration,
             .unavailable, .deleting:
            return .unavailable
        case .missingSnapshot, .loading, .empty, nil:
            return nil
        }
    }
}

private extension PresentationSnapshot {
    var legacyDisplayHasContent: Bool {
        providerID == .claude
            && (claudeUsage != nil || claudeAPIUsage != nil)
    }
}

enum NormalizedUsageAccessibility {
    nonisolated static func safeComponent(_ value: String) -> String {
        value.utf8.map { byte in
            switch byte {
            case 48...57, 65...90, 97...122, 45, 95:
                return String(UnicodeScalar(byte))
            default:
                return String(format: "%%%02X", byte)
            }
        }.joined()
    }
}

enum NormalizedUsageStrings {
    static func localized(
        _ key: String,
        default defaultValue: String
    ) -> String {
        Bundle.main.localizedString(
            forKey: key,
            value: defaultValue,
            table: nil
        )
    }

    static func formatted(
        _ key: String,
        default defaultFormat: String,
        arguments: [CVarArg]
    ) -> String {
        String(
            format: Bundle.main.localizedString(
                forKey: key,
                value: defaultFormat,
                table: nil
            ),
            locale: .autoupdatingCurrent,
            arguments: arguments
        )
    }
}

struct ProviderPopoverHeader: View {
    @ObservedObject var profileManager: ProfileManager
    let presentation: NormalizedUsagePresentation
    let claudeStatus: ClaudeStatus
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onManageProfiles: () -> Void
    let onPreferences: () -> Void

    private var providerStatusText: String {
        if presentation.providerID == .claude {
            return claudeStatus.description
        }
        switch presentation.healthStatus {
        case .healthy:
            return NormalizedUsageStrings.localized(
                "popover.normalized.health.healthy",
                default: "Available"
            )
        case .degraded:
            return NormalizedUsageStrings.localized(
                "popover.normalized.health.degraded",
                default: "Partial data"
            )
        case .unavailable:
            return NormalizedUsageStrings.localized(
                "popover.normalized.health.unavailable",
                default: "Unavailable"
            )
        case .unauthenticated:
            return NormalizedUsageStrings.localized(
                "popover.normalized.health.sign_in",
                default: "Sign-in required"
            )
        case .unsupported:
            return NormalizedUsageStrings.localized(
                "popover.normalized.health.unsupported",
                default: "Unsupported account"
            )
        case nil:
            return NormalizedUsageStrings.localized(
                "popover.normalized.health.checking",
                default: "Checking usage"
            )
        }
    }

    private var accountDescription: String {
        let identity = presentation.accountName
            ?? presentation.organizationName
            ?? presentation.profileName
        if let plan = presentation.planName,
           !plan.isEmpty {
            return "\(identity) · \(plan)"
        }
        return identity
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                ProfileSwitcherCompact(
                    profileManager: profileManager,
                    onManageProfiles: onManageProfiles
                )

                HStack(spacing: 4) {
                    Text(presentation.providerName)
                        .font(.system(size: 9, weight: .semibold))
                    Text("·")
                    Text(providerStatusText)
                        .lineLimit(1)
                }
                .foregroundColor(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(
                    presentation
                        .providerHeaderAccessibilityIdentifier
                )

                Text(accountDescription)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel(
                        NormalizedUsageStrings.localized(
                            "popover.normalized.accessibility.account",
                            default: "Account"
                        )
                        + ": \(accountDescription)"
                    )
                    .accessibilityIdentifier(
                        presentation.accountAccessibilityIdentifier
                    )
            }

            Spacer()

            HStack(alignment: .center, spacing: 2) {
                HeaderIconButton(
                    icon: "arrow.clockwise",
                    isRefreshing: isRefreshing,
                    action: onRefresh
                )
                .disabled(isRefreshing)
                .accessibilityLabel(
                    NormalizedUsageStrings.localized(
                        "popover.normalized.action.refresh",
                        default: "Refresh usage"
                    )
                )
                .accessibilityIdentifier("popover.action.refresh")

                HeaderIconButton(
                    icon: "gearshape.fill",
                    fontSize: 12,
                    action: onPreferences
                )
                .accessibilityLabel(
                    NormalizedUsageStrings.localized(
                        "popover.normalized.action.settings",
                        default: "Open settings"
                    )
                )
                .accessibilityIdentifier("popover.action.settings")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct NormalizedUsageView: View {
    let presentation: NormalizedUsagePresentation
    let displayPreferences: NormalizedUsageDisplayPreferences
    let timeDisplay: PopoverTimeDisplay
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(presentation.notices) { notice in
                NormalizedUsageNoticeView(notice: notice)
            }

            if presentation.providerID == .claude,
               let usage = presentation.legacyClaudeUsage {
                SmartUsageDashboard(
                    usage: usage,
                    apiUsage: presentation.legacyClaudeAPIUsage,
                    displayPreferences: displayPreferences
                )
                .padding(.horizontal, -14)
                .padding(.vertical, -8)
            } else {
                normalizedContent(now: now)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func normalizedContent(now: Date) -> some View {
        if let state = presentation.emptyState {
            NormalizedUsageEmptyStateView(
                state: state,
                profileName: presentation.profileName
            )
        } else {
            ForEach(presentation.groups) { group in
                UsageLimitGroupView(
                    group: group,
                    displayPreferences: displayPreferences,
                    timeDisplay: timeDisplay,
                    now: now
                )
            }
            if let summary = presentation.summary {
                NormalizedUsageSummaryView(
                    summary: summary,
                    timeDisplay: timeDisplay,
                    now: now
                )
            }
            if !presentation.credits.isEmpty {
                NormalizedUsageCreditsView(
                    credits: presentation.credits,
                    timeDisplay: timeDisplay,
                    now: now
                )
            }
        }
    }
}

private struct NormalizedUsageNoticeView: View {
    let notice: NormalizedUsageNotice

    private var icon: String {
        switch notice.kind {
        case .loading:
            return "arrow.clockwise"
        case .stale:
            return "clock"
        case .degraded:
            return "exclamationmark.circle"
        case .refreshFailed, .unavailable:
            return "exclamationmark.triangle"
        case .unauthenticated:
            return "person.crop.circle.badge.exclamationmark"
        case .unsupported:
            return "nosign"
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .frame(width: 14)
            Text(
                NormalizedUsageStrings.localized(
                    notice.localizationKey,
                    default: notice.defaultMessage
                )
            )
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(0.05))
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(notice.accessibilityIdentifier)
    }
}

private struct NormalizedUsageEmptyStateView: View {
    let state: NormalizedUsageEmptyState
    let profileName: String

    private var message: (key: String, value: String) {
        switch state {
        case .missingSnapshot:
            return (
                "popover.normalized.state.missing_snapshot",
                "Usage for %@ has not loaded yet."
            )
        case .loading:
            return (
                "popover.normalized.state.loading",
                "Loading usage…"
            )
        case .empty:
            return (
                "popover.normalized.state.empty",
                "No usage limits were reported."
            )
        case .disabled:
            return (
                "popover.normalized.state.disabled",
                "Usage tracking is disabled for this provider."
            )
        case .unlinked:
            return (
                "popover.normalized.state.unlinked",
                "Link this profile before refreshing usage."
            )
        case .dependencyMissing:
            return (
                "popover.normalized.state.dependency_missing",
                "The provider command is not available."
            )
        case .unauthenticated:
            return (
                "popover.normalized.state.unauthenticated",
                "Sign in to view subscription usage."
            )
        case .unsupportedAccount:
            return (
                "popover.normalized.state.unsupported_account",
                "This account does not expose subscription usage."
            )
        case .unsupportedUsage:
            return (
                "popover.normalized.state.unsupported_usage",
                "Usage details are not supported for this provider."
            )
        case .invalidConfiguration:
            return (
                "popover.normalized.state.invalid_configuration",
                "This profile configuration needs attention."
            )
        case .unavailable:
            return (
                "popover.normalized.state.unavailable",
                "Usage is currently unavailable."
            )
        case .deleting:
            return (
                "popover.normalized.state.deleting",
                "This profile is being removed."
            )
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if state == .loading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "chart.bar.xaxis")
                    .foregroundColor(.secondary)
            }
            Text(
                state == .missingSnapshot
                    ? NormalizedUsageStrings.formatted(
                        message.key,
                        default: message.value,
                        arguments: [profileName]
                    )
                    : NormalizedUsageStrings.localized(
                        message.key,
                        default: message.value
                    )
            )
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(state.accessibilityIdentifier)
    }
}

private struct NormalizedUsageSummaryView: View {
    let summary: NormalizedUsageSummaryPresentation
    let timeDisplay: PopoverTimeDisplay
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                NormalizedUsageStrings.localized(
                    "popover.normalized.summary.title",
                    default: "Usage summary"
                )
            )
            .font(.system(size: 12, weight: .semibold))

            if summary.metrics.isEmpty,
               summary.dailyBuckets == nil {
                Text(
                    NormalizedUsageStrings.localized(
                        "popover.normalized.summary.no_values",
                        default: "No summary values were reported."
                    )
                )
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            }

            ForEach(summary.metrics) { metric in
                metricRow(metric)
                    .accessibilityIdentifier(
                        "popover.summary.metric."
                            + NormalizedUsageAccessibility
                                .safeComponent(metric.id.rawValue)
                    )
            }

            if let buckets = summary.dailyBuckets {
                if buckets.isEmpty {
                    Text(
                        NormalizedUsageStrings.localized(
                            "popover.normalized.summary.daily_empty",
                            default: "No daily usage was reported."
                        )
                    )
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                } else {
                    Text(
                        NormalizedUsageStrings.localized(
                            "popover.normalized.summary.daily_title",
                            default: "Daily usage"
                        )
                    )
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    ForEach(buckets) { bucket in
                        HStack {
                            Text(
                                NormalizedUsageFormatter.day(
                                    bucket.startedAt
                                )
                            )
                            Spacer()
                            Text(
                                bucket.metrics.map {
                                    NormalizedUsageFormatter.metric($0)
                                }.joined(separator: " · ")
                            )
                        }
                        .font(.system(size: 10))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(
                            "popover.summary.daily."
                                + String(
                                    Int(
                                        bucket.startedAt
                                            .timeIntervalSince1970
                                    )
                                )
                        )
                    }
                }
            }

            if let end = summary.periodEndsAt {
                Text(
                    NormalizedUsageFormatter.periodEnd(
                        end,
                        now: now,
                        display: timeDisplay
                    )
                )
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    Color.primary.opacity(0.1),
                    lineWidth: 0.5
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("popover.summary")
    }

    private func metricRow(_ metric: UsageMetric) -> some View {
        HStack {
            Text(metric.displayName ?? metric.id.rawValue)
                .foregroundColor(.secondary)
            Spacer()
            Text(NormalizedUsageFormatter.metric(metric))
                .fontWeight(.semibold)
        }
        .font(.system(size: 10))
    }
}

private struct NormalizedUsageCreditsView: View {
    let credits: [UsageCredit]
    let timeDisplay: PopoverTimeDisplay
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(
                    NormalizedUsageStrings.localized(
                        "popover.normalized.credits.title",
                        default: "Credits"
                    )
                )
                .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(
                    NormalizedUsageStrings.localized(
                        "popover.normalized.credits.read_only",
                        default: "Read only"
                    )
                )
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
            }
            ForEach(credits) { credit in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(credit.displayName ?? credit.id.rawValue)
                        Spacer()
                        Text(NormalizedUsageFormatter.credit(credit))
                            .fontWeight(.semibold)
                    }
                    if let reset = credit.resetsAt {
                        Text(
                            NormalizedUsageFormatter.reset(
                                reset,
                                now: now,
                                display: timeDisplay
                            )
                        )
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    }
                }
                .font(.system(size: 10))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(
                    "popover.credit."
                        + NormalizedUsageAccessibility.safeComponent(
                            credit.id.rawValue
                        )
                )
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    Color.primary.opacity(0.1),
                    lineWidth: 0.5
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("popover.credits")
    }
}

enum NormalizedUsageFormatter {
    static func percentage(
        usedPercentage: Double?,
        showRemaining: Bool
    ) -> Double? {
        guard let usedPercentage,
              usedPercentage.isFinite,
              usedPercentage >= 0 else {
            return nil
        }
        let clamped = min(usedPercentage, 100)
        return showRemaining ? 100 - clamped : clamped
    }

    static func progressFraction(
        usedPercentage: Double?,
        showRemaining: Bool
    ) -> Double {
        guard let percentage = percentage(
            usedPercentage: usedPercentage,
            showRemaining: showRemaining
        ) else {
            return 0
        }
        return min(max(percentage / 100, 0), 1)
    }

    static func percentageText(
        usedPercentage: Double?,
        showRemaining: Bool
    ) -> String {
        guard let value = percentage(
            usedPercentage: usedPercentage,
            showRemaining: showRemaining
        ) else {
            return NormalizedUsageStrings.localized(
                "popover.normalized.value.unavailable",
                default: "Unavailable"
            )
        }
        let qualifier = showRemaining
            ? NormalizedUsageStrings.localized(
                "popover.normalized.value.remaining",
                default: "remaining"
            )
            : NormalizedUsageStrings.localized(
                "popover.normalized.value.used",
                default: "used"
            )
        return "\(number(value))% \(qualifier)"
    }

    static func quantity(
        _ quantity: UsageQuantity,
        showRemaining: Bool
    ) -> String {
        let value: Double
        let qualifier: String
        if showRemaining, let limit = quantity.limit {
            value = max(limit - quantity.used, 0)
            qualifier = NormalizedUsageStrings.localized(
                "popover.normalized.value.remaining",
                default: "remaining"
            )
        } else {
            value = quantity.used
            qualifier = NormalizedUsageStrings.localized(
                "popover.normalized.value.used",
                default: "used"
            )
        }
        return "\(formattedValue(value, unit: quantity.unit, currency: quantity.currencyCode)) \(qualifier)"
    }

    static func metric(_ metric: UsageMetric) -> String {
        formattedValue(
            metric.value,
            unit: metric.unit,
            currency: metric.currencyCode
        )
    }

    static func credit(_ credit: UsageCredit) -> String {
        formattedValue(
            credit.balance,
            unit: credit.unit,
            currency: credit.currencyCode
        )
    }

    static func reset(
        _ date: Date,
        now: Date,
        display: PopoverTimeDisplay
    ) -> String {
        guard date > now else {
            return NormalizedUsageStrings.localized(
                "popover.normalized.reset.now",
                default: "Resets now"
            )
        }
        let remaining = remainingTime(
            date.timeIntervalSince(now)
        )
        let absolute = resetDate(date)
        switch display {
        case .resetTime:
            return NormalizedUsageStrings.formatted(
                "popover.normalized.reset.at",
                default: "Resets %@",
                arguments: [absolute]
            )
        case .remainingTime:
            return NormalizedUsageStrings.formatted(
                "popover.normalized.reset.in",
                default: "Resets in %@",
                arguments: [remaining]
            )
        case .both:
            return NormalizedUsageStrings.formatted(
                "popover.normalized.reset.both",
                default: "Resets in %@ (%@)",
                arguments: [remaining, absolute]
            )
        }
    }

    static func day(
        _ date: Date,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        // Codex daily buckets are provider calendar dates normalized to UTC
        // midnight. Formatting them in the viewer's local zone can move a
        // bucket to the previous day in western time zones.
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: date)
    }

    static func periodEnd(
        _ date: Date,
        now: Date,
        display: PopoverTimeDisplay
    ) -> String {
        reset(date, now: now, display: display)
    }

    private static func formattedValue(
        _ value: Double,
        unit: UsageUnit,
        currency: UsageCurrencyCode?
    ) -> String {
        if unit == .currency, let currency {
            let formatter = NumberFormatter()
            formatter.locale = .autoupdatingCurrent
            formatter.numberStyle = .currency
            formatter.currencyCode = currency.rawValue
            return formatter.string(
                from: NSNumber(value: value)
            ) ?? "\(currency.rawValue) \(number(value))"
        }
        let unitName: String
        switch unit {
        case .tokens:
            unitName = NormalizedUsageStrings.localized(
                "popover.normalized.unit.tokens",
                default: "tokens"
            )
        case .requests:
            unitName = NormalizedUsageStrings.localized(
                "popover.normalized.unit.requests",
                default: "requests"
            )
        case .count:
            unitName = ""
        default:
            unitName = unit.rawValue
        }
        return [number(value), unitName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func number(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value.rounded() == value
            ? 0
            : 2
        return formatter.string(
            from: NSNumber(value: value)
        ) ?? String(value)
    }

    private static func remainingTime(_ interval: TimeInterval) -> String {
        let totalMinutes = max(Int(interval / 60), 0)
        let days = totalMinutes / (24 * 60)
        let hours = totalMinutes % (24 * 60) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0
                ? "\(hours)h \(minutes)m"
                : "\(hours)h"
        }
        return minutes > 0 ? "\(minutes)m" : "< 1m"
    }

    private static func resetDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
