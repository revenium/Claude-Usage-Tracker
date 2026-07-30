import Foundation

public struct CodexProcessConfiguration: Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let codexHomeURL: URL
    let workingDirectoryURL: URL

    public init(
        executableURL: URL,
        arguments: [String] = ["app-server"],
        environment: [String: String] = [:],
        codexHomeURL: URL,
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
              isDirectory.boolValue
        else {
            throw CodexTransportError.invalidConfiguration(.codexHome)
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

final class BoundedProcess: @unchecked Sendable {
    private let configuration: CodexProcessConfiguration
    private let limits: CodexTransportLimits
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lineBuffer: BoundedLineBuffer
    private let stateLock = NSLock()
    private var started = false
    private var closed = false
    private var terminationWaiters: [
        UUID: CheckedContinuation<Int32?, Never>
    ] = [:]
    private var terminationStatus: Int32?
    private var launchedProcessIdentifier: Int32?
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
            try process.run()
            let identifier = process.processIdentifier
            guard identifier > 0 else {
                process.terminate()
                process.waitUntilExit()
                throw CodexTransportError.launchFailed
            }
            stateLock.lock()
            launchedProcessIdentifier = identifier
            stateLock.unlock()
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

    func send(_ data: Data, method: CodexMethod?) async throws {
        guard isWritable() else {
            throw CodexTransportError.writeFailed(method: method)
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
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
        if wasStarted, process.isRunning {
            process.terminate()
        }
        if wasStarted {
            let status = await waitForTermination(
                timeout: limits.terminationGracePeriod
            )
            if status == nil {
                forceKillOwnedProcess()
                guard await waitForTermination(
                    timeout: max(limits.terminationGracePeriod, 1)
                ) != nil else {
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
        forceKillOwnedProcess()
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

    private func forceKillOwnedProcess() {
        let identifier: Int32?
        let hasTerminated: Bool
        stateLock.lock()
        identifier = launchedProcessIdentifier
        hasTerminated = terminationStatus != nil
        stateLock.unlock()

        guard !hasTerminated,
              process.isRunning,
              let identifier,
              identifier > 0
        else {
            return
        }
        _ = kill(identifier, SIGKILL)
    }

    deinit {
        try? stdinPipe.fileHandleForWriting.close()
        forceKillOwnedProcess()
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
