import Foundation
import XCTest
import UsageCore
@testable import Claude_Usage

/// The popover used to show only the organization's extra usage. These tests
/// pin the member's own figure beside it: the values it decodes, the guard
/// that refuses to show one context's number under another's label, and the
/// rule that a failed token renewal never touches a stored credential.
///
/// Every figure here is a real response captured from a Team member's account
/// on 2026-08-22.
@MainActor
final class PersonalExtraUsageTests: XCTestCase {

    /// The organization the maintainer's claude.ai session belongs to.
    private let teamOrganizationID = "665a6475-2eb6-4da8-8379-d5529d283568"
    /// A second organization, on the same email, holding a personal
    /// subscription. Its CLI login must never feed the team profile.
    private let personalOrganizationID = "ef142542-c027-47d7-9b93-80f8415554a9"

    override func tearDown() {
        StubClaudeEndpointsURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Decoding

    /// The live member response. `utilization` comes back null, so the
    /// percentage has to be computed from used and limit.
    func testMemberExtraUsageDecodesAsFiftyDollarsUnused() throws {
        let json = """
        {
            "extra_usage": {
                "is_enabled": true,
                "monthly_limit": 5000,
                "used_credits": 0.0,
                "utilization": null,
                "currency": "USD",
                "decimal_places": 2,
                "disabled_reason": null,
                "user_disabled": false,
                "spend_limit_reached": false,
                "credits_ever_enabled": true
            }
        }
        """

        let decoded = try JSONDecoder().decode(
            ClaudeAPIService.OAuthUsageResponse.self,
            from: Data(json.utf8)
        )
        let extraUsage = try XCTUnwrap(decoded.extraUsage)
        XCTAssertEqual(extraUsage.isEnabled, true)
        XCTAssertEqual(extraUsage.monthlyLimit, 5_000)
        XCTAssertEqual(extraUsage.usedCredits, 0)
        XCTAssertEqual(extraUsage.currency, "USD")

        var usage = ClaudeUsage.empty
        usage.personalCostUsed = extraUsage.usedCredits
        usage.personalCostLimit = extraUsage.monthlyLimit
        usage.personalCostCurrency = extraUsage.currency

        let window = try XCTUnwrap(
            try makeReport(from: usage)
                .limitGroups
                .first { $0.id.rawValue == "extra-usage" }?
                .windows
                .first
        )
        XCTAssertEqual(window.quantity?.limit, 50)
        XCTAssertEqual(window.quantity?.used, 0)
        XCTAssertEqual(window.usedPercentage, 0)
        XCTAssertEqual(window.quantity?.currencyCode?.rawValue, "USD")
    }

    /// A record written before the member figure existed decodes with no
    /// member figure — not with a zero, which would read as "you have spent
    /// nothing" rather than "we do not know".
    func testUsageRecordWithoutPersonalKeysDecodesWithNilPersonalFields() throws {
        let json = """
        {
            "sessionTokensUsed": 1250,
            "sessionLimit": 10000,
            "sessionPercentage": 12.5,
            "sessionResetTime": 20000,
            "weeklyTokensUsed": 480000,
            "weeklyLimit": 1000000,
            "weeklyPercentage": 48,
            "weeklyResetTime": 30000,
            "opusWeeklyTokensUsed": 0,
            "opusWeeklyPercentage": 0,
            "sonnetWeeklyTokensUsed": 0,
            "sonnetWeeklyPercentage": 0,
            "costUsed": 26118,
            "costLimit": 100000,
            "costCurrency": "USD",
            "lastUpdated": 10000,
            "userTimezone": {"identifier": "GMT"}
        }
        """

        let usage = try JSONDecoder().decode(
            ClaudeUsage.self,
            from: Data(json.utf8)
        )

        XCTAssertNil(usage.personalCostUsed)
        XCTAssertNil(usage.personalCostLimit)
        XCTAssertNil(usage.personalCostCurrency)
        XCTAssertEqual(usage.costUsed, 26_118)
    }

    func testPersonalFiguresSurviveAnEncodeDecodeRoundTrip() throws {
        var usage = ClaudeUsage.empty
        usage.personalCostUsed = 0
        usage.personalCostLimit = 5_000
        usage.personalCostCurrency = "USD"

        let decoded = try JSONDecoder().decode(
            ClaudeUsage.self,
            from: JSONEncoder().encode(usage)
        )

        XCTAssertEqual(decoded.personalCostUsed, 0)
        XCTAssertEqual(decoded.personalCostLimit, 5_000)
        XCTAssertEqual(decoded.personalCostCurrency, "USD")
    }

    // MARK: - Popover groups

    /// Both figures, in the order a person reads them: theirs, then the
    /// company's. The organization's amounts are the ones a real team
    /// reported at the same moment the member reported nothing.
    func testBothFiguresRenderAsTwoGroupsWithThePersonalOneFirst() throws {
        var usage = ClaudeUsage.empty
        usage.costUsed = 26_118
        usage.costLimit = 100_000
        usage.costCurrency = "USD"
        usage.costScope = .organization
        usage.personalCostUsed = 0
        usage.personalCostLimit = 5_000
        usage.personalCostCurrency = "USD"

        let groups = try makeReport(from: usage).limitGroups.filter {
            $0.id.rawValue.hasPrefix("extra-usage")
        }

        XCTAssertEqual(
            groups.map(\.id.rawValue),
            ["extra-usage", "extra-usage-organization"]
        )
        XCTAssertEqual(groups[0].displayName, "Extra Usage")
        XCTAssertEqual(groups[1].displayName, "Extra Usage · Organization")

        XCTAssertEqual(groups[0].windows[0].quantity?.used, 0)
        XCTAssertEqual(groups[0].windows[0].quantity?.limit, 50)

        XCTAssertEqual(groups[1].windows[0].quantity?.used, 261.18)
        XCTAssertEqual(groups[1].windows[0].quantity?.limit, 1_000)
        XCTAssertEqual(
            try XCTUnwrap(groups[1].windows[0].usedPercentage),
            26.12,
            accuracy: 0.005
        )
    }

    /// Regression guard for the previous change: with no member figure the
    /// popover looks exactly as it did — one group, labelled as the
    /// organization's, under the identifier it has always had.
    func testOrganizationOnlyStillRendersOneGroupUnderTheOriginalIdentifier() throws {
        var usage = ClaudeUsage.empty
        usage.costUsed = 26_118
        usage.costLimit = 100_000
        usage.costCurrency = "USD"
        usage.costScope = .organization

        let groups = try makeReport(from: usage).limitGroups.filter {
            $0.id.rawValue.hasPrefix("extra-usage")
        }

        XCTAssertEqual(groups.map(\.id.rawValue), ["extra-usage"])
        XCTAssertEqual(groups[0].displayName, "Extra Usage · Organization")
    }

    /// The popover explains a missing member figure only when there is an
    /// organization figure with no member figure beside it — and says which
    /// of the three reasons applies, because they need different actions.
    func testTheNoticeAppearsOnlyForAnUnaccompaniedOrganizationFigure() {
        var organizationOnly = ClaudeUsage.empty
        organizationOnly.costUsed = 26_118
        organizationOnly.costLimit = 100_000
        organizationOnly.costCurrency = "USD"
        organizationOnly.costScope = .organization
        organizationOnly.personalExtraUsageIssue = .notLinked
        XCTAssertEqual(
            ClaudeUsageProviderAdapter
                .personalExtraUsageIssueToExplain(for: organizationOnly),
            .notLinked
        )

        // A linked account whose sign-in stopped working must not be told to
        // link one: that sends someone to a screen with nothing to connect.
        var brokenSignIn = organizationOnly
        brokenSignIn.personalExtraUsageIssue = .signInUnusable
        XCTAssertEqual(
            ClaudeUsageProviderAdapter
                .personalExtraUsageIssueToExplain(for: brokenSignIn),
            .signInUnusable
        )

        // Distinct from the above: re-syncing cannot renew an expired login,
        // so the two must never collapse into one message.
        var expiredSignIn = organizationOnly
        expiredSignIn.personalExtraUsageIssue = .signInExpired
        XCTAssertEqual(
            ClaudeUsageProviderAdapter
                .personalExtraUsageIssueToExplain(for: expiredSignIn),
            .signInExpired
        )

        var otherOrganization = organizationOnly
        otherOrganization.personalExtraUsageIssue = .differentOrganization
        XCTAssertEqual(
            ClaudeUsageProviderAdapter
                .personalExtraUsageIssueToExplain(for: otherOrganization),
            .differentOrganization
        )

        var withPersonal = organizationOnly
        withPersonal.personalCostUsed = 0
        withPersonal.personalCostLimit = 5_000
        withPersonal.personalCostCurrency = "USD"
        withPersonal.personalExtraUsageIssue = nil
        XCTAssertNil(
            ClaudeUsageProviderAdapter
                .personalExtraUsageIssueToExplain(for: withPersonal)
        )

        // A single-person organization's figure already is the viewer's.
        var singlePerson = organizationOnly
        singlePerson.costScope = .personal
        XCTAssertNil(
            ClaudeUsageProviderAdapter
                .personalExtraUsageIssueToExplain(for: singlePerson)
        )

        // Extra usage simply switched off leaves no reason to explain.
        var noReason = organizationOnly
        noReason.personalExtraUsageIssue = nil
        XCTAssertNil(
            ClaudeUsageProviderAdapter
                .personalExtraUsageIssueToExplain(for: noReason)
        )

        XCTAssertNil(
            ClaudeUsageProviderAdapter
                .personalExtraUsageIssueToExplain(for: .empty)
        )
    }

    // MARK: - The organization guard

    /// The defect this guard exists for: one person, one email, two Claude
    /// Code logins in different organizations. The member figure from the
    /// wrong one must never appear under this profile — and must not even be
    /// requested.
    func testAMismatchedCLIOrganizationSkipsTheMemberFigureEntirely() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: personalOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: try seededProfile(profileID)
        )

