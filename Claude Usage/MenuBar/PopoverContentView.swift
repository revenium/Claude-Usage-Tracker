import SwiftUI
import Charts
import UsageCore

// MARK: - Always-active vibrancy background
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        // Base vibrancy layer
        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.isEmphasized = true
        effectView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(effectView)

        // Solid tint overlay for more density
        let tintView = NSView()
        tintView.wantsLayer = true
        if NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            tintView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        } else {
            tintView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.4).cgColor
        }
        tintView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tintView)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: container.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tintView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: container.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Update tint for appearance changes
        if let tintView = nsView.subviews.last {
            tintView.wantsLayer = true
            if NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                tintView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
            } else {
                tintView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.4).cgColor
            }
        }
    }
}

/// Native macOS popover interface - minimal, flat, system-style
struct PopoverNavigationActions {
    let manageProfiles: () -> Void
    let preferences: () -> Void
}

enum LegacyPopoverBanner: Equatable {
    enum Action: Equatable {
        case preferences
        case refresh
    }

    case credentialError
    case refreshFailed(count: Int)
    case stale(minutesAgo: Int)

    var action: Action {
        switch self {
        case .credentialError:
            return .preferences
        case .refreshFailed, .stale:
            return .refresh
        }
    }

    static func resolve(
        hasCredentialError: Bool,
        consecutiveRefreshFailures: Int,
        lastSuccessfulRefreshTime: Date?,
        now: Date
    ) -> LegacyPopoverBanner? {
        if hasCredentialError {
            return .credentialError
        }
        if consecutiveRefreshFailures >= 3 {
            return .refreshFailed(
                count: consecutiveRefreshFailures
            )
        }
        if let lastSuccessfulRefreshTime {
            let age = now.timeIntervalSince(
                lastSuccessfulRefreshTime
            )
            if age > 300 {
                return .stale(minutesAgo: Int(age / 60))
            }
        }
        return nil
    }
}

struct PopoverContentView: View {
    @ObservedObject var manager: MenuBarManager
    let onRefresh: () -> Void
    let navigationActions: PopoverNavigationActions

    @State private var isRefreshing = false
    // Replaces NSPopover's native resize animation, which can recurse indefinitely
    // on macOS 26/27 when preferredContentSize drives the hosting controller.
    @State private var appeared = false
    @ObservedObject private var profileManager: ProfileManager

    init(
        manager: MenuBarManager,
        profileManager: ProfileManager,
        onRefresh: @escaping () -> Void,
        onManageProfiles: @escaping () -> Void,
        onPreferences: @escaping () -> Void
    ) {
        self.manager = manager
        _profileManager = ObservedObject(
            wrappedValue: profileManager
        )
        self.onRefresh = onRefresh
        navigationActions = PopoverNavigationActions(
            manageProfiles: onManageProfiles,
            preferences: onPreferences
        )
    }

