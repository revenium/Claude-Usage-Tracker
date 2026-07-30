import CodexUsageProvider
import CryptoKit
import Darwin
import Foundation
import UsageCore

enum ProviderExecutableDiagnosticStatus:
    String,
    Codable,
    Sendable
{
    case available
    case missing
    case notApplicable
}

enum ProviderAppServerCapability:
    String,
    Codable,
    Sendable
{
    case compatible
    case incompatible
    case unavailable
    case notChecked
    case notApplicable
}

struct ProviderDiagnosticSnapshot: Codable, Equatable, Sendable {
    let generatedAt: Date
    let appVersion: String
    let appBuild: String?
    let osVersion: String
    let providerID: String
    let codexExecutableStatus: ProviderExecutableDiagnosticStatus
    let codexVersion: String?
    let appServerCapability: ProviderAppServerCapability
    let homeFingerprint: String?
    let health: ProviderHealth?
    let requestDurationMilliseconds: Int?
    let recentErrorCategories: [ProviderErrorCategory]

    var supportText: String {
        var lines = [
            "Claude Usage diagnostics",
            "Generated: \(generatedAt.ISO8601Format())",
            "App version: \(appVersion)",
            "App build: \(appBuild ?? "unknown")",
            "macOS: \(osVersion)",
            "Provider: \(providerID)",
            "Codex executable: \(codexExecutableStatus.rawValue)",
            "Codex version: \(codexVersion ?? "unknown")",
            "App-server capability: \(appServerCapability.rawValue)",
            "Codex home fingerprint: \(homeFingerprint ?? "none")",
            "Provider health: \(health?.status.rawValue ?? "not-checked")",
            "Provider issue: \(health?.issue?.rawValue ?? "none")",
            "Request duration: "
                + requestDurationMilliseconds.map { "\($0) ms" }
                .unwrap(or: "not-recorded")
        ]
        let categories = recentErrorCategories.map(\.rawValue)
        lines.append(
            "Recent provider errors: "
                + (categories.isEmpty
                    ? "none" : categories.joined(separator: ", "))
        )
        return SensitiveDataRedactor.redact(
            lines.joined(separator: "\n")
        )
    }
}

@MainActor
final class ProviderDiagnosticsService {
    typealias VersionProbe =
        @Sendable (URL) async -> String?

    static let shared = ProviderDiagnosticsService(
        codexProviderFactory:
            ProviderUICompositionRoot.shared.codexProviderFactory
    )

    private let codexProviderFactory: CodexProviderFactory
    private let errorLogger: ErrorLogger
    private let versionProbe: VersionProbe
    private let appVersion: () -> String
    private let appBuild: () -> String?
    private let osVersion: () -> String
    private let now: () -> Date

