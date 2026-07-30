//
//  NetworkRequestLog.swift
//  Claude Usage
//
//  Created by Claude on 2026-01-29.
//

import Foundation

struct NetworkRequestLog: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let url: String
    let method: String
    let statusCode: Int?
    let duration: TimeInterval?
    let requestBody: String?
    let responsePreview: String?
    let fullResponseSize: Int?
    let errorMessage: String?

    init(id: UUID = UUID(), timestamp: Date, url: String, method: String,
         statusCode: Int? = nil, duration: TimeInterval? = nil,
         requestBody: String? = nil, responsePreview: String? = nil,
         fullResponseSize: Int? = nil, errorMessage: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.url = SensitiveDataRedactor.redact(url: url)
        self.method = SensitiveDataRedactor.redact(method)
        self.statusCode = statusCode
        self.duration = duration
        self.requestBody =
            requestBody.map { SensitiveDataRedactor.redact($0) }
        self.responsePreview =
            responsePreview.map {
                SensitiveDataRedactor.redact($0)
            }
        self.fullResponseSize = fullResponseSize
        self.errorMessage =
            errorMessage.map { SensitiveDataRedactor.redact($0) }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case url
        case method
        case statusCode
        case duration
        case requestBody
        case responsePreview
        case fullResponseSize
        case errorMessage
    }

    /// Legacy persisted logs are untrusted input. Decode through the same
    /// initializer as new records so old query values and bodies cannot reach
    /// the debug UI or a later export.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            timestamp: try container.decode(
                Date.self,
                forKey: .timestamp
            ),
            url: try container.decode(String.self, forKey: .url),
            method: try container.decode(String.self, forKey: .method),
            statusCode: try container.decodeIfPresent(
                Int.self,
                forKey: .statusCode
            ),
            duration: try container.decodeIfPresent(
                TimeInterval.self,
                forKey: .duration
            ),
            requestBody: try container.decodeIfPresent(
                String.self,
                forKey: .requestBody
            ),
            responsePreview: try container.decodeIfPresent(
                String.self,
                forKey: .responsePreview
            ),
            fullResponseSize: try container.decodeIfPresent(
                Int.self,
                forKey: .fullResponseSize
            ),
            errorMessage: try container.decodeIfPresent(
                String.self,
                forKey: .errorMessage
            )
        )
    }
}

struct NetworkLoggingSession: Codable {
    var isActive: Bool
    var startTime: Date?
    var endTime: Date?
    var duration: TimeInterval
    var logs: [NetworkRequestLog]

    init(isActive: Bool = false, startTime: Date? = nil,
         endTime: Date? = nil, duration: TimeInterval = 900,
         logs: [NetworkRequestLog] = []) {
        self.isActive = isActive
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
        self.logs = logs
    }
}

enum LoggingDuration: TimeInterval, CaseIterable, Identifiable {
    case fifteenMinutes = 900      // 15 * 60
    case thirtyMinutes = 1800      // 30 * 60
    case oneHour = 3600            // 60 * 60
    case threeHours = 10800        // 3 * 60 * 60
    case twelveHours = 43200       // 12 * 60 * 60

    var id: TimeInterval { rawValue }

    var displayName: String {
        switch self {
        case .fifteenMinutes: return "15 minutes"
        case .thirtyMinutes: return "30 minutes"
        case .oneHour: return "1 hour"
        case .threeHours: return "3 hours"
        case .twelveHours: return "12 hours"
        }
    }
}
