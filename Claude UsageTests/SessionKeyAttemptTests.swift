import Foundation
import XCTest
@testable import Claude_Usage

final class SessionKeyAttemptTests: XCTestCase {
    func testCompletionIsRejectedAfterKeyEditCancelOrProfileSwitch() {
        var attempt = SessionKeyAttempt()
        let generation = attempt.generation

        attempt.invalidate()
        XCTAssertFalse(SessionKeyAttemptPolicy.acceptsCompletion(
            generation: generation,
            currentGeneration: attempt.generation,
            keyMatches: true
        ))
        XCTAssertFalse(SessionKeyAttemptPolicy.acceptsCompletion(
            generation: attempt.generation,
            currentGeneration: attempt.generation,
            keyMatches: false
        ))
        XCTAssertFalse(SessionKeyAttemptPolicy.acceptsCompletion(
            generation: attempt.generation,
            currentGeneration: attempt.generation,
            keyMatches: true,
            targetMatches: false
        ))
    }

    func testChromeLaunchRequiresBothLocalNonceAndParentGeneration() {
        let generation = UUID()
        let launch = ChromeLaunchAttempt(
            nonce: UUID(),
            parentGeneration: generation
        )

        XCTAssertTrue(SessionKeyAttemptPolicy.acceptsChromeLaunch(
            launch,
            currentNonce: launch.nonce,
            currentGeneration: generation
        ))
        XCTAssertFalse(SessionKeyAttemptPolicy.acceptsChromeLaunch(
            launch,
            currentNonce: UUID(),
            currentGeneration: generation
        ))
        XCTAssertFalse(SessionKeyAttemptPolicy.acceptsChromeLaunch(
            launch,
            currentNonce: launch.nonce,
            currentGeneration: UUID()
        ))
    }

    func testFirstRunCompletionAcceptsOnlyTheCreatedActiveClaudeProfile() {
        let generation = UUID()
        let createdProfileID = UUID()

        XCTAssertTrue(SessionKeyAttemptPolicy.acceptsSetupCompletion(
            generation: generation,
            currentGeneration: generation,
            keyMatches: true,
            capturedTarget: .newProfile,
            completedProfileID: createdProfileID,
            completedProfileIsClaude: true,
            activeClaudeProfileID: createdProfileID
        ))
        XCTAssertFalse(SessionKeyAttemptPolicy.acceptsSetupCompletion(
            generation: generation,
            currentGeneration: generation,
            keyMatches: true,
            capturedTarget: .newProfile,
            completedProfileID: createdProfileID,
            completedProfileIsClaude: true,
            activeClaudeProfileID: UUID()
        ))
        XCTAssertFalse(SessionKeyAttemptPolicy.acceptsSetupCompletion(
            generation: generation,
            currentGeneration: UUID(),
            keyMatches: true,
            capturedTarget: .newProfile,
            completedProfileID: createdProfileID,
            completedProfileIsClaude: true,
            activeClaudeProfileID: createdProfileID
        ))
    }

    func testExistingCompletionRequiresTheCapturedProfileIdentity() {
        let generation = UUID()
        let capturedProfileID = UUID()

        XCTAssertTrue(SessionKeyAttemptPolicy.acceptsSetupCompletion(
            generation: generation,
            currentGeneration: generation,
            keyMatches: true,
            capturedTarget: .existing(capturedProfileID),
            completedProfileID: capturedProfileID,
            completedProfileIsClaude: true,
            activeClaudeProfileID: capturedProfileID
        ))
        XCTAssertFalse(SessionKeyAttemptPolicy.acceptsSetupCompletion(
            generation: generation,
            currentGeneration: generation,
            keyMatches: true,
            capturedTarget: .existing(capturedProfileID),
            completedProfileID: UUID(),
            completedProfileIsClaude: true,
            activeClaudeProfileID: capturedProfileID
        ))
    }

    func testFailedFirstRunPromotesOnlyItsSoleActiveClaudeProfileForRetry() {
        let createdProfileID = UUID()

        XCTAssertEqual(
            SessionKeyAttemptPolicy.retryTargetAfterFailedSetup(
                capturedTarget: .newProfile,
                claudeProfileIDs: [createdProfileID]
            ),
            .createdProfile(createdProfileID)
        )
        XCTAssertEqual(
            SessionKeyAttemptPolicy.retryTargetAfterFailedSetup(
                capturedTarget: .newProfile,
                claudeProfileIDs: [createdProfileID, UUID()]
            ),
            .newProfile
        )
        XCTAssertEqual(
            SessionKeyAttemptPolicy.retryTargetAfterFailedSetup(
                capturedTarget: .existing(createdProfileID),
                claudeProfileIDs: [createdProfileID]
            ),
            .existing(createdProfileID)
        )
    }

    func testSaveRequiresExplicitOrganizationTargetAndChromeConfirmation() {
        XCTAssertFalse(SessionKeyAttemptPolicy.hasSelectableOrganization(0))
        XCTAssertTrue(SessionKeyAttemptPolicy.hasSelectableOrganization(1))
        XCTAssertFalse(SessionKeyAttemptPolicy.permitsSave(
            validationSucceeded: true,
            isSessionOnlyRetry: false,
            selectedOrganizationID: nil,
            chromeProfileLabel: nil,
            chromeContextConfirmed: false
        ))
        XCTAssertFalse(SessionKeyAttemptPolicy.permitsSave(
            validationSucceeded: true,
            isSessionOnlyRetry: false,
            selectedOrganizationID: "org",
            chromeProfileLabel: "Work — Profile 1",
            chromeContextConfirmed: false
        ))
        XCTAssertFalse(SessionKeyAttemptPolicy.permitsSave(
            validationSucceeded: true,
            isSessionOnlyRetry: false,
            selectedOrganizationID: "org",
            chromeProfileLabel: nil,
            chromeContextConfirmed: false,
            targetMatches: false
        ))
        XCTAssertTrue(SessionKeyAttemptPolicy.permitsSave(
            validationSucceeded: true,
            isSessionOnlyRetry: false,
            selectedOrganizationID: "org",
            chromeProfileLabel: "Work — Profile 1",
            chromeContextConfirmed: true
        ))
    }

    func testSessionOnlyRetryStillRequiresOrganizationAndChromeConfirmation() {
        XCTAssertFalse(SessionKeyAttemptPolicy.permitsSave(
            validationSucceeded: false,
            isSessionOnlyRetry: true,
            selectedOrganizationID: nil,
            chromeProfileLabel: nil,
            chromeContextConfirmed: false
        ))
        XCTAssertTrue(SessionKeyAttemptPolicy.permitsSave(
            validationSucceeded: false,
            isSessionOnlyRetry: true,
            selectedOrganizationID: "org",
            chromeProfileLabel: "Work — Profile 1",
            chromeContextConfirmed: true
        ))
    }
}
