//
//  StatusBarUIManagerIntendedWidthTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-08-08.
//

import AppKit
import UsageCore
import XCTest
@testable import Claude_Usage

/// Covers the intended-width machinery `currentOverflowPlan(for:)` relies on
/// to plan the overflow split from what a profile's item WILL render as,
/// rather than a render-behind measurement or the old hardcoded 40pt
/// estimate. See `StatusBarOverflowTests` for the overflow-plan tests this
/// complements.
@MainActor
final class StatusBarUIManagerIntendedWidthTests: HostedAppTestCase {
    private func makeProfile(sessionPercentage: Double) -> Profile {
        var usage = ClaudeUsage.empty
        usage.sessionPercentage = sessionPercentage
        usage.sessionResetTime = Date().addingTimeInterval(3_600)
        var profile = Profile(name: "Test")
        profile.claudeUsage = usage
        return profile
    }

    // MARK: - renderProfileMenuBar

    func testRenderProfileMenuBarWidthIsIndependentOfDarkMode() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        let profile = makeProfile(sessionPercentage: 42)
        let config = MultiProfileDisplayConfig()

        let light = manager.renderProfileMenuBar(
            for: profile,
            config: config,
            isDarkMode: false,
            isActive: false
        )
        let dark = manager.renderProfileMenuBar(
            for: profile,
            config: config,
            isDarkMode: true,
            isActive: false
        )

        XCTAssertEqual(
            light.image.size.width,
            dark.image.size.width,
            accuracy: 0.01,
            "appearance changes colour only; geometry must not depend on it "
                + "— intendedItemWidth always renders isDarkMode: false"
        )
    }

    // MARK: - intendedItemWidth

    func testIntendedItemWidthVariesWithPercentageDigitCount() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        // Profile label off: it's clamped to a fixed 3-character floor
        // (`String(profileName.prefix(3)).count * 6 + 4`) that would
        // otherwise mask small differences in the percentage text's own
        // width for a short profile name.
        let config = MultiProfileDisplayConfig(
            iconStyle: .percentage,
            showWeek: false,
            showProfileLabel: false
        )

        let oneDigit = manager.intendedItemWidth(
            for: makeProfile(sessionPercentage: 5),
            config: config,
            isActive: false
        )
        let twoDigits = manager.intendedItemWidth(
            for: makeProfile(sessionPercentage: 42),
            config: config,
            isActive: false
        )
        let threeDigits = manager.intendedItemWidth(
            for: makeProfile(sessionPercentage: 100),
            config: config,
            isActive: false
        )

        XCTAssertNotEqual(
            oneDigit,
            twoDigits,
            "a 1-digit and a 2-digit percentage must not render the same width"
        )
        XCTAssertNotEqual(
            twoDigits,
            threeDigits,
            "a 2-digit and a 3-digit percentage must not render the same width"
        )
        XCTAssertNotEqual(
            twoDigits,
            StatusBarUIManager.estimatedProfileItemWidth,
            "must not silently collapse back to the old hardcoded 40pt estimate"
        )
    }

    func testIntendedItemWidthVariesWithShowWeek() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        let profile = makeProfile(sessionPercentage: 42)
        let withoutWeek = MultiProfileDisplayConfig(
            iconStyle: .percentage,
            showWeek: false,
            showProfileLabel: false
        )
        let withWeek = MultiProfileDisplayConfig(
            iconStyle: .percentage,
            showWeek: true,
            showProfileLabel: false
        )

        let widthWithoutWeek = manager.intendedItemWidth(
            for: profile,
            config: withoutWeek,
            isActive: false
        )
        let widthWithWeek = manager.intendedItemWidth(
            for: profile,
            config: withWeek,
            isActive: false
        )

        XCTAssertNotEqual(
            widthWithoutWeek,
            widthWithWeek,
            "showing the weekly window must change the rendered width — "
                + "it is not a constant, which is what the 40pt estimate got wrong"
        )
    }

    // MARK: - calibratedButtonPadding

    func testCalibratedButtonPaddingReturnsNilWithNoQualifyingItem() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }

        XCTAssertNil(
            manager.calibratedButtonPadding(),
            "with no status item created yet, no button has both a "
                + "laid-out window and an image to measure"
        )
    }
}