    private func profileInitials(for name: String) -> String {
        let words = name.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        } else if let first = words.first {
            return String(first.prefix(2)).uppercased()
        }
        return "?"
    }

    private var displayedProfile: Profile? {
        if let clickedProfileID = manager.clickedProfileId {
            return profileManager.profiles.first {
                $0.id == clickedProfileID
            }
        }
        return profileManager.activeProfile
    }

    private var displayPreferences: NormalizedUsageDisplayPreferences {
        NormalizedUsageDisplayPreferences.make(
            displayMode: profileManager.displayMode,
            displayedProfile: displayedProfile,
            multiProfileConfiguration:
                profileManager.multiProfileConfig
        )
    }

    private var timeDisplay: PopoverTimeDisplay {
        SharedDataStore.shared.loadPopoverTimeDisplay()
    }

    private func presentation(
        at now: Date
    ) -> NormalizedUsagePresentation {
        if let displayedProfile {
            return NormalizedUsagePresentationBuilder.make(
                snapshot: manager.displayedUsagePresentation,
                expectedProfile: NormalizedUsageExpectedProfile(
                    id: displayedProfile.id,
                    name: displayedProfile.name,
                    providerID: displayedProfile.providerID,
                    providerRevision:
                        displayedProfile.providerRevision
                ),
                now: now
            )
        }

        // A removed profile can remain the popover click target for one render
        // turn. Keep that target isolated instead of falling back to active
        // profile data.
        let unavailableID = manager.clickedProfileId
            ?? Self.unavailableProfileID
        return NormalizedUsagePresentationBuilder.make(
            snapshot: nil,
            expectedProfile: NormalizedUsageExpectedProfile(
                id: unavailableID,
                name: NormalizedUsageStrings.localized(
                    "popover.normalized.selected_profile",
                    default: "Selected profile"
                ),
                providerID: Self.unknownProviderID,
                providerRevision: 0
            ),
            now: now
        )
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            popoverBody(
                presentation: presentation(at: timeline.date),
                now: timeline.date
            )
        }
    }

    private func popoverBody(
        presentation: NormalizedUsagePresentation,
        now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            shellContent(
                presentation: presentation,
                now: now
            )
        }
        .padding(.bottom, 8)
        .frame(width: 280)
        .background(VisualEffectBackground())
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.96, anchor: .top)
        .onAppear {
            appeared = false
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                appeared = true
            }
        }
    }

    @ViewBuilder
    private func shellContent(
        presentation: NormalizedUsagePresentation,
        now: Date
    ) -> some View {
        ProviderPopoverHeader(
            profileManager: profileManager,
            presentation: presentation,
            claudeStatus: manager.status,
            isRefreshing: isRefreshing
                || presentation.notices.contains {
                    $0.kind == .loading
                },
            onRefresh: triggerRefresh,
            onManageProfiles:
                navigationActions.manageProfiles,
            onPreferences:
                navigationActions.preferences
        )

        PopoverDivider()

        if presentation.providerID == .claude {
            claudeBanner(now: now)
        }

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                normalizedProfileTag(
                    presentation: presentation
                )
                NormalizedUsageView(
                    presentation: presentation,
                    displayPreferences: displayPreferences,
                    timeDisplay: timeDisplay,
                    now: now
                )
            }
        }
        .frame(maxHeight: 520)
    }

    private func triggerRefresh() {
        withAnimation(.easeInOut(duration: 0.3)) {
            isRefreshing = true
        }
        onRefresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.easeInOut(duration: 0.3)) {
                isRefreshing = false
            }
        }
    }

    @ViewBuilder
    private func claudeBanner(now: Date) -> some View {
        if let banner = LegacyPopoverBanner.resolve(
            hasCredentialError: manager.hasCredentialError,
            consecutiveRefreshFailures:
                manager.consecutiveRefreshFailures,
            lastSuccessfulRefreshTime:
                manager.lastSuccessfulRefreshTime,
            now: now
        ) {
            switch banner {
            case .credentialError:
                StatusBannerView(
                    icon: "exclamationmark.triangle.fill",
                    message:
                        "popover.banner.credentials_expired".localized,
                    color: .orange,
                    onTap: navigationActions.preferences
                )
            case .refreshFailed(let count):
                StatusBannerView(
                    icon: "arrow.clockwise.circle.fill",
                    message: String(
                        format:
                            "popover.banner.refresh_failed".localized,
                        count
                    ),
                    color: .yellow,
                    onTap: onRefresh
                )
            case .stale(let minutesAgo):
                StatusBannerView(
                    icon: "clock.fill",
                    message: String(
                        format:
                            "popover.banner.updated_ago".localized,
                        minutesAgo
                    ),
                    color: .orange,
                    onTap: onRefresh
                )
            }
        }
    }

    @ViewBuilder
    private func normalizedProfileTag(
        presentation: NormalizedUsagePresentation
    ) -> some View {
        if profileManager.displayMode == .multi,
           let viewingProfile = displayedProfile {
            HStack(spacing: 8) {
                profileAvatar(for: viewingProfile)

                VStack(alignment: .leading, spacing: 1) {
                    Text(viewingProfile.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(presentation.providerName)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }

                Spacer()
                activeBadge(for: viewingProfile)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.03))
            )
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(
                "popover.profile."
                    + viewingProfile.id.uuidString
            )
        }
    }

    private func profileAvatar(for profile: Profile) -> some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 20, height: 20)

            Text(profileInitials(for: profile.name))
                .font(
                    .system(
                        size: 8,
                        weight: .bold,
                        design: .rounded
                    )
                )
                .foregroundColor(.accentColor)
        }
    }

    @ViewBuilder
    private func activeBadge(for profile: Profile) -> some View {
        if profileManager.isActive(profile) {
            Text(
                NormalizedUsageStrings.localized(
                    "popover.normalized.profile.active",
                    default: "Active"
                )
            )
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color.accentColor.opacity(0.12))
            )
        }
    }

    private static let unavailableProfileID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    private static let unknownProviderID: ProviderID = {
        guard let providerID = try? ProviderID("unknown") else {
            preconditionFailure("Invalid unknown provider identifier")
        }
        return providerID
    }()
}

// MARK: - Native Divider

struct PopoverDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 16)
    }
}

// MARK: - Profile Switcher Compact (for header)

