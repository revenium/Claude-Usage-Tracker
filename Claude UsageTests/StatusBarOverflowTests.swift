//
//  StatusBarOverflowTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-08-07.
//

import AppKit
import UsageCore
import XCTest
@testable import Claude_Usage

@MainActor
final class StatusBarOverflowTests: HostedAppTestCase {
    private final class MenuTarget: NSObject {
        @objc func toggle() {}
    }

    /// A `MenuBarSpaceProbing` fake that returns a fixed app-menu/status-
    /// region boundary measurement (or `nil`, simulating no Accessibility
    /// grant / no measurable screen) regardless of what `StatusBarUIManager`
    /// asks for, while still substituting the caller-supplied item widths
    /// so tests reflect however many items are actually in play.
    private final class FakeSpaceProbe: MenuBarSpaceProbing {
        var fixedMeasurement: (
            appMenuMaxX: CGFloat, statusRegionMinX: CGFloat
        )?

        /// The last `currentlyOnScreenWidth` the manager passed in, so tests
        /// can assert it only ever credits us for items actually rendered.
        private(set) var lastCurrentlyOnScreenWidth: CGFloat?

        /// How many times `currentOverflowPlan` actually consulted this
        /// probe. This is the load-bearing assertion for the
        /// manager-detected regression fix: `currentOverflowPlan` must skip
        /// this Accessibility-backed call entirely once a menu bar manager
        /// is detected, not merely discard the result afterward — a test
        /// that only checked the resulting split would still pass even if
        /// the (expensive, contention-prone) probe call happened anyway.
        private(set) var makeLayoutInputCallCount = 0

        func makeLayoutInput(
            ourItemWidths: [CGFloat],
            overflowItemWidth: CGFloat,
            currentlyOnScreenWidth: CGFloat
        ) -> MenuBarLayoutInput? {
            makeLayoutInputCallCount += 1
            lastCurrentlyOnScreenWidth = currentlyOnScreenWidth
            guard let fixedMeasurement else { return nil }
            return MenuBarLayoutInput(
                appMenuMaxX: fixedMeasurement.appMenuMaxX,
                statusRegionMinX: fixedMeasurement.statusRegionMinX,
                ourItemWidths: ourItemWidths,
                overflowItemWidth: overflowItemWidth,
                currentlyOnScreenWidth: currentlyOnScreenWidth
            )
        }
    }

    private func makeProfiles(_ count: Int) -> [Profile] {
        (0..<count).map {
            Profile(name: "Profile \($0)")
        }
    }

    /// A `RunningApplicationBundleIdentifiersProviding` fake so tests can
    /// simulate "a menu bar manager is running" without any real process
    /// actually running. Mirrors `FakeSpaceProbe` immediately above.
    private final class FakeRunningApplications:
        RunningApplicationBundleIdentifiersProviding
    {
        var bundleIdentifiers: [String] = []
        var runningBundleIdentifiers: [String] { bundleIdentifiers }
    }

    // MARK: - splitForOverflow (pure logic)

    func testUpToFourProfilesNeverOverflow() {
        for count in 0...4 {
            let profiles = makeProfiles(count)
            let plan = StatusBarUIManager.splitForOverflow(profiles)
            XCTAssertEqual(
                plan.individual.count,
                count,
                "\(count) profiles must all get their own item"
            )
            XCTAssertTrue(
                plan.overflow.isEmpty,
                "\(count) profiles must never produce an overflow item"
            )
        }
    }

    func testMoreThanFourProfilesOverflowsPastTheFirstThree() {
        let profiles = makeProfiles(7)
        let plan = StatusBarUIManager.splitForOverflow(profiles)
        XCTAssertEqual(plan.individual.count, 3)
        XCTAssertEqual(plan.overflow.count, 4)
        XCTAssertEqual(
            plan.individual.map(\.id),
            Array(profiles.prefix(3)).map(\.id),
            "The first three profiles, in order, keep their own item"
        )
        XCTAssertEqual(
            plan.overflow.map(\.id),
            Array(profiles.dropFirst(3)).map(\.id)
        )
    }

    // MARK: - StatusBarUIManager integration
    //
    // Every manager here is process-retained (matching the convention
    // established by `ProviderMenuPresentationTests`) and torn down with
    // `defer { manager.cleanup() }`: letting a `StatusBarUIManager` that
    // owns real `NSStatusItem`s be deallocated mid-test — instead of
    // cleaned up while still alive — corrupts AppKit's status-bar state and
    // aborts the test process.

