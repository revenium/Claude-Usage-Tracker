import Darwin
import Foundation

public struct CodexHomeIdentity: Equatable, Sendable {
    public let deviceID: UInt64
    public let fileID: UInt64

    public init(deviceID: UInt64, fileID: UInt64) {
        self.deviceID = deviceID
        self.fileID = fileID
    }

    fileprivate static func read(
        from url: URL,
        fileManager: FileManager = .default
    ) -> Self? {
        guard let attributes = try? fileManager.attributesOfItem(
            atPath: url.path
        ),
        let device = attributes[.systemNumber] as? NSNumber,
        let file = attributes[.systemFileNumber] as? NSNumber else {
            return nil
        }
        return Self(
            deviceID: device.uint64Value,
            fileID: file.uint64Value
        )
    }
}

public struct CodexProcessConfiguration: Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let codexHomeURL: URL
    fileprivate let codexHomeIdentity: CodexHomeIdentity
    let workingDirectoryURL: URL

    public init(
        executableURL: URL,
        arguments: [String] = ["app-server"],
        environment: [String: String] = [:],
        codexHomeURL: URL,
        expectedCodexHomeIdentity: CodexHomeIdentity? = nil,
        workingDirectoryURL: URL? = nil
    ) throws {
        let fileManager = FileManager.default
        let executable = executableURL.standardizedFileURL
        let codexHome = codexHomeURL.standardizedFileURL.resolvingSymlinksInPath()
        let workingDirectory = (workingDirectoryURL ?? codexHomeURL)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        guard executable.isFileURL,
              executable.path.hasPrefix("/"),
              fileManager.isExecutableFile(atPath: executable.path)
        else {
            throw CodexTransportError.invalidConfiguration(.executable)
        }

        var isDirectory: ObjCBool = false
        guard codexHome.isFileURL,
              codexHome.path.hasPrefix("/"),
              fileManager.fileExists(atPath: codexHome.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let observedCodexHomeIdentity = CodexHomeIdentity.read(
                  from: codexHome,
                  fileManager: fileManager
              )
        else {
            throw CodexTransportError.invalidConfiguration(.codexHome)
        }

        let codexHomeIdentity: CodexHomeIdentity
        if let expectedCodexHomeIdentity {
            guard expectedCodexHomeIdentity == observedCodexHomeIdentity else {
                throw CodexTransportError.invalidConfiguration(.codexHome)
            }
            codexHomeIdentity = expectedCodexHomeIdentity
        } else {
            codexHomeIdentity = observedCodexHomeIdentity
        }

        isDirectory = false
        guard workingDirectory.isFileURL,
              workingDirectory.path.hasPrefix("/"),
              fileManager.fileExists(atPath: workingDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw CodexTransportError.invalidConfiguration(.workingDirectory)
        }

        guard environment["CODEX_HOME"] == nil,
              environment.allSatisfy({ key, value in
                  !key.isEmpty
                      && !key.contains("=")
                      && !key.contains("\0")
                      && !value.contains("\0")
              }),
              arguments.allSatisfy({ !$0.contains("\0") })
        else {
            throw CodexTransportError.invalidConfiguration(.environment)
        }

        self.executableURL = executable
        self.arguments = arguments
        self.environment = environment
        self.codexHomeURL = codexHome
        self.codexHomeIdentity = codexHomeIdentity
        self.workingDirectoryURL = workingDirectory
    }
}

public struct CodexTransportLimits: Equatable, Sendable {
    public var maximumLineBytes: Int
    public var maximumStdoutBytes: Int
    public var maximumStderrBytes: Int
    public var startupTimeout: TimeInterval
    public var requestTimeout: TimeInterval
    public var overallTimeout: TimeInterval
    public var terminationGracePeriod: TimeInterval

