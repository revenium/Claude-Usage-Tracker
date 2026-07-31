//
//  NetworkLoggerService.swift
//  Claude Usage
//
//  Created by Claude on 2026-01-29.
//

import Foundation
import Combine

enum NetworkLogStorageFailure: Equatable {
    case unsafeLegacyCaptureRetained
}

struct NetworkLogStorageOperations {
    let fileExists: (URL) -> Bool
    let read: (URL) throws -> Data
    let writeAtomically: (Data, URL) throws -> Void
    let remove: (URL) throws -> Void

    static let live = NetworkLogStorageOperations(
        fileExists: {
            FileManager.default.fileExists(atPath: $0.path)
        },
        read: {
            try Data(contentsOf: $0)
        },
        writeAtomically: {
            try $0.write(to: $1, options: .atomic)
        },
        remove: {
            try FileManager.default.removeItem(at: $0)
        }
    )
}

final class NetworkLoggerService: ObservableObject {
    static let shared = NetworkLoggerService()

    @Published private(set) var session: NetworkLoggingSession
    @Published private(set) var storageFailure:
        NetworkLogStorageFailure?

    private var timer: Timer?
    private let maxLogs = 500
    private let maxFileSizeBytes = 10 * 1024 * 1024  // 10MB
    private let requestBodyMaxLength = 2000
    private let responsePreviewMaxLength = 1000
    private let storageURLOverride: URL?
    private let loggingService: LoggingService
    private let storageOperations: NetworkLogStorageOperations

    private var storageURL: URL {
        if let storageURLOverride {
            return storageURLOverride
        }
        return Self.defaultStorageURL()
    }

    private static func defaultStorageURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let appDirectory = appSupport.appendingPathComponent("Claude Usage")

        // Create directory if needed
        try? FileManager.default.createDirectory(
            at: appDirectory,
            withIntermediateDirectories: true
        )