    func testSetupMultiProfileWithFourOrFewerCreatesNoOverflowItem() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        let target = MenuTarget()
        manager.setupMultiProfile(
            profiles: makeProfiles(4),
            target: target,
            action: #selector(MenuTarget.toggle)
        )
        XCTAssertNil(manager.overflowButton)
        XCTAssertTrue(manager.overflowProfileIDs.isEmpty)
    }

    func testSetupMultiProfileWithSevenCreatesThreeIndividualPlusOverflow() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        let target = MenuTarget()
        let profiles = makeProfiles(7)
        manager.setupMultiProfile(
            profiles: profiles,
            target: target,
            action: #selector(MenuTarget.toggle)
        )

        for profile in profiles.prefix(3) {
            XCTAssertNotNil(
                manager.button(for: profile.id),
                "\(profile.name) should have its own status item"
            )
        }
        for profile in profiles.dropFirst(3) {
            XCTAssertNil(
                manager.button(for: profile.id),
                "\(profile.name) must not get its own status item once "
                    + "overflowed"
            )
        }

        XCTAssertNotNil(manager.overflowButton)
        XCTAssertEqual(
            manager.overflowProfileIDs,
            profiles.dropFirst(3).map(\.id)
        )
        XCTAssertTrue(manager.isOverflowButton(manager.overflowButton))
        XCTAssertEqual(
            manager.autosaveName(for: manager.overflowButton),
            "claude-usage-tracker.overflow"
        )
    }

    func testUpdateMultiProfileConfigurationAddsAndRemovesOverflow() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        let target = MenuTarget()
        let action = #selector(MenuTarget.toggle)

        // Start under the threshold: no overflow item.
        manager.setupMultiProfile(
            profiles: makeProfiles(3),
            target: target,
            action: action
        )
        XCTAssertNil(manager.overflowButton)

        // Grow past the threshold: overflow item must appear.
        let grown = makeProfiles(7)
        manager.updateMultiProfileConfiguration(
            profiles: grown,
            target: target,
            action: action
        )
        XCTAssertNotNil(manager.overflowButton)
        XCTAssertEqual(manager.overflowProfileIDs.count, 4)

        // Shrink back under the threshold: overflow item must be removed.
        manager.updateMultiProfileConfiguration(
            profiles: Array(grown.prefix(2)),
            target: target,
            action: action
        )
        XCTAssertNil(manager.overflowButton)
        XCTAssertTrue(manager.overflowProfileIDs.isEmpty)
    }

    func testCleanupRemovesOverflowItem() {
        let manager = retain(StatusBarUIManager())
        let target = MenuTarget()
        manager.setupMultiProfile(
            profiles: makeProfiles(7),
            target: target,
            action: #selector(MenuTarget.toggle)
        )
        XCTAssertNotNil(manager.overflowButton)
        manager.cleanup()
        XCTAssertNil(manager.overflowButton)
        XCTAssertTrue(manager.overflowProfileIDs.isEmpty)
    }

    // MARK: - MenuBarManager.overflowProfileRows (pure logic)

    func testOverflowProfileRowsMatchOrderAndPercentage() {
        let profiles = makeProfiles(2)
        var withUsage = ClaudeUsage.empty
        withUsage.sessionPercentage = 42
        withUsage.sessionResetTime = Date().addingTimeInterval(3_600)
        var claudeProfile = profiles[0]
        claudeProfile.claudeUsage = withUsage

        let rows = MenuBarManager.overflowProfileRows(
            profileIDs: [profiles[1].id, profiles[0].id],
            profiles: [claudeProfile, profiles[1]],
            snapshots: [:],
            activeProfileID: nil
        )

        XCTAssertEqual(rows.map(\.id), [profiles[1].id, profiles[0].id])
        XCTAssertEqual(rows[0].name, profiles[1].name)
        XCTAssertEqual(rows[1].name, claudeProfile.name)
    }

    func testOverflowProfileRowsSkipsUnknownProfileIDs() {
        let profiles = makeProfiles(1)
        let missingID = UUID()
        let rows = MenuBarManager.overflowProfileRows(
            profileIDs: [profiles[0].id, missingID],
            profiles: profiles,
            snapshots: [:],
            activeProfileID: nil
        )
        XCTAssertEqual(rows.map(\.id), [profiles[0].id])
    }

    // MARK: - overflowPlan(for:mode:currentCollapsedCount:spaceInput:) (pure logic)

    func testOverflowPlanNeverModeKeepsEveryProfileIndividualRegardlessOfCount() {
        let profiles = makeProfiles(20)
        let plan = StatusBarUIManager.overflowPlan(
            for: profiles,
            mode: .never,
            currentCollapsedCount: 0,
            spaceInput: nil
        )
        XCTAssertEqual(plan.individual.count, 20)
        XCTAssertTrue(plan.overflow.isEmpty)
    }

    func testOverflowPlanAfterCountModeUsesTheConfiguredThreshold() {
        let profiles = makeProfiles(8)
        let plan = StatusBarUIManager.overflowPlan(
            for: profiles,
            mode: .afterCount(6),
            currentCollapsedCount: 0,
            spaceInput: nil
        )
        XCTAssertEqual(plan.individual.count, 5)
        XCTAssertEqual(plan.overflow.count, 3)
    }

    func testOverflowPlanAutomaticModeWithNoSpaceInputNeverCollapses() {
        // No screen to measure against (e.g. fully headless) — automatic
        // mode must fall back to never collapsing rather than guess.
        let profiles = makeProfiles(20)
        let plan = StatusBarUIManager.overflowPlan(
            for: profiles,
            mode: .automatic,
            currentCollapsedCount: 0,
            spaceInput: nil
        )
        XCTAssertEqual(plan.individual.count, 20)
        XCTAssertTrue(plan.overflow.isEmpty)
    }

    func testOverflowPlanAutomaticModeCollapsesWhenSpaceIsInsufficient() {
        let profiles = makeProfiles(5)
        let spaceInput = MenuBarLayoutInput(
            appMenuMaxX: 0,
            statusRegionMinX: 108,
            ourItemWidths: Array(repeating: CGFloat(40), count: 5),
            overflowItemWidth: 30,
            currentlyOnScreenWidth: 0
        )
        // freeWidth = 108 - 0 - 8 (gutter) = 100; 5 * 40 = 200 does not fit.
        let plan = StatusBarUIManager.overflowPlan(
            for: profiles,
            mode: .automatic,
            currentCollapsedCount: 0,
            spaceInput: spaceInput
        )
        XCTAssertFalse(plan.overflow.isEmpty)
        XCTAssertEqual(plan.individual.count + plan.overflow.count, 5)
        XCTAssertNotEqual(
            plan.overflow.count,
            1,
            "must never collapse exactly one profile"
        )
    }

    func testOverflowPlanAutomaticModeDoesNotCollapseWhenAKnownManagerIsRunning() {
        // Identical to
        // testOverflowPlanAutomaticModeCollapsesWhenSpaceIsInsufficient
        // above (freeWidth = 100, five 40pt items do not fit), except a
        // known menu bar manager is also running. The measurement is
        // exactly as insufficient as before, but the guard must still keep
        // every profile individual — a manager already reserved an
        // expandable region for this, so collapsing would be wrong even
        // though the free-space arithmetic is unchanged.
        let profiles = makeProfiles(5)
        let spaceInput = MenuBarLayoutInput(
            appMenuMaxX: 0,
            statusRegionMinX: 108,
            ourItemWidths: Array(repeating: CGFloat(40), count: 5),
            overflowItemWidth: 30,
            currentlyOnScreenWidth: 0
        )
        let plan = StatusBarUIManager.overflowPlan(
            for: profiles,
            mode: .automatic,
            currentCollapsedCount: 0,
            spaceInput: spaceInput,
            runningBundleIdentifiers: ["com.jordanbaird.Ice"]
        )
        XCTAssertEqual(plan.individual.count, 5)
        XCTAssertTrue(plan.overflow.isEmpty)
    }

    func testOverflowPlanAutomaticModeCollapsesWhenNoKnownManagerIsRunning() {
        // The fail-safe direction of the same guard: an app that is NOT on
        // `MenuBarManagerDetection.knownManagers` must not suppress
        // collapsing, even alongside other unrelated running applications.
        let profiles = makeProfiles(5)
        let spaceInput = MenuBarLayoutInput(
            appMenuMaxX: 0,
            statusRegionMinX: 108,
            ourItemWidths: Array(repeating: CGFloat(40), count: 5),
            overflowItemWidth: 30,
            currentlyOnScreenWidth: 0
        )
        let plan = StatusBarUIManager.overflowPlan(
            for: profiles,
            mode: .automatic,
            currentCollapsedCount: 0,
            spaceInput: spaceInput,
            runningBundleIdentifiers: [
                "com.apple.finder", "com.apple.Safari"
            ]
        )
        XCTAssertFalse(plan.overflow.isEmpty)
    }

    // MARK: - StatusBarUIManager.overflowMode integration

    func testNeverModeCreatesNoOverflowItemForManyProfiles() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        manager.overflowMode = .never
        let target = MenuTarget()
        let profiles = makeProfiles(12)
        manager.setupMultiProfile(
            profiles: profiles,
            target: target,
            action: #selector(MenuTarget.toggle)
        )

        XCTAssertNil(manager.overflowButton)
        for profile in profiles {
            XCTAssertNotNil(
                manager.button(for: profile.id),
                "\(profile.name) must keep its own item in .never mode"
            )
        }
    }

    func testAfterCountModeWithCustomThresholdOnAnInstance() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        manager.overflowMode = .afterCount(6)
        let target = MenuTarget()
        let profiles = makeProfiles(8)
        manager.setupMultiProfile(
            profiles: profiles,
            target: target,
            action: #selector(MenuTarget.toggle)
        )

        XCTAssertNotNil(manager.overflowButton)
        XCTAssertEqual(manager.overflowProfileIDs.count, 3)
        for profile in profiles.prefix(5) {
            XCTAssertNotNil(manager.button(for: profile.id))
        }
    }

    func testAutomaticModeCollapsesUsingInjectedSpaceProbe() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        manager.overflowMode = .automatic
        let fakeProbe = FakeSpaceProbe()
        // freeWidth = 108 - 0 - 8 (gutter) = 100pt: far too little for 5
        // items that report ~40pt each (the estimated default width for
        // items that don't have a real status item window yet).
        fakeProbe.fixedMeasurement = (
            appMenuMaxX: 0, statusRegionMinX: 108
        )
        manager.spaceProbe = fakeProbe
        // Isolate this test from whatever menu bar managers actually happen
        // to be running on the machine executing it — the default
        // `NSWorkspaceRunningApplications()` would otherwise make this test
        // pass or fail depending on real, un-mocked machine state (this is
        // exactly what caught the manager-detection guard suppressing
        // collapse on a developer machine running Thaw).
        manager.runningApplicationsProvider = FakeRunningApplications()
        let target = MenuTarget()
        let profiles = makeProfiles(5)
        manager.setupMultiProfile(
            profiles: profiles,
            target: target,
            action: #selector(MenuTarget.toggle)
        )

        XCTAssertNotNil(
            manager.overflowButton,
            "narrow simulated menu bar space must force a collapse"
        )
        XCTAssertFalse(manager.overflowProfileIDs.isEmpty)
        XCTAssertNotEqual(
            manager.overflowProfileIDs.count,
            1,
            "must never collapse exactly one profile"
        )
        // `setupMultiProfile` cleans up every prior status item before
        // computing this plan, so none of the 5 new profiles have a
        // status item yet. `currentlyOnScreenWidth` must reflect that
        // truthfully as 0 rather than crediting the estimated ~40pt
        // fallback width for items that are not actually on the menu bar
        // yet — the probe's status region measurement already accounts
        // only for items truly on screen.
        XCTAssertEqual(
            fakeProbe.lastCurrentlyOnScreenWidth,
            0,
            "must not credit unrendered items an estimated width; only "
                + "items actually on screen may count toward "
                + "currentlyOnScreenWidth"
        )
    }

    func testAutomaticModeDoesNotCollapseWhenRunningApplicationsProviderReportsAKnownManager() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        manager.overflowMode = .automatic
        let fakeProbe = FakeSpaceProbe()
        // Same narrow simulated space as
        // testAutomaticModeCollapsesUsingInjectedSpaceProbe, which collapses
        // without a manager present.
        fakeProbe.fixedMeasurement = (
            appMenuMaxX: 0, statusRegionMinX: 108
        )
        manager.spaceProbe = fakeProbe
        let fakeRunningApplications = FakeRunningApplications()
        fakeRunningApplications.bundleIdentifiers = ["com.stonerl.Thaw"]
        manager.runningApplicationsProvider = fakeRunningApplications
        let target = MenuTarget()
        let profiles = makeProfiles(5)
        manager.setupMultiProfile(
            profiles: profiles,
            target: target,
            action: #selector(MenuTarget.toggle)
        )

        XCTAssertNil(
            manager.overflowButton,
            "a detected menu bar manager must suppress collapsing even "
                + "when the measured space is the same narrow width that "
                + "collapses without one"
        )
        for profile in profiles {
            XCTAssertNotNil(manager.button(for: profile.id))
        }
    }

    /// Regression test for the shipped bug where a detected menu bar
    /// manager (Ice, Thaw, Bartender, ...) still paid for the Accessibility
    /// probe on every replan even though its result was always discarded.
    /// That contention, on a machine where the manager is simultaneously
    /// driving our own status item windows via synthetic drag events, made
    /// Thaw's move events time out and locked up its rearrange UI —
    /// asserting only on the resulting split (as
    /// `testAutomaticModeDoesNotCollapseWhenRunningApplicationsProviderReportsAKnownManager`
    /// does) would still pass even with the probe firing uselessly every
    /// time, so this asserts directly on the call count instead.
    func testAutomaticModeNeverConsultsSpaceProbeWhenManagerDetected() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        manager.overflowMode = .automatic
        let fakeProbe = FakeSpaceProbe()
        // Narrow enough to force a collapse if the probe were consulted —
        // proving the split below comes from skipping the probe, not from
        // the probe happening to report ample space.
        fakeProbe.fixedMeasurement = (
            appMenuMaxX: 0, statusRegionMinX: 108
        )
        manager.spaceProbe = fakeProbe
        let fakeRunningApplications = FakeRunningApplications()
        fakeRunningApplications.bundleIdentifiers = ["com.stonerl.Thaw"]
        manager.runningApplicationsProvider = fakeRunningApplications
        let target = MenuTarget()
        let profiles = makeProfiles(5)
        manager.setupMultiProfile(
            profiles: profiles,
            target: target,
            action: #selector(MenuTarget.toggle)
        )

        XCTAssertEqual(
            fakeProbe.makeLayoutInputCallCount,
            0,
            "a detected menu bar manager must skip the Accessibility probe "
                + "entirely, not merely discard its result — the probe "
                + "contends with the manager's own AX-driven item moves"
        )
        XCTAssertNil(manager.overflowButton)
        for profile in profiles {
            XCTAssertNotNil(manager.button(for: profile.id))
        }
    }

    /// Companion to `testAutomaticModeNeverConsultsSpaceProbeWhenManagerDetected`:
    /// proves the manager-detected skip didn't also disable the probe when
    /// no manager is present. Without a manager, `.automatic` must consult
    /// the probe exactly as before, and collapsing must still happen when
    /// simulated space is insufficient.
    func testAutomaticModeConsultsSpaceProbeWhenNoManagerDetected() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        manager.overflowMode = .automatic
        let fakeProbe = FakeSpaceProbe()
        fakeProbe.fixedMeasurement = (
            appMenuMaxX: 0, statusRegionMinX: 108
        )
        manager.spaceProbe = fakeProbe
        manager.runningApplicationsProvider = FakeRunningApplications()
        let target = MenuTarget()
        let profiles = makeProfiles(5)
        manager.setupMultiProfile(
            profiles: profiles,
            target: target,
            action: #selector(MenuTarget.toggle)
        )

        XCTAssertEqual(
            fakeProbe.makeLayoutInputCallCount,
            1,
            "with no manager detected, the probe must still be consulted "
                + "exactly once per replan, same as before this fix"
        )
        XCTAssertNotNil(
            manager.overflowButton,
            "collapsing must still happen when space is insufficient and "
                + "no manager is present"
        )
        XCTAssertFalse(manager.overflowProfileIDs.isEmpty)
    }

    func testAutomaticModeNeverCollapsesWhenSpaceIsAmple() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        manager.overflowMode = .automatic
        let fakeProbe = FakeSpaceProbe()
        // A very wide simulated gap between the app menus and the status
        // region: plenty of room for every profile.
        fakeProbe.fixedMeasurement = (
            appMenuMaxX: 0, statusRegionMinX: 6008
        )
        manager.spaceProbe = fakeProbe
        // See testAutomaticModeCollapsesUsingInjectedSpaceProbe: keep this
        // test's outcome independent of whatever is actually running on the
        // machine executing it.
        manager.runningApplicationsProvider = FakeRunningApplications()
        let target = MenuTarget()
        let profiles = makeProfiles(7)
        manager.setupMultiProfile(
            profiles: profiles,
            target: target,
            action: #selector(MenuTarget.toggle)
        )

        XCTAssertNil(manager.overflowButton)
        for profile in profiles {
            XCTAssertNotNil(manager.button(for: profile.id))
        }
    }

    // MARK: - Preserving menu bar positions (not destroying items that may
    // come back)
    //
    // `StatusBarUIManager.cleanup()` used to call `removeStatusItem` on
    // every item unconditionally, including on the application-termination
    // path — which discards AppKit's persisted
    // `"NSStatusItem Preferred Position <autosaveName>"` entry for that item
    // and is why every menu bar manager (Bartender/Ice/Thaw) arrangement was
    // lost on every app restart. AppKit's actual persistence behavior can't
    // be exercised from a unit test (see the doc comment on
    // `cleanup(isApplicationTerminating:)`), so these tests instead cover
    // the decisions the fix is built from: which items get
    // `removeStatusItem` at all, and — since keeping a collapsed-into-
    // overflow item alive-but-hidden only pays off if it doesn't silently
    // reappear in width or lookup calculations — that a hidden item behaves
    // exactly like a removed one everywhere except AppKit's own bookkeeping.

    func testShouldRemoveStatusItemIsFalseOnlyWhenApplicationIsTerminating() {
        XCTAssertFalse(
            StatusBarUIManager.shouldRemoveStatusItem(
                isApplicationTerminating: true
            ),
            "the app-quit path must never call removeStatusItem — doing so "
                + "discards AppKit's persisted menu bar position"
        )
        XCTAssertTrue(
            StatusBarUIManager.shouldRemoveStatusItem(
                isApplicationTerminating: false
            ),
            "every other teardown (config reload, display-mode switch, "
                + "multi-profile setup) is a genuine removal and must keep "
                + "removing items as before"
        )
    }

    func testReconcileMultiProfileItemsRemovesOnlyDeselectedProfiles() {
        let stillHere = UUID()
        let collapsedIntoOverflow = UUID()
        let deselected = UUID()
        let brandNew = UUID()

        let result = StatusBarUIManager.reconcileMultiProfileItems(
            currentIDs: [stillHere, collapsedIntoOverflow, deselected],
            stillSelectedIDs: [stillHere, collapsedIntoOverflow, brandNew]
        )

        XCTAssertEqual(
            result.idsToRemove,
            [deselected],
            "only a profile absent from stillSelectedIDs — genuinely "
                + "deselected or deleted — may be removed; a profile that "
                + "merely crossed into overflow is still selected and must "
                + "not be marked for removal"
        )
        XCTAssertEqual(result.idsToAdd, [brandNew])
    }

    func testReconcileMultiProfileItemsRemovesNothingWhenEveryProfileStaysSelected() {
        let a = UUID()
        let b = UUID()
        let result = StatusBarUIManager.reconcileMultiProfileItems(
            currentIDs: [a, b],
            stillSelectedIDs: [a, b]
        )
        XCTAssertTrue(result.idsToRemove.isEmpty)
        XCTAssertTrue(result.idsToAdd.isEmpty)
    }

    func testUpdateMultiProfileConfigurationHidesRatherThanRemovesAProfileThatCollapsesIntoOverflow() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        manager.overflowMode = .afterCount(4)
        let target = MenuTarget()
        let action = #selector(MenuTarget.toggle)

        let individual = makeProfiles(3)
        manager.setupMultiProfile(
            profiles: individual,
            target: target,
            action: action
        )
        for profile in individual {
            XCTAssertNotNil(manager.button(for: profile.id))
        }
        let originalIdentities = individual.map {
            manager.multiProfileItemIdentityForTesting($0.id)
        }
        XCTAssertTrue(originalIdentities.allSatisfy { $0 != nil })

        // Add 4 more profiles. With threshold 4, only the first 3 (the
        // original set, unchanged) stay individual; the 4 new ones collapse
        // into overflow.
        let overflowed = makeProfiles(4)
        manager.updateMultiProfileConfiguration(
            profiles: individual + overflowed,
            target: target,
            action: action
        )

        for profile in individual {
            XCTAssertNotNil(
                manager.button(for: profile.id),
                "\(profile.name) must remain individually visible"
            )
        }
        XCTAssertEqual(
            individual.map { manager.multiProfileItemIdentityForTesting($0.id) },
            originalIdentities,
            "profiles that stay individual must keep their original "
                + "NSStatusItem — not be torn down and recreated"
        )
        for profile in overflowed {
            XCTAssertNil(
                manager.button(for: profile.id),
                "\(profile.name) collapsed into overflow has no visible "
                    + "button"
            )
            XCTAssertNotNil(
                manager.multiProfileItemIdentityForTesting(profile.id),
                "\(profile.name)'s item must still exist, hidden, rather "
                    + "than being removed — it may become individual again"
            )
        }

        // Switch to `.never` so every profile — including the 4 that were
        // overflowed — becomes individual again, and must reuse the SAME
        // item it was hidden behind rather than a freshly created one.
        let hiddenIdentitiesBeforeReturn = overflowed.map {
            manager.multiProfileItemIdentityForTesting($0.id)
        }
        manager.overflowMode = .never
        manager.updateMultiProfileConfiguration(
            profiles: individual + overflowed,
            target: target,
            action: action
        )
        for profile in overflowed {
            XCTAssertNotNil(
                manager.button(for: profile.id),
                "\(profile.name) must become visible again once it's no "
                    + "longer overflowed"
            )
        }
        XCTAssertEqual(
            overflowed.map { manager.multiProfileItemIdentityForTesting($0.id) },
            hiddenIdentitiesBeforeReturn,
            "a profile returning from overflow must reuse the item it was "
                + "hidden behind, not a new one with a new window ID"
        )
    }

    func testUpdateOverflowItemReusesTheSameItemAcrossEmptyAndNonEmptyCycles() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        let target = MenuTarget()
        let action = #selector(MenuTarget.toggle)

        manager.setupMultiProfile(
            profiles: makeProfiles(7),
            target: target,
            action: action
        )
        let originalIdentity = manager.overflowItemIdentityForTesting
        XCTAssertNotNil(originalIdentity)
        XCTAssertNotNil(manager.overflowButton)

        // Shrink under the threshold: overflow empties out.
        manager.updateMultiProfileConfiguration(
            profiles: makeProfiles(2),
            target: target,
            action: action
        )
        XCTAssertNil(
            manager.overflowButton,
            "no overflow currently needed must look identical to callers, "
                + "whether or not the item survives underneath"
        )
        XCTAssertEqual(
            manager.overflowItemIdentityForTesting,
            originalIdentity,
            "the overflow item must be hidden, not removed, when it "
                + "empties out — it routinely refills again"
        )

        // Grow back past the threshold: overflow reappears and must be the
        // same item, not a freshly created one.
        manager.updateMultiProfileConfiguration(
            profiles: makeProfiles(7),
            target: target,
            action: action
        )
        XCTAssertNotNil(manager.overflowButton)
        XCTAssertEqual(
            manager.overflowItemIdentityForTesting,
            originalIdentity,
            "reappearing overflow must reuse the original item, preserving "
                + "its AppKit-persisted menu bar position"
        )
    }

    func testMultiProfileItemHiddenBehindOverflowContributesNoWidth() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        manager.overflowMode = .afterCount(4)
        let target = MenuTarget()
        let action = #selector(MenuTarget.toggle)
        let config = MultiProfileDisplayConfig()

        let individual = makeProfiles(3)
        manager.setupMultiProfile(
            profiles: individual,
            target: target,
            action: action
        )
        // Paint real images so `itemWidth(for:)` has non-zero content to
        // fall back to even without a laid-out AppKit window (this test
        // process's status items are not necessarily on screen).
        manager.updateMultiProfileButtons(profiles: individual, config: config)
        let widthWithThreeVisible =
            manager.multiProfileItemsOnScreenWidthForTesting
        XCTAssertGreaterThan(
            widthWithThreeVisible,
            0,
            "3 rendered, visible individual items must contribute non-zero "
                + "width"
        )

        let overflowed = makeProfiles(4)
        let grown = individual + overflowed
        manager.updateMultiProfileConfiguration(
            profiles: grown,
            target: target,
            action: action
        )
        // Render the newly-added (hidden) items too, so a bug that credits
        // them width can't hide behind "well, they were never painted".
        manager.updateMultiProfileButtons(profiles: grown, config: config)

        XCTAssertEqual(
            manager.multiProfileItemsOnScreenWidthForTesting,
            widthWithThreeVisible,
            accuracy: 0.01,
            "profiles collapsed into overflow are kept alive but hidden; "
                + "they must contribute exactly zero width, the same as if "
                + "they had been removed outright"
        )
    }
}