    public init(
        maximumLineBytes: Int = 256 * 1_024,
        maximumStdoutBytes: Int = 2 * 1_024 * 1_024,
        maximumStderrBytes: Int = 256 * 1_024,
        startupTimeout: TimeInterval = 10,
        requestTimeout: TimeInterval = 20,
        overallTimeout: TimeInterval = 30,
        terminationGracePeriod: TimeInterval = 2
    ) throws {
        guard maximumLineBytes > 0,
              maximumStdoutBytes >= maximumLineBytes,
              maximumStderrBytes > 0,
              startupTimeout.isFinite,
              startupTimeout > 0,
              requestTimeout.isFinite,
              requestTimeout > 0,
              overallTimeout.isFinite,
              overallTimeout > 0,
              terminationGracePeriod.isFinite,
              terminationGracePeriod > 0
        else {
            throw CodexTransportError.invalidConfiguration(.limits)
        }
        self.maximumLineBytes = maximumLineBytes
        self.maximumStdoutBytes = maximumStdoutBytes
        self.maximumStderrBytes = maximumStderrBytes
        self.startupTimeout = startupTimeout
        self.requestTimeout = requestTimeout
        self.overallTimeout = overallTimeout
        self.terminationGracePeriod = terminationGracePeriod
    }
}

public enum CodexConfigurationField: String, Equatable, Sendable {
    case executable
    case codexHome
    case workingDirectory
    case environment
    case clientInfo
    case limits
}

public enum CodexOutputStream: String, Equatable, Sendable {
    case stdout
    case stderr
}

public enum CodexTimeoutStage: String, Equatable, Sendable {
    case startup
    case request
    case notification
    case overall
    case termination
}

public enum CodexTransportError: Error, Equatable, Sendable {
    case invalidConfiguration(CodexConfigurationField)
    case launchFailed
    case writeFailed(method: CodexMethod?)
    case outputLimitExceeded(CodexOutputStream)
    case lineLimitExceeded
    case malformedFrame
    case processExited(status: Int32)
    case unexpectedEOF
    case requestIDMismatch(expected: Int64, received: CodexRequestIDKind)
    case requestIDExhausted
    case rpcFailure(code: Int64, method: CodexMethod, id: Int64)
    case unsupportedServerRequest(method: CodexMethod)
    case unexpectedResponse(idKind: CodexRequestIDKind)
    case timedOut(stage: CodexTimeoutStage, method: CodexMethod?, id: Int64?)
    case cancelled(method: CodexMethod?, id: Int64?)
}

extension CodexTransportError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case let .invalidConfiguration(field):
            "Invalid Codex process configuration (\(field.rawValue))."
        case .launchFailed:
            "The Codex app-server process could not be launched."
        case let .writeFailed(method):
            "The Codex app-server request could not be written\(Self.metadata(method: method))."
        case let .outputLimitExceeded(stream):
            "The Codex app-server exceeded the \(stream.rawValue) safety limit."
        case .lineLimitExceeded:
            "The Codex app-server emitted an oversized protocol frame."
        case .malformedFrame:
            "The Codex app-server emitted a malformed protocol frame."
        case let .processExited(status):
            "The Codex app-server exited before completing the operation (status \(status))."
        case .unexpectedEOF:
            "The Codex app-server closed its protocol stream before completing the operation."
        case let .requestIDMismatch(expected, received):
            "The Codex app-server returned a mismatched request ID (expected \(expected), received \(received.rawValue) ID)."
        case .requestIDExhausted:
            "The Codex app-server request ID sequence was exhausted."
        case let .rpcFailure(code, method, id):
            "The Codex app-server rejected \(method.diagnosticLabel) (request \(id), code \(code))."
        case let .unsupportedServerRequest(method):
            "The Codex app-server sent an unsupported server request (\(method.diagnosticLabel))."
        case let .unexpectedResponse(idKind):
            "The Codex app-server sent an unexpected \(idKind.rawValue)-ID response."
        case let .timedOut(stage, method, id):
            "The Codex app-server operation timed out during \(stage.rawValue)\(Self.metadata(method: method, id: id))."
        case let .cancelled(method, id):
            "The Codex app-server operation was cancelled\(Self.metadata(method: method, id: id))."
        }
    }

    public var errorDescription: String? { description }

    private static func metadata(method: CodexMethod?, id: Int64? = nil) -> String {
        switch (method, id) {
        case let (method?, id?):
            " (\(method.diagnosticLabel), request \(id))"
        case let (method?, nil):
            " (\(method.diagnosticLabel))"
        case let (nil, id?):
            " (request \(id))"
        case (nil, nil):
            ""
        }
    }
}