struct ProfileSwitcherCompact: View {
    @ObservedObject private var profileManager: ProfileManager
    @State private var isHovered = false
    let onManageProfiles: () -> Void

    init(
        profileManager: ProfileManager,
        onManageProfiles: @escaping () -> Void
    ) {
        _profileManager = ObservedObject(
            wrappedValue: profileManager
        )
        self.onManageProfiles = onManageProfiles
    }

    private var rows: [ProviderProfileRowPresentation] {
        ProviderProfileRowPresentation.make(
            profiles: profileManager.profiles,
            isActive: profileManager.isActive
        )
    }

    var body: some View {
        Menu {
            ForEach(rows) { row in
                Button(action: {
                    Task {
                        await profileManager.activateProfile(row.id)
                    }
                }) {
                    ProviderProfileMenuRow(row: row)
                }
                .accessibilityIdentifier(row.accessibilityIdentifier)
            }

            Divider()

            Button(action: onManageProfiles) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12))
                    Text("popover.manage_profiles".localized)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .accessibilityIdentifier("popover.action.manage_profiles")
        } label: {
            Text(profileManager.activeProfile?.name ?? "popover.no_profile".localized)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .accessibilityIdentifier("popover.profile.switcher")
    }
}

// MARK: - Profile Switcher Bar

struct ProfileSwitcherBar: View {
    @StateObject private var profileManager = ProfileManager.shared
    @State private var isHovered = false
    let onManageProfiles: () -> Void

    private var rows: [ProviderProfileRowPresentation] {
        ProviderProfileRowPresentation.make(
            profiles: profileManager.profiles,
            isActive: profileManager.isActive
        )
    }

    var body: some View {
        Menu {
            ForEach(rows) { row in
                Button(action: {
                    Task {
                        await profileManager.activateProfile(row.id)
                    }
                }) {
                    ProviderProfileMenuRow(row: row)
                }
            }

            Divider()

            Button(action: onManageProfiles) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12))
                    Text("popover.manage_profiles".localized)
                        .font(.system(size: 12, weight: .medium))
                }
            }
        } label: {
            HStack(spacing: 8) {
                // Profile avatar
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 28, height: 28)

                    Text(profileInitials)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(profileManager.activeProfile?.name ?? "popover.no_profile".localized)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        if profileManager.profiles.count > 1 {
                            Text(String(format: "popover.profiles_count".localized, profileManager.profiles.count))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.secondary)
                        } else {
                            Text("popover.profile_count_singular".localized)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.secondary)
                        }

                        Text("•")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.5))

                        Text("common.switch".localized)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            )
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private var profileInitials: String {
        guard let name = profileManager.activeProfile?.name else { return "?" }
        let words = name.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        } else if let first = words.first {
            return String(first.prefix(2)).uppercased()
        }
        return "?"
    }
}

private struct ProviderProfileMenuRow: View {
    let row: ProviderProfileRowPresentation

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.systemImage)
                .font(.system(size: 11))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(
                    "\(row.providerName) · "
                        + row.connectionDescription
                )
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(1)
            }

            Spacer()

            if row.isActive {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityLabel(
                        NormalizedUsageStrings.localized(
                            "popover.normalized.profile.active",
                            default: "Active"
                        )
                    )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(row.accessibilityIdentifier)
    }
}

// MARK: - Header Icon Button
struct HeaderIconButton: View {
    let icon: String
    var fontSize: CGFloat = 10.5
    var isRefreshing: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 10, height: 10)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: fontSize, weight: .medium))
                        .imageScale(.medium)
                }
            }
            .foregroundColor(isHovered ? .primary : .secondary)
            .frame(width: 24, height: 24, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - API Cost Card
struct APICostCard: View {
    let apiUsage: APIUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("API Cost")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)

                    Text("This Month")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Total cost
                if let formatted = apiUsage.formattedAPICost {
                    Text(formatted)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)
                }
            }

            // Daily cost chart
            DailyCostChart(dailyCosts: apiUsage.sortedDailyCosts, currency: apiUsage.currency)

            // Per-key breakdown (if multiple sources) or flat model list
            if apiUsage.hasMultipleSources {
                VStack(spacing: 6) {
                    ForEach(apiUsage.sortedCostSources) { source in
                        APICostSourceRow(source: source, currency: apiUsage.currency)
                    }
                }
            } else {
                // Single source or no source data — show flat model breakdown
                let models = apiUsage.sortedModelCosts
                if !models.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(models, id: \.model) { item in
                            HStack {
                                Text(item.model)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)

                                Spacer()

                                Text(item.cost)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }
}

