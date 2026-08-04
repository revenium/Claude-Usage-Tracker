import XCTest
@testable import Claude_Usage

/// The statusline script is written to `~/.claude/fetch-claude-usage.swift`
/// at `0o755` — world-readable. It used to carry the session key as a string
/// literal, which put a live credential in a file any process could read.
///
/// These assert the generated text directly, the same way
/// `SecretSerializationGuardTests` asserts encoded output: a future edit that
/// reintroduces interpolation of a secret fails here.
final class StatuslineCredentialGuardTests: XCTestCase {
    private func generatedScript() -> String {
        StatuslineService.shared.renderScriptForTesting()
    }

    /// The template cannot interpolate per-profile data, because it takes no
    /// parameters. Assert that structurally — identical output across calls —
    /// rather than searching for a sentinel the template has no way to
    /// receive, which is an assertion that cannot fail.
    ///
    /// Whether the *installed* file ends up credential-free is a separate
    /// question, covered against real on-disk scripts in
    /// `StatuslinePublishingTests`.
    func testGeneratedScriptCarriesNoCredential() {
        let script = generatedScript()

        XCTAssertFalse(
            script.contains("sk-ant-"),
            "No key-shaped literal belongs in a 0o755 file"
        )
        XCTAssertEqual(
            script,
            generatedScript(),
            "The script varies with something; it must depend on no state"
        )
    }

    /// The script performs no Keychain access at all. It reads usage the app
    /// already published, so there is nothing for an ACL to gate — which is
    /// what the security-CLI approach got wrong.
    func testGeneratedScriptTouchesNoKeychain() {
        let script = generatedScript()

        XCTAssertFalse(script.contains("/usr/bin/security"))
        XCTAssertFalse(script.contains("find-generic-password"))
        XCTAssertFalse(script.contains("SecItem"))
        // Not the word "Keychain": the script says in a comment that it
        // performs no Keychain access, and that documentation is wanted.
        // Assert on the APIs that would actually do it.
        XCTAssertFalse(script.contains("SecKeychain"))
        XCTAssertFalse(script.contains("kSec"))
        XCTAssertTrue(
            script.contains(StatuslineService.usageCacheFilename),
            "It reads the published usage file instead"
        )
    }

    /// Absent or stale data must render nothing rather than a number that
    /// looks current and is not.
    func testGeneratedScriptRefusesStaleData() {
        let script = generatedScript()

        XCTAssertTrue(script.contains("staleAfterSeconds"))
        XCTAssertTrue(script.contains("NO_FRESH_USAGE"))
    }

    /// The marker is how an upgrade recognises a script that predates the
    /// runtime read. Without it in the generated output, every launch would
    /// think a rewrite is still pending.
    func testGeneratedScriptCarriesTheRuntimeMarker() {
        let script = generatedScript()

        XCTAssertTrue(
            script.contains(StatuslineService.publishedUsageMarker)
        )
    }

    // Detection of a pre-change script is exercised against real on-disk
    // files by `StatuslinePublishingTests`. It used to be asserted here by
    // checking that a string literal did not contain the marker, which called
    // no production code and could not fail.
}