enum BoundedProcessOutputError: Error, Equatable, Sendable {
    case outputLimit(CodexOutputStream)
    case lineLimit
    case exited(Int32)
    case eof
}

private final class BoundedLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumLineBytes: Int
    private let maximumStdoutBytes: Int
    private var totalBytes = 0
    private var pendingBytes = Data()
    private var lines: [Data] = []
    private var terminalError: BoundedProcessOutputError?
    private var exitStatus: Int32?
    private var stdoutEnded = false
    private var waiters: [
        UUID: (Result<Data, Error>) -> Void
    ] = [:]
    private var waiterOrder: [UUID] = []
    private var cancelledWaiters = Set<UUID>()

    init(maximumLineBytes: Int, maximumStdoutBytes: Int) {
        self.maximumLineBytes = maximumLineBytes
        self.maximumStdoutBytes = maximumStdoutBytes
    }

    func consume(_ data: Data) {
        var completions: [((Result<Data, Error>) -> Void, Result<Data, Error>)] = []
        lock.lock()
        if terminalError == nil {
            if data.isEmpty {
                stdoutEnded = true
                if !pendingBytes.isEmpty {
                    if pendingBytes.count > maximumLineBytes {
                        terminalError = .lineLimit
                    } else {
                        lines.append(pendingBytes)
                    }
                    pendingBytes.removeAll(keepingCapacity: false)
                }
            } else {
                totalBytes += data.count
                if totalBytes > maximumStdoutBytes {
                    terminalError = .outputLimit(.stdout)
                } else {
                    pendingBytes.append(data)
                    extractLinesLocked()
                }
            }
        }
        completions = satisfyWaitersLocked()
        lock.unlock()
        completions.forEach { completion, result in completion(result) }
    }

    func fail(_ error: BoundedProcessOutputError) {
        var completions: [((Result<Data, Error>) -> Void, Result<Data, Error>)] = []
        lock.lock()
        if terminalError == nil {
            terminalError = error
        }
        completions = satisfyWaitersLocked()
        lock.unlock()
        completions.forEach { completion, result in completion(result) }
    }

    func processExited(status: Int32) {
        var completions: [((Result<Data, Error>) -> Void, Result<Data, Error>)] = []
        lock.lock()
        exitStatus = status
        completions = satisfyWaitersLocked()
        lock.unlock()
        completions.forEach { completion, result in completion(result) }
    }

    func nextLine() async throws -> Data {
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(token: token) { result in
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            self.cancel(token: token)
        }
    }

    private func register(
        token: UUID,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        var result: Result<Data, Error>?
        lock.lock()
        if cancelledWaiters.remove(token) != nil {
            result = .failure(CancellationError())
        } else if let terminalError {
            result = .failure(terminalError)
        } else if !lines.isEmpty {
            result = .success(lines.removeFirst())
        } else if stdoutEnded, let exitStatus {
            result = .failure(BoundedProcessOutputError.exited(exitStatus))
        } else if stdoutEnded {
            result = .failure(BoundedProcessOutputError.eof)
        } else {
            waiters[token] = completion
            waiterOrder.append(token)
        }
        lock.unlock()
        if let result {
            completion(result)
        }
    }

    private func cancel(token: UUID) {
        var completion: ((Result<Data, Error>) -> Void)?
        lock.lock()
        if let registered = waiters.removeValue(forKey: token) {
            waiterOrder.removeAll { $0 == token }
            completion = registered
        } else {
            cancelledWaiters.insert(token)
        }
        lock.unlock()
        completion?(.failure(CancellationError()))
    }

    private func extractLinesLocked() {
        while let newlineIndex = pendingBytes.firstIndex(of: 0x0A) {
            var line = pendingBytes[..<newlineIndex]
            if line.last == 0x0D {
                line = line.dropLast()
            }
            if line.count > maximumLineBytes {
                terminalError = .lineLimit
                return
            }
            lines.append(Data(line))
            pendingBytes.removeSubrange(...newlineIndex)
        }
        if pendingBytes.count > maximumLineBytes {
            terminalError = .lineLimit
        }
    }

    private func satisfyWaitersLocked()
        -> [((Result<Data, Error>) -> Void, Result<Data, Error>)]
    {
        var completions: [((Result<Data, Error>) -> Void, Result<Data, Error>)] = []
        if let terminalError {
            lines.removeAll()
            pendingBytes.removeAll()
            for token in waiterOrder {
                if let waiter = waiters.removeValue(forKey: token) {
                    completions.append((waiter, .failure(terminalError)))
                }
            }
            waiterOrder.removeAll()
            return completions
        }

        while !waiterOrder.isEmpty, !lines.isEmpty {
            let token = waiterOrder.removeFirst()
            guard let waiter = waiters.removeValue(forKey: token) else { continue }
            completions.append((waiter, .success(lines.removeFirst())))
        }

        let failure: Error?
        if stdoutEnded, let exitStatus {
            failure = BoundedProcessOutputError.exited(exitStatus)
        } else if stdoutEnded {
            failure = BoundedProcessOutputError.eof
        } else {
            failure = nil
        }

        if let failure, lines.isEmpty {
            for token in waiterOrder {
                if let waiter = waiters.removeValue(forKey: token) {
                    completions.append((waiter, .failure(failure)))
                }
            }
            waiterOrder.removeAll()
        }
        return completions
    }
}

