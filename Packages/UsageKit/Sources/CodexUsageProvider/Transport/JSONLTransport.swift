import Foundation

struct JSONLTransport: Sendable {
    private let process: BoundedProcess
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maximumLineBytes: Int

    init(process: BoundedProcess, maximumLineBytes: Int) {
        self.process = process
        self.maximumLineBytes = maximumLineBytes
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    func send(_ request: CodexRequestFrame) async throws {
        try await sendEncodable(request, method: request.method)
    }

    func send(_ notification: CodexNotificationFrame) async throws {
        try await sendEncodable(notification, method: notification.method)
    }

    func receive() async throws -> CodexInboundFrame {
        let line: Data
        do {
            line = try await process.nextLine()
        } catch let error as BoundedProcessOutputError {
            switch error {
            case let .outputLimit(stream):
                throw CodexTransportError.outputLimitExceeded(stream)
            case .lineLimit:
                throw CodexTransportError.lineLimitExceeded
            case let .exited(status):
                throw CodexTransportError.processExited(status: status)
            case .eof:
                throw CodexTransportError.unexpectedEOF
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexTransportError.unexpectedEOF
        }

        do {
            return try decoder.decode(CodexInboundFrame.self, from: line)
        } catch {
            throw CodexTransportError.malformedFrame
        }
    }

    private func sendEncodable<T: Encodable & Sendable>(
        _ frame: T,
        method: CodexMethod
    ) async throws {
        let encoded: Data
        do {
            encoded = try encoder.encode(frame)
        } catch {
            throw CodexTransportError.writeFailed(method: method)
        }
        guard encoded.count <= maximumLineBytes else {
            throw CodexTransportError.lineLimitExceeded
        }
        var line = encoded
        line.append(0x0A)
        try await process.send(line, method: method)
    }
}
