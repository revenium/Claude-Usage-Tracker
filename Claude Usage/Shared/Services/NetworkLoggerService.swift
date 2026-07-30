//
//  NetworkLoggerService.swift
//  Claude Usage
//
//  Created by Claude on 2026-01-29.
//

import Foundation
import Combine

final class NetworkLoggerService: ObservableObject {
    static let shared = NetworkLoggerService()

    @Published private(set) var session: NetworkLoggingSession

    private var timer: Timer?
    private let maxLogs = 500
    private let maxFileSizeBytes = 10 * 1024 * 1024  // 10MB
    private let requestBodyMaxLength = 2000
    private let responsePreviewMaxLength = 1000
    private let storageURLOverride: URL?
    private let loggingService: LoggingService

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
        loggingService: LoggingService = .shared
    ) {
        storageURLOverride = storageURL
        self.loggingService = loggingService
        self.session =
            session
            ?? Self.loadSession(
                from: storageURL ?? Self.defaultStorageURL(),
                loggingService: loggingService
            )
            ?? NetworkLoggingSession()

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
        session.logs.removeAll()
        saveSession()

        loggingService.logDebug("Network logs cleared")
    }

    func logRequest(url: String, method: String, requestBody: Data?,
                    responseData: Data?, statusCode: Int?,
                    duration: TimeInterval?, error: Error?) {
        guard session.isActive else { return }

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
                        try newData.write(
                            to: storageURL,
                            options: .atomic
                        )
                        return
                    }
                }
            } else {
                try data.write(to: storageURL, options: .atomic)
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
        loggingService: LoggingService
    ) -> NetworkLoggingSession? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
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
                try sanitized.write(to: url, options: .atomic)
            } catch {
                discardLegacyCapture(url)
                loggingService.logStorageError(
                    "sanitizeLegacyNetworkLogs",
                    error: NetworkLogStorageError.rewriteFailed
                )
            }
            return session
        } catch {
            discardLegacyCapture(url)
            loggingService.logStorageError(
                "loadNetworkLogs",
                error: NetworkLogStorageError.legacyDataRejected
            )
            return nil
        }
    }

    private static func discardLegacyCapture(_ url: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        // Network diagnostics are disposable app-owned data. If legacy
        // bytes cannot be sanitized and atomically replaced, retaining them
        // under a different filename would merely preserve the secret.
        try? fileManager.removeItem(at: url)
    }
}

private enum NetworkLogStorageError: LocalizedError {
    case legacyDataRejected
    case rewriteFailed

    var errorDescription: String? {
        switch self {
        case .legacyDataRejected:
            "Legacy network diagnostics were rejected and discarded."
        case .rewriteFailed:
            "Sanitized network diagnostics could not be committed; the raw capture was discarded."
        }
    }
}