    init(
        codexProviderFactory: CodexProviderFactory,
        errorLogger: ErrorLogger? = nil,
        versionProbe: @escaping VersionProbe =
            CodexVersionProbe.readVersion,
        appVersion: @escaping () -> String = {
            Bundle.main.object(
                forInfoDictionaryKey:
                    "CFBundleShortVersionString"
            ) as? String ?? "unknown"
        },
        appBuild: @escaping () -> String? = {
            Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String
        },
        osVersion: @escaping () -> String = {
            ProcessInfo.processInfo.operatingSystemVersionString
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.codexProviderFactory = codexProviderFactory
        self.errorLogger = errorLogger ?? .shared
        self.versionProbe = versionProbe
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osVersion = osVersion
        self.now = now
    }

    func snapshot(
        for profile: Profile?
    ) async -> ProviderDiagnosticSnapshot {
        guard let profile else {
            return baseSnapshot(
                providerID: "none",
                executableStatus: .notApplicable,
                appServerCapability: .notApplicable
            )
        }
        guard profile.providerID == .codex,
              case .codex(let configuration) =
                profile.providerConfiguration else {
            return baseSnapshot(
                providerID: profile.providerID.rawValue,
                executableStatus: .notApplicable,
                appServerCapability: .notApplicable
            )
        }

        let fingerprint = Self.fingerprint(
            configuration.linkedHome?.filesystemIdentity
        )
        guard let linkedHome = configuration.linkedHome,
              codexProviderFactory.isHomeAvailable(linkedHome) else {
            return baseSnapshot(
                providerID: ProviderID.codex.rawValue,
                executableStatus: .notApplicable,
                appServerCapability: .unavailable,
                homeFingerprint: fingerprint,
                health: ProviderHealth(
                    status: .unavailable,
                    checkedAt: now(),
                    issue: .configurationInvalid
                )
            )
        }

        let executableURL: URL
        do {
            executableURL =
                try codexProviderFactory.resolveExecutable()
        } catch {
            return baseSnapshot(
                providerID: ProviderID.codex.rawValue,
                executableStatus: .missing,
                appServerCapability: .unavailable,
                homeFingerprint: fingerprint,
                health: ProviderHealth(
                    status: .unavailable,
                    checkedAt: now(),
                    issue: .dependencyMissing
                )
            )
        }

        let codexVersion = await versionProbe(executableURL).flatMap {
            Self.safeVersion($0)
        }
        guard codexProviderFactory.isEnabled else {
            return baseSnapshot(
                providerID: ProviderID.codex.rawValue,
                executableStatus: .available,
                codexVersion: codexVersion,
                appServerCapability: .notChecked,
                homeFingerprint: fingerprint
            )
        }

        let startedAt = now()
        do {
            let captured = try codexProviderFactory.capture(
                linkedHome: linkedHome
            )
            let provider =
                try codexProviderFactory.makeFreshProvider(captured)
            let health = await provider.health()
            return baseSnapshot(
                providerID: ProviderID.codex.rawValue,
                executableStatus: .available,
                codexVersion: codexVersion,
                appServerCapability: Self.capability(for: health),
                homeFingerprint: fingerprint,
                health: health,
                requestDurationMilliseconds:
                    Self.durationMilliseconds(
                        from: startedAt,
                        to: now()
                    )
            )
        } catch {
            let health = Self.health(
                for: error,
                checkedAt: now()
            )
            return baseSnapshot(
                providerID: ProviderID.codex.rawValue,
                executableStatus: .available,
                codexVersion: codexVersion,
                appServerCapability: Self.capability(for: health),
                homeFingerprint: fingerprint,
                health: health,
                requestDurationMilliseconds:
                    Self.durationMilliseconds(
                        from: startedAt,
                        to: now()
                    )
            )
        }
    }

    /// Fixture-friendly constructor used to prove every health state produces
    /// useful, safe support text without touching a provider or filesystem.
    func snapshot(
        providerID: ProviderID,
        health: ProviderHealth,
        codexVersion: String? = nil,
        homeIdentity: CodexHomeFilesystemIdentity? = nil,
        requestDurationMilliseconds: Int? = nil
    ) -> ProviderDiagnosticSnapshot {
        baseSnapshot(
            providerID: providerID.rawValue,
            executableStatus:
                providerID == .codex ? .available : .notApplicable,
            codexVersion:
                codexVersion.flatMap(Self.safeVersion),
            appServerCapability:
                providerID == .codex
                ? Self.capability(for: health) : .notApplicable,
            homeFingerprint: Self.fingerprint(homeIdentity),
            health: health,
            requestDurationMilliseconds:
                requestDurationMilliseconds
        )
    }

    private func baseSnapshot(
        providerID: String,
        executableStatus: ProviderExecutableDiagnosticStatus,
        codexVersion: String? = nil,
        appServerCapability: ProviderAppServerCapability,
        homeFingerprint: String? = nil,
        health: ProviderHealth? = nil,
        requestDurationMilliseconds: Int? = nil
    ) -> ProviderDiagnosticSnapshot {
        ProviderDiagnosticSnapshot(
            generatedAt: now(),
            appVersion:
                SensitiveDataRedactor.redact(appVersion()),
            appBuild:
                appBuild().map {
                    SensitiveDataRedactor.redact($0)
                },
            osVersion:
                SensitiveDataRedactor.redact(osVersion()),
            providerID:
                SensitiveDataRedactor.redact(providerID),
            codexExecutableStatus: executableStatus,
            codexVersion: codexVersion,
            appServerCapability: appServerCapability,
            homeFingerprint: homeFingerprint,
            health: health,
            requestDurationMilliseconds:
                requestDurationMilliseconds,
            recentErrorCategories:
                errorLogger.getRecentProviderCategories()
        )
    }

    private static func health(
        for error: Error,
        checkedAt: Date
    ) -> ProviderHealth {
        switch ProviderErrorMapper.category(for: error) {
        case .missingExecutable:
            return ProviderHealth(
                status: .unavailable,
                checkedAt: checkedAt,
                issue: .dependencyMissing
            )
        case .invalidHome, .duplicateHome:
            return ProviderHealth(
                status: .unavailable,
                checkedAt: checkedAt,
                issue: .configurationInvalid
            )
        case .loggedOut:
            return ProviderHealth(
                status: .unauthenticated,
                checkedAt: checkedAt,
                issue: .authenticationRequired
            )
        case .unsupportedAccount:
            return ProviderHealth(
                status: .unsupported,
                checkedAt: checkedAt,
                issue: .accountUnsupported
            )
        case .incompatibleAppServer:
            return ProviderHealth(
                status: .degraded,
                checkedAt: checkedAt,
                issue: .protocolMismatch
            )
        case .malformedResponse:
            return ProviderHealth(
                status: .degraded,
                checkedAt: checkedAt,
                issue: .responseInvalid
            )
        case .partialUsage:
            return ProviderHealth(
                status: .degraded,
                checkedAt: checkedAt,
                issue: .optionalUsageUnavailable
            )
        case .launchFailure, .timeout, .cancellation,
             .transientFailure, nil:
            return ProviderHealth(
                status: .unavailable,
                checkedAt: checkedAt,
                issue: .transportUnavailable
            )
        }
    }

    private static func capability(
        for health: ProviderHealth
    ) -> ProviderAppServerCapability {
        switch health.issue {
        case .protocolMismatch, .responseInvalid:
            return .incompatible
        case .dependencyMissing, .configurationInvalid,
             .transportUnavailable:
            return .unavailable
        case .authenticationRequired, .accountUnsupported,
             .optionalUsageUnavailable, .unknown, nil:
            switch health.status {
            case .unavailable:
                return .unavailable
            case .healthy, .degraded, .unauthenticated,
                 .unsupported:
                return .compatible
            }
        }
    }

    private static func fingerprint(
        _ identity: CodexHomeFilesystemIdentity?
    ) -> String? {
        guard let identity else { return nil }
        let input = Data(
            "\(identity.deviceID):\(identity.fileID)".utf8
        )
        let digest = SHA256.hash(data: input)
        return "fs-" + digest.prefix(6).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func safeVersion(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty,
              trimmed.count <= 128,
              trimmed.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        let redacted = SensitiveDataRedactor.redact(trimmed)
        return redacted == SensitiveDataRedactor.redactedRPC
            ? nil : redacted
    }

    private static func durationMilliseconds(
        from start: Date,
        to end: Date
    ) -> Int {
        max(0, Int(end.timeIntervalSince(start) * 1_000))
    }

}

private extension Optional where Wrapped == String {
    func unwrap(or fallback: String) -> String {
        self ?? fallback
    }
}

/// A diagnostics-only boundary for invoking the trusted, locally installed
/// Codex executable. Output, environment, execution, cleanup, and direct-child
/// reaping are bounded before a version can be accepted.
///
/// A process group handles the ordinary executable tree. We additionally
/// snapshot process identities and parentage so a descendant that calls
/// `setsid`/`setpgid` remains individually owned and terminated. No user-space
/// implementation can promise discovery of a deliberately malicious
/// double-fork that exits and reparents entirely between snapshots, so this is
/// intentionally not presented as a sandbox for an untrusted executable.
nonisolated enum CodexVersionProbe {
    private static let maximumOutputBytes = 4_096
    private static let defaultTimeout: TimeInterval = 2
    private static let defaultTerminationGrace: TimeInterval = 0.25
    private static let pollIntervalMilliseconds: Int32 = 5
    private static let maximumReadsPerDrain = 32

    static func readVersion(
        _ executableURL: URL
    ) async -> String? {
        await readVersion(
            executableURL,
            timeout: defaultTimeout,
            terminationGrace: defaultTerminationGrace
        )
    }

    static func readVersion(
        _ executableURL: URL,
        timeout: TimeInterval,
        terminationGrace: TimeInterval
    ) async -> String? {
        await readVersion(
            executableURL,
            timeout: timeout,
            terminationGrace: terminationGrace,
            reapTimeout: max(terminationGrace, 1)
        )
    }

    static func readVersion(
        _ executableURL: URL,
        timeout: TimeInterval,
        terminationGrace: TimeInterval,
        reapTimeout: TimeInterval
    ) async -> String? {
        guard timeout.isFinite, timeout > 0,
              terminationGrace.isFinite,
              terminationGrace > 0,
              reapTimeout.isFinite,
              reapTimeout >= 0 else {
            return nil
        }
        return await Task.detached(priority: .utility) {
            runSynchronously(
                executableURL,
                timeout: timeout,
                terminationGrace: terminationGrace,
                reapTimeout: reapTimeout
            )
        }.value
    }

    private static func runSynchronously(
        _ executableURL: URL,
        timeout: TimeInterval,
        terminationGrace: TimeInterval,
        reapTimeout: TimeInterval
    ) -> String? {
        let output = CodexVersionOutputBuffer(
            limit: maximumOutputBytes
        )
        guard let spawned = spawn(executableURL) else {
            return nil
        }
        let processIdentifier = spawned.processIdentifier
        let outputDescriptor = spawned.outputDescriptor
        var ownedProcesses = OwnedProcessTracker(
            leader: processIdentifier
        )
        var timedOut = false
        let executionDeadline = deadline(after: timeout)
        while true {
            ownedProcesses.refresh()
            if hasExited(processIdentifier) {
                break
            }
            guard drain(
                outputDescriptor,
                into: output,
                until: executionDeadline
            ) else {
                timedOut = true
                break
            }
            guard DispatchTime.now().uptimeNanoseconds
                    < executionDeadline else {
                timedOut = true
                break
            }
            waitForReadable(
                outputDescriptor,
                until: executionDeadline
            )
        }
        ownedProcesses.refresh()

        let containment = terminateOwnedProcesses(
            processGroup: processIdentifier,
            ownedProcesses: &ownedProcesses,
            outputDescriptor: outputDescriptor,
            output: output,
            grace: terminationGrace
        )

        let reaping = reapDirectChild(
            processIdentifier,
            outputDescriptor: outputDescriptor,
            output: output,
            timeout: reapTimeout
        )
        if reaping.needsLateReaper {
            CodexVersionLateReaper.shared.register(
                processIdentifier
            )
        }
        _ = drain(
            outputDescriptor,
            into: output,
            until: deadline(after: terminationGrace)
        )
        _ = Darwin.close(outputDescriptor)

        guard !timedOut,
              containment,
              reaping.reaped,
              exitedSuccessfully(reaping.status),
              let data = output.value,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty,
              trimmed.count <= 128,
              trimmed.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        let redacted = SensitiveDataRedactor.redact(trimmed)
        return redacted == SensitiveDataRedactor.redactedRPC
            ? nil : redacted
    }

    private struct SpawnedProcess {
        let processIdentifier: pid_t
        let outputDescriptor: Int32
    }

    /// Creates the process group atomically with the child. A post-launch
    /// setpgid call has an exec race that can let a forked writer escape.
    private static func spawn(
        _ executableURL: URL
    ) -> SpawnedProcess? {
        var descriptors = [Int32](repeating: 0, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else {
            return nil
        }
        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        func closeDescriptors() {
            _ = Darwin.close(readDescriptor)
            _ = Darwin.close(writeDescriptor)
        }
        let currentFlags = fcntl(
            readDescriptor,
            F_GETFL
        )
        guard currentFlags >= 0,
              fcntl(
                  readDescriptor,
                  F_SETFL,
                  currentFlags | O_NONBLOCK
              ) == 0 else {
            closeDescriptors()
            return nil
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(
            &fileActions
        ) == 0 else {
            closeDescriptors()
            return nil
        }
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
        }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            closeDescriptors()
            return nil
        }
        defer {
            posix_spawnattr_destroy(&attributes)
        }

        let spawnFlags = Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_CLOEXEC_DEFAULT
        )
        guard posix_spawnattr_setflags(
            &attributes,
            spawnFlags
        ) == 0,
        posix_spawnattr_setpgroup(&attributes, 0) == 0,
        posix_spawn_file_actions_addclose(
            &fileActions,
            readDescriptor
        ) == 0,
        posix_spawn_file_actions_adddup2(
            &fileActions,
            writeDescriptor,
            STDOUT_FILENO
        ) == 0 else {
            closeDescriptors()
            return nil
        }
        if writeDescriptor != STDOUT_FILENO,
           posix_spawn_file_actions_addclose(
               &fileActions,
               writeDescriptor
           ) != 0 {
            closeDescriptors()
            return nil
        }
        guard posix_spawn_file_actions_addopen(
            &fileActions,
            STDERR_FILENO,
            "/dev/null",
            O_WRONLY,
            0
        ) == 0 else {
            closeDescriptors()
            return nil
        }

        let chdirResult: Int32
        if #available(macOS 26.0, *) {
            chdirResult =
                posix_spawn_file_actions_addchdir(
                    &fileActions,
                    "/"
                )
        } else {
            chdirResult =
                posix_spawn_file_actions_addchdir_np(
                    &fileActions,
                    "/"
                )
        }
        guard chdirResult == 0 else {
            closeDescriptors()
            return nil
        }

        let argumentStorage = [
            strdup(executableURL.path),
            strdup("--version")
        ]
        let environmentStorage = [
            strdup("HOME=/var/empty"),
            strdup("LANG=C"),
            strdup("LC_ALL=C")
        ]
        defer {
            argumentStorage.forEach { free($0) }
            environmentStorage.forEach { free($0) }
        }
        guard argumentStorage.allSatisfy({ $0 != nil }),
              environmentStorage.allSatisfy({ $0 != nil }) else {
            closeDescriptors()
            return nil
        }
        var arguments = argumentStorage + [nil]
        var environment = environmentStorage + [nil]
        var processIdentifier: pid_t = 0
        let result = arguments.withUnsafeMutableBufferPointer {
            argumentBuffer in
            environment.withUnsafeMutableBufferPointer {
                environmentBuffer in
                posix_spawn(
                    &processIdentifier,
                    argumentStorage[0],
                    &fileActions,
                    &attributes,
                    argumentBuffer.baseAddress,
                    environmentBuffer.baseAddress
                )
            }
        }
        _ = Darwin.close(writeDescriptor)
        guard result == 0, processIdentifier > 0 else {
            _ = Darwin.close(readDescriptor)
            return nil
        }
        return SpawnedProcess(
            processIdentifier: processIdentifier,
            outputDescriptor: readDescriptor
        )
    }

