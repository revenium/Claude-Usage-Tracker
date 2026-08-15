//
//  LegacyBundleRelocationServiceTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-08-15.
//

import XCTest

@testable import Claude_Usage

final class LegacyBundleRelocationServiceTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    private let legacyBundleIdentifier = "com.example.legacy"
    private let currentBundleIdentifier = "com.example.renamed"
    private let expectedAppFileName = "Renamed App.app"

    override func setUpWithError() throws {
        try super.setUpWithError()

        suiteName =
            "LegacyBundleRelocationServiceTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    private func makeService(
        currentBundleIdentifier: String? = nil,
        bundleFileName: String = "Legacy App.app",
        alreadyCompleted: Bool = false,
        permanentlyDeferred: Bool = false,
        restoreLaunchAtLoginPending: Bool = false,
        isLaunchAtLoginEnabled: @escaping () -> Bool = { false },
        setLaunchAtLoginEnabled: @escaping (Bool) -> Bool = { _ in true }
    ) -> LegacyBundleRelocationService {
        if restoreLaunchAtLoginPending {
            defaults.set(
                true,
                forKey: LegacyBundleRelocationService
                    .relocationRestoreLaunchAtLoginKey
            )
        }
        if alreadyCompleted {
            defaults.set(
                true,
                forKey: LegacyBundleRelocationService.relocationCompletedKey
            )
        }
        if permanentlyDeferred {
            defaults.set(
                true,
                forKey: LegacyBundleRelocationService
                    .relocationDeferredPermanentlyKey
            )
        }

        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(bundleFileName, isDirectory: true)

        return LegacyBundleRelocationService(
            defaults: defaults,
            fileManager: .default,
            currentBundleIdentifier:
                currentBundleIdentifier ?? self.currentBundleIdentifier,
            legacyBundleIdentifier: legacyBundleIdentifier,
            expectedAppFileName: expectedAppFileName,
            bundleURL: bundleURL,
            isLaunchAtLoginEnabled: isLaunchAtLoginEnabled,
            setLaunchAtLoginEnabled: setLaunchAtLoginEnabled
        )
    }

    // MARK: - Launch-at-login hand-off
    //
    // The relocated bundle re-registers itself, because registering from the
    // process whose bundle path just moved can silently point the login item
    // at a location the app no longer occupies. Silent is the operative word:
    // the user just stops being launched at login with nothing to connect it
    // to, so these cover the hand-off rather than trusting it.

    func test_restoresLaunchAtLogin_whenFlagPendingAndNameAlreadyCorrect()
        throws
    {
        var calls: [Bool] = []
        let service = makeService(
            bundleFileName: expectedAppFileName,
            restoreLaunchAtLoginPending: true,
            setLaunchAtLoginEnabled: { enabled in
                calls.append(enabled)
                return true
            }
        )

        service.relocateIfNeeded()

        XCTAssertEqual(calls, [true])
        XCTAssertFalse(
            defaults.bool(
                forKey: LegacyBundleRelocationService
                    .relocationRestoreLaunchAtLoginKey
            ),
            "the pending flag must be cleared so the restore runs exactly once"
        )
    }

    func test_doesNotTouchLaunchAtLogin_whenNoRestoreIsPending() throws {
        var calls: [Bool] = []
        let service = makeService(
            bundleFileName: expectedAppFileName,
            setLaunchAtLoginEnabled: { enabled in
                calls.append(enabled)
                return true
            }
        )

        service.relocateIfNeeded()

        XCTAssertTrue(calls.isEmpty)
    }

    func test_clearsRestoreFlag_evenWhenReregistrationFails() throws {
        let service = makeService(
            bundleFileName: expectedAppFileName,
            restoreLaunchAtLoginPending: true,
            setLaunchAtLoginEnabled: { _ in false }
        )

        service.relocateIfNeeded()

        XCTAssertFalse(
            defaults.bool(
                forKey: LegacyBundleRelocationService
                    .relocationRestoreLaunchAtLoginKey
            ),
            "a failed re-registration must not retry on every future launch"
        )
    }

    // MARK: - Should relocate

    func test_shouldOfferRelocation_whenFilenameIsStaleAndIdentityIsCurrent()
        throws
    {
        let service = makeService()
        XCTAssertTrue(service.shouldOfferRelocation())
    }

    // MARK: - No-op cases

    func test_shouldNotOffer_whenFilenameIsAlreadyCorrect() throws {
        let service = makeService(bundleFileName: expectedAppFileName)
        XCTAssertFalse(service.shouldOfferRelocation())
    }

    func test_shouldNotOffer_whenStillRunningUnderLegacyIdentity() throws {
        let service = makeService(
            currentBundleIdentifier: legacyBundleIdentifier
        )
        XCTAssertFalse(service.shouldOfferRelocation())
    }

    func test_shouldNotOffer_whenBundleIdentifierIsNil() throws {
        let service = makeService(currentBundleIdentifier: "")
        // Empty string is still a valid non-nil, non-legacy identifier;
        // verify the nil path separately via a service constructed with a
        // nil identifier.
        XCTAssertTrue(service.shouldOfferRelocation())

        let nilIdentifierService = LegacyBundleRelocationService(
            defaults: defaults,
            fileManager: .default,
            currentBundleIdentifier: nil,
            legacyBundleIdentifier: legacyBundleIdentifier,
            expectedAppFileName: expectedAppFileName,
            bundleURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "Legacy App.app",
                    isDirectory: true
                )
        )
        XCTAssertFalse(nilIdentifierService.shouldOfferRelocation())
    }

    func test_shouldNotOffer_whenAlreadyCompleted() throws {
        let service = makeService(alreadyCompleted: true)
        XCTAssertFalse(service.shouldOfferRelocation())
    }

    func test_shouldNotOffer_whenPermanentlyDeferred() throws {
        let service = makeService(permanentlyDeferred: true)
        XCTAssertFalse(service.shouldOfferRelocation())
    }

    // MARK: - UAT variant

    func test_shouldOfferRelocation_forUATVariantWithItsOwnExpectedName()
        throws
    {
        // The UAT variant has its own expected filename (e.g. "RevvyTach
        // UAT.app"); relocation logic must key off whatever
        // expectedAppFileName it was constructed with, not a hardcoded
        // release-variant name.
        let uatExpectedName = "Renamed App UAT.app"
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Legacy App.app", isDirectory: true)
        let service = LegacyBundleRelocationService(
            defaults: defaults,
            fileManager: .default,
            currentBundleIdentifier: "com.example.renamed.uat",
            legacyBundleIdentifier: "com.example.legacy.uat",
            expectedAppFileName: uatExpectedName,
            bundleURL: bundleURL
        )
        XCTAssertTrue(service.shouldOfferRelocation())
    }

    func test_shouldNotOffer_forUATVariantAlreadyAtCorrectName() throws {
        let uatExpectedName = "Renamed App UAT.app"
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(uatExpectedName, isDirectory: true)
        let service = LegacyBundleRelocationService(
            defaults: defaults,
            fileManager: .default,
            currentBundleIdentifier: "com.example.renamed.uat",
            legacyBundleIdentifier: "com.example.legacy.uat",
            expectedAppFileName: uatExpectedName,
            bundleURL: bundleURL
        )
        XCTAssertFalse(service.shouldOfferRelocation())
    }

    // MARK: - Destination

    func test_destinationURL_isSiblingOfCurrentBundleWithExpectedName()
        throws
    {
        let service = makeService()
        XCTAssertEqual(
            service.destinationURL.lastPathComponent,
            expectedAppFileName
        )
        XCTAssertEqual(
            service.destinationURL.deletingLastPathComponent().path,
            FileManager.default.temporaryDirectory.path
        )
    }
}
