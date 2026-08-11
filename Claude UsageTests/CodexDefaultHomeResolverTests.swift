//
//  CodexDefaultHomeResolverTests.swift
//  Claude UsageTests
//

import XCTest
@testable import Claude_Usage

/// `CodexDefaultHomeResolver.prefillCandidate(defaultHomePath:profiles:)` is
/// the pure matching core behind `prefillCandidate(profiles:)`. It exists
/// specifically so the "is this default already claimed?" rule is testable
/// without touching the real `~/.codex` — `resolvedPath()` always consults
/// the developer's actual home directory and has no injectable override, so
/// a test that only had `prefillCandidate(profiles:)` to call could never
/// deterministically exercise both branches.
final class CodexDefaultHomeResolverTests: XCTestCase {
    /// Builds a `CanonicalCodexHome` purely by decoding a `{"path": ...}`
    /// payload — the same technique used elsewhere in this suite (see
    /// `CodexProviderFactoryTests`) to get a real value of this type without
    /// touching disk. Decoding only validates the string shape; it never
    /// resolves the path against the filesystem.
    private func canonicalHome(_ path: String) throws -> CanonicalCodexHome {
        try JSONDecoder().decode(
            CanonicalCodexHome.self,
            from: Data(#"{"path":"\#(path)"}"#.utf8)
        )
    }

    /// Nothing has claimed the resolved default yet, so it's safe to
    /// propose — a profile linked to a different home doesn't block it.
    func testReturnsDefaultPathWhenNoProfileClaimsIt() throws {
        let elsewhere = Profile(
            name: "Elsewhere",
            providerConfiguration: .codex(
                .init(linkedHome: try canonicalHome(
                    "/Users/example/work-codex"
                ))
            )
        )
        XCTAssertEqual(
            CodexDefaultHomeResolver.prefillCandidate(
                defaultHomePath: "/Users/example/.codex",
                profiles: [elsewhere]
            ),
            "/Users/example/.codex"
        )
    }

    /// Another profile already links the exact default path — proposing it
    /// again would silently hand this profile someone else's home, so the
    /// field must come back empty instead.
    func testReturnsEmptyWhenAProfileAlreadyLinksTheDefaultPath() throws {
        let owner = Profile(
            name: "Owner",
            providerConfiguration: .codex(
                .init(linkedHome: try canonicalHome("/Users/example/.codex"))
            )
        )
        XCTAssertEqual(
            CodexDefaultHomeResolver.prefillCandidate(
                defaultHomePath: "/Users/example/.codex",
                profiles: [owner]
            ),
            ""
        )
    }

    /// No resolvable default at all (nil, e.g. `~/.codex` doesn't exist)
    /// always means an empty field, regardless of what profiles exist.
    func testReturnsEmptyWhenNoDefaultHomeIsResolvable() {
        XCTAssertEqual(
            CodexDefaultHomeResolver.prefillCandidate(
                defaultHomePath: nil,
                profiles: []
            ),
            ""
        )
    }
}
