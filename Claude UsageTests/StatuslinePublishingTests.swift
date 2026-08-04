import XCTest
@testable import Claude_Usage

/// The statusline reads usage the app publishes; nothing else writes it.
///
/// `StatuslineCredentialGuardTests` proves the generated script carries no
/// credential and reads the published file. That leaves the other half: the
/// app must actually publish, and the two files it publishes must agree.
/// Without this, the script is correct and permanently empty — which is the
/// state the branch was in before these tests.
///
/// Isolated through `CLAUDE_CONFIG_DIR` so nothing here touches the real
/// `~/.claude`.
final class StatuslinePublishingTests: XCTestCase {
    private var configDirectory: URL!
    private var previousConfigDirectory: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousConfigDirectory =
            ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        configDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("statusline-publishing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        setenv("CLAUDE_CONFIG_DIR", configDirectory.path, 1)

        // The redirect is what keeps this test out of the user's home
        // directory. If it ever stops working, fail here rather than
        // discovering it by overwriting their real statusline cache.
        XCTAssertEqual(
            Constants.ClaudePaths.claudeDirectory.path,
            configDirectory.path,
            "CLAUDE_CONFIG_DIR no longer redirects; refusing to write to the "
                + "real ~/.claude"
        )
    }

    override func tearDownWithError() throws {
        if let previousConfigDirectory {
            setenv("CLAUDE_CONFIG_DIR", previousConfigDirectory, 1)
        } else {
            unsetenv("CLAUDE_CONFIG_DIR")
        }
        try? FileManager.default.removeItem(at: configDirectory)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// 2030-01-01T00:00:00Z — fixed so the emitted string can be asserted
    /// exactly, and far enough out that the session window is never already
    /// expired when the suite runs. A nearer constant makes
    /// `effectiveSessionPercentage` return 0 and quietly turns these into
    /// tests of the expiry path instead.
    private let resetTime = Date(timeIntervalSince1970: 1_893_456_000)

    private func makeUsage(sessionPercentage: Double) -> ClaudeUsage {
        let now = Date()
        return ClaudeUsage(
            sessionTokensUsed: 25,
            sessionLimit: 100,
            sessionPercentage: sessionPercentage,
            sessionResetTime: resetTime,
            weeklyTokensUsed: 60,
            weeklyLimit: 100,
            weeklyPercentage: 60,
            weeklyResetTime: now.addingTimeInterval(604_800),
            opusWeeklyTokensUsed: 10,
            opusWeeklyPercentage: 10,
            sonnetWeeklyTokensUsed: 20,
            sonnetWeeklyPercentage: 20,
            sonnetWeeklyResetTime: now.addingTimeInterval(604_800),
            fableWeeklyTokensUsed: 0,
            fableWeeklyPercentage: 0,
            fableWeeklyResetTime: now.addingTimeInterval(604_800),
            fableWeeklyLimitAvailable: true,
            costUsed: 100,
            costLimit: 1_000,
            costCurrency: "USD",
            overageBalance: 500,
            overageBalanceCurrency: "USD",
            lastUpdated: now,
            userTimezone: TimeZone(secondsFromGMT: 0)!
        )
    }

    private var publishedURL: URL {
        configDirectory.appendingPathComponent(
            StatuslineService.usageCacheFilename
        )
    }

    private func publishedPayload() throws -> [String: Any] {
        let data = try Data(contentsOf: publishedURL)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: - The gap this closes

    /// A usage refresh must leave the script something to read. The refresh
    /// path calls `writeUsageCache`; if that does not publish, the statusline
    /// renders nothing no matter how correct the script is.
    func testARefreshPublishesUsageForTheScript() throws {
        StatuslineService.shared.writeUsageCache(usage: makeUsage(
            sessionPercentage: 42
        ))

        let payload = try publishedPayload()
        XCTAssertEqual(payload["utilization"] as? Int, 42)
        XCTAssertNotNil(payload["writtenAt"] as? Double)
    }

    /// The bash script prefers the key/value cache and falls back to the
    /// script, which reads the JSON. If the two disagree the statusline shows
    /// a different number depending on which path served it — visible to the
    /// user as a figure that changes without a refresh.
    func testBothCachesAgree() throws {
        StatuslineService.shared.writeUsageCache(usage: makeUsage(
            sessionPercentage: 73
        ))

        let legacy = try String(
            contentsOf: configDirectory
                .appendingPathComponent(".statusline-usage-cache"),
            encoding: .utf8
        )
        let legacyFields = legacy
            .split(separator: "\n")
            .reduce(into: [String: String]()) { fields, line in
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    fields[String(parts[0])] = String(parts[1])
                }
            }
        let payload = try publishedPayload()

        XCTAssertEqual(
            legacyFields["UTILIZATION"],
            (payload["utilization"] as? Int).map(String.init),
            "The two caches disagree on utilization"
        )
        XCTAssertEqual(
            legacyFields["RESETS_AT"],
            payload["resetsAt"] as? String,
            "The two caches disagree on the reset time"
        )
    }

    /// Published usage is per-user data in a shared directory.
    ///
    /// Checked after a *republish* as well: the file is replaced by rename on
    /// every refresh, so each one lands a new inode whose mode has to be right
    /// from the start. The transient window this guards against — a file
    /// created at umask default and chmod-ed afterwards — cannot be observed
    /// from here without racing the writer; this pins the settled state, and
    /// the ordering itself is enforced in `publishUsageForStatusline`.
    func testPublishedUsageIsNotWorldReadable() throws {
        for percentage in [10.0, 20.0] {
            StatuslineService.shared.writeUsageCache(usage: makeUsage(
                sessionPercentage: percentage
            ))

            let attributes = try FileManager.default
                .attributesOfItem(atPath: publishedURL.path)
            XCTAssertEqual(
                attributes[.posixPermissions] as? NSNumber,
                NSNumber(value: 0o600),
                "Wrong mode after publishing \(percentage)"
            )
        }
    }

    /// The rename-into-place must not leave scratch files behind.
    func testPublishingLeavesNoTemporaryFiles() throws {
        StatuslineService.shared.writeUsageCache(usage: makeUsage(
            sessionPercentage: 10
        ))

        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: configDirectory.path)
            .filter { $0.hasPrefix(".\(StatuslineService.usageCacheFilename)") }
        XCTAssertEqual(leftovers, [], "Temporary files were left behind")
    }

