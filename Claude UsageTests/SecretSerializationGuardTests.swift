import XCTest
@testable import Claude_Usage

/// The guard that makes "plaintext is unrepresentable on disk" checkable
/// rather than aspirational.
///
/// Everything else in Phase 1 argues that no path *can* write a secret. This
/// asserts the outcome directly: feed sentinel values through every model
/// that can hold one, encode it the way the app encodes it, and search the
/// bytes. A future field that quietly carries a secret fails here even if
/// nobody remembers why this file exists.
final class SecretSerializationGuardTests: XCTestCase {
    /// Distinctive enough that a substring match cannot be a coincidence.
    private static let sentinels = [
        "SENTINEL-CLAUDE-b3f1a9",
        "SENTINEL-API-7c2e40",
        "SENTINEL-CLI-15d8ab"
    ]

    private func populatedProfile() -> Profile {
        var profile = Profile(
            id: UUID(),
            name: "Guard",
            organizationId: "org",
            apiOrganizationId: "api-org"
        )
        profile.claudeSessionKey = Self.sentinels[0]
        profile.apiSessionKey = Self.sentinels[1]
        profile.cliCredentialsJSON = Self.sentinels[2]
        return profile
    }

    private func assertNoSentinels(
        in data: Data,
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let text = String(data: data, encoding: .utf8) ?? ""
        for sentinel in Self.sentinels {
            XCTAssertFalse(
                text.contains(sentinel),
                "\(what) encoded a secret: \(sentinel)",
                file: file,
                line: line
            )
        }
    }

    func testEncodingAProfileEmitsNoSecret() throws {
        let data = try JSONEncoder().encode(populatedProfile())

        assertNoSentinels(in: data, "Profile")
    }

    /// The shape actually written to preferences is an array.
    func testEncodingTheStoredProfileArrayEmitsNoSecret() throws {
        let data = try JSONEncoder().encode([
            populatedProfile(),
            populatedProfile()
        ])

        assertNoSentinels(in: data, "profiles_v3 payload")
    }

    /// A legacy record carries its plaintext in an envelope. Decoding must
    /// recover it — that is what makes an existing install rescuable — and
    /// re-encoding must emit none of it.
    func testALegacyRecordSurvivesDecodingButNotReencoding() throws {
        var retry = ProfileCredentialMigrationRetry()
        retry.claudeSessionKey = Self.sentinels[0]
        retry.apiSessionKey = Self.sentinels[1]
        retry.cliCredentialsJSON = Self.sentinels[2]
        let legacy = try legacyProfilesData([
            (Profile(id: UUID(), name: "Legacy"), retry)
        ])

        let decoded = try JSONDecoder().decode([Profile].self, from: legacy)

        XCTAssertEqual(decoded.first?.claudeSessionKey, Self.sentinels[0])
        XCTAssertEqual(decoded.first?.apiSessionKey, Self.sentinels[1])
        XCTAssertEqual(decoded.first?.cliCredentialsJSON, Self.sentinels[2])
        assertNoSentinels(
            in: try JSONEncoder().encode(decoded),
            "re-encoded legacy record"
        )
    }

    /// A profile still carrying an un-adopted envelope must not encode it
    /// either. Adoption normally empties it first; this pins the model rather
    /// than relying on that ordering.
    func testAnUnadoptedEnvelopeIsStillNotEncoded() throws {
        var profile = populatedProfile()
        profile.credentialMigrationRetry.claudeSessionKey = Self.sentinels[0]
        profile.credentialMigrationRetry.apiSessionKey = Self.sentinels[1]
        profile.credentialMigrationRetry.cliCredentialsJSON = Self.sentinels[2]

        assertNoSentinels(
            in: try JSONEncoder().encode(profile),
            "profile holding an un-adopted envelope"
        )
    }

    /// Credentials travel as their own value type in places; it must not gain
    /// a Codable conformance that writes them.
    func testProfileCredentialsIsNotSilentlyEncodable() {
        XCTAssertFalse(
            (ProfileCredentials.self as Any) is any Encodable.Type,
            "ProfileCredentials became Encodable — a secret can now be "
                + "serialized by anything that accepts an Encodable"
        )
    }
}
