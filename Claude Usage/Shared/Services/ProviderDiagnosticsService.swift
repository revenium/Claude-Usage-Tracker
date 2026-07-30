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

/// A diagnostics-only subprocess boundary with the same ownership guarantees
/// as provider requests: bounded output, no inherited credentials, bounded
/// execution, and a proven reap before returning on every launched path.
nonisolated enum CodexVersionProbe {
    private static let maximumOutputBytes = 4_096
    private static let defaultTimeout: TimeInterval = 2
    private static let defaultTerminationGrace: TimeInterval = 0.25
    private static let pollIntervalMilliseconds: Int32 = 5

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
        guard timeout.isFinite, timeout > 0,
              terminationGrace.isFinite,
              terminationGrace > 0 else {
            return nil
        }
        return await Task.detached(priority: .utility) {
            runSynchronously(
                executableURL,
                timeout: timeout,
                terminationGrace: terminationGrace
            )
        }.value
    }

    private static func runSynchronously(
        _ executableURL: URL,
        timeout: TimeInterval,
        terminationGrace: TimeInterval
    ) -> String? {
        let output = CodexVersionOutputBuffer(
            limit: maximumOutputBytes
        )
        guard let spawned = spawn(executableURL) else {
            return nil
        }
        let processIdentifier = spawned.processIdentifier
        let outputDescriptor = spawned.outputDescriptor
        var timedOut = false
        let executionDeadline = deadline(after: timeout)
        while !hasExited(processIdentifier) {
            drain(outputDescriptor, into: output)
            guard DispatchTime.now().uptimeNanoseconds
                    < executionDeadline else {
                timedOut = true
                break
            }
            waitForReadable(outputDescriptor)
        }
        drain(outputDescriptor, into: output)

        let descendantsExited = terminateProcessGroup(
            processIdentifier,
            outputDescriptor: outputDescriptor,
            output: output,
            grace: terminationGrace
        )

        var status: Int32 = 0
        var reaped = false
        let reapDeadline = deadline(
            after: max(terminationGrace, 1)
        )
        while DispatchTime.now().uptimeNanoseconds
                < reapDeadline {
            let result = waitpid(
                processIdentifier,
                &status,
                WNOHANG
            )
            if result == processIdentifier {
                reaped = true
                break
            }
            if result == -1 {
                break
            }
            drain(outputDescriptor, into: output)
            waitForReadable(outputDescriptor)
        }
        if !reaped {
            _ = Darwin.kill(-processIdentifier, SIGKILL)
            // A blocking wait is safe only after waitid(WNOWAIT) has proven
            // the direct child exited. Otherwise preserve the caller's
            // bounded return and leave the unreaped PID ownership-stable
            // while a utility worker completes the reaping barrier.
            if hasExited(processIdentifier) {
                while !reaped {
                    let result = waitpid(
                        processIdentifier,
                        &status,
                        0
                    )
                    if result == processIdentifier {
                        reaped = true
                    } else if result == -1, errno != EINTR {
                        break
                    }
                }
            } else {
                deferReaping(processIdentifier)
            }
        }
        drain(outputDescriptor, into: output)
        _ = Darwin.close(outputDescriptor)

        guard !timedOut,
              descendantsExited,
              reaped,
              exitedSuccessfully(status),
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

    private static func terminateProcessGroup(
        _ processGroup: pid_t,
        outputDescriptor: Int32,
        output: CodexVersionOutputBuffer,
        grace: TimeInterval
    ) -> Bool {
        _ = Darwin.kill(-processGroup, SIGTERM)
        let gracefulDeadline = deadline(after: grace)
        while hasLiveMembers(processGroup) {
            drain(outputDescriptor, into: output)
            guard DispatchTime.now().uptimeNanoseconds
                    < gracefulDeadline else {
                break
            }
            waitForReadable(outputDescriptor)
        }
        if hasLiveMembers(processGroup) {
            _ = Darwin.kill(-processGroup, SIGKILL)
        }
        let killDeadline = deadline(after: max(grace, 1))
        while hasLiveMembers(processGroup) {
            drain(outputDescriptor, into: output)
            guard DispatchTime.now().uptimeNanoseconds
                    < killDeadline else {
                return false
            }
            waitForReadable(outputDescriptor)
        }
        return true
    }

    private static func hasLiveMembers(
        _ processGroup: pid_t
    ) -> Bool {
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
            guard returnedCount >= 0 else {
                return true
            }
            // libproc returns a PID count (not a byte count); the byte size
            // supplied above is only the capacity of the destination buffer.
            let count = Int(returnedCount)
            let candidates =
                identifiers.prefix(min(count, capacity))
            if candidates.contains(where: {
                guard $0 > 0 else { return false }
                if $0 == processGroup {
                    return !hasExited($0)
                }
                return !isZombie($0)
            }) {
                return true
            }
            if count < capacity {
                return false
            }
            if capacity == maximumCapacity {
                return true
            }
            capacity *= 2
        }
        return true
    }

    private static func isZombie(
        _ processIdentifier: pid_t
    ) -> Bool {
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
        return returnedSize == expectedSize
            && info.pbi_status == UInt32(SZOMB)
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

    private static func drain(
        _ descriptor: Int32,
        into output: CodexVersionOutputBuffer
    ) {
        var bytes = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = Darwin.read(
                descriptor,
                &bytes,
                bytes.count
            )
            if count > 0 {
                output.consume(
                    Data(bytes.prefix(Int(count)))
                )
                continue
            }
            if count == -1,
               errno == EINTR {
                continue
            }
            return
        }
    }

    private static func waitForReadable(
        _ descriptor: Int32
    ) {
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

    private static func deferReaping(
        _ processIdentifier: pid_t
    ) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(
                processIdentifier,
                &status,
                0
            ) == -1,
            errno == EINTR {
                // Retry only interrupted waits.
            }
        }
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
