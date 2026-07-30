import Foundation

public struct CodexClientInfo: Codable, Equatable, Sendable {
    public var name: String
    public var title: String?
    public var version: String

    public init(name: String, title: String? = nil, version: String) throws {
        guard Self.isValid(name), Self.isValid(version),
              title.map(Self.isValid) ?? true
        else {
            throw CodexTransportError.invalidConfiguration(.clientInfo)
        }
        self.name = name
        self.title = title
        self.version = version
    }

    private static func isValid(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 128
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }
}

public struct CodexAppServerClient: Sendable {
    private let processConfiguration: CodexProcessConfiguration
    private let limits: CodexTransportLimits
    private let clientInfo: CodexClientInfo

    public init(
        processConfiguration: CodexProcessConfiguration,
        limits: CodexTransportLimits = try! CodexTransportLimits(),
        clientInfo: CodexClientInfo = try! CodexClientInfo(
            name: "claude_usage_tracker",
            title: "Claude Usage",
            version: "1"
        )
    ) {
        self.processConfiguration = processConfiguration
        self.limits = limits
        self.clientInfo = clientInfo
    }

    /// Executes one request in a fresh, initialized app-server process.
    public func request(
        _ method: CodexMethod,
        params: CodexJSONValue? = nil
    ) async throws -> CodexJSONValue {
        do {
            let session = try await openSession()
            let result = try await session.request(method, params: params)
            try await session.close()
            return result
        } catch is CancellationError {
            throw CodexTransportError.cancelled(method: method, id: nil)
        } catch {
            throw error
        }
    }

    /// Opens an initialized session for login flows that span notifications.
    ///
    /// Refresh callers should prefer `request(_:params:)` so their process is
    /// request-scoped.
    public func openSession() async throws -> CodexAppServerSession {
        try await CodexAppServerSession.open(
            processConfiguration: processConfiguration,
            limits: limits,
            clientInfo: clientInfo
        )
    }

    /// Executes a bounded operation in one initialized app-server process.
    ///
    /// The session's overall timeout starts before initialization and is shared
    /// by every request made by `operation`. Cleanup is awaited on every path.
    public func withSession<Value: Sendable>(
        _ operation: @escaping @Sendable (
            CodexAppServerSession
        ) async throws -> Value
    ) async throws -> Value {
        do {
            let session = try await openSession()
            do {
                let value = try await operation(session)
                try await session.close()
                return value
            } catch let operationError {
                do {
                    try await session.close()
                } catch {
                    // A failed close means the owned child was not proven
                    // reaped. Surface that cleanup failure rather than hiding
                    // it.
                    throw error
                }
                throw operationError
            }
        } catch is CancellationError {
            throw CodexTransportError.cancelled(method: nil, id: nil)
        }
    }
}