    struct ProcessIdentity: Hashable {
        let processIdentifier: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    struct ProcessSnapshot {
        let identity: ProcessIdentity
        let parentIdentifier: pid_t
        let isZombie: Bool
    }

    enum ProcessCensus {
        case available([ProcessSnapshot])
        case unavailable
    }

    enum ProcessIdentityState: Equatable {
        case sameLiveProcess
        case exitedOrReused
        case unknown
    }

    private enum ProcessGroupState: Equatable {
        case clear
        case live
        case unknown
    }

    struct OwnedProcessTracker {
        let leader: pid_t
        private(set) var descendants: Set<ProcessIdentity> = []
        private(set) var censusReliable = true
        private(set) var identityReliable = true

        init(
            leader: pid_t,
            descendants: Set<ProcessIdentity> = []
        ) {
            self.leader = leader
            self.descendants = descendants
        }

        mutating func refresh() {
            refresh(
                identityStateProvider:
                    CodexVersionProbe.observedIdentityState,
                directChildrenProvider:
                    CodexVersionProbe.directChildren
            )
        }

        mutating func refresh(
            identityStateProvider:
                (ProcessIdentity) -> ProcessIdentityState,
            directChildrenProvider:
                (pid_t) -> ProcessCensus
        ) {
            // Census and identity ambiguity can be transient while a
            // descendant is exiting. Re-evaluate both on every snapshot;
            // containment remains fail-closed if either is still unresolved
            // at the decision boundary, without turning a later proven
            // absence into failure. No ambiguous PID is traversed or signaled.
            censusReliable = true
            identityReliable = true
            // Once the unreaped leader has exited, it cannot create another
            // child and libproc may reject child enumeration for its zombie
            // PID. Previously observed descendants remain identity-tracked.
            var pending = CodexVersionProbe.hasExited(leader)
                ? [] : [leader]
            var visited = Set<pid_t>()
            for identity in descendants {
                switch identityStateProvider(identity) {
                case .sameLiveProcess:
                    pending.append(identity.processIdentifier)
                case .exitedOrReused:
                    continue
                case .unknown:
                    identityReliable = false
                }
            }
            while let parent = pending.popLast() {
                guard visited.insert(parent).inserted else {
                    continue
                }
                guard case .available(let children) =
                        directChildrenProvider(parent) else {
                    censusReliable = false
                    continue
                }
                for snapshot in children {
                    descendants.insert(snapshot.identity)
                    pending.append(
                        snapshot.identity.processIdentifier
                    )
                }
            }
        }

