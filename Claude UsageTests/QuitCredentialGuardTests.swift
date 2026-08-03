import XCTest
@testable import Claude_Usage

/// The quit guard is the last line of defence for a credential that only
/// exists in memory. Its policy is pure so it can be pinned here rather than
/// exercised through AppKit.
final class QuitCredentialGuardTests: XCTestCase {
    private let alice = UUID()
    private let bob = UUID()
    private let carol = UUID()

    private var ordered: [(id: UUID, name: String)] {
        [(alice, "Alice"), (bob, "Bob"), (carol, "Carol")]
    }

    /// Also the post-retry case: this function only ever sees the set that
    /// survived the final write, so "nothing was held" and "everything was
    /// rescued" are the same input here. The distinction lives in the caller.
    func testNothingHeldQuitsWithoutBotheringTheUser() {
        XCTAssertEqual(
            QuitCredentialGuard.outcome(
                remaining: [],
                orderedProfiles: ordered
            ),
            .terminate
        )
    }

    func testRemainingCredentialsAreConfirmedByName() {
        XCTAssertEqual(
            QuitCredentialGuard.outcome(
                remaining: [bob],
                orderedProfiles: ordered
            ),
            .confirm(accountNames: ["Bob"])
        )
    }

    /// Complete list, in the caller's display order — not set order, which
    /// would shuffle between launches.
    func testNamesAreCompleteAndInProfileOrder() {
        XCTAssertEqual(
            QuitCredentialGuard.outcome(
                remaining: [carol, alice],
                orderedProfiles: ordered
            ),
            .confirm(accountNames: ["Alice", "Carol"])
        )
    }

    /// A held credential whose profile is gone must still stop the quit.
    /// Falling through to `.terminate` would discard it silently, which is
    /// the behaviour this whole change exists to end.
    func testHeldCredentialForAnUnknownProfileStillConfirms() {
        XCTAssertEqual(
            QuitCredentialGuard.outcome(
                remaining: [UUID()],
                orderedProfiles: ordered
            ),
            .confirm(accountNames: [])
        )
    }
}