// MARK: - Daily Cost Chart
struct DailyCostChart: View {
    let dailyCosts: [(date: Date, cents: Double)]
    let currency: String

    private struct DayCost: Identifiable {
        let id: Date
        let dollars: Double
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private var xDomain: ClosedRange<Date> {
        let cal = Calendar.current
        let today = Date()
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: today))!
        // End of today (start of tomorrow)
        let endOfToday = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: today))!
        return startOfMonth ... endOfToday
    }

    var body: some View {
        if !dailyCosts.isEmpty {
            let data = dailyCosts.map { DayCost(id: $0.date, dollars: $0.cents / 100.0) }
            let maxValue = data.map(\.dollars).max() ?? 0
            Chart(data) { item in
                BarMark(
                    x: .value("Day", item.id, unit: .day),
                    y: .value("Cost", item.dollars),
                    width: .fixed(12)
                )
                .foregroundStyle(Color.orange.opacity(0.75))
                .cornerRadius(2)
            }
            .chartXScale(domain: xDomain)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { value in
                    AxisValueLabel(centered: true) {
                        if let date = value.as(Date.self) {
                            Text("\(Calendar.current.component(.day, from: date))")
                                .font(.system(size: 7))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                        .foregroundStyle(Color.secondary.opacity(0.15))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(formatDollars(v, max: maxValue))
                                .font(.system(size: 7, design: .rounded))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                    }
                }
            }
            .chartYScale(domain: 0 ... max(maxValue * 1.15, 0.01))
            .frame(height: 80)
        }
    }

    private func formatDollars(_ amount: Double, max: Double) -> String {
        if max >= 100 {
            return "$\(Int(amount))"
        } else if max >= 1 {
            return String(format: "$%.1f", amount)
        } else {
            return String(format: "$%.2f", amount)
        }
    }
}

// MARK: - API Cost Source Row
struct APICostSourceRow: View {
    let source: APICostSource
    let currency: String
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 4) {
            // Source header (tappable to expand)
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: source.sourceType.icon)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 12)

                    Text(source.keyName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Spacer()

                    Text(source.formattedTotal(currency: currency))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.6))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.06))
                )
            }
            .buttonStyle(.plain)

            // Expanded model breakdown
            if isExpanded {
                let models = source.sortedModelCosts(currency: currency)
                VStack(spacing: 3) {
                    ForEach(models, id: \.model) { item in
                        HStack {
                            Text(item.model)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.secondary)
                                .lineLimit(1)

                            Spacer()

                            Text(item.cost)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.leading, 24)
                .padding(.trailing, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - API Usage Card
struct APIUsageCard: View {
    let apiUsage: APIUsage
    let showRemaining: Bool
    var timeDisplay: PopoverTimeDisplay = .resetTime

    private var displayPercentage: Double {
        UsageStatusCalculator.getDisplayPercentage(
            usedPercentage: apiUsage.usagePercentage,
            showRemaining: showRemaining
        )
    }

    private var statusLevel: UsageStatusLevel {
        UsageStatusCalculator.calculateStatus(
            usedPercentage: apiUsage.usagePercentage,
            showRemaining: showRemaining
        )
    }

    private var usageColor: Color {
        switch statusLevel {
        case .safe: return .adaptiveGreen
        case .moderate: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("menubar.api_credits".localized)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)

                    Text("menubar.anthropic_console".localized)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text("\(Int(displayPercentage))%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(usageColor)
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Color.primary.opacity(0.08))

                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(usageColor)
                        .frame(width: geometry.size.width * min(displayPercentage / 100.0, 1.0))
                        .animation(.easeInOut(duration: 0.6), value: displayPercentage)
                }
            }
            .frame(height: 4)

            // Used / Remaining
            HStack {
                Text(apiUsage.formattedUsed)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Spacer()

                Text(apiUsage.formattedRemaining)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Reset Time
            if apiUsage.resetsAt > Date() {
                Text(resetTimeText(for: apiUsage.resetsAt))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }

    private func resetTimeText(for reset: Date) -> String {
        switch timeDisplay {
        case .resetTime:
            return "menubar.resets_time".localized(with: reset.resetTimeString())
        case .remainingTime:
            return "menubar.resets_in".localized(with: reset.timeRemainingString())
        case .both:
            return "menubar.resets_both".localized(with: reset.timeRemainingString(), reset.resetTimeString())
        }
    }
}

// MARK: - Status Banner View
struct StatusBannerView: View {
    let icon: String
    let message: String
    let color: Color
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(color)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
            Spacer()
            if onTap != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(color.opacity(0.12))
        .cornerRadius(6)
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .onTapGesture { onTap?() }
    }
}