        mutating func signalDescendants(_ signal: Int32) {
            signalDescendants(
                signal,
                identityStateProvider:
                    CodexVersionProbe.observedIdentityState,
                signalSender: {
                    _ = Darwin.kill($0, $1)
                }
            )
        }

        mutating func signalDescendants(
            _ signal: Int32,
            identityStateProvider:
                (ProcessIdentity) -> ProcessIdentityState,
            signalSender: (pid_t, Int32) -> Void
        ) {
            for identity in descendants {
                switch identityStateProvider(identity) {
                case .sameLiveProcess:
                    signalSender(
                        identity.processIdentifier,
                        signal
                    )
                case .exitedOrReused:
                    continue
                case .unknown:
                    // Existence alone cannot establish that this is still our
                    // process. Never signal an ambiguous or reused PID.
                    identityReliable = false
                }
            }
        }

        mutating func markCensusUnreliable() {
            censusReliable = false
        }

        mutating func hasLiveDescendants() -> Bool {
            var hasLive = false
            for identity in descendants {
                switch CodexVersionProbe.observedIdentityState(
                    identity
                ) {
                case .sameLiveProcess:
                    hasLive = true
                case .exitedOrReused:
                    continue
                case .unknown:
                    identityReliable = false
                    // Preserve the wait bound and fail containment closed.
                    hasLive = true
                }
            }
            return hasLive
        }