private final class BoundedByteSink: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private let onOverflow: @Sendable () -> Void
    private var totalBytes = 0
    private var overflowed = false

    init(maximumBytes: Int, onOverflow: @escaping @Sendable () -> Void) {
        self.maximumBytes = maximumBytes
        self.onOverflow = onOverflow
    }

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        var didOverflow = false
        lock.lock()
        totalBytes += data.count
        if totalBytes > maximumBytes, !overflowed {
            overflowed = true
            didOverflow = true
        }
        lock.unlock()
        if didOverflow {
            onOverflow()
        }
    }
}

struct CodexOwnedProcessIdentity: Hashable, Sendable {
    let identifier: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

struct CodexProcessObservation: Equatable, Sendable {
    let identity: CodexOwnedProcessIdentity
    let parentIdentifier: Int32
    let isZombie: Bool
}

enum CodexOwnedProcessPolicy {
    static func isLiveRootProcess(
        _ observation: CodexProcessObservation?,
        parentIdentifier: Int32
    ) -> Bool {
        guard let observation else { return false }
        return observation.parentIdentifier == parentIdentifier
            && !observation.isZombie
    }

    static func isLiveMatch(
        _ expected: CodexOwnedProcessIdentity,
        observation: CodexProcessObservation?
    ) -> Bool {
        guard let observation else { return false }
        return observation.identity == expected && !observation.isZombie
    }

    static func isLiveDirectChild(
        _ observation: CodexProcessObservation?,
        of parent: CodexOwnedProcessIdentity,
        parentObservation: CodexProcessObservation?
    ) -> Bool {
        guard let observation else { return false }
        return isLiveMatch(
            parent,
            observation: parentObservation
        )
            && observation.parentIdentifier == parent.identifier
            && !observation.isZombie
    }
}

final class BoundedProcess: @unchecked Sendable {
    private let configuration: CodexProcessConfiguration
    private let limits: CodexTransportLimits
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let writeQueue = DispatchQueue(
        label: "CodexUsageProvider.BoundedProcess.stdin",
        qos: .utility
    )
    private let lineBuffer: BoundedLineBuffer
    private let stateLock = NSLock()
    private var started = false
    private var closed = false
    private var terminationWaiters: [
        UUID: CheckedContinuation<Int32?, Never>
    ] = [:]
    private var terminationStatus: Int32?
    private var launchedProcessIdentifier: Int32?
    private var launchedProcessIdentity: CodexOwnedProcessIdentity?
    private var ownedDescendantIdentities =
        Set<CodexOwnedProcessIdentity>()
    private lazy var stderrSink = BoundedByteSink(
        maximumBytes: limits.maximumStderrBytes
    ) { [lineBuffer] in
        lineBuffer.fail(.outputLimit(.stderr))
    }

    init(configuration: CodexProcessConfiguration, limits: CodexTransportLimits) {
        self.configuration = configuration
        self.limits = limits
        lineBuffer = BoundedLineBuffer(
            maximumLineBytes: limits.maximumLineBytes,
            maximumStdoutBytes: limits.maximumStdoutBytes
        )
    }

