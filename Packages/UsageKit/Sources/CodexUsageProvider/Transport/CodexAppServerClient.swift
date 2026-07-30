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
}

public actor CodexAppServerSession {
    private let process: BoundedProcess
    private let transport: JSONLTransport
    private let limits: CodexTransportLimits
    private let startedAtNanoseconds: UInt64
    private var nextRequestID: Int64 = 1
    private var notifications: [CodexNotificationFrame] = []
    private var isClosed = false

    static func open(
        processConfiguration: CodexProcessConfiguration,
        limits: CodexTransportLimits,
        clientInfo: CodexClientInfo
    ) async throws -> CodexAppServerSession {
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
        do {
            return try await performRequest(
                method,
                params: params,
                stage: .request,
                timeout: limits.requestTimeout
            )
        } catch is CancellationError {
            let id = nextRequestID > 1 ? nextRequestID - 1 : nil
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
                while true {
                    switch try await self.transport.receive() {
                    case let .notification(notification):
                        if method == nil || notification.method == method {
                            return notification
                        }
                        await self.store(notification: notification)
                    case let .request(request):
                        throw CodexTransportError.unsupportedServerRequest(
                            method: request.method
                        )
                    case let .response(response):
                        throw CodexTransportError.unexpectedResponse(
                            idKind: response.id.kind
                        )
                    }
                }
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
        guard !isClosed else { return }
        isClosed = true
        try await process.close()
        notifications.removeAll()
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
        let plan = timeoutPlan(requested: timeout, stage: stage)
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
            while true {
                switch try await self.transport.receive() {
                case let .notification(notification):
                    await self.store(notification: notification)
                case let .request(request):
                    throw CodexTransportError.unsupportedServerRequest(
                        method: request.method
                    )
                case let .response(response):
                    guard response.id == .integer(id) else {
                        throw CodexTransportError.requestIDMismatch(
                            expected: id,
                            received: response.id.kind
                        )
                    }
                    switch response.outcome {
                    case let .result(result):
                        return result
                    case let .error(error):
                        throw CodexTransportError.rpcFailure(
                            code: error.code,
                            method: method,
                            id: id
                        )
                    }
                }
            }
        }
    }

    private func allocateRequestID() throws -> Int64 {
        guard nextRequestID > 0, nextRequestID < Int64.max else {
            throw CodexTransportError.requestIDExhausted
        }
        let id = nextRequestID
        nextRequestID += 1
        return id
    }

    private func store(notification: CodexNotificationFrame) {
        notifications.append(notification)
    }

    private func ensureOpen(method: CodexMethod?) throws {
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
