import Foundation
import Security
import XCTest
@testable import Claude_Usage

final class ChromeProfileServiceTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/fake/chrome", isDirectory: true)

    func testDiscoveryFiltersFiveProfilesSortsDuplicateNamesAndRetainsNoSecrets() throws {
        let localState = try JSONSerialization.data(withJSONObject: [
            "profile": ["info_cache": [
                "Profile 2": ["name": "Same", "user_name": "private@example.com", "gaia_name": "Private", "avatar_icon": "secret"],
                "Profile 1": ["name": "Same", "user_name": "another@example.com"],
                "Default": ["name": "Personal"],
                "Profile 3": ["name": "Work"],
                "Profile 4": ["name": "Zebra"],
                "Guest Profile": ["name": "Guest"],
                "System Profile": ["name": "System"],
                "Ephemeral": ["name": "Temp", "is_ephemeral": true],
                "Omitted": ["name": "Hidden", "is_omitted_from_profile_list": true],
            ]]
        ])
        let filesystem = FakeFilesystem(
            localState: localState,
            directories: ["Default", "Profile 1", "Profile 2", "Profile 3", "Profile 4", "Guest Profile", "System Profile", "Ephemeral", "Omitted"]
        )

        let profiles = makeDiscoverer(filesystem).discoverProfiles()

        XCTAssertEqual(profiles.map(\.name), ["Personal", "Same", "Same", "Work", "Zebra"])
        XCTAssertEqual(profiles.map(\.directoryName), ["Default", "Profile 1", "Profile 2", "Profile 3", "Profile 4"])
        XCTAssertEqual(profiles.map(\.label), ["Personal — Default", "Same — Profile 1", "Same — Profile 2", "Work — Profile 3", "Zebra — Profile 4"])
        XCTAssertFalse(String(describing: profiles).contains("private@example.com"))
        XCTAssertFalse(String(describing: profiles).contains("avatar_icon"))
    }

    func testDiscoveryRejectsUnsafeKeysAndUnsafeLocalState() throws {
        let data = try localState(for: [
            "Profile 1": ["name": "Good"],
        ])
        XCTAssertEqual(
            makeDiscoverer(FakeFilesystem(localState: data, directories: ["Profile 1"]))
                .discoverProfiles().map(\.directoryName),
            ["Profile 1"]
        )
        XCTAssertFalse(ChromeProfilePathPolicy.isValidDirectoryName("../escape"))
        XCTAssertFalse(ChromeProfilePathPolicy.isValidDirectoryName("/absolute"))
        XCTAssertFalse(ChromeProfilePathPolicy.isValidDirectoryName(String(repeating: "x", count: 256)))
        XCTAssertFalse(ChromeProfilePathPolicy.isValidDirectoryName("Profile\\evil"))
        XCTAssertFalse(ChromeProfilePathPolicy.isValidDirectoryName("Profile\u{0001}"))

        XCTAssertTrue(makeDiscoverer(FakeFilesystem(localState: data, directories: ["Profile 1"], localStateIsSymlink: true)).discoverProfiles().isEmpty)
        XCTAssertTrue(makeDiscoverer(FakeFilesystem(localState: data, directories: ["Profile 1"], localStateOwner: 999)).discoverProfiles().isEmpty)
        XCTAssertTrue(makeDiscoverer(FakeFilesystem(localState: data, directories: ["Profile 1"], rootIsSymlink: true)).discoverProfiles().isEmpty)
        XCTAssertTrue(makeDiscoverer(FakeFilesystem(localState: data, directories: ["Profile 1"], rootOwner: 999)).discoverProfiles().isEmpty)
        XCTAssertTrue(makeDiscoverer(FakeFilesystem(localState: Data(repeating: 0, count: ChromeProfileDiscoverer.maximumLocalStateSize + 1), localStateSize: ChromeProfileDiscoverer.maximumLocalStateSize + 1)).discoverProfiles().isEmpty)
        XCTAssertTrue(makeDiscoverer(FakeFilesystem(localState: Data("not json".utf8))).discoverProfiles().isEmpty)
    }

    func testDiscoveryRejectsSymlinkWrongOwnerAndNonDirectoryProfileCandidates() throws {
        let data = try localState(for: [
            "Profile 1": ["name": "One"],
            "Profile 2": ["name": "Two"],
            "Profile 3": ["name": "Three"],
            "Profile 4": ["name": "Four"],
        ])
        let filesystem = FakeFilesystem(
            localState: data,
            directories: ["Profile 1", "Profile 2", "Profile 4"],
            symlinkDirectories: ["Profile 2"],
            regularFiles: ["Profile 3"],
            profileOwners: ["Profile 4": 999]
        )
        XCTAssertEqual(
            makeDiscoverer(filesystem).discoverProfiles().map(\.directoryName),
            ["Profile 1"]
        )
    }

    func testLaunchPolicyHasExactArgumentsAndNoForbiddenSwitches() {
        let arguments = ChromeProfileLaunchPolicy.arguments(for: "Profile 1")
        XCTAssertEqual(arguments, [
            "--profile-directory=Profile 1",
            "--ignore-profile-directory-if-not-exists",
            "--new-window",
            "https://claude.ai/",
        ])
        XCTAssertNil(ChromeProfileLaunchPolicy.arguments(for: "../Profile 1"))
        let joined = arguments!.joined(separator: " ")
        for forbidden in ["--user-data-dir", "--remote-debugging", "--user-agent", "--profile-email", "secret"] {
            XCTAssertFalse(joined.contains(forbidden))
        }
    }

    func testChromeRequirementCompilesAndPinsAppleGoogleDeveloperID() {
        let source = ChromeProfileLauncher.chromeCodeRequirement
        XCTAssertTrue(source.contains("anchor apple generic"))
        XCTAssertTrue(source.contains("identifier \"com.google.Chrome\""))
        XCTAssertTrue(source.contains("1.2.840.113635.100.6.2.6"))
        XCTAssertTrue(source.contains("1.2.840.113635.100.6.1.13"))
        XCTAssertTrue(source.contains("subject.OU"))
        XCTAssertTrue(source.contains("EQHXZ8M8AV"))

        var requirement: SecRequirement?
        XCTAssertEqual(
            SecRequirementCreateWithString(
                source as CFString,
                SecCSFlags(),
                &requirement
            ),
            errSecSuccess
        )
        XCTAssertNotNil(requirement)
        XCTAssertNotEqual(
            ChromeProfileLauncher.signatureValidationFlags.rawValue
                & kSecCSCheckAllArchitectures,
            0
        )
    }

    func testLauncherRevalidatesProfileAndChromeIdentityBeforeWorkspace() async {
        let data = try! localState(for: ["Profile 1": ["name": "One"]])
        let filesystem = FakeFilesystem(localState: data, directories: ["Profile 1"])
        let profile = ChromeProfile(name: "One", directoryName: "Profile 1")
        let app = ChromeApplication(url: URL(fileURLWithPath: "/Applications/Google Chrome.app"), bundleIdentifier: "com.google.Chrome")
        let goodSignature = ChromeCodeSignature(bundleIdentifier: "com.google.Chrome", teamIdentifier: "EQHXZ8M8AV", satisfiesTrustedRequirement: true)
        let launches = Locked<[(URL, ChromeWorkspaceLaunchRequest)]>([])
        let launcher = ChromeProfileLauncher(
            discoverer: makeDiscoverer(filesystem),
            applicationResolver: { _ in app },
            signatureVerifier: { _ in goodSignature },
            workspaceLauncher: { url, request in
                launches.withValue { $0.append((url, request)) }
                return true
            }
        )

        let successfulLaunch = await launcher.launch(profile: profile)
        XCTAssertTrue(successfulLaunch)
        XCTAssertEqual(launches.snapshot.count, 1)
        XCTAssertEqual(
            launches.snapshot[0].1.arguments,
            ChromeProfileLaunchPolicy.arguments(for: "Profile 1")
        )
        XCTAssertTrue(launches.snapshot[0].1.activates)
        XCTAssertTrue(launches.snapshot[0].1.createsNewApplicationInstance)
        XCTAssertFalse(
            launches.snapshot[0].1.allowsRunningApplicationSubstitution
        )

        for (replacement, badSignature) in [
            (
                ChromeApplication(
                    url: app.url,
                    bundleIdentifier: "com.evil.Chrome"
                ),
                goodSignature
            ),
            (
                app,
                ChromeCodeSignature(
                    bundleIdentifier: "com.evil.Chrome",
                    teamIdentifier: "EQHXZ8M8AV",
                    satisfiesTrustedRequirement: true
                )
            ),
            (
                app,
                ChromeCodeSignature(
                    bundleIdentifier: "com.google.Chrome",
                    teamIdentifier: "EVILTEAM",
                    satisfiesTrustedRequirement: true
                )
            ),
        ] {
            let called = Locked(false)
            let rejected = ChromeProfileLauncher(
                discoverer: makeDiscoverer(filesystem),
                applicationResolver: { _ in replacement },
                signatureVerifier: { _ in badSignature },
                workspaceLauncher: { _, _ in
                    called.withValue { $0 = true }
                    return true
                }
            )
            let wasRejected = await rejected.launch(profile: profile)
            XCTAssertFalse(wasRejected)
            XCTAssertFalse(called.snapshot)
        }

        let invalidCalled = Locked(false)
        let invalid = ChromeProfileLauncher(
            discoverer: makeDiscoverer(filesystem),
            applicationResolver: { _ in app },
            signatureVerifier: { _ in ChromeCodeSignature(bundleIdentifier: "com.google.Chrome", teamIdentifier: "EQHXZ8M8AV", satisfiesTrustedRequirement: false) },
            workspaceLauncher: { _, _ in
                invalidCalled.withValue { $0 = true }
                return true
            }
        )
        let invalidResult = await invalid.launch(profile: profile)
        XCTAssertFalse(invalidResult)
        XCTAssertFalse(invalidCalled.snapshot)

        filesystem.directories.remove("Profile 1")
        let removedProfileResult = await launcher.launch(profile: profile)
        XCTAssertFalse(removedProfileResult)
    }

    func testLauncherReturnsWorkspaceCompletionResultAndRejectsMissingDependencies() async {
        let data = try! localState(for: ["Profile 1": ["name": "One"]])
        let filesystem = FakeFilesystem(
            localState: data,
            directories: ["Profile 1"]
        )
        let profile = ChromeProfile(name: "One", directoryName: "Profile 1")
        let app = ChromeApplication(
            url: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
            bundleIdentifier: "com.google.Chrome"
        )
        let signature = ChromeCodeSignature(
            bundleIdentifier: "com.google.Chrome",
            teamIdentifier: "EQHXZ8M8AV",
            satisfiesTrustedRequirement: true
        )

        let workspaceFailure = ChromeProfileLauncher(
            discoverer: makeDiscoverer(filesystem),
            applicationResolver: { _ in app },
            signatureVerifier: { _ in signature },
            workspaceLauncher: { _, _ in false }
        )
        let workspaceFailureResult = await workspaceFailure.launch(
            profile: profile
        )
        XCTAssertFalse(workspaceFailureResult)

        let workspaceCalled = Locked(false)
        let missingApplication = ChromeProfileLauncher(
            discoverer: makeDiscoverer(filesystem),
            applicationResolver: { _ in nil },
            signatureVerifier: { _ in signature },
            workspaceLauncher: { _, _ in
                workspaceCalled.withValue { $0 = true }
                return true
            }
        )
        let missingApplicationResult = await missingApplication.launch(
            profile: profile
        )
        XCTAssertFalse(missingApplicationResult)
        XCTAssertFalse(workspaceCalled.snapshot)

        let missingSignature = ChromeProfileLauncher(
            discoverer: makeDiscoverer(filesystem),
            applicationResolver: { _ in app },
            signatureVerifier: { _ in nil },
            workspaceLauncher: { _, _ in
                workspaceCalled.withValue { $0 = true }
                return true
            }
        )
        let missingSignatureResult = await missingSignature.launch(
            profile: profile
        )
        XCTAssertFalse(missingSignatureResult)
        XCTAssertFalse(workspaceCalled.snapshot)
    }

    private func makeDiscoverer(_ filesystem: FakeFilesystem) -> ChromeProfileDiscoverer {
        ChromeProfileDiscoverer(userDataDirectory: root, filesystem: filesystem.seam)
    }

    private func localState(for cache: [String: [String: Any]]) throws -> Data {
        let root: [String: Any] = [
            "profile": ["info_cache": cache],
        ]
        return try JSONSerialization.data(withJSONObject: root)
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    var snapshot: Value {
        withValue { $0 }
    }
}