    func start() throws {
        stateLock.lock()
        guard !started, !closed else {
            stateLock.unlock()
            throw CodexTransportError.launchFailed
        }
        started = true
        stateLock.unlock()

        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.environment = configuration.environment.merging(
            ["CODEX_HOME": configuration.codexHomeURL.path],
            uniquingKeysWith: { _, injected in injected }
        )
        process.currentDirectoryURL = configuration.workingDirectoryURL
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        guard fcntl(
            stdinPipe.fileHandleForWriting.fileDescriptor,
            F_SETNOSIGPIPE,
            1
        ) == 0 else {
            stateLock.lock()
            started = false
            stateLock.unlock()
            throw CodexTransportError.launchFailed
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [lineBuffer] handle in
            lineBuffer.consume(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [stderrSink] handle in
            stderrSink.consume(handle.availableData)
        }
        process.terminationHandler = { [weak self, lineBuffer] process in
            lineBuffer.processExited(status: process.terminationStatus)
            self?.recordTermination(status: process.terminationStatus)
        }

        do {
            guard !withUnsafeCurrentTask(body: {
                $0?.isCancelled ?? false
            }) else {
                throw CodexTransportError.cancelled(
                    method: nil,
                    id: nil
                )
            }
            try validateCodexHomeAtLaunch()
            try process.run()
            let identifier = process.processIdentifier
            guard identifier > 0 else {
                process.terminate()
                process.waitUntilExit()
                throw CodexTransportError.launchFailed
            }
            let processObservation = Self.processObservation(
                for: identifier
            )
            let processIdentity =
                CodexOwnedProcessPolicy.isLiveRootProcess(
                    processObservation,
                    parentIdentifier: getpid()
                )
                ? processObservation?.identity
                : nil
            if processIdentity == nil, process.isRunning {
                // Never retain a live child whose birth identity could not be
                // established and verified as our direct child. The direct
                // child cannot reuse its PID before it is reaped, so this
                // launch-failure cleanup remains scoped to the Process
                // instance we just started.
                _ = kill(identifier, SIGKILL)
                process.waitUntilExit()
                throw CodexTransportError.launchFailed
            }
            stateLock.lock()
            launchedProcessIdentifier = identifier
            launchedProcessIdentity = processIdentity
            stateLock.unlock()
        } catch let error as CodexTransportError {
            stateLock.lock()
            started = false
            stateLock.unlock()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            lineBuffer.fail(.eof)
            throw error
        } catch {
            stateLock.lock()
            started = false
            stateLock.unlock()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            lineBuffer.fail(.eof)
            throw CodexTransportError.launchFailed
        }
    }

    private func validateCodexHomeAtLaunch() throws {
        let fileManager = FileManager.default
        let storedHome = configuration.codexHomeURL.standardizedFileURL
        let resolvedHome = storedHome
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard storedHome == resolvedHome,
              fileManager.fileExists(
                atPath: storedHome.path,
                isDirectory: &isDirectory
              ),
              isDirectory.boolValue,
              CodexHomeIdentity.read(
                  from: storedHome,
                  fileManager: fileManager
              ) == configuration.codexHomeIdentity else {
            throw CodexTransportError.invalidConfiguration(.codexHome)
        }
    }

    func send(_ data: Data, method: CodexMethod?) async throws {
        guard isWritable() else {
            throw CodexTransportError.writeFailed(method: method)
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                writeQueue.async {
                    do {
                        try self.stdinPipe.fileHandleForWriting.write(
                            contentsOf: data
                        )
                        continuation.resume()
                    } catch {
                        continuation.resume(
                            throwing: CodexTransportError.writeFailed(
                                method: method
                            )
                        )
                    }
                }
            }
        } onCancel: {
            self.abortBlockedIO()
        }
    }

    func nextLine() async throws -> Data {
        do {
            return try await lineBuffer.nextLine()
        } catch BoundedProcessOutputError.eof {
            if let status = await waitForTermination(
                timeout: min(limits.terminationGracePeriod, 0.05)
            ) {
                throw BoundedProcessOutputError.exited(status)
            }
            throw BoundedProcessOutputError.eof
        }
    }

