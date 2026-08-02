import SwiftUI

struct NormalizedUsageWindowIndicators {
    let elapsedFraction: Double?
    let timeMarkerFraction: Double?
    let paceStatus: PaceStatus?
    let statusLevel: UsageStatusLevel

    static func make(
        usedPercentage: Double?,
        resetsAt: Date?,
        duration: TimeInterval?,
        preferences: NormalizedUsageDisplayPreferences,
        now: Date
    ) -> NormalizedUsageWindowIndicators {
        let elapsed = elapsedFraction(
            resetsAt: resetsAt,
            duration: duration,
            now: now
        )
        let marker = preferences.showTimeMarker
            ? elapsed.map {
                preferences.showRemainingPercentage ? 1 - $0 : $0
            }
            : nil
        let pace: PaceStatus?
        if preferences.showPaceMarker,
           let elapsed,
           let usedPercentage,
           usedPercentage.isFinite,
           usedPercentage >= 0 {
            pace = PaceStatus.calculate(
                usedPercentage: usedPercentage,
                elapsedFraction: elapsed
            )
        } else {
            pace = nil
        }
        return NormalizedUsageWindowIndicators(
            elapsedFraction: elapsed,
            timeMarkerFraction: marker,
            paceStatus: pace,
            statusLevel: UsageStatusCalculator.calculateStatus(
                usedPercentage: usedPercentage ?? 0,
                showRemaining:
                    preferences.showRemainingPercentage,
                elapsedFraction:
                    preferences.usePaceColoring ? elapsed : nil
            )
        )
    }

    static func elapsedFraction(
        resetsAt: Date?,
        duration: TimeInterval?,
        now: Date
    ) -> Double? {
        guard let resetsAt,
              let duration,
              duration.isFinite,
              duration > 0 else {
            return nil
        }
        if resetsAt <= now { return 1 }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining.isFinite else { return nil }
        return min(max((duration - remaining) / duration, 0), 1)
    }

    static func paceSymbol(for status: PaceStatus) -> String {
        switch status {
        case .comfortable: return "↓"
        case .onTrack: return "✓"
        case .warming: return "↗"
        case .pressing: return "↑"
        case .critical: return "!"
        case .runaway: return "‼"
        }
    }

    static func paceDescription(for status: PaceStatus) -> String {
        switch status {
        case .comfortable:
            return NormalizedUsageStrings.localized(
                "popover.normalized.pace.comfortable",
                default: "Comfortable pace"
            )
        case .onTrack:
            return NormalizedUsageStrings.localized(
                "popover.normalized.pace.on_track",
                default: "On-track pace"
            )
        case .warming:
            return NormalizedUsageStrings.localized(
                "popover.normalized.pace.warming",
                default: "Warming pace"
            )
        case .pressing:
            return NormalizedUsageStrings.localized(
                "popover.normalized.pace.pressing",
                default: "Pressing pace"
            )
        case .critical:
            return NormalizedUsageStrings.localized(
                "popover.normalized.pace.critical",
                default: "Critical pace"
            )
        case .runaway:
            return NormalizedUsageStrings.localized(
                "popover.normalized.pace.runaway",
                default: "Runaway pace"
            )
        }
    }
}

struct UsageLimitGroupView: View {
    let group: NormalizedUsageGroupPresentation
    let displayPreferences: NormalizedUsageDisplayPreferences
    let timeDisplay: PopoverTimeDisplay
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PopoverSectionHeader(title: group.title)
                .padding(.leading, 2)

            if group.windows.isEmpty {
                Text(
                    NormalizedUsageStrings.localized(
                        "popover.normalized.group.empty",
                        default: "No limits were reported for this group."
                    )
                )
                .font(PopoverDesign.metaFont)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .popoverCard()
                .accessibilityIdentifier(
                    group.accessibilityIdentifier + ".empty"
                )
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(
                        Array(group.windows.enumerated()),
                        id: \.element.id
                    ) { index, window in
                        if index > 0 {
                            PopoverCardDivider()
                                .padding(.vertical, 10)
                        }
                        NormalizedUsageWindowView(
                            window: window,
                            displayPreferences: displayPreferences,
                            timeDisplay: timeDisplay,
                            now: now
                        )
                    }
                }
                .popoverCard()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(group.accessibilityIdentifier)
    }
}

private struct NormalizedUsageWindowView: View {
    let window: NormalizedUsageWindowPresentation
    let displayPreferences: NormalizedUsageDisplayPreferences
    let timeDisplay: PopoverTimeDisplay
    let now: Date

    private var showRemaining: Bool {
        displayPreferences.showRemainingPercentage
    }

    private var percentageText: String {
        NormalizedUsageFormatter.compactPercentageText(
            usedPercentage: window.usedPercentage,
            showRemaining: showRemaining
        )
    }

    private var percentageAccessibilityText: String {
        NormalizedUsageFormatter.percentageText(
            usedPercentage: window.usedPercentage,
            showRemaining: showRemaining
        )
    }

    private var indicators: NormalizedUsageWindowIndicators {
        NormalizedUsageWindowIndicators.make(
            usedPercentage: window.usedPercentage,
            resetsAt: window.resetsAt,
            duration: window.duration,
            preferences: displayPreferences,
            now: now
        )
    }

    private var statusColor: Color {
        switch indicators.statusLevel {
        case .safe:
            return .adaptiveGreen
        case .moderate:
            return .orange
        case .critical:
            return .red
        }
    }

    private var paceColor: Color {
        indicators.paceStatus?.swiftUIColor ?? .primary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(window.title)
                        .font(PopoverDesign.rowTitleFont)
                    if let quantity = window.quantity {
                        Text(
                            NormalizedUsageFormatter.quantity(
                                quantity,
                                showRemaining: showRemaining
                            )
                        )
                        .font(PopoverDesign.metaFont)
                        .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if let paceStatus = indicators.paceStatus {
                    Text(
                        NormalizedUsageWindowIndicators.paceSymbol(
                            for: paceStatus
                        )
                    )
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(paceColor)
                    .accessibilityLabel(
                        NormalizedUsageWindowIndicators.paceDescription(
                            for: paceStatus
                        )
                    )
                    .accessibilityIdentifier(
                        window.accessibilityIdentifier + ".pace"
                    )
                }
                Text(percentageText)
                    .font(PopoverDesign.valueFont)
                    .monospacedDigit()
                    .foregroundColor(
                        window.usedPercentage == nil
                            ? .secondary
                            : statusColor
                    )
                    .accessibilityIdentifier(
                        window.accessibilityIdentifier + ".value"
                    )
            }

            if window.usedPercentage != nil {
                PopoverProgressBar(
                    fraction: NormalizedUsageFormatter
                        .progressFraction(
                            usedPercentage: window.usedPercentage,
                            showRemaining: showRemaining
                        ),
                    color: statusColor,
                    markerFraction: indicators.timeMarkerFraction,
                    markerColor: paceColor
                )
                .accessibilityLabel(percentageAccessibilityText)
                .accessibilityValue(percentageAccessibilityText)
                .accessibilityIdentifier(
                    window.accessibilityIdentifier + ".progress"
                )
            }

            if let reset = window.resetsAt {
                Text(
                    NormalizedUsageFormatter.reset(
                        reset,
                        now: now,
                        display: timeDisplay
                    )
                )
                .font(PopoverDesign.metaFont)
                .foregroundColor(.secondary)
                .accessibilityIdentifier(
                    window.accessibilityIdentifier + ".reset"
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(window.accessibilityIdentifier)
    }
}