        XCTAssertNil(usage.personalCostUsed)
        XCTAssertNil(usage.personalCostLimit)
        XCTAssertNil(usage.personalCostCurrency)
        XCTAssertEqual(usage.costUsed, 26_118)
        XCTAssertFalse(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.hasSuffix("/api/oauth/usage")
            },
            "the member's usage must not be requested for a mismatched "
                + "organization"
        )
    }

    /// The same flow with the logins agreeing: the member's own figure lands
    /// on the record beside the organization's.
    func testAMatchingCLIOrganizationPopulatesTheMemberFigure() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: try seededProfile(profileID)
        )

        XCTAssertEqual(usage.personalCostUsed, 0)
        XCTAssertEqual(usage.personalCostLimit, 5_000)
        XCTAssertEqual(usage.personalCostCurrency, "USD")
        XCTAssertEqual(usage.costUsed, 26_118)
        XCTAssertEqual(usage.costLimit, 100_000)
    }

    /// A renewal that fails must cost nothing. Losing a credential that still
    /// works is far worse than going without one number.
    func testAFailedTokenRenewalLeavesTheStoredCredentialUntouched() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        let expired = Self.credentialsJSON(expiresAt: 1_000)
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: expired,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: try seededProfile(profileID)
        )

        XCTAssertNil(usage.personalCostUsed)
        XCTAssertNil(usage.personalCostLimit)
        XCTAssertEqual(
            try store.loadProfileCredentials(profileID).cliCredentialsJSON,
            expired,
            "a failed renewal must not rewrite or clear the credential"
        )
    }

    // MARK: - Renewal mechanics

    /// The server may hand back a new refresh token. Keeping the old one
    /// would break the *next* renewal, and dropping the surrounding keys
    /// would break everything else that reads this blob.
    func testARenewalRotatesTheRefreshTokenAndKeepsEverythingElse() throws {
        let stored = """
        {
            "claudeAiOauth": {
                "accessToken": "old-access",
                "refreshToken": "old-refresh",
                "expiresAt": 1000,
                "scopes": ["user:inference"],
                "subscriptionType": "max"
            },
            "unrelatedKey": "kept"
        }
        """
        let response = """
        {
            "access_token": "new-access",
            "refresh_token": "new-refresh",
            "expires_in": 28800,
            "scope": "user:inference user:profile",
            "token_type": "Bearer"
        }
        """

        let merged = try XCTUnwrap(
            ClaudeCLITokenRefresher.merging(
                tokenResponse: Data(response.utf8),
                into: stored,
                now: Date(timeIntervalSince1970: 1_000_000)
            )
        )
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(merged.utf8))
                as? [String: Any]
        )
        let oauth = try XCTUnwrap(json["claudeAiOauth"] as? [String: Any])

        XCTAssertEqual(oauth["accessToken"] as? String, "new-access")
        XCTAssertEqual(oauth["refreshToken"] as? String, "new-refresh")
        XCTAssertEqual(oauth["subscriptionType"] as? String, "max")
        XCTAssertEqual(json["unrelatedKey"] as? String, "kept")
        XCTAssertEqual(
            oauth["scopes"] as? [String],
            ["user:inference", "user:profile"]
        )
        // Milliseconds since epoch, the unit the CLI stores expiry in.
        XCTAssertEqual(oauth["expiresAt"] as? Double, 1_028_800_000)

        // And with a real clock the renewed credential reads as live again,
        // which is the whole point of renewing it.
        let renewedNow = try XCTUnwrap(
            ClaudeCLITokenRefresher.merging(
                tokenResponse: Data(response.utf8),
                into: stored,
                now: Date()
            )
        )
        XCTAssertTrue(ClaudeCodeSyncService.shared.isTokenExpired(stored))
        XCTAssertFalse(
            ClaudeCodeSyncService.shared.isTokenExpired(renewedNow)
        )
    }

    /// A response the app cannot understand is not applied at all.
    func testAnUnusableRenewalResponseIsNotApplied() {
        let stored = Self.credentialsJSON(expiresAt: 1_000)
        XCTAssertNil(
            ClaudeCLITokenRefresher.merging(
                tokenResponse: Data(#"{"error":"invalid_grant"}"#.utf8),
                into: stored
            )
        )
    }

    // MARK: - The credentials file that is not a login

    /// The defect behind every profile showing an organization figure with no
    /// member figure: `~/.claude/.credentials.json` exists on installs that
    /// have only MCP server logins, holds `mcpOAuth` and nothing else, and is
    /// perfectly valid JSON. It was read before the Keychain and accepted on
    /// JSON validity alone, so it won, carried no token, and could not be
    /// renewed — leaving profiles that looked linked but never once returned
    /// the signed-in member's usage.
    func testACredentialsFileWithoutALoginIsNotAcceptedAsOne() throws {
        let mcpOnly = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(#"{"mcpOAuth":{"some-server":{"accessToken":"x"}}}"#.utf8)
            ) as? [String: Any]
        )
        XCTAssertFalse(
            ClaudeCodeSyncService.containsClaudeCodeLogin(mcpOnly),
            "An MCP-only credentials file must fall through to the Keychain."
        )

        let empty = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data("{}".utf8))
                as? [String: Any]
        )
        XCTAssertFalse(ClaudeCodeSyncService.containsClaudeCodeLogin(empty))

        let blankToken = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)
            ) as? [String: Any]
        )
        XCTAssertFalse(
            ClaudeCodeSyncService.containsClaudeCodeLogin(blankToken),
            "An empty token is no more usable than a missing one."
        )

        let realLogin = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(
                    #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","refreshToken":"sk-ant-ort01-def"}}"#.utf8
                )
            ) as? [String: Any]
        )
        XCTAssertTrue(
            ClaudeCodeSyncService.containsClaudeCodeLogin(realLogin)
        )
    }

    // MARK: - One login per account

    /// Claude Code stores one Keychain item per configuration directory,
    /// named `Claude Code-credentials-<first 8 hex of SHA-256 of the path>`.
    /// Verified against a machine holding 13 such items, 10 of which mapped
    /// exactly onto their `~/.claude-accounts/<name>` directories.
    ///
    /// Getting this wrong is not a visible failure — it silently resolves to
    /// some other account's login, which is the shape of the original defect.
    func testEachAccountResolvesToItsOwnKeychainItem() {
        XCTAssertEqual(
            ClaudeCodeSyncService.serviceName(
                forConfigurationDirectory: "/Users/jason/.claude"
            ),
            "Claude Code-credentials-cacce12b"
        )
        XCTAssertEqual(
            ClaudeCodeSyncService.serviceName(
                forConfigurationDirectory: "/Users/jason/.claude-accounts/jcr"
            ),
            "Claude Code-credentials-05bbc126"
        )
        XCTAssertEqual(
            ClaudeCodeSyncService.serviceName(
                forConfigurationDirectory: "/Users/jason/.claude-accounts/r2"
            ),
            "Claude Code-credentials-14546770"
        )

        // Two accounts must never collide onto one login.
        let names = [
            "/Users/jason/.claude",
            "/Users/jason/.claude-accounts/jcr",
            "/Users/jason/.claude-accounts/r2",
            "/Users/jason/.claude-accounts/r3"
        ].map { ClaudeCodeSyncService.serviceName(forConfigurationDirectory: $0) }
        XCTAssertEqual(Set(names).count, names.count)

        // A trailing slash is a different path and must not be normalized
        // away by accident: it would resolve to an item that does not exist.
        XCTAssertNotEqual(
            ClaudeCodeSyncService.serviceName(
                forConfigurationDirectory: "/Users/jason/.claude-accounts/jcr"
            ),
            ClaudeCodeSyncService.serviceName(
                forConfigurationDirectory: "/Users/jason/.claude-accounts/jcr/"
            )
        )
    }

    /// The directory an account's login lives in, which is what the item name
    /// above is derived from.
    func testAnAccountsConfigurationDirectory() {
        XCTAssertEqual(
            ClaudeCodeSyncService
                .configurationDirectory(forAccountNamed: "jcr")
                .path,
            Constants.ClaudePaths.homeDirectory
                .appendingPathComponent(".claude-accounts")
                .appendingPathComponent("jcr")
                .path
        )
    }

    /// An expired login must be reported as expired, not as a generic
    /// failure: the remedies are opposite and the wrong one is a dead end.
    func testAnExpiredLoginIsReportedAsExpired() async {
        let noRefreshToken = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-x"}}"#
        let outcome = await ClaudeCLITokenRefresher.refreshOutcome(
            from: noRefreshToken,
            session: .shared
        )
        XCTAssertEqual(outcome, .failed(.expired))
    }

    // MARK: - Catalog

    func testEnglishCatalogCarriesEveryPersonalUsageMessage() throws {
        let path = try XCTUnwrap(
            Bundle.main.path(forResource: "en", ofType: "lproj")
        )
        let english = try XCTUnwrap(Bundle(path: path))

        // Each names the missing connection and where to fix it. A profile
        // signs in twice — claude.ai in a browser, and Claude Code — so a
        // message that says only "connect your account" cannot be acted on.
        XCTAssertEqual(
            english.localizedString(
                forKey: "popover.extra_usage.cli_not_linked",
                value: nil,
                table: nil
            ),
            "This is your organization's total. Your own extra usage comes "
                + "from Claude Code, which isn't linked to this account yet "
                + "— add it in Settings → CLI Account."
        )
        // An expired login and a stale copy need OPPOSITE advice. Telling
        // someone to re-sync an expired login sends them round a loop where
        // the button appears to work and nothing changes — observed live.
        XCTAssertEqual(
            english.localizedString(
                forKey: "popover.extra_usage.cli_sign_in_expired",
                value: nil,
                table: nil
            ),
            "This is your organization's total. The Claude Code sign-in for "
                + "this account has expired — sign in to it again to see your "
                + "own extra usage. Settings → CLI Account shows you how."
        )
        XCTAssertEqual(
            english.localizedString(
                forKey: "popover.extra_usage.cli_sign_in_unusable",
                value: nil,
                table: nil
            ),
            "This is your organization's total. Your own extra usage couldn't "
                + "be read just now — re-sync your Claude Code account in "
                + "Settings → CLI Account."
        )
        for key in [
            "cli.login_expired_title",
            "cli.login_expired_explain",
            "cli.login_expired_then_resync"
        ] {
            XCTAssertNotEqual(
                english.localizedString(forKey: key, value: nil, table: nil),
                key,
                "\(key) is missing from the English catalog."
            )
        }
        XCTAssertEqual(
            english.localizedString(
                forKey: "popover.extra_usage.cli_other_organization",
                value: nil,
                table: nil
            ),
            "This is your organization's total. Your linked Claude Code "
                + "account belongs to a different organization, so its usage "
                + "isn't shown here."
        )
        XCTAssertEqual(
            english.localizedString(
                forKey: "cli.connect_extra_usage_hint",
                value: nil,
                table: nil
            ),
            "Connect your Claude Code account to see your own extra usage. "
                + "If you're an admin, you'll see your organization's by "
                + "default."
        )
    }

    // MARK: - Helpers

    private func makeReport(from usage: ClaudeUsage) throws -> UsageReport {
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        return try ClaudeUsageProviderAdapter.makeReport(
            from: usage,
            context: ClaudeUsageProviderContext(
                health: ProviderHealth(
                    status: .healthy,
                    checkedAt: fetchedAt
                ),
                fetchedAt: fetchedAt
            )
        )
    }

    private static func credentialsJSON(expiresAt: Double) -> String {
        """
        {"claudeAiOauth":{"accessToken":"fixture-access-token",\
        "refreshToken":"fixture-refresh-token","expiresAt":\(expiresAt),\
        "scopes":["user:inference"],"subscriptionType":"max"}}
        """
    }

    private func seedProfile(
        id: UUID,
        organizationID: String,
        credentialsJSON: String? = nil,
        in store: ProfileStore
    ) throws {
        let profile = Profile(
            id: id,
            name: "Fixture",
            claudeSessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: organizationID,
            // Already classified, so the scope lookup needs no extra request.
            organizationIsPersonal: false,
            cliCredentialsJSON: credentialsJSON
                ?? Self.credentialsJSON(
                    expiresAt: Date()
                        .addingTimeInterval(8 * 3600)
                        .timeIntervalSince1970 * 1000
                ),
            hasCliAccount: true
        )
        try seedProfilesForTesting([profile], in: store)
        try store.saveCLIProfileCredential(
            profile.cliCredentialsJSON,
            for: id
        )
        seededProfiles.append(profile)
    }

    private var seededProfiles: [Profile] = []

    /// The exact profile a test seeded, so it can be threaded into
    /// `fetchUsageData(sessionKey:organizationId:profile:)` the same way a
    /// real caller would rather than left for the service to re-derive.
    private func seededProfile(_ id: UUID) throws -> Profile {
        try XCTUnwrap(seededProfiles.first { $0.id == id })
    }

    private func makeService(
        profileID: UUID,
        store: ProfileStore
    ) throws -> ClaudeAPIService {
        let manager = ProfileManager(profileStore: store)
        let profile = try XCTUnwrap(
            seededProfiles.first { $0.id == profileID }
        )
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)
        return ClaudeAPIService(
            profileManager: manager,
            systemCredentialsReader: { nil }
        )
    }

    private var retained: [AnyObject] = []
}

