import XCTest
@testable import Claude_Usage

/// Guards against a regression of the MIT compliance fix: the app bundle
/// must ship the permission notice and warranty disclaimer for both its own
/// license and Sparkle's, not just a reference to "MIT License" in the UI.
///
/// These tests run hosted inside "Claude Usage.app" (TEST_HOST), so
/// `Bundle.main` here is the real built app bundle, not the test bundle —
/// a passing run proves the resources actually land in `Contents/Resources`.
final class LicenseResourceServiceTests: XCTestCase {
    func testBundledLicensesListsAppAndSparkle() {
        let ids = LicenseResourceService.bundledLicenses.map(\.id)
        XCTAssertEqual(ids, ["app", "sparkle"])
    }

    func testEveryBundledLicenseResourceExistsInTheAppBundle() {
        for license in LicenseResourceService.bundledLicenses {
            let url = Bundle.main.url(
                forResource: license.resourceName,
                withExtension: license.resourceExtension
            )
            XCTAssertNotNil(
                url,
                "\(license.resourceName).\(license.resourceExtension) " +
                "is missing from the built app's Resources"
            )
        }
    }

    func testEveryBundledLicenseTextLoadsAndIsNonEmpty() {
        for license in LicenseResourceService.bundledLicenses {
            let text = LicenseResourceService.loadText(for: license)
            XCTAssertNotNil(
                text,
                "Failed to load text for \(license.resourceName)"
            )
            XCTAssertFalse(
                text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
                "\(license.resourceName) resolved to empty text"
            )
        }
    }

    func testAppLicenseTextContainsTheMitPermissionAndWarrantyClauses() throws {
        let appLicense = try XCTUnwrap(
            LicenseResourceService.bundledLicenses.first { $0.id == "app" }
        )
        let text = try XCTUnwrap(LicenseResourceService.loadText(for: appLicense))

        XCTAssertTrue(text.contains("Permission is hereby granted"))
        XCTAssertTrue(
            text.contains(
                "The above copyright notice and this permission notice shall be included"
            )
        )
        XCTAssertTrue(text.contains("THE SOFTWARE IS PROVIDED \"AS IS\""))
    }

    func testSparkleLicenseTextListsAllPinnedCopyrightHolders() throws {
        let sparkleLicense = try XCTUnwrap(
            LicenseResourceService.bundledLicenses.first { $0.id == "sparkle" }
        )
        let text = try XCTUnwrap(LicenseResourceService.loadText(for: sparkleLicense))

        for holder in [
            "Andy Matuschak",
            "Elgato Systems GmbH",
            "Kornel Lesiński",
            "Mayur Pawashe",
            "C.W. Betts",
            "Petroules Corporation"
        ] {
            XCTAssertTrue(
                text.contains(holder),
                "Sparkle license text is missing copyright holder: \(holder)"
            )
        }
    }

    func testLoadTextReturnsNilForAMissingResource() {
        let missing = BundledLicense(
            id: "missing",
            sectionTitleKey: "about.licenses_app_section",
            resourceName: "Does-Not-Exist-\(UUID().uuidString)",
            resourceExtension: "txt"
        )

        XCTAssertNil(LicenseResourceService.loadText(for: missing))
    }
}