    func close() async throws {
        guard let wasStarted = markClosed() else { return }

        try? stdinPipe.fileHandleForWriting.close()
        if wasStarted {
            signalOwnedProcessTree(SIGTERM)
            var status = await waitForTermination(
                timeout: limits.terminationGracePeriod
            )
            var descendantsExited = await waitForOwnedDescendantsExit(
                timeout: limits.terminationGracePeriod
            )
            if status == nil || !descendantsExited {
                signalOwnedProcessTree(SIGKILL)
                status = await waitForTermination(
                    timeout: max(limits.terminationGracePeriod, 1)
                )
                descendantsExited = await waitForOwnedDescendantsExit(
                    timeout: max(limits.terminationGracePeriod, 1)
                )
                guard status != nil, descendantsExited else {
                    throw CodexTransportError.timedOut(
                        stage: .termination,
                        method: nil,
                        id: nil
                    )
                }
            }
            // Foundation calls the termination handler only after observing the
            // owned child exit. waitUntilExit is then nonblocking and provides
            // an explicit reaping barrier before cleanup can report success.
            process.waitUntilExit()
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        process.terminationHandler = nil
    }

    private func markClosed() -> Bool? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed else { return nil }
        closed = true
        return started
    }

    private func isWritable() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return started && !closed
    }

    private func abortBlockedIO() {
        try? stdinPipe.fileHandleForWriting.close()
        signalOwnedProcessTree(SIGKILL)
    }

    private func waitForTermination(timeout: TimeInterval?) async -> Int32? {
        let token = UUID()
        return await withCheckedContinuation { continuation in
            stateLock.lock()
            if let terminationStatus {
                stateLock.unlock()
                continuation.resume(returning: terminationStatus)
            } else {
                terminationWaiters[token] = continuation
                stateLock.unlock()
                if let timeout {
                    DispatchQueue.global(qos: .utility).asyncAfter(
                        deadline: .now() + timeout
                    ) { [weak self] in
                        self?.timeoutTerminationWaiter(token: token)
                    }
                }
            }
        }
    }

    private func recordTermination(status: Int32) {
        var waiters: [CheckedContinuation<Int32?, Never>] = []
        stateLock.lock()
        terminationStatus = status
        waiters = Array(terminationWaiters.values)
        terminationWaiters.removeAll()
        stateLock.unlock()
        waiters.forEach { $0.resume(returning: status) }
    }

    private func timeoutTerminationWaiter(token: UUID) {
        var waiter: CheckedContinuation<Int32?, Never>?
        stateLock.lock()
        waiter = terminationWaiters.removeValue(forKey: token)
        stateLock.unlock()
        waiter?.resume(returning: nil)
    }

    private func signalOwnedProcessTree(_ signal: Int32) {
        let rootIdentity: CodexOwnedProcessIdentity?
        let previouslyObservedDescendants:
            Set<CodexOwnedProcessIdentity>
        stateLock.lock()
        rootIdentity = launchedProcessIdentity
        previouslyObservedDescendants = ownedDescendantIdentities
        stateLock.unlock()

        guard let rootIdentity else { return }
        // Census from every retained live process as well as the direct
        // child. A TERM-handling descendant can remain alive after the root
        // exits or is reparented and can spawn another child before KILL
        // escalation; a root-only second census would no longer reach it.
        var censusRoots = previouslyObservedDescendants
        censusRoots.insert(rootIdentity)
        var observedDescendants =
            Set<CodexOwnedProcessIdentity>()
        for identity in censusRoots {
            observedDescendants.formUnion(
                Self.descendants(of: identity)
            )
        }
        stateLock.lock()
        ownedDescendantIdentities.formUnion(observedDescendants)
        let descendants = Array(ownedDescendantIdentities)
        let rootHasTerminated = terminationStatus != nil
        stateLock.unlock()

        // Descendants are signaled before the direct child so they cannot
        // escape enumeration by becoming reparented during teardown.
        for identity in descendants where Self.isLive(identity) {
            _ = kill(identity.identifier, signal)
        }
        if !rootHasTerminated, Self.isLive(rootIdentity) {
            _ = kill(rootIdentity.identifier, signal)
        }
    }

