//
//  CodexSwitchServiceTests.swift
//  Claude UsageTests
//

import XCTest
@testable import Claude_Usage

/// `CodexSwitchService` resolves paths from the real `HOME` environment
/// variable (mirroring `ClaudeSwitchService`), so these tests redirect it to
/// an isolated temporary directory for the duration of each test.
final class CodexSwitchServiceTests: XCTestCase {
    private var originalHome: String?
    private var temporaryHome: URL!
    private var service: CodexSwitchService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalHome = ProcessInfo.processInfo.environment["HOME"]
        temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "codex-switch-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryHome,
            withIntermediateDirectories: true
        )
        setenv("HOME", temporaryHome.path, 1)
        service = CodexSwitchService(propagatesToTmux: false)
    }

    override func tearDownWithError() throws {
        if let originalHome {
            setenv("HOME", originalHome, 1)
        } else {
            unsetenv("HOME")
        }
        try? FileManager.default.removeItem(at: temporaryHome)
        try super.tearDownWithError()
    }

    func testSwitchToHomeWritesLastCodexHomePointerFile() throws {
        let linkedHomeURL = temporaryHome.appendingPathComponent(
            "codex-home", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: linkedHomeURL, withIntermediateDirectories: true
        )
        let home = try CodexHomeCanonicalizer()
            .canonicalize(linkedHomeURL.path)

        XCTAssertNil(service.currentHomePath())

        try service.switchToHome(home)

        XCTAssertEqual(
            service.currentHomePath(),
            home.path
        )
        let pointerFile = temporaryHome
            .appendingPathComponent(".claude-tokens")
            .appendingPathComponent(".last-codex-home")
        let written = try String(
            contentsOf: pointerFile, encoding: .utf8
        )
        XCTAssertEqual(
            written.trimmingCharacters(in: .whitespacesAndNewlines),
            home.path
        )
    }

    func testSwitchToHomeNeverTouchesClaudeAccountState() throws {
        let linkedHomeURL = temporaryHome.appendingPathComponent(
            "codex-home-2", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: linkedHomeURL, withIntermediateDirectories: true
        )
        let home = try CodexHomeCanonicalizer()
            .canonicalize(linkedHomeURL.path)

        try service.switchToHome(home)

        // Only the Codex pointer file exists under .claude-tokens — the
        // Claude `.last-account` mechanism is untouched by a Codex switch.
        let tokensDir = temporaryHome
            .appendingPathComponent(".claude-tokens")
        let lastAccountFile = tokensDir
            .appendingPathComponent(".last-account")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: lastAccountFile.path)
        )
    }

    func testClearHomeRemovesPointerFile() throws {
        let linkedHomeURL = temporaryHome.appendingPathComponent(
            "codex-home-3", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: linkedHomeURL, withIntermediateDirectories: true
        )
        let home = try CodexHomeCanonicalizer()
            .canonicalize(linkedHomeURL.path)
        try service.switchToHome(home)
        XCTAssertNotNil(service.currentHomePath())

        service.clearHome()

        XCTAssertNil(service.currentHomePath())
    }

    func testSwitchToHomeRejectsDeletedLinkedHomeWithoutWritingPointer() throws {
        let linkedHomeURL = temporaryHome.appendingPathComponent(
            "deleted-codex-home", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: linkedHomeURL, withIntermediateDirectories: true
        )
        let home = try CodexHomeCanonicalizer()
            .canonicalize(linkedHomeURL.path)
        try FileManager.default.removeItem(at: linkedHomeURL)

        XCTAssertThrowsError(try service.switchToHome(home)) { error in
            XCTAssertEqual(error as? CodexHomeCanonicalizationError, .missing)
        }
        XCTAssertNil(service.currentHomePath())
    }

    /// A legacy path-only persisted link (decoded before this app recorded
    /// filesystem identity, so `filesystemIdentity` is nil) must still be
    /// switchable. Re-canonicalizing always produces a non-nil identity, and
    /// `switchToHome` must not compare against one the caller never verified
    /// — see the comment at its identity check.
    func testSwitchToHomeAcceptsLegacyPathOnlyHome() throws {
        let linkedHomeURL = temporaryHome.appendingPathComponent(
            "legacy-codex-home", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: linkedHomeURL, withIntermediateDirectories: true
        )
        let legacyPayload = try JSONEncoder().encode(
            ["path": linkedHomeURL.path]
        )
        let legacyHome = try JSONDecoder().decode(
            CanonicalCodexHome.self, from: legacyPayload
        )
        XCTAssertNil(legacyHome.filesystemIdentity)

        try service.switchToHome(legacyHome)

        XCTAssertEqual(service.currentHomePath(), legacyHome.path)
    }

    /// A home whose verified identity no longer matches the directory at
    /// that path (deleted and replaced, e.g. by unmounting and recreating a
    /// volume) must be rejected — even though the path itself still exists
    /// and canonicalizes successfully.
    func testSwitchToHomeRejectsIdentityMismatchWithoutWritingPointer() throws {
        let linkedHomeURL = temporaryHome.appendingPathComponent(
            "replaced-codex-home", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: linkedHomeURL, withIntermediateDirectories: true
        )
        let verifiedHome = try CodexHomeCanonicalizer()
            .canonicalize(linkedHomeURL.path)
        XCTAssertNotNil(verifiedHome.filesystemIdentity)

        // Replace the directory at the same path with a new one so the
        // filesystem identity (device + file ID) differs, while the path
        // itself still resolves and canonicalizes cleanly.
        try FileManager.default.removeItem(at: linkedHomeURL)
        try FileManager.default.createDirectory(
            at: linkedHomeURL, withIntermediateDirectories: true
        )

        XCTAssertThrowsError(try service.switchToHome(verifiedHome)) { error in
            XCTAssertEqual(
                error as? CodexHomeCanonicalizationError,
                .changedSinceVerification
            )
        }
        XCTAssertNil(service.currentHomePath())
    }

    /// This is the self-heal the app runs at startup: a pointer naming a
    /// directory that's gone must be discarded so a new tmux pane doesn't
    /// inherit a CODEX_HOME that immediately fails.
    func testDiscardStaleHomeIfMissingRemovesPointerToDeletedDirectory() throws {
        let linkedHomeURL = temporaryHome.appendingPathComponent(
            "vanishing-codex-home", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: linkedHomeURL, withIntermediateDirectories: true
        )
        let home = try CodexHomeCanonicalizer()
            .canonicalize(linkedHomeURL.path)
        try service.switchToHome(home)
        try FileManager.default.removeItem(at: linkedHomeURL)
        XCTAssertNotNil(service.currentHomePath())

        service.discardStaleHomeIfMissing()

        XCTAssertNil(service.currentHomePath())
    }

    /// The self-heal must not touch a pointer whose directory still exists
    /// — it is a targeted cleanup for unusable state, not a general reset.
    func testDiscardStaleHomeIfMissingPreservesPointerToExistingDirectory() throws {
        let linkedHomeURL = temporaryHome.appendingPathComponent(
            "still-here-codex-home", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: linkedHomeURL, withIntermediateDirectories: true
        )
        let home = try CodexHomeCanonicalizer()
            .canonicalize(linkedHomeURL.path)
        try service.switchToHome(home)

        service.discardStaleHomeIfMissing()

        XCTAssertEqual(service.currentHomePath(), home.path)
    }
}
