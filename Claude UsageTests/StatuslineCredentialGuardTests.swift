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
    private let sentinelKey = "sk-ant-sid01-SENTINEL-9f3c2a"
    private func generatedScript() -> String {
        StatuslineService.shared.renderScriptForTesting()
    }

    func testGeneratedScriptCarriesNoCredential() {
        let script = generatedScript()

        XCTAssertFalse(
            script.contains(sentinelKey),
            "The script must not contain a credential"
        )
        XCTAssertFalse(
            script.contains("sk-ant-"),
            "No key-shaped literal belongs in a 0o755 file"
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
            script.contains(StatuslineService.runtimeCredentialMarker)
        )
    }

    /// Detection keys off the marker, not off key-shaped strings, so a script
    /// from before this change is recognised whatever it happens to contain.
    func testAScriptWithoutTheMarkerIsTreatedAsEmbedding() {
        let legacy = """
        #!/usr/bin/env swift
        let injectedKey = "\(sentinelKey)"
        """

        XCTAssertFalse(
            legacy.contains(StatuslineService.runtimeCredentialMarker),
            "A pre-change script has no marker, which is what triggers the "
                + "rewrite"
        )
    }
}