private final class FakeFilesystem: @unchecked Sendable {
    let localState: Data
    let localStateIsSymlink: Bool
    let localStateOwner: UInt32
    let localStateSize: Int?
    var directories: Set<String>
    let symlinkDirectories: Set<String>
    let regularFiles: Set<String>
    let rootIsSymlink: Bool
    let rootOwner: UInt32
    let profileOwners: [String: UInt32]

    init(
        localState: Data,
        directories: Set<String> = [],
        symlinkDirectories: Set<String> = [],
        regularFiles: Set<String> = [],
        localStateIsSymlink: Bool = false,
        localStateOwner: UInt32 = 501,
        localStateSize: Int? = nil,
        rootIsSymlink: Bool = false,
        rootOwner: UInt32 = 501,
        profileOwners: [String: UInt32] = [:]
    ) {
        self.localState = localState
        self.directories = directories
        self.symlinkDirectories = symlinkDirectories
        self.regularFiles = regularFiles
        self.localStateIsSymlink = localStateIsSymlink
        self.localStateOwner = localStateOwner
        self.localStateSize = localStateSize
        self.rootIsSymlink = rootIsSymlink
        self.rootOwner = rootOwner
        self.profileOwners = profileOwners
    }

    var seam: ChromeProfileFilesystem {
        ChromeProfileFilesystem(
            metadata: { url in
                if url.path == "/fake/chrome" {
                    return ChromeProfileFileMetadata(
                        exists: true,
                        isRegularFile: false,
                        isDirectory: true,
                        isSymbolicLink: self.rootIsSymlink,
                        ownerUserID: self.rootOwner,
                        size: nil
                    )
                }
                if url.lastPathComponent == "Local State" {
                    return ChromeProfileFileMetadata(exists: true, isRegularFile: true, isDirectory: false, isSymbolicLink: self.localStateIsSymlink, ownerUserID: self.localStateOwner, size: self.localStateSize ?? self.localState.count)
                }
                let name = url.lastPathComponent
                return ChromeProfileFileMetadata(
                    exists: self.directories.contains(name)
                        || self.regularFiles.contains(name),
                    isRegularFile: self.regularFiles.contains(name),
                    isDirectory: self.directories.contains(name),
                    isSymbolicLink: self.symlinkDirectories.contains(name),
                    ownerUserID: self.profileOwners[name] ?? 501,
                    size: nil
                )
            },
            readData: { _ in
                return self.localState
            },
            currentUserID: { 501 }
        )
    }
}