    private func waitForOwnedDescendantsExit(
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if pruneExitedDescendants() {
                return true
            }
            guard Date() < deadline else {
                return false
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func pruneExitedDescendants() -> Bool {
        stateLock.lock()
        ownedDescendantIdentities = ownedDescendantIdentities.filter(
            Self.isLive
        )
        let isEmpty = ownedDescendantIdentities.isEmpty
        stateLock.unlock()
        return isEmpty
    }

    private static func descendants(
        of root: CodexOwnedProcessIdentity
    ) -> [CodexOwnedProcessIdentity] {
        var visited = Set<CodexOwnedProcessIdentity>()
        return descendants(of: root, visited: &visited)
    }

    private static func descendants(
        of parent: CodexOwnedProcessIdentity,
        visited: inout Set<CodexOwnedProcessIdentity>
    ) -> [CodexOwnedProcessIdentity] {
        guard CodexOwnedProcessPolicy.isLiveMatch(
            parent,
            observation: processObservation(for: parent.identifier)
        ),
        visited.insert(parent).inserted else {
            return []
        }
        let directChildren = childProcessIdentifiers(
            of: parent.identifier
        )
        var result: [CodexOwnedProcessIdentity] = []
        for childIdentifier in directChildren
            where childIdentifier > 0
        {
            let observation = processObservation(
                for: childIdentifier
            )
            guard CodexOwnedProcessPolicy.isLiveDirectChild(
                observation,
                of: parent,
                parentObservation: processObservation(
                    for: parent.identifier
                )
            ),
            let child = observation?.identity else {
                continue
            }
            result.append(
                contentsOf: descendants(
                    of: child,
                    visited: &visited
                )
            )
            result.append(child)
        }
        return result
    }

    private static func isLive(
        _ identity: CodexOwnedProcessIdentity
    ) -> Bool {
        CodexOwnedProcessPolicy.isLiveMatch(
            identity,
            observation: processObservation(
                for: identity.identifier
            )
        )
    }

    private static func processObservation(
        for identifier: Int32
    ) -> CodexProcessObservation? {
        guard identifier > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let returnedSize = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(
                identifier,
                PROC_PIDTBSDINFO,
                0,
                $0,
                Int32(expectedSize)
            )
        }
        guard returnedSize == expectedSize,
              info.pbi_pid <= UInt32(Int32.max),
              info.pbi_ppid <= UInt32(Int32.max),
              Int32(info.pbi_pid) == identifier else {
            return nil
        }
        return CodexProcessObservation(
            identity: CodexOwnedProcessIdentity(
                identifier: identifier,
                startSeconds: info.pbi_start_tvsec,
                startMicroseconds: info.pbi_start_tvusec
            ),
            parentIdentifier: Int32(info.pbi_ppid),
            isZombie: info.pbi_status == UInt32(SZOMB)
        )
    }

    private static func childProcessIdentifiers(
        of parent: Int32
    ) -> [Int32] {
        let maximumCapacity = 4_096
        var capacity = 16
        while capacity <= maximumCapacity {
            var identifiers = [Int32](repeating: 0, count: capacity)
            let returnedCount = identifiers.withUnsafeMutableBytes { buffer in
                proc_listchildpids(
                    parent,
                    buffer.baseAddress,
                    Int32(buffer.count)
                )
            }
            guard returnedCount >= 0 else { return [] }
            let count = Int(returnedCount)
            if count < capacity {
                return Array(identifiers.prefix(count)).filter { $0 > 0 }
            }
            if capacity == maximumCapacity {
                // The census may be truncated, but signaling every known
                // direct child is safer than discarding the populated buffer.
                return identifiers.filter { $0 > 0 }
            }
            capacity *= 2
        }
        return []
    }

    deinit {
        try? stdinPipe.fileHandleForWriting.close()
        signalOwnedProcessTree(SIGKILL)
        let needsReapingBarrier: Bool
        stateLock.lock()
        needsReapingBarrier =
            launchedProcessIdentifier != nil && terminationStatus == nil
        stateLock.unlock()
        if needsReapingBarrier {
            // Keep the Foundation Process alive on a utility queue until its
            // internal waiter reaps the child. Deinitialization itself never
            // blocks on an untrusted process.
            let process = process
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
            }
        }
    }
}