        var containmentReliable: Bool {
            censusReliable && identityReliable
        }
    }

    private static func terminateOwnedProcesses(
        processGroup: pid_t,
        ownedProcesses: inout OwnedProcessTracker,
        outputDescriptor: Int32,
        output: CodexVersionOutputBuffer,
        grace: TimeInterval
    ) -> Bool {
        _ = Darwin.kill(-processGroup, SIGTERM)
        // The direct child PID cannot be reused before we reap it. Signal it
        // independently in case the executable changed its own process group.
        _ = Darwin.kill(processGroup, SIGTERM)
        ownedProcesses.signalDescendants(SIGTERM)
        let gracefulDeadline = deadline(after: grace)
        if waitForOwnedProcessesToExit(
            processGroup: processGroup,
            ownedProcesses: &ownedProcesses,
            outputDescriptor: outputDescriptor,
            output: output,
            until: gracefulDeadline
        ) {
            return ownedProcesses.containmentReliable
        }

        _ = Darwin.kill(-processGroup, SIGKILL)
        _ = Darwin.kill(processGroup, SIGKILL)
        ownedProcesses.signalDescendants(SIGKILL)
        let killDeadline = deadline(after: max(grace, 1))
        let exited = waitForOwnedProcessesToExit(
            processGroup: processGroup,
            ownedProcesses: &ownedProcesses,
            outputDescriptor: outputDescriptor,
            output: output,
            until: killDeadline
        )
        return exited && ownedProcesses.containmentReliable
    }

    private static func waitForOwnedProcessesToExit(
        processGroup: pid_t,
        ownedProcesses: inout OwnedProcessTracker,
        outputDescriptor: Int32,
        output: CodexVersionOutputBuffer,
        until deadline: UInt64
    ) -> Bool {
        while DispatchTime.now().uptimeNanoseconds < deadline {
            ownedProcesses.refresh()
            let groupState = processGroupState(
                processGroup,
                leader: ownedProcesses.leader
            )
            let hasLiveDescendants =
                ownedProcesses.hasLiveDescendants()
            if groupState == .clear,
               !hasLiveDescendants,
               ownedProcesses.containmentReliable {
                return true
            }
            if groupState == .unknown {
                ownedProcesses.markCensusUnreliable()
            }
            guard drain(
                outputDescriptor,
                into: output,
                until: deadline
            ) else {
                break
            }
            waitForReadable(
                outputDescriptor,
                until: deadline
            )
        }
        ownedProcesses.refresh()
        let groupState = processGroupState(
            processGroup,
            leader: ownedProcesses.leader
        )
        if groupState == .unknown {
            ownedProcesses.markCensusUnreliable()
        }
        let hasLiveDescendants =
            ownedProcesses.hasLiveDescendants()
        return groupState == .clear
            && !hasLiveDescendants
    }