    /// The bash script parses the reset time with
    /// `date -ju -f "%Y-%m-%dT%H:%M:%S"` after stripping a fractional
    /// `.NNNZ` suffix. Pin the shape it actually emits so a formatter change
    /// cannot silently produce a string that parses to nothing and drops the
    /// reset time from the statusline.
    func testPublishedResetTimeMatchesWhatTheScriptCanParse() throws {
        StatuslineService.shared.writeUsageCache(usage: makeUsage(
            sessionPercentage: 10
        ))

        let resetsAt = try XCTUnwrap(
            try publishedPayload()["resetsAt"] as? String
        )
        let stripped = resetsAt.replacingOccurrences(
            of: "\\.[0-9]+Z$",
            with: "",
            options: .regularExpression
        )
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        // `date -ju` ignores a trailing `Z`, so drop it the same way.
        let parsed = parser.date(
            from: String(stripped.hasSuffix("Z") ? stripped.dropLast() : stripped[...])
        )

        XCTAssertEqual(parsed, resetTime, "Emitted \(resetsAt)")
    }

    /// An expired session window reports 0%, and that is what must reach the
    /// statusline — not the stale pre-reset percentage.
    func testAnExpiredWindowPublishesZero() throws {
        var usage = makeUsage(sessionPercentage: 88)
        usage.sessionResetTime = Date().addingTimeInterval(-60)

        StatuslineService.shared.writeUsageCache(usage: usage)

        XCTAssertEqual(try publishedPayload()["utilization"] as? Int, 0)
    }

    // MARK: - Remediating a script that still embeds a credential

    private static let legacyKey = "sk-ant-sid01-SENTINEL-LEGACY-4b21e7"

    private var scriptURL: URL {
        configDirectory.appendingPathComponent("fetch-claude-usage.swift")
    }

