import XCTest
@testable import Claude_Usage

/// Records every `/usr/bin/security` invocation and replays scripted results.
///
/// The point of the seam: the write path here is the only code in this app
/// that can destroy a user's Claude Code login, and its failure modes — a
/// locked Keychain, a denied ACL, a dismissed SecurityAgent prompt — are
/// exactly the ones no test can arrange against the real Keychain.
private final class RecordingSecurityRunner: SecurityCommandRunning {
    private(set) var invocations: [[String]] = []

    /// Consulted in order; the last entry is reused once exhausted.
    var results: [SecurityCommandResult] = [
        SecurityCommandResult(exitCode: 0, standardOutput: "", standardError: "")
    ]
    private var nextResultIndex = 0

    /// The verb of each invocation, e.g. `add-generic-password`.
    var verbs: [String] { invocations.compactMap(\.first) }

    func run(_ arguments: [String]) throws -> SecurityCommandResult {
        invocations.append(arguments)
        let result = results[min(nextResultIndex, results.count - 1)]
        nextResultIndex += 1
        return result
    }
}

final class ClaudeCodeSyncServiceTests: HostedAppTestCase {
    private let credentials = #"{"claudeAiOauth":{"accessToken":"abc"}}"#

    /// Everything injected here is retained for the process lifetime, per
    /// `HostedAppTestCase`: the app target uses main-actor default isolation,
    /// and releasing an injected actor-isolated service from the XCTest thunk
    /// trips a runtime allocator bug that crashes the host.
    @MainActor
    private func makeService(
        runner: RecordingSecurityRunner
    ) -> ClaudeCodeSyncService {
        _ = retain(runner)
        return retain(
            ClaudeCodeSyncService(
                profileStore: retain(makeIsolatedProfileStore()),
                securityRunner: runner
            )
        )
    }

    // MARK: - Writes must never open a window with no login

    /// The regression this file exists for. The previous implementation ran
    /// `delete-generic-password` before adding, so a failure of the add left
    /// the user logged out of Claude Code. `-U` already updates in place.
    @MainActor
    func testSuccessfulWriteNeverDeletesTheExistingItem() throws {
        let runner = RecordingSecurityRunner()
        try makeService(runner: runner).writeSystemCredentials(credentials)

        XCTAssertEqual(runner.verbs, ["add-generic-password"])
        XCTAssertFalse(
            runner.verbs.contains("delete-generic-password"),
            "A successful write must not delete the user's live credentials"
        )
    }

    @MainActor
    func testWriteUpdatesInPlace() throws {
        let runner = RecordingSecurityRunner()
        try makeService(runner: runner).writeSystemCredentials(credentials)

        let add = try XCTUnwrap(runner.invocations.first)
        XCTAssertTrue(add.contains("-U"), "The add must update an existing item")
        XCTAssertTrue(add.contains(credentials))
        XCTAssertTrue(add.contains(NSUserName()))
    }

    /// A failed write must leave whatever was already in the Keychain alone.
    @MainActor
    func testFailedWriteLeavesExistingCredentialsUntouched() {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(
                exitCode: 1,
                standardOutput: "",
                standardError: "security: SecKeychainItemCreateFromContent: "
                    + "User interaction is not allowed."
            )
        ]

        XCTAssertThrowsError(
            try makeService(runner: runner).writeSystemCredentials(credentials)
        )
        XCTAssertFalse(runner.verbs.contains("delete-generic-password"))
    }

    /// The exit code alone is not an `OSStatus` and explains nothing; the
    /// CLI's stderr is the only real diagnostic, so it has to survive.
    @MainActor
    func testWriteFailureCarriesExitCodeAndStderr() {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(
                exitCode: 51,
                standardOutput: "",
                standardError: "security: the specified keychain is not valid"
            )
        ]

        XCTAssertThrowsError(
            try makeService(runner: runner).writeSystemCredentials(credentials)
        ) { error in
            guard case ClaudeCodeError.keychainWriteFailed(
                let exitCode,
                let message
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(exitCode, 51)
            XCTAssertTrue(message.contains("not valid"), message)
            XCTAssertTrue(
                error.localizedDescription.contains("not valid"),
                error.localizedDescription
            )
        }
    }

    /// `-U` should make this unreachable, but if the Keychain refuses the
    /// update as a duplicate anyway there still has to be a way through.
    @MainActor
    func testDuplicateItemFallsBackToDeleteThenAdd() throws {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(exitCode: 45, standardOutput: "", standardError: ""),
            SecurityCommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            SecurityCommandResult(exitCode: 0, standardOutput: "", standardError: "")
        ]

        try makeService(runner: runner).writeSystemCredentials(credentials)

        XCTAssertEqual(
            runner.verbs,
            [
                "add-generic-password",
                "delete-generic-password",
                "add-generic-password"
            ]
        )
    }

    // MARK: - Reads

    @MainActor
    func testReadReturnsTrimmedKeychainValue() throws {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(
                exitCode: 0,
                standardOutput: credentials + "\n",
                standardError: ""
            )
        ]
        let service = makeService(runner: runner)

        XCTAssertEqual(try service.readKeychainCredentials(), credentials)
    }

    /// 44 is `security`'s "no such item", which is an absence, not a failure.
    @MainActor
    func testMissingItemReadsAsAbsentRatherThanFailing() throws {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(exitCode: 44, standardOutput: "", standardError: "")
        ]
        let service = makeService(runner: runner)

        XCTAssertNil(try service.readKeychainCredentials())
    }

    @MainActor
    func testReadFailureCarriesExitCodeAndStderr() {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(
                exitCode: 36,
                standardOutput: "",
                standardError: "security: interaction not allowed"
            )
        ]
        let service = makeService(runner: runner)

        XCTAssertThrowsError(try service.readKeychainCredentials()) { error in
            guard case ClaudeCodeError.keychainReadFailed(
                let exitCode,
                let message
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(exitCode, 36)
            XCTAssertTrue(message.contains("interaction not allowed"), message)
        }
    }
}