    private static func processGroupState(
        _ processGroup: pid_t,
        leader: pid_t
    ) -> ProcessGroupState {
        var capacity = 16
        let maximumCapacity = 4_096
        while capacity <= maximumCapacity {
            var identifiers = [pid_t](
                repeating: 0,
                count: capacity
            )
            let returnedCount =
                identifiers.withUnsafeMutableBytes { buffer in
                    proc_listpgrppids(
                        processGroup,
                        buffer.baseAddress,
                        Int32(buffer.count)
                    )
                }
            guard returnedCount > 0 else {
                // libproc is documented in practice to return zero both for
                // an empty result and some errors. Independently establish
                // absence instead of interpreting the ambiguous value as
                // success.
                let fallbackState =
                    fullProcessListGroupState(
                        processGroup,
                        leader: leader
                    )
                if fallbackState != .unknown {
                    return fallbackState
                }
                errno = 0
                if Darwin.kill(-processGroup, 0) == -1,
                   errno == ESRCH {
                    return .clear
                }
                if hasExited(leader) {
                    // A zombie leader can keep the group identifier visible
                    // to kill(2), but does not execute or retain stdout.
                    return .unknown
                }
                return .live
            }
            // libproc returns a PID count (not a byte count); the byte size
            // supplied above is only the capacity of the destination buffer.
            let count = Int(returnedCount)
            let candidates =
                identifiers.prefix(min(count, capacity))
            var hasUnknownCandidate = false
            for processIdentifier in candidates
            where processIdentifier > 0 {
                if processIdentifier == processGroup,
                   hasExited(processIdentifier) {
                    continue
                }
                switch processGroupMemberState(
                    processIdentifier
                ) {
                case .live:
                    return .live
                case .clear:
                    continue
                case .unknown:
                    hasUnknownCandidate = true
                }
            }
            if hasUnknownCandidate {
                return .unknown
            }
            if count < capacity {
                return .clear
            }
            if capacity == maximumCapacity {
                return .unknown
            }
            capacity *= 2
        }
        return .unknown
    }

    /// `proc_listpgrppids` can ambiguously return zero while a zombie leader
    /// keeps kill(-pgid, 0) successful. A separately sized all-PID census plus
    /// current group lookup resolves that state without treating signalability
    /// as proof of stored PID identity or individual-process ownership.
    private static func fullProcessListGroupState(
        _ processGroup: pid_t,
        leader: pid_t
    ) -> ProcessGroupState {
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount >= 0 else {
            return .unknown
        }
        var capacity = max(256, Int(estimatedCount) + 64)
        let maximumCapacity = 32_768
        while capacity <= maximumCapacity {
            var identifiers = [pid_t](
                repeating: 0,
                count: capacity
            )
            let returnedCount =
                identifiers.withUnsafeMutableBytes { buffer in
                    proc_listallpids(
                        buffer.baseAddress,
                        Int32(buffer.count)
                    )
                }
            guard returnedCount >= 0 else {
                return .unknown
            }
            if returnedCount >= capacity {
                guard capacity < maximumCapacity else {
                    return .unknown
                }
                capacity = min(capacity * 2, maximumCapacity)
                continue
            }

            for processIdentifier
            in identifiers.prefix(Int(returnedCount))
            where processIdentifier > 0 {
                errno = 0
                let candidateGroup = getpgid(
                    processIdentifier
                )
                if candidateGroup == -1 {
                    if processIdentifier == leader,
                       errno != ESRCH,
                       !hasExited(leader) {
                        return .unknown
                    }
                    // An unrelated inaccessible or already-changing system
                    // PID does not corroborate membership in this group.
                    // Owned descendants are same-user and independently
                    // covered by stable identity tracking.
                    continue
                }
                guard candidateGroup == processGroup else {
                    continue
                }
                if processIdentifier == leader,
                   hasExited(leader) {
                    continue
                }
                switch processGroupMemberState(
                    processIdentifier
                ) {
                case .clear:
                    continue
                case .live:
                    return .live
                case .unknown:
                    // The process may have exited or changed groups between
                    // getpgid(2) and proc_pidinfo(2). Re-check group
                    // membership before failing this bounded census closed;
                    // never promote an inaccessible snapshot to live.
                    errno = 0
                    let recheckedGroup = getpgid(
                        processIdentifier
                    )
                    if recheckedGroup == -1,
                       errno == ESRCH {
                        continue
                    }
                    if recheckedGroup != processGroup {
                        continue
                    }
                    return .unknown
                }
            }
            return .clear
        }
        return .unknown
    }

