import SwiftUI

/// Design tokens for the menu bar popover. One place controls the popover's
/// spacing rhythm, type scale, card treatment, and provider accents so the
/// header, usage cards, notices, and banners stay visually coherent.
enum PopoverDesign {
    // MARK: - Layout

    /// Total popover content width. Matches
    /// `Constants.WindowSizes.popoverSize.width` so the SwiftUI content
    /// fills the NSPopover instead of leaving dead margin.
    static let width: CGFloat = 320

    /// Horizontal inset applied to every top-level section.
    static let outerInset: CGFloat = 16

    /// Vertical spacing between stacked sections.
    static let sectionSpacing: CGFloat = 10

    /// Corner radius for grouped cards.
    static let cardRadius: CGFloat = 10

    /// Padding inside grouped cards.
    static let cardPadding: CGFloat = 12

    // MARK: - Type scale

    /// Primary identity (profile name in the header).
    static let identityFont = Font.system(size: 14, weight: .semibold)

    /// Metric row title ("Session", "Weekly").
    static let rowTitleFont = Font.system(size: 13, weight: .medium)

    /// Percentage values; monospaced digits keep columns steady while
    /// values refresh.
    static let valueFont = Font.system(
        size: 13, weight: .semibold, design: .rounded
    )

    /// Supporting metadata (reset times, quantities, status line).
    static let metaFont = Font.system(size: 11)

    /// Section headers rendered above grouped cards.
    static let sectionHeaderFont = Font.system(
        size: 11, weight: .semibold
    )

    /// Small emphasized labels (chips, badges).
    static let chipFont = Font.system(size: 11, weight: .medium)

    // MARK: - Surfaces

    /// Fill for grouped cards. An opacity-based fill (rather than a stroked
    /// outline) reads as one grouped surface over the popover material in
    /// both light and dark mode.
    static let cardFill = Color.primary.opacity(0.05)

    /// Slightly stronger fill for interactive hover states.
    static let hoverFill = Color.primary.opacity(0.08)

    /// Track color behind progress bars.
    static let progressTrack = Color.primary.opacity(0.1)

    /// Progress bar height.
    static let progressHeight: CGFloat = 6

    // MARK: - Provider accents

    /// Claude's terracotta brand accent; used sparingly (avatar, provider
    /// glyphs) so status colors keep their semantic meaning.
    static let claudeAccent = Color(
        .sRGB, red: 0.85, green: 0.47, blue: 0.34, opacity: 1
    )

    /// Codex renders neutral — its brand is monochrome.
    static let codexAccent = Color.secondary

    static func providerAccent(named providerName: String) -> Color {
        providerName.caseInsensitiveCompare("Claude") == .orderedSame
            ? claudeAccent
            : codexAccent
    }

    static func providerGlyph(named providerName: String) -> String {
        providerName.caseInsensitiveCompare("Claude") == .orderedSame
            ? "sparkles"
            : "chevron.left.forwardslash.chevron.right"
    }
}

// MARK: - Section header

/// Uppercase tracked section label rendered above a grouped card, giving
/// sections like "Subscription" and "Fable" a distinct visual level instead
/// of competing with row titles.
struct PopoverSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(PopoverDesign.sectionHeaderFont)
            .textCase(.uppercase)
            .kerning(0.6)
            .foregroundColor(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Card container

struct PopoverCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(PopoverDesign.cardPadding)
            .background(
                RoundedRectangle(
                    cornerRadius: PopoverDesign.cardRadius,
                    style: .continuous
                )
                .fill(PopoverDesign.cardFill)
            )
    }
}

extension View {
    /// Wraps content in the popover's standard grouped-card surface.
    func popoverCard() -> some View {
        modifier(PopoverCardModifier())
    }
}

// MARK: - Inset divider

/// Hairline divider between rows inside a grouped card.
struct PopoverCardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
    }
}

// MARK: - Progress bar

/// Capsule progress bar shared by every usage row, with the optional
/// pace/time marker preserved from the previous design.
struct PopoverProgressBar: View {
    let fraction: Double
    let color: Color
    var markerFraction: Double? = nil
    var markerColor: Color = .primary

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(PopoverDesign.progressTrack)
                Capsule()
                    .fill(color)
                    .frame(
                        width: max(
                            geometry.size.width
                                * min(max(fraction, 0), 1),
                            fraction > 0
                                ? PopoverDesign.progressHeight
                                : 0
                        )
                    )
                    .animation(
                        .easeInOut(duration: 0.6),
                        value: fraction
                    )
            }
            .overlay(alignment: .leading) {
                if let markerFraction {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(markerColor)
                        .frame(width: 2.5, height: 10)
                        .offset(
                            x: round(
                                geometry.size.width
                                    * min(max(markerFraction, 0), 1)
                            ) - 1.25
                        )
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(height: PopoverDesign.progressHeight)
    }
}
