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

        XCTAssertNil(CodexSwitchService.shared.currentHomePath())

        try CodexSwitchService.shared.switchToHome(home)

        XCTAssertEqual(
            CodexSwitchService.shared.currentHomePath(),
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

        try CodexSwitchService.shared.switchToHome(home)

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
        try CodexSwitchService.shared.switchToHome(home)
        XCTAssertNotNil(CodexSwitchService.shared.currentHomePath())

        CodexSwitchService.shared.clearHome()

        XCTAssertNil(CodexSwitchService.shared.currentHomePath())
    }
}