    /// Installs a pre-change script: a live credential baked into a 0755 file,
    /// and no runtime marker, which is how the upgrade recognises it.
    private func installLegacyCredentialBearingScript() throws {
        try """
        #!/usr/bin/env swift
        let sessionKey = "\(Self.legacyKey)"
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        // `isInstalled` requires both halves to be present.
        try "#!/bin/bash\n".write(
            to: configDirectory
                .appendingPathComponent("statusline-command.sh"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// The regression this guards is the whole point of the change: a script
    /// with a live credential in a world-readable file must be replaced on
    /// upgrade.
    ///
    /// Remediation used to run through the profile-gated install path, so a
    /// user with no active profile — or one with no organization ID, which the
    /// replacement script never needed — kept the old script and its
    /// credential. The error was caught and logged, so it looked like nothing
    /// was wrong.
    ///
    /// This test deliberately configures no profile at all.
    func testALegacyScriptIsRemediatedWithoutAnyProfile() throws {
        try installLegacyCredentialBearingScript()

        let rewritten = StatuslineService.shared
            .rewriteScriptEmbeddingCredentialIfNeeded()

        XCTAssertTrue(rewritten, "Remediation refused to run")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertFalse(
            script.contains(Self.legacyKey),
            "The credential is still on disk in a 0755 file"
        )
        XCTAssertTrue(
            script.contains(StatuslineService.publishedUsageMarker),
            "The replacement must carry the marker, or every launch retries"
        )
    }

    /// Once rewritten there is nothing left to do, so the next launch must not
    /// keep rewriting.
    func testRemediationIsNotRepeatedOnceDone() throws {
        try installLegacyCredentialBearingScript()

        XCTAssertTrue(
            StatuslineService.shared.rewriteScriptEmbeddingCredentialIfNeeded()
        )
        XCTAssertFalse(
            StatuslineService.shared.rewriteScriptEmbeddingCredentialIfNeeded(),
            "A remediated script was treated as still embedding a credential"
        )
    }

    /// Detection runs against the file on disk, keyed on the marker rather
    /// than on key-shaped strings, so a pre-change script is recognised
    /// whatever it happens to contain.
    func testAMarkerlessScriptOnDiskIsDetectedAsNeedingRewrite() throws {
        try installLegacyCredentialBearingScript()

        XCTAssertTrue(StatuslineService.shared.installedScriptNeedsRewrite)
    }

    func testAMarkedScriptOnDiskIsNotFlagged() throws {
        try installLegacyCredentialBearingScript()
        _ = StatuslineService.shared.rewriteScriptEmbeddingCredentialIfNeeded()

        XCTAssertFalse(StatuslineService.shared.installedScriptNeedsRewrite)
    }

    /// Enabling is recorded in `settings.json`, so remediation must honour it.
    ///
    /// A user who disabled the statusline has a *placeholder* on disk, and a
    /// pre-change placeholder has no marker either. Remediating it with the
    /// enabled script would silently switch the feature back on — the user's
    /// choice undone by a security fix.
    func testRemediationLeavesADisabledStatuslineDisabled() throws {
        try installLegacyCredentialBearingScript()
        // No settings.json at all: the statusline is not enabled.

        XCTAssertTrue(
            StatuslineService.shared.rewriteScriptEmbeddingCredentialIfNeeded()
        )

        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(
            script.contains("NO_SESSION_KEY"),
            "A disabled statusline was switched back on by remediation"
        )
        XCTAssertFalse(script.contains(Self.legacyKey))
        XCTAssertTrue(
            script.contains(StatuslineService.publishedUsageMarker),
            "The placeholder needs the marker too, or it is rewritten forever"
        )
    }

    /// The mirror of the above: when it *is* enabled, the reader is installed.
    func testRemediationKeepsAnEnabledStatuslineEnabled() throws {
        try installLegacyCredentialBearingScript()
        try #"{"statusLine":{"type":"command","command":"bash x"}}"#
            .write(
                to: configDirectory.appendingPathComponent("settings.json"),
                atomically: true,
                encoding: .utf8
            )

        XCTAssertTrue(
            StatuslineService.shared.rewriteScriptEmbeddingCredentialIfNeeded()
        )

        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(
            script.contains(StatuslineService.usageCacheFilename),
            "An enabled statusline must get the published-usage reader"
        )
        XCTAssertFalse(script.contains(Self.legacyKey))
    }

    /// The replacement is executable — the bash statusline runs it.
    func testTheRemediatedScriptStaysExecutable() throws {
        try installLegacyCredentialBearingScript()

        _ = StatuslineService.shared.rewriteScriptEmbeddingCredentialIfNeeded()

        let attributes = try FileManager.default
            .attributesOfItem(atPath: scriptURL.path)
        XCTAssertEqual(
            attributes[.posixPermissions] as? NSNumber,
            NSNumber(value: 0o755)
        )
    }
}