/// Serves the whole set of endpoints one usage refresh touches, so no test
/// here reaches Anthropic. Anything not explicitly canned answers 404, which
/// is how a genuinely unexpected request shows up as a failing assertion
/// rather than a hang.
private nonisolated final class StubClaudeEndpointsURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var responses: [String: (Int, Data)] = [:]
    nonisolated(unsafe) private static var isActive = false
    nonisolated(unsafe) private(set) static var requestedURLs: [String] = []

    static func install(
        cliOrganizationID: String,
        tokenRefreshStatusCode: Int = 200
    ) {
        requestedURLs = []
        responses = [
            "https://claude.ai/api/organizations": (200, Data("""
            [{"uuid":"665a6475-2eb6-4da8-8379-d5529d283568",
              "name":"Revenium","capabilities":["chat","raven"],
              "raven_type":"team"}]
            """.utf8)),
            "https://claude.ai/api/organizations/665a6475-2eb6-4da8-8379-d5529d283568/usage":
                (200, Data("{}".utf8)),
            "https://claude.ai/api/organizations/665a6475-2eb6-4da8-8379-d5529d283568/overage_spend_limit":
                (200, Data("""
                {"monthly_credit_limit":100000,"currency":"USD",
                 "used_credits":26118,"is_enabled":true,
                 "limit_type":"organization"}
                """.utf8)),
            "https://api.anthropic.com/api/oauth/profile": (200, Data("""
            {"organization":{"uuid":"\(cliOrganizationID)"},
             "account":{"email_address":"fixture@example.com"}}
            """.utf8)),
            "https://api.anthropic.com/api/oauth/usage": (200, Data("""
            {"extra_usage":{"is_enabled":true,"monthly_limit":5000,
             "used_credits":0.0,"utilization":null,"currency":"USD"}}
            """.utf8)),
            "https://platform.claude.com/v1/oauth/token": (
                tokenRefreshStatusCode,
                Data(tokenBody(for: tokenRefreshStatusCode).utf8)
            )
        ]
        isActive = true
        URLProtocol.registerClass(StubClaudeEndpointsURLProtocol.self)
    }

    private static func tokenBody(for statusCode: Int) -> String {
        guard statusCode == 200 else {
            return #"{"error":"invalid_grant"}"#
        }
        return """
        {"access_token":"renewed-access",
         "refresh_token":"renewed-refresh",
         "expires_in":28800}
        """
    }

    static func reset() {
        guard isActive else { return }
        URLProtocol.unregisterClass(StubClaudeEndpointsURLProtocol.self)
        isActive = false
        responses = [:]
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard isActive, let host = request.url?.host else { return false }
        return [
            "claude.ai",
            "api.anthropic.com",
            "platform.claude.com"
        ].contains(host)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badURL)
            )
            return
        }
        Self.requestedURLs.append(url.absoluteString)
        let canned = Self.responses[url.absoluteString]
            ?? (404, Data("{}".utf8))
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: canned.0,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: canned.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
