//
//  CodexCLISwitchRequirementTests.swift
//  Claude UsageTests
//

import XCTest
@testable import Claude_Usage

/// `CodexCLISwitchRequirement.determine` is a pure function specifically so
/// the requirement rule can be tested without standing up a view, a
/// `ProfileManager`, or real profiles on disk.
final class CodexCLISwitchRequirementTests: XCTestCase {
    /// Nothing linked means there's no CODEX_HOME for a shell to follow, so
    /// the snippet has nothing to do — this is the state every new Codex
    /// user starts in, and showing "Required" here would both be wrong and
    /// reintroduce the exact first-run friction this feature removes.
    func testZeroLinkedHomesIsOptional() {
        XCTAssertEqual(
            CodexCLISwitchRequirement.determine(
                linkedHomePaths: [],
                defaultCodexHomePath: "/Users/example/.codex"
            ),
            .optional
        )
    }

    func testOneLinkedHomeAtTheDefaultIsOptional() {
        XCTAssertEqual(
            CodexCLISwitchRequirement.determine(
                linkedHomePaths: ["/Users/example/.codex"],
                defaultCodexHomePath: "/Users/example/.codex"
            ),
            .optional
        )
    }

    func testOneLinkedHomeElsewhereIsRequired() {
        XCTAssertEqual(
            CodexCLISwitchRequirement.determine(
                linkedHomePaths: ["/Users/example/codex-work"],
                defaultCodexHomePath: "/Users/example/.codex"
            ),
            .required
        )
    }

    func testTwoLinkedHomesIsRequiredEvenIfOneIsTheDefault() {
        XCTAssertEqual(
            CodexCLISwitchRequirement.determine(
                linkedHomePaths: [
                    "/Users/example/.codex",
                    "/Users/example/codex-work",
                ],
                defaultCodexHomePath: "/Users/example/.codex"
            ),
            .required
        )
    }

    /// `~/.codex` not existing at all must not crash the comparison and
    /// must not be mistaken for a match against any linked home.
    func testOneLinkedHomeWithNoResolvableDefaultIsRequired() {
        XCTAssertEqual(
            CodexCLISwitchRequirement.determine(
                linkedHomePaths: ["/Users/example/.codex"],
                defaultCodexHomePath: nil
            ),
            .required
        )
    }
}
