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
        let process = Process()
        let outputPipe = Pipe()
        let output = CodexVersionOutputBuffer(
            limit: maximumOutputBytes
        )
        let termination = DispatchSemaphore(value: 0)
        let readHandle = outputPipe.fileHandleForReading

        process.executableURL = executableURL
        process.arguments = ["--version"]
        process.environment = [
            "HOME": "/var/empty",
            "LANG": "C",
            "LC_ALL": "C"
        ]
        process.currentDirectoryURL =
            URL(fileURLWithPath: "/", isDirectory: true)
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            termination.signal()
        }
        readHandle.readabilityHandler = { handle in
            output.consume(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            readHandle.readabilityHandler = nil
            try? outputPipe.fileHandleForWriting.close()
            try? readHandle.close()
            return nil
        }
        // Process owns its duplicated descriptor after launch. Closing the
        // parent's writer is required for the reader to observe EOF.
        try? outputPipe.fileHandleForWriting.close()

        var timedOut = false
        let initialWait = termination.wait(
            timeout: dispatchDeadline(after: timeout)
        )
        if initialWait == .timedOut {
            timedOut = true
            process.terminate()
            let gracefulWait = termination.wait(
                timeout:
                    dispatchDeadline(after: terminationGrace)
            )
            if gracefulWait == .timedOut {
                _ = Darwin.kill(
                    process.processIdentifier,
                    SIGKILL
                )
            }
        }

        // waitUntilExit performs the final waitpid/reap. It intentionally
        // happens even after the termination handler fires and before any
        // caller can observe probe completion.
        process.waitUntilExit()
        readHandle.readabilityHandler = nil
        output.consume(readHandle.readDataToEndOfFile())
        try? readHandle.close()

        guard !timedOut,
              process.terminationStatus == 0,
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

    private static func dispatchDeadline(
        after interval: TimeInterval
    ) -> DispatchTime {
        .now()
            + .milliseconds(
                max(1, Int(interval * 1_000))
            )
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
        guard data.count + chunk.count <= limit else {
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
