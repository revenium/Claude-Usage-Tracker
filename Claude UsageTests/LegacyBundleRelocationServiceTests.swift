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
        permanentlyDeferred: Bool = false
    ) -> LegacyBundleRelocationService {
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
            bundleURL: bundleURL
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
