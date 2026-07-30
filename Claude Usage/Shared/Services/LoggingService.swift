//
//  LoggingService.swift
//  Claude Usage
//
//  Created by Claude Code on 2025-12-20.
//

import Foundation
import os.log

/// Centralized logging service using os.log.
///
/// Every public entry point crosses the same fail-closed redaction boundary
/// before a value reaches either Unified Logging or a test observer.
final class LoggingService {
    typealias Observer = (String) -> Void

    static let shared = LoggingService()

    private let subsystem =
        Bundle.main.bundleIdentifier ?? "com.claudeusage"
    private let observer: Observer?

    private lazy var apiLogger =
        OSLog(subsystem: subsystem, category: "API")
    private lazy var storageLogger =
        OSLog(subsystem: subsystem, category: "Storage")
    private lazy var notificationLogger =
        OSLog(subsystem: subsystem, category: "Notifications")
    private lazy var uiLogger =
        OSLog(subsystem: subsystem, category: "UI")
    private lazy var generalLogger =
        OSLog(subsystem: subsystem, category: "General")

    init(observer: Observer? = nil) {
        self.observer = observer
    }

    // MARK: - API Logging

    func logAPIRequest(_ endpoint: String) {
        emit(
            "📤 API Request: \(endpoint)",
            log: apiLogger,
            type: .info
        )
    }

    func logAPIResponse(_ endpoint: String, statusCode: Int) {
        emit(
            "📥 API Response: \(endpoint) [\(statusCode)]",
            log: apiLogger,
            type: .info
        )
    }

    func logAPIError(_ endpoint: String, error: Error) {
        emit(
            "❌ API Error: \(endpoint) - "
                + SensitiveDataRedactor.redact(error: error),
            log: apiLogger,
            type: .error
        )
    }

    // MARK: - Storage Logging

    func logStorageSave(_ key: String) {
        emit(
            "💾 Storage Save: \(key)",
            log: storageLogger,
            type: .debug
        )
    }

    func logStorageLoad(_ key: String, success: Bool) {
        emit(
            "📂 Storage Load: \(key) "
                + (success ? "✓" : "✗ (not found)"),
            log: storageLogger,
            type: .debug
        )
    }

    func logStorageError(_ operation: String, error: Error) {
        emit(
            "❌ Storage Error [\(operation)]: "
                + SensitiveDataRedactor.redact(error: error),
            log: storageLogger,
            type: .error
        )
    }

    // MARK: - Notification Logging

    func logNotificationSent(_ type: String) {
        emit(
            "🔔 Notification Sent: \(type)",
            log: notificationLogger,
            type: .info
        )
    }

    func logNotificationError(_ error: Error) {
        emit(
            "❌ Notification Error: "
                + SensitiveDataRedactor.redact(error: error),
            log: notificationLogger,
            type: .error
        )
    }

    func logNotificationPermission(_ granted: Bool) {
        emit(
            "🔐 Notification Permission: "
                + (granted ? "Granted" : "Denied"),
            log: notificationLogger,
            type: .info
        )
    }

    // MARK: - UI Logging

    func logUIEvent(_ event: String) {
        emit(
            "🖱️ UI Event: \(event)",
            log: uiLogger,
            type: .debug
        )
    }

    func logWindowEvent(_ event: String) {
        emit(
            "🪟 Window Event: \(event)",
            log: uiLogger,
            type: .debug
        )
    }

    // MARK: - General Logging

    func log(_ message: String, type: OSLogType = .default) {
        emit(message, log: generalLogger, type: type)
    }

    func logError(_ message: String, error: Error? = nil) {
        let detail = error.map {
            ": " + SensitiveDataRedactor.redact(error: $0)
        } ?? ""
        emit(
            "❌ \(message)\(detail)",
            log: generalLogger,
            type: .error
        )
    }

    func logWarning(_ message: String) {
        emit(
            "⚠️ \(message)",
            log: generalLogger,
            type: .fault
        )
    }

    func logInfo(_ message: String) {
        emit(
            "ℹ️ \(message)",
            log: generalLogger,
            type: .info
        )
    }

    func logDebug(_ message: String) {
        emit(
            "🐛 \(message)",
            log: generalLogger,
            type: .debug
        )
    }

    private func emit(
        _ message: String,
        log: OSLog,
        type: OSLogType
    ) {
        let safeMessage = SensitiveDataRedactor.redact(message)
        observer?(safeMessage)
        os_log("%{public}@", log: log, type: type, safeMessage)
    }
}