public actor CodexAppServerSession {
    private struct PendingRequest {
        let method: CodexMethod
        var waiterToken: UUID?
        var continuation:
            CheckedContinuation<CodexJSONValue, Error>?
        var result: Result<CodexJSONValue, Error>?
    }

    private struct NotificationWaiter {
        let method: CodexMethod?
        let continuation:
            CheckedContinuation<CodexNotificationFrame, Error>
    }

    private let process: BoundedProcess
    private let transport: JSONLTransport
    private let limits: CodexTransportLimits
    private let startedAtNanoseconds: UInt64
    private var nextRequestID: Int64 = 1
    private var notifications: [CodexNotificationFrame] = []
    private var pendingRequests: [Int64: PendingRequest] = [:]
    private var completedRequestIDs = Set<Int64>()
    private var notificationWaiters: [UUID: NotificationWaiter] = [:]
    private var notificationWaiterOrder: [UUID] = []
    private var readerTask: Task<Void, Never>?
    private var closeTask: Task<Void, Error>?
    private var terminalError: CodexTransportError?
    private var isClosed = false

    static func open(
        processConfiguration: CodexProcessConfiguration,
        limits: CodexTransportLimits,
        clientInfo: CodexClientInfo
    ) async throws -> CodexAppServerSession {
        try Task.checkCancellation()
        let process = BoundedProcess(
            configuration: processConfiguration,
            limits: limits
        )
        do {
            try process.start()
        } catch {
            try? await process.close()
            throw error
        }

        let session = CodexAppServerSession(process: process, limits: limits)
        await session.startReader()
        do {
            let initializeParams: CodexJSONValue = .object([
                "clientInfo": .object([
                    "name": .string(clientInfo.name),
                    "title": clientInfo.title.map(CodexJSONValue.string) ?? .null,
                    "version": .string(clientInfo.version)
                ])
            ])
            _ = try await session.performRequest(
                .initialize,
                params: initializeParams,
                stage: .startup,
                timeout: limits.startupTimeout
            )
            try await session.sendInitialized()
            return session
        } catch is CancellationError {
            try await session.close()
            throw CodexTransportError.cancelled(method: .initialize, id: 1)
        } catch let operationError {
            try await session.close()
            throw operationError
        }
    }

    private init(process: BoundedProcess, limits: CodexTransportLimits) {
        self.process = process
        self.limits = limits
        transport = JSONLTransport(
            process: process,
            maximumLineBytes: limits.maximumLineBytes
        )
        startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
    }

    public func request(
        _ method: CodexMethod,
        params: CodexJSONValue? = nil
    ) async throws -> CodexJSONValue {
        try ensureOpen(method: method)
        let id = nextRequestID
        do {
            return try await performRequest(
                method,
                params: params,
                stage: .request,
                timeout: limits.requestTimeout
            )
        } catch is CancellationError {
            try await close()
            throw CodexTransportError.cancelled(method: method, id: id)
        } catch let operationError {
            try await close()
            throw operationError
        }
    }

    public func nextNotification(
        matching method: CodexMethod? = nil
    ) async throws -> CodexNotificationFrame {
        try ensureOpen(method: method)
        if let index = notifications.firstIndex(where: {
            method == nil || $0.method == method
        }) {
            return notifications.remove(at: index)
        }

        let token = UUID()
        do {
            let plan = timeoutPlan(
                requested: limits.requestTimeout,
                stage: .notification
            )
            return try await withTimeout(
                seconds: plan.seconds,
                timeoutError: self.timeoutError(
                    stage: plan.stage,
                    method: method,
                    id: nil
                )
            ) {
                try await self.waitForNotification(
                    token: token,
                    method: method
                )
            }
        } catch is CancellationError {
            try await close()
            throw CodexTransportError.cancelled(method: method, id: nil)
        } catch let operationError {
            try await close()
            throw operationError
        }
    }

    public func close() async throws {
        if let closeTask {
            try await closeTask.value
            return
        }
        isClosed = true
        readerTask?.cancel()
        readerTask = nil
        let process = process
        let task = Task {
            try await process.close()
        }
        closeTask = task
        do {
            try await task.value
        } catch let error as CodexTransportError {
            terminalError = terminalError ?? error
            failAllWaiters(with: error)
            throw error
        } catch {
            let transportError = CodexTransportError.timedOut(
                stage: .termination,
                method: nil,
                id: nil
            )
            terminalError = terminalError ?? transportError
            failAllWaiters(with: transportError)
            throw transportError
        }
        failAllWaiters(
            with: terminalError
                ?? .cancelled(method: nil, id: nil)
        )
        notifications.removeAll()
    }

    private func startReader() {
        guard readerTask == nil else { return }
        let transport = transport
        readerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let frame = try await transport.receive()
                    guard let self else { return }
                    await self.route(frame)
                } catch is CancellationError {
                    return
                } catch let error as CodexTransportError {
                    guard let self else { return }
                    await self.readerFailed(error)
                    return
                } catch {
                    guard let self else { return }
                    await self.readerFailed(.unexpectedEOF)
                    return
                }
            }
        }
    }

    private func route(_ frame: CodexInboundFrame) async {
        guard !isClosed else { return }
        switch frame {
        case let .notification(notification):
            route(notification)
        case let .request(request):
            await readerFailed(
                .unsupportedServerRequest(method: request.method)
            )
        case let .response(response):
            guard let id = correlatedNumericID(response.id)
            else {
                await readerFailed(
                    protocolError(for: response.id)
                )
                return
            }
            if completedRequestIDs.contains(id) {
                await readerFailed(
                    .unexpectedResponse(idKind: response.id.kind)
                )
                return
            }
            guard var pending = pendingRequests[id] else {
                await readerFailed(
                    protocolError(for: response.id)
                )
                return
            }

            let result: Result<CodexJSONValue, Error>
            switch response.outcome {
            case let .result(value):
                result = .success(value)
            case let .error(error):
                result = .failure(
                    CodexTransportError.rpcFailure(
                        code: error.code,
                        method: pending.method,
                        id: id
                    )
                )
            }
            completedRequestIDs.insert(id)
            if let continuation = pending.continuation {
                pendingRequests.removeValue(forKey: id)
                continuation.resume(with: result)
            } else {
                pending.result = result
                pendingRequests[id] = pending
            }
        }
    }

    private func route(_ notification: CodexNotificationFrame) {
        if let token = notificationWaiterOrder.first(where: { token in
            guard let waiter = notificationWaiters[token] else {
                return false
            }
            return waiter.method == nil
                || waiter.method == notification.method
        }),
        let waiter = notificationWaiters.removeValue(forKey: token)
        {
            notificationWaiterOrder.removeAll { $0 == token }
            waiter.continuation.resume(returning: notification)
            return
        }
        notifications.append(notification)
    }

    private func readerFailed(_ error: CodexTransportError) async {
        guard terminalError == nil else { return }
        terminalError = error
        // Preserve the protocol/reader failure as the operation's result
        // before process teardown yields the actor. Otherwise a concurrent
        // timeout or cancellation can win during the termination grace
        // period and mask the already-observed terminal cause.
        failAllWaiters(with: error)
        try? await close()
    }

    private func failAllWaiters(with error: CodexTransportError) {
        let requestContinuations = pendingRequests.values.compactMap(
            \.continuation
        )
        let notificationContinuations = notificationWaiterOrder.compactMap {
            notificationWaiters[$0]?.continuation
        }
        pendingRequests.removeAll()
        notificationWaiters.removeAll()
        notificationWaiterOrder.removeAll()
        requestContinuations.forEach {
            $0.resume(throwing: error)
        }
        notificationContinuations.forEach {
            $0.resume(throwing: error)
        }
    }

    private func sendInitialized() async throws {
        let plan = timeoutPlan(
            requested: limits.startupTimeout,
            stage: .startup
        )
        try await withTimeout(
            seconds: plan.seconds,
            timeoutError: self.timeoutError(
                stage: plan.stage,
                method: .initialized,
                id: nil
            )
        ) {
            try await self.transport.send(
                CodexNotificationFrame(method: .initialized)
            )
        }
    }

    private func performRequest(
        _ method: CodexMethod,
        params: CodexJSONValue?,
        stage: CodexTimeoutStage,
        timeout: TimeInterval
    ) async throws -> CodexJSONValue {
        let id = try allocateRequestID()
        pendingRequests[id] = PendingRequest(
            method: method,
            waiterToken: nil,
            continuation: nil,
            result: nil
        )
        let plan = timeoutPlan(requested: timeout, stage: stage)
        do {
            return try await withTimeout(
                seconds: plan.seconds,
                timeoutError: self.timeoutError(
                    stage: plan.stage,
                    method: method,
                    id: id
                )
            ) {
                try await self.transport.send(
                    CodexRequestFrame(
                        id: .integer(id),
                        method: method,
                        params: params
                    )
                )
                return try await self.waitForResponse(
                    id: id,
                    method: method
                )
            }
        } catch {
            let outwardError: Error
            if Task.isCancelled {
                // A cancelled caller can induce EPIPE or process-exit reader
                // errors while aborting blocked stdin. Preserve cancellation
                // as the initiating cause instead of exposing teardown timing.
                outwardError = CodexTransportError.cancelled(
                    method: method,
                    id: id
                )
            } else if case .writeFailed = error as? CodexTransportError,
               let terminalError
            {
                // A reader-detected protocol failure may close stdin while a
                // reentrant request is entering its write. Preserve that
                // terminal cause instead of exposing timing-dependent EPIPE.
                outwardError = terminalError
            } else {
                outwardError = error
            }
            if var pending = pendingRequests.removeValue(forKey: id),
               let continuation = pending.continuation
            {
                pending.continuation = nil
                continuation.resume(throwing: outwardError)
            }
            throw outwardError
        }
    }

    private func waitForResponse(
        id: Int64,
        method: CodexMethod
    ) async throws -> CodexJSONValue {
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard var pending = pendingRequests[id] else {
                    continuation.resume(
                        throwing: terminalError
                            ?? CodexTransportError.unexpectedResponse(
                                idKind: .integer
                            )
                    )
                    return
                }
                if let result = pending.result {
                    pendingRequests.removeValue(forKey: id)
                    continuation.resume(with: result)
                    return
                }
                pending.waiterToken = token
                pending.continuation = continuation
                pendingRequests[id] = pending
            }
        } onCancel: {
            Task {
                await self.cancelResponseWaiter(
                    id: id,
                    token: token,
                    method: method
                )
            }
        }
    }

    private func cancelResponseWaiter(
        id: Int64,
        token: UUID,
        method: CodexMethod
    ) {
        guard var pending = pendingRequests[id],
              pending.waiterToken == token,
              let continuation = pending.continuation
        else {
            return
        }
        pending.waiterToken = nil
        pending.continuation = nil
        pendingRequests[id] = pending
        continuation.resume(
            throwing: CodexTransportError.cancelled(
                method: method,
                id: id
            )
        )
    }

    private func waitForNotification(
        token: UUID,
        method: CodexMethod?
    ) async throws -> CodexNotificationFrame {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let terminalError {
                    continuation.resume(throwing: terminalError)
                    return
                }
                if let index = notifications.firstIndex(where: {
                    method == nil || $0.method == method
                }) {
                    continuation.resume(
                        returning: notifications.remove(at: index)
                    )
                    return
                }
                notificationWaiters[token] = NotificationWaiter(
                    method: method,
                    continuation: continuation
                )
                notificationWaiterOrder.append(token)
            }
        } onCancel: {
            Task {
                await self.cancelNotificationWaiter(token: token)
            }
        }
    }

    private func cancelNotificationWaiter(token: UUID) {
        guard let waiter = notificationWaiters.removeValue(
            forKey: token
        ) else {
            return
        }
        notificationWaiterOrder.removeAll { $0 == token }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func allocateRequestID() throws -> Int64 {
        guard nextRequestID > 0, nextRequestID < Int64.max else {
            throw CodexTransportError.requestIDExhausted
        }
        let id = nextRequestID
        nextRequestID += 1
        return id
    }

    private func correlatedNumericID(
        _ id: CodexRequestID
    ) -> Int64? {
        switch id {
        case let .integer(value):
            return value > 0 ? value : nil
        case let .string(value):
            guard let numeric = Int64(value),
                  numeric > 0,
                  String(numeric) == value
            else {
                return nil
            }
            return numeric
        }
    }

    private func protocolError(
        for receivedID: CodexRequestID
    ) -> CodexTransportError {
        if pendingRequests.count == 1,
           let expected = pendingRequests.keys.first
        {
            return .requestIDMismatch(
                expected: expected,
                received: receivedID.kind
            )
        }
        return .unexpectedResponse(idKind: receivedID.kind)
    }

    private func ensureOpen(method: CodexMethod?) throws {
        if let terminalError {
            throw terminalError
        }
        guard !isClosed else {
            throw CodexTransportError.writeFailed(method: method)
        }
    }

    private func timeoutPlan(
        requested: TimeInterval,
        stage: CodexTimeoutStage
    ) -> (seconds: TimeInterval, stage: CodexTimeoutStage) {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsedNanoseconds = now >= startedAtNanoseconds
            ? now - startedAtNanoseconds
            : 0
        let elapsed = Double(elapsedNanoseconds) / 1_000_000_000
        let remaining = limits.overallTimeout - elapsed
        if remaining <= requested {
            return (max(0.000_001, remaining), .overall)
        }
        return (requested, stage)
    }

    private func timeoutError(
        stage: CodexTimeoutStage,
        method: CodexMethod?,
        id: Int64?
    ) -> CodexTransportError {
        .timedOut(stage: stage, method: method, id: id)
    }
}

private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    timeoutError: CodexTransportError,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            let nanoseconds = UInt64(
                min(seconds * 1_000_000_000, Double(UInt64.max))
            )
            try await Task.sleep(nanoseconds: nanoseconds)
            throw timeoutError
        }
        guard let result = try await group.next() else {
            throw timeoutError
        }
        group.cancelAll()
        return result
    }
}
