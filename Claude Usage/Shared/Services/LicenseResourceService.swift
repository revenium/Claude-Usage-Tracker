//
//  LicenseResourceService.swift
//  Claude Usage - Bundled License Texts
//
//  Created by Claude Code on 2026-08-12.
//

import Foundation

/// A license text vendored into the app bundle's Resources so it ships with
/// every distributed copy, as MIT requires (see
/// `Claude Usage/Resources/Licenses/NOTICE.txt` for provenance).
struct BundledLicense: Identifiable {
    let id: String
    let sectionTitleKey: String
    let resourceName: String
    let resourceExtension: String
}

/// Loads the license texts vendored under `Claude Usage/Resources/Licenses/`.
///
/// Files added under the project's synchronized `Claude Usage` folder are
/// copied into `Contents/Resources` flat (subfolders are not preserved as
/// folder references), so these are looked up at the bundle root rather than
/// under a `Licenses/` subdirectory. Verified by inspecting a built `.app`.
enum LicenseResourceService {
    /// Ordered list of licenses shown in the About > Licenses sheet.
    static let bundledLicenses: [BundledLicense] = [
        BundledLicense(
            id: "app",
            sectionTitleKey: "about.licenses_app_section",
            resourceName: "Claude-Usage-Tracker-LICENSE",
            resourceExtension: "txt"
        ),
        BundledLicense(
            id: "sparkle",
            sectionTitleKey: "about.licenses_sparkle_section",
            resourceName: "Sparkle-LICENSE",
            resourceExtension: "txt"
        )
    ]

    /// Loads the text of a bundled license, or `nil` if the resource is
    /// missing or unreadable.
    static func loadText(for license: BundledLicense, bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(
            forResource: license.resourceName,
            withExtension: license.resourceExtension
        ) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
