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

    func testNothingHeldQuitsWithoutBotheringTheUser() {
        XCTAssertEqual(
            QuitCredentialGuard.outcome(
                remaining: [],
                orderedProfiles: ordered
            ),
            .terminate
        )
    }

    /// The common case: the final write rescued everything, so quitting is
    /// silent. Deciding on the pre-retry set would nag about credentials that
    /// were just saved.
    func testRescuedCredentialsQuitSilently() {
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