        return appDirectory.appendingPathComponent("network_logs.json")
    }

    init(
        session: NetworkLoggingSession? = nil,
        storageURL: URL? = nil,
        loggingService: LoggingService = .shared,
        storageOperations: NetworkLogStorageOperations = .live
    ) {
        storageURLOverride = storageURL
        self.loggingService = loggingService
        self.storageOperations = storageOperations
        if let session {
            self.session = session
            storageFailure = nil
        } else {
            switch Self.loadSession(
                from: storageURL ?? Self.defaultStorageURL(),
                loggingService: loggingService,
                storageOperations: storageOperations
            ) {
            case .loaded(let loaded):
                self.session = loaded
                storageFailure = nil
            case .absent:
                self.session = NetworkLoggingSession()
                storageFailure = nil
            case .failed(let failure):
                // Never expose a decoded in-memory copy when the unsafe
                // source could not be replaced or verifiably removed.
                self.session = NetworkLoggingSession()
                storageFailure = failure
            }
        }

        // Resume timer if session was active
        if self.session.isActive,
           let endTime = self.session.endTime,
           endTime > Date() {
            scheduleAutoStop(until: endTime)
        } else if self.session.isActive {
            // Session expired while app was closed
            stopLogging()
        }
    }

    // MARK: - Public API

    func startLogging(duration: TimeInterval) {
        guard storageFailure == nil else {
            loggingService.logStorageError(
                "startNetworkLogging",
                error: NetworkLogStorageError.cleanupRequired
            )
            return
        }

        let now = Date()
        session.isActive = true
        session.startTime = now
        session.endTime = now.addingTimeInterval(duration)
        session.duration = duration

        scheduleAutoStop(until: session.endTime!)
        saveSession()

        loggingService.logDebug(
            "Network logging started for \(duration)s"
        )
    }

    func stopLogging() {
        session.isActive = false
        timer?.invalidate()
        timer = nil
        saveSession()

        loggingService.logDebug("Network logging stopped")
    }

    func clearLogs() {
        guard storageFailure == nil else {
            loggingService.logStorageError(
                "clearNetworkLogs",
                error: NetworkLogStorageError.cleanupRequired
            )
            return
        }

        session.logs.removeAll()
        saveSession()

        loggingService.logDebug("Network logs cleared")
    }

    @discardableResult
    func retryUnsafeLegacyCaptureCleanup() -> Bool {
        guard storageFailure == .unsafeLegacyCaptureRetained else {
            return true
        }

        let cleanSession = NetworkLoggingSession()
        let cleanData: Data
        do {
            cleanData = try JSONEncoder().encode(cleanSession)
        } catch {
            loggingService.logStorageError(
                "retryLegacyNetworkLogCleanup",
                error: NetworkLogStorageError.safeReplacementEncodingFailed
            )
            return false
        }

        if !storageOperations.fileExists(storageURL) {
            completeUnsafeLegacyCaptureCleanup(
                with: cleanSession
            )
            return true
        }

        do {
            // Prefer an atomic replacement so a file that cannot be removed
            // may still be made safe. Verify the exact safe payload before
            // clearing the blocking failure state.
            try storageOperations.writeAtomically(
                cleanData,
                storageURL
            )
            let persistedData = try storageOperations.read(
                storageURL
            )
            guard persistedData == cleanData else {
                throw NetworkLogStorageError.replacementNotVerified
            }

            completeUnsafeLegacyCaptureCleanup(
                with: cleanSession
            )
            return true
        } catch {
            // If replacement cannot be verified, fall back to removal. Never
            // decode or publish the retained file's contents.
            do {
                if storageOperations.fileExists(storageURL) {
                    try storageOperations.remove(storageURL)
                }
                guard !storageOperations.fileExists(storageURL) else {
                    throw NetworkLogStorageError.removalNotVerified
                }

                completeUnsafeLegacyCaptureCleanup(
                    with: cleanSession
                )
                return true
            } catch {
                storageFailure = .unsafeLegacyCaptureRetained
                loggingService.logStorageError(
                    "retryLegacyNetworkLogCleanup",
                    error: NetworkLogStorageError.removalNotVerified
                )
                return false
            }
        }
    }

    func logRequest(url: String, method: String, requestBody: Data?,
                    responseData: Data?, statusCode: Int?,
                    duration: TimeInterval?, error: Error?) {
        guard storageFailure == nil, session.isActive else {
            return
        }

        // Check if session has expired
        if let endTime = session.endTime, Date() > endTime {
            stopLogging()
            return
        }

        let requestBodyString =
            SensitiveDataRedactor.redact(data: requestBody).map {
                $0
                .prefix(requestBodyMaxLength)
                .description
            }

        let responsePreview =
            SensitiveDataRedactor.redact(data: responseData).map {
                $0
                .prefix(responsePreviewMaxLength)
                .description
            }

        let log = NetworkRequestLog(
            timestamp: Date(),
            url: url,
            method: method,
            statusCode: statusCode,
            duration: duration,
            requestBody: requestBodyString,
            responsePreview: responsePreview,
            fullResponseSize: responseData?.count,
            errorMessage: error.map {
                SensitiveDataRedactor.redact(error: $0)
            }
        )

        session.logs.append(log)

        // Enforce max logs limit (FIFO)
        if session.logs.count > maxLogs {
            session.logs.removeFirst(session.logs.count - maxLogs)
        }

        saveSession()
    }

    var remainingTime: TimeInterval? {
        guard session.isActive, let endTime = session.endTime else { return nil }
        let remaining = endTime.timeIntervalSinceNow
        return remaining > 0 ? remaining : 0
    }

    // MARK: - Private Helpers

    private func completeUnsafeLegacyCaptureCleanup(
        with cleanSession: NetworkLoggingSession
    ) {
        timer?.invalidate()
        timer = nil
        session = cleanSession
        storageFailure = nil
        loggingService.logDebug(
            "Unsafe legacy network diagnostics were securely cleared"
        )
    }

    private func scheduleAutoStop(until endTime: Date) {
        timer?.invalidate()
        timer = Timer(fire: endTime, interval: 0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.stopLogging()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func saveSession() {
        guard storageFailure == nil else {
            loggingService.logStorageError(
                "saveNetworkLogs",
                error: NetworkLogStorageError.cleanupRequired
            )
            return
        }

        do {
            let data = try JSONEncoder().encode(session)

            // Check file size limit
            if data.count > maxFileSizeBytes {
                loggingService.logWarning(
                    "Network logs exceed max size, truncating..."
                )
                // Remove oldest logs until under limit
                while session.logs.count > 0 {
                    session.logs.removeFirst()
                    let newData = try JSONEncoder().encode(session)
                    if newData.count <= maxFileSizeBytes {
                        try storageOperations.writeAtomically(
                            newData,
                            storageURL
                        )
                        storageFailure = nil
                        return
                    }
                }
            } else {
                try storageOperations.writeAtomically(
                    data,
                    storageURL
                )
                storageFailure = nil
            }
        } catch {
            loggingService.logStorageError(
                "saveNetworkLogs",
                error: error
            )
        }
    }

    private static func loadSession(
        from url: URL,
        loggingService: LoggingService,
        storageOperations: NetworkLogStorageOperations
    ) -> NetworkLogLoadResult {
        guard storageOperations.fileExists(url) else {
            return .absent
        }
        do {
            let data = try storageOperations.read(url)
            let session = try JSONDecoder().decode(
                NetworkLoggingSession.self,
                from: data
            )
            do {
                // Decoding passes every legacy record through
                // NetworkRequestLog's sanitizing initializer. Persist the
                // sanitized representation immediately so a later process
                // can never rediscover raw legacy credentials.
                let sanitized = try JSONEncoder().encode(session)
                try storageOperations.writeAtomically(
                    sanitized,
                    url
                )
            } catch {
                return discardLegacyCapture(
                    url,
                    operation: "sanitizeLegacyNetworkLogs",
                    reason: .rewriteFailed,
                    loggingService: loggingService,
                    storageOperations: storageOperations
                )
            }
            return .loaded(session)
        } catch {
            return discardLegacyCapture(
                url,
                operation: "loadNetworkLogs",
                reason: .legacyDataRejected,
                loggingService: loggingService,
                storageOperations: storageOperations
            )
        }
    }

    private static func discardLegacyCapture(
        _ url: URL,
        operation: String,
        reason: NetworkLogStorageError,
        loggingService: LoggingService,
        storageOperations: NetworkLogStorageOperations
    ) -> NetworkLogLoadResult {
        do {
            if storageOperations.fileExists(url) {
                try storageOperations.remove(url)
            }
            guard !storageOperations.fileExists(url) else {
                throw NetworkLogStorageError.removalNotVerified
            }
            loggingService.logStorageError(
                operation,
                error: reason
            )
            return .absent
        } catch {
            // The source may still contain raw pre-redaction bytes. Report a
            // safe typed failure and never claim it was discarded.
            loggingService.logStorageError(
                operation,
                error: NetworkLogStorageError.removalNotVerified
            )
            return .failed(.unsafeLegacyCaptureRetained)
        }
    }
}

private enum NetworkLogLoadResult {
    case absent
    case loaded(NetworkLoggingSession)
    case failed(NetworkLogStorageFailure)
}

private enum NetworkLogStorageError: LocalizedError {
    case cleanupRequired
    case legacyDataRejected
    case replacementNotVerified
    case safeReplacementEncodingFailed
    case rewriteFailed
    case removalNotVerified

    var errorDescription: String? {
        switch self {
        case .cleanupRequired:
            "Unsafe legacy network diagnostics must be cleared "
                + "before logging can continue."
        case .legacyDataRejected:
            "Legacy network diagnostics were rejected and discarded."
        case .replacementNotVerified:
            "The safe network diagnostics replacement could not "
                + "be verified."
        case .safeReplacementEncodingFailed:
            "The safe network diagnostics replacement could not "
                + "be prepared."
        case .rewriteFailed:
            "Sanitized network diagnostics could not be committed; "
                + "the raw capture was discarded."
        case .removalNotVerified:
            "Unsafe legacy network diagnostics could not be removed."
        }
    }
}
