import Foundation
import CodexUsageProvider
import UsageCore
import XCTest
@testable import Claude_Usage

@MainActor
final class CodexProviderFactoryTests: HostedAppTestCase {
    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) {
            self.value = value
        }

        func withValue<Result>(
            _ body: (inout Value) -> Result
        ) -> Result {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }

        var snapshot: Value {
            withValue { $0 }
        }
    }

    func testProductionAvailabilityDisablesWholeCodexFactory() {
        let dependencyCalls = Locked(0)
        let factory = CodexProviderFactory(
            availability: .production,
            homeValidator: { _, _ in
                dependencyCalls.withValue { $0 += 1 }
                return true
            },
            executableResolver: {
                dependencyCalls.withValue { $0 += 1 }
                return URL(fileURLWithPath: "/usr/bin/true")
            }
        )

        XCTAssertFalse(
            UsageProviderFeatureAvailability.production.codexSupportEnabled
        )
        XCTAssertFalse(factory.isEnabled)
        XCTAssertThrowsError(try factory.capture(linkedHome: nil)) {
            XCTAssertEqual(
                $0 as? CodexProviderFactoryError,
                .featureDisabled
            )
        }
        XCTAssertEqual(dependencyCalls.snapshot, 0)
    }

    func testEnabledFactoryRequiresLinkedHomeBeforeDependencies() {
        let dependencyCalls = Locked(0)
        let factory = CodexProviderFactory(
            availability: .testing(),
            homeValidator: { _, _ in
                dependencyCalls.withValue { $0 += 1 }
                return true
            },
            executableResolver: {
                dependencyCalls.withValue { $0 += 1 }
                return URL(fileURLWithPath: "/usr/bin/true")
            }
        )

        XCTAssertTrue(factory.isEnabled)
        XCTAssertThrowsError(try factory.capture(linkedHome: nil)) {
            XCTAssertEqual(
                $0 as? CodexProviderFactoryError,
                .homeUnlinked
            )
        }
        XCTAssertEqual(dependencyCalls.snapshot, 0)
    }

    func testDisabledFactoryCannotBypassGateWithCapturedInputs()
        throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let linkedHome = try CodexHomeCanonicalizer()
            .canonicalize(root.path)
        let enabledFactory = CodexProviderFactory(
            availability: .testing(),
            executableResolver: {
                URL(fileURLWithPath: "/usr/bin/true")
            }
        )
        let captured = try enabledFactory.capture(
            linkedHome: linkedHome
        )
        let fetchCalls = Locked(0)
        let disabledFactory = CodexProviderFactory(
            availability: .production,
            fetchFactory: { _ in
                fetchCalls.withValue { $0 += 1 }
                return {
                    try Self.makeReport(generation: 1)
                }
            }
        )

        XCTAssertThrowsError(
            try disabledFactory.makeFreshFetch(captured)
        ) {
            XCTAssertEqual(
                $0 as? CodexProviderFactoryError,
                .featureDisabled
            )
        }
        XCTAssertThrowsError(
            try disabledFactory.makeFreshProvider(captured)
        ) {
            XCTAssertEqual(
                $0 as? CodexProviderFactoryError,
                .featureDisabled
            )
        }
        XCTAssertEqual(fetchCalls.snapshot, 0)
    }

    func testCaptureRequiresPersistedFilesystemIdentity() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(
            #"{"path":"\#(root.path)"}"#.utf8
        )
        let unresolved = try JSONDecoder().decode(
            CanonicalCodexHome.self,
            from: data
        )
        let resolverCalls = Locked(0)
        let factory = CodexProviderFactory(
            availability: .testing(),
            executableResolver: {
                resolverCalls.withValue { $0 += 1 }
                return URL(fileURLWithPath: "/usr/bin/true")
            }
        )

        XCTAssertThrowsError(
            try factory.capture(linkedHome: unresolved)
        ) {
            XCTAssertEqual(
                $0 as? CodexProviderFactoryError,
                .homeUnavailable
            )
        }
        XCTAssertEqual(resolverCalls.snapshot, 0)
    }

    func testCaptureReturnsOnlyVerifiedRequestInputs() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let linkedHome = try CodexHomeCanonicalizer()
            .canonicalize(root.path)
        let factory = CodexProviderFactory(
            availability: .testing(),
            executableResolver: {
                URL(fileURLWithPath: "/usr/bin/true")
            }
        )

        let captured = try factory.capture(linkedHome: linkedHome)

        XCTAssertEqual(captured.codexHomeURL.path, linkedHome.path)
        XCTAssertEqual(
            captured.codexHomeIdentity,
            linkedHome.filesystemIdentity
        )
        XCTAssertEqual(
            captured.executableURL,
            URL(fileURLWithPath: "/usr/bin/true")
                .resolvingSymlinksInPath()
                .standardizedFileURL
        )
        XCTAssertTrue(factory.isHomeAvailable(captured))
    }

    func testHomeAvailabilityFailsClosedAfterSamePathReplacement()
        throws
    {
        let fileManager = FileManager.default
        let parent = makeTemporaryDirectory()
        let linkedDirectory = parent.appendingPathComponent(
            "linked",
            isDirectory: true
        )
        let retainedDirectory = parent.appendingPathComponent(
            "retained",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: linkedDirectory,
            withIntermediateDirectories: false
        )
        defer { try? fileManager.removeItem(at: parent) }
        let linkedHome = try CodexHomeCanonicalizer()
            .canonicalize(linkedDirectory.path)
        let factory = CodexProviderFactory(
            availability: .testing(),
            executableResolver: {
                URL(fileURLWithPath: "/usr/bin/true")
            }
        )
        let captured = try factory.capture(linkedHome: linkedHome)

        try fileManager.moveItem(
            at: linkedDirectory,
            to: retainedDirectory
        )
        try fileManager.createDirectory(
            at: linkedDirectory,
            withIntermediateDirectories: false
        )

        XCTAssertFalse(factory.isHomeAvailable(linkedHome))
        XCTAssertFalse(factory.isHomeAvailable(captured))
    }

    func testCapturedExecutableIsRevalidatedBeforeFetchConstruction()
        throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex")
        try makeExecutable(at: executable)
        let linkedHome = try CodexHomeCanonicalizer()
            .canonicalize(root.path)
        let fetchCalls = Locked(0)
        let factory = CodexProviderFactory(
            availability: .testing(),
            executableResolver: { executable },
            fetchFactory: { _ in
                fetchCalls.withValue { $0 += 1 }
                return {
                    try Self.makeReport(generation: 1)
                }
            }
        )
        let captured = try factory.capture(linkedHome: linkedHome)
        try FileManager.default.removeItem(at: executable)

        XCTAssertThrowsError(try factory.makeFreshFetch(captured)) {
            XCTAssertEqual(
                $0 as? CodexProviderFactoryError,
                .executableMissing
            )
        }
        XCTAssertEqual(fetchCalls.snapshot, 0)
    }

    func testCapturedHomeFailsClosedAfterSymlinkRepoint() throws {
        let fileManager = FileManager.default
        let parent = makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: parent) }
        let linkedDirectory = parent.appendingPathComponent(
            "linked",
            isDirectory: true
        )
        let replacementDirectory = parent.appendingPathComponent(
            "replacement",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: linkedDirectory,
            withIntermediateDirectories: false
        )
        try fileManager.createDirectory(
            at: replacementDirectory,
            withIntermediateDirectories: false
        )
        let linkedHome = try CodexHomeCanonicalizer()
            .canonicalize(linkedDirectory.path)
        let fetchCalls = Locked(0)
        let factory = CodexProviderFactory(
            availability: .testing(),
            executableResolver: {
                URL(fileURLWithPath: "/usr/bin/true")
            },
            fetchFactory: { _ in
                fetchCalls.withValue { $0 += 1 }
                return {
                    try Self.makeReport(generation: 1)
                }
            }
        )
        let captured = try factory.capture(linkedHome: linkedHome)

        try fileManager.removeItem(at: linkedDirectory)
        try fileManager.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: replacementDirectory
        )

        XCTAssertFalse(factory.isHomeAvailable(captured))
        XCTAssertThrowsError(try factory.makeFreshFetch(captured)) {
            XCTAssertEqual(
                $0 as? CodexProviderFactoryError,
                .homeUnavailable
            )
        }
        XCTAssertEqual(fetchCalls.snapshot, 0)
    }

    func testResolverUsesPATHPrecedenceAndResolvesSymlink() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstBin = root.appendingPathComponent(
            "first",
            isDirectory: true
        )
        let secondBin = root.appendingPathComponent(
            "second",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: firstBin,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: secondBin,
            withIntermediateDirectories: false
        )
        let firstTarget = root.appendingPathComponent("first-codex")
        let secondTarget = secondBin.appendingPathComponent("codex")
        try makeExecutable(at: firstTarget)
        try makeExecutable(at: secondTarget)
        try FileManager.default.createSymbolicLink(
            at: firstBin.appendingPathComponent("codex"),
            withDestinationURL: firstTarget
        )

        let resolved = try CodexProviderFactory.resolveExecutable(
            environment: [
                "PATH": "\(firstBin.path):\(secondBin.path)"
            ],
            homeDirectoryURL: root,
            fallbackDirectories: []
        )

        XCTAssertEqual(
            resolved,
            firstTarget.resolvingSymlinksInPath().standardizedFileURL
        )
    }

    func testResolverIgnoresUnsafeCandidatesAndUsesFirstValidDirectFile()
        throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directoryCandidate = root.appendingPathComponent(
            "directory-candidate",
            isDirectory: true
        )
        let nonExecutableCandidate = root.appendingPathComponent(
            "non-executable",
            isDirectory: true
        )
        let validCandidate = root.appendingPathComponent(
            "valid",
            isDirectory: true
        )
        for directory in [
            directoryCandidate,
            nonExecutableCandidate,
            validCandidate
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
        }
        try FileManager.default.createDirectory(
            at: directoryCandidate.appendingPathComponent(
                "codex",
                isDirectory: true
            ),
            withIntermediateDirectories: false
        )
        try Data("not executable".utf8).write(
            to: nonExecutableCandidate.appendingPathComponent("codex")
        )
        let validExecutable = validCandidate.appendingPathComponent("codex")
        try makeExecutable(at: validExecutable)

        let resolved = try CodexProviderFactory.resolveExecutable(
            environment: [
                "PATH":
                    ":relative:\(directoryCandidate.path):"
                    + "\(nonExecutableCandidate.path):"
                    + "\(validCandidate.path):\(validCandidate.path)"
            ],
            homeDirectoryURL: root,
            fallbackDirectories: []
        )

        XCTAssertEqual(
            resolved,
            validExecutable.standardizedFileURL
        )
    }

    func testResolverUsesFixedFallbackAfterPATH() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fallback = root.appendingPathComponent(
            "fallback",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fallback,
            withIntermediateDirectories: false
        )
        let executable = fallback.appendingPathComponent("codex")
        try makeExecutable(at: executable)

        let resolved = try CodexProviderFactory.resolveExecutable(
            environment: ["PATH": ":relative:"],
            homeDirectoryURL: root,
            fallbackDirectories: [fallback]
        )

        XCTAssertEqual(resolved, executable.standardizedFileURL)
    }

    func testResolverFailureIsTypedAndPathFree() {
        let secretPath = "/secret/account/codex"

        XCTAssertThrowsError(
            try CodexProviderFactory.resolveExecutable(
                environment: ["PATH": secretPath],
                fallbackDirectories: []
            )
        ) { error in
            XCTAssertEqual(
                error as? CodexProviderFactoryError,
                .executableMissing
            )
            XCTAssertFalse(
                String(describing: error).contains(secretPath)
            )
        }
    }

    func testFactoryCreatesFreshFetchOperationForEveryCall() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let linkedHome = try CodexHomeCanonicalizer()
            .canonicalize(root.path)
        let generations = Locked(0)
        let factory = CodexProviderFactory(
            availability: .testing(),
            executableResolver: {
                URL(fileURLWithPath: "/usr/bin/true")
            },
            fetchFactory: { _ in
                let generation = generations.withValue {
                    $0 += 1
                    return $0
                }
                return {
                    try Self.makeReport(generation: generation)
                }
            }
        )
        let captured = try factory.capture(linkedHome: linkedHome)

        let firstFetch = try factory.makeFreshFetch(captured)
        let secondFetch = try factory.makeFreshFetch(captured)
        let first = try await firstFetch()
        let second = try await secondFetch()

        XCTAssertEqual(generations.snapshot, 2)
        XCTAssertEqual(first.account?.displayName, "request-1")
        XCTAssertEqual(second.account?.displayName, "request-2")
    }

    func testFactoryConstructsFreshConcreteProvidersWithoutLaunching()
        throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let linkedHome = try CodexHomeCanonicalizer()
            .canonicalize(root.path)
        let providerBuilds = Locked(0)
        let factory = CodexProviderFactory(
            availability: .testing(),
            executableResolver: {
                URL(fileURLWithPath: "/usr/bin/true")
            },
            providerBuilder: { client in
                providerBuilds.withValue { $0 += 1 }
                return CodexUsageProvider(client: client)
            }
        )
        let captured = try factory.capture(linkedHome: linkedHome)

        XCTAssertNoThrow(try factory.makeFreshProvider(captured))
        XCTAssertNoThrow(try factory.makeFreshProvider(captured))
        XCTAssertEqual(providerBuilds.snapshot, 2)
    }

    func testFactoryConstructionFailureDoesNotExposeUnderlyingError()
        throws
    {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let linkedHome = try CodexHomeCanonicalizer()
            .canonicalize(root.path)
        let factory = CodexProviderFactory(
            availability: .testing(),
            executableResolver: {
                URL(fileURLWithPath: "/usr/bin/true")
            },
            fetchFactory: { _ in
                throw SecretFailure.value("auth.json-secret")
            }
        )
        let captured = try factory.capture(linkedHome: linkedHome)

        XCTAssertThrowsError(try factory.makeFreshFetch(captured)) {
            XCTAssertEqual(
                $0 as? CodexProviderFactoryError,
                .providerConstructionFailed
            )
            XCTAssertFalse(
                String(describing: $0).contains("auth.json-secret")
            )
        }
    }

    func testCapabilityCatalogIsProviderFactorySourceOfTruth() {
        let factory = CodexProviderFactory()

        XCTAssertEqual(
            factory.capabilities,
            CodexProviderFactory.capabilities
        )
        XCTAssertEqual(
            factory.capabilities,
            CodexUsageProvider.supportedCapabilities
        )
        XCTAssertEqual(factory.capabilities[.account], .available)
        XCTAssertEqual(factory.capabilities[.health], .available)
        XCTAssertEqual(factory.capabilities[.usageLimits], .available)
        XCTAssertEqual(factory.capabilities[.usageSummary], .unknown)
        XCTAssertEqual(factory.capabilities[.interactiveLogin], .available)
        XCTAssertEqual(
            factory.capabilities[.automaticSessionStart],
            .unavailable
        )
        XCTAssertEqual(
            factory.capabilities[.statusLineIntegration],
            .unavailable
        )
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "codex-provider-factory-\(UUID().uuidString)",
                isDirectory: true
            )
        try! FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func makeExecutable(at url: URL) throws {
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    nonisolated private static func makeReport(
        generation: Int
    ) throws -> UsageReport {
        try UsageReport(
            providerID: .codex,
            account: ProviderAccount(
                displayName: "request-\(generation)"
            ),
            health: ProviderHealth(
                status: .healthy,
                checkedAt: Date(timeIntervalSinceReferenceDate: 1)
            ),
            limitGroups: [],
            fetchedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
    }

    private enum SecretFailure: Error {
        case value(String)
    }
}