    private static func directChildren(
        of parent: pid_t
    ) -> ProcessCensus {
        var capacity = 16
        let maximumCapacity = 4_096
        while capacity <= maximumCapacity {
            var identifiers = [pid_t](
                repeating: 0,
                count: capacity
            )
            errno = 0
            let returnedCount =
                identifiers.withUnsafeMutableBytes { buffer in
                    proc_listchildpids(
                        parent,
                        buffer.baseAddress,
                        Int32(buffer.count)
                    )
                }
            guard returnedCount >= 0,
                  returnedCount != 0 || errno == 0 else {
                return .unavailable
            }
            let count = Int(returnedCount)
            if count >= capacity {
                guard capacity < maximumCapacity else {
                    return .unavailable
                }
                capacity = min(capacity * 2, maximumCapacity)
                continue
            }
            var snapshots: [ProcessSnapshot] = []
            for processIdentifier in identifiers.prefix(count) {
                guard processIdentifier > 0 else {
                    continue
                }
                guard let snapshot = processSnapshot(
                    processIdentifier
                ) else {
                    // `kill(pid, 0)` may establish absence, but success can
                    // never confirm a stable PID/start-time identity.
                    guard isDefinitelyAbsent(
                        processIdentifier
                    ) else {
                        return .unavailable
                    }
                    continue
                }
                guard snapshot.parentIdentifier == parent else {
                    continue
                }
                snapshots.append(snapshot)
            }
            return .available(snapshots)
        }
        return .unavailable
    }

    private static func processSnapshot(
        _ processIdentifier: pid_t
    ) -> ProcessSnapshot? {
        guard processIdentifier > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let returnedSize = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(
                processIdentifier,
                PROC_PIDTBSDINFO,
                0,
                $0,
                Int32(expectedSize)
            )
        }
        guard returnedSize == expectedSize else {
            return nil
        }
        return ProcessSnapshot(
            identity: ProcessIdentity(
                processIdentifier: processIdentifier,
                startSeconds: info.pbi_start_tvsec,
                startMicroseconds: info.pbi_start_tvusec
            ),
            parentIdentifier: pid_t(info.pbi_ppid),
            isZombie: info.pbi_status == UInt32(SZOMB)
        )
    }

    static func identityState(
        _ identity: ProcessIdentity,
        observed snapshot: ProcessSnapshot?,
        absenceConfirmed: Bool
    ) -> ProcessIdentityState {
        guard let snapshot else {
            return absenceConfirmed ? .exitedOrReused : .unknown
        }
        guard snapshot.identity == identity else {
            return .exitedOrReused
        }
        return snapshot.isZombie
            ? .exitedOrReused
            : .sameLiveProcess
    }

    private static func observedIdentityState(
        _ identity: ProcessIdentity
    ) -> ProcessIdentityState {
        let snapshot = processSnapshot(
            identity.processIdentifier
        )
        return identityState(
            identity,
            observed: snapshot,
            absenceConfirmed:
                snapshot == nil
                    && isDefinitelyAbsent(
                        identity.processIdentifier
                    )
        )
    }

    private static func isDefinitelyAbsent(
        _ processIdentifier: pid_t
    ) -> Bool {
        errno = 0
        return Darwin.kill(processIdentifier, 0) == -1
            && errno == ESRCH
    }

    private static func processGroupMemberState(
        _ processIdentifier: pid_t
    ) -> ProcessGroupState {
        if let snapshot = processSnapshot(processIdentifier) {
            return snapshot.isZombie ? .clear : .live
        }
        // Full BSD info includes the stable start time used for owned PID
        // identities, but can disappear during process teardown before the
        // shorter status record. The latter is sufficient only for current
        // process-group liveness and is never used to prove ownership.
        var shortInfo = proc_bsdshortinfo()
        let expectedSize = MemoryLayout<proc_bsdshortinfo>.size
        let returnedSize = withUnsafeMutablePointer(
            to: &shortInfo
        ) {
            proc_pidinfo(
                processIdentifier,
                PROC_PIDT_SHORTBSDINFO,
                0,
                $0,
                Int32(expectedSize)
            )
        }
        if returnedSize == expectedSize {
            return shortInfo.pbsi_status == UInt32(SZOMB)
                ? .clear
                : .live
        }
        return isDefinitelyAbsent(processIdentifier)
            ? .clear
            : .unknown
    }

    /// Observes exit without reaping so the process-group identifier remains
    /// owned until every descendant has been contained.
    private static func hasExited(
        _ processIdentifier: pid_t
    ) -> Bool {
        var info = siginfo_t()
        while true {
            let result = waitid(
                P_PID,
                UInt32(processIdentifier),
                &info,
                WEXITED | WNOHANG | WNOWAIT
            )
            if result == 0 {
                return info.si_pid == processIdentifier
            }
            if errno != EINTR {
                return false
            }
        }
    }

    @discardableResult
    private static func drain(
        _ descriptor: Int32,
        into output: CodexVersionOutputBuffer,
        until deadline: UInt64
    ) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 1_024)
        var reads = 0
        while reads < maximumReadsPerDrain {
            guard DispatchTime.now().uptimeNanoseconds
                    < deadline else {
                return false
            }
            let count = Darwin.read(
                descriptor,
                &bytes,
                bytes.count
            )
            if count > 0 {
                output.consume(
                    Data(bytes.prefix(Int(count)))
                )
                reads += 1
                continue
            }
            if count == -1,
               errno == EINTR {
                continue
            }
            return true
        }
        return DispatchTime.now().uptimeNanoseconds < deadline
    }

    private static func waitForReadable(
        _ descriptor: Int32,
        until deadline: UInt64
    ) {
        guard DispatchTime.now().uptimeNanoseconds
                < deadline else {
            return
        }
        var descriptorState = pollfd(
            fd: descriptor,
            events: Int16(POLLIN | POLLHUP),
            revents: 0
        )
        _ = Darwin.poll(
            &descriptorState,
            1,
            pollIntervalMilliseconds
        )
    }

    private static func exitedSuccessfully(
        _ status: Int32
    ) -> Bool {
        // Darwin wait status: low seven bits are the terminating signal;
        // the next byte is the exit status when no signal is present.
        (status & 0x7f) == 0
            && ((status >> 8) & 0xff) == 0
    }

    private static func reapDirectChild(
        _ processIdentifier: pid_t,
        outputDescriptor: Int32,
        output: CodexVersionOutputBuffer,
        timeout: TimeInterval
    ) -> (
        reaped: Bool,
        status: Int32,
        needsLateReaper: Bool
    ) {
        var status: Int32 = 0
        guard timeout > 0 else {
            return (false, status, true)
        }
        let reapDeadline = deadline(after: timeout)
        while DispatchTime.now().uptimeNanoseconds
                < reapDeadline {
            let result = waitpid(
                processIdentifier,
                &status,
                WNOHANG
            )
            if result == processIdentifier {
                return (true, status, false)
            }
            if result == -1, errno != EINTR {
                return (false, status, false)
            }
            _ = drain(
                outputDescriptor,
                into: output,
                until: reapDeadline
            )
            waitForReadable(
                outputDescriptor,
                until: reapDeadline
            )
        }
        // The foreground remains bounded and receives no version. Register an
        // exact-PID exit source so a child that exits later is eventually
        // reaped without occupying a worker in blocking waitpid.
        return (false, status, true)
    }

    private static func deadline(
        after interval: TimeInterval
    ) -> UInt64 {
        let nanoseconds = UInt64(
            max(1, interval * 1_000_000_000)
        )
        return DispatchTime.now().uptimeNanoseconds
            &+ nanoseconds
    }
}

private nonisolated final class CodexVersionLateReaper:
    @unchecked Sendable
{
    static let shared = CodexVersionLateReaper()

    private let queue = DispatchQueue(
        label: "io.revenium.claude-usage.codex-version-reaper",
        qos: .utility
    )
    private let lock = NSLock()
    private var sources: [pid_t: DispatchSourceProcess] = [:]

    func register(_ processIdentifier: pid_t) {
        guard processIdentifier > 0 else { return }
        let source = DispatchSource.makeProcessSource(
            identifier: processIdentifier,
            eventMask: .exit,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.reapExitedProcess(processIdentifier)
        }

        lock.lock()
        guard sources[processIdentifier] == nil else {
            lock.unlock()
            source.resume()
            source.cancel()
            return
        }
        sources[processIdentifier] = source
        lock.unlock()
        source.resume()
    }

    private func reapExitedProcess(
        _ processIdentifier: pid_t
    ) {
        // Keep successful reaping and registry removal atomic with respect to
        // registration. waitpid frees the PID for reuse; without this lock a
        // new child could reuse it while the old source was still indexed,
        // causing register to discard the new child's reaper.
        lock.lock()
        guard sources[processIdentifier] != nil else {
            lock.unlock()
            return
        }
        var status: Int32 = 0
        let result = waitpid(
            processIdentifier,
            &status,
            WNOHANG
        )
        if result == 0 || (result == -1 && errno == EINTR) {
            lock.unlock()
            // The exit event is authoritative, but retry asynchronously if a
            // signal interrupted waitpid or delivery raced final bookkeeping.
            queue.asyncAfter(
                deadline: .now() + .milliseconds(1)
            ) { [weak self] in
                self?.reapExitedProcess(
                    processIdentifier
                )
            }
            return
        }
        let source = sources.removeValue(
            forKey: processIdentifier
        )
        lock.unlock()
        source?.cancel()
    }
}

private nonisolated final class CodexVersionOutputBuffer:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var exceededLimit = false

    init(limit: Int) {
        self.limit = limit
    }

    func consume(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !exceededLimit else { return }
        guard chunk.count <= limit - data.count else {
            exceededLimit = true
            data.removeAll(keepingCapacity: false)
            return
        }
        data.append(chunk)
    }

    var value: Data? {
        lock.lock()
        defer { lock.unlock() }
        return exceededLimit ? nil : data
    }
}
