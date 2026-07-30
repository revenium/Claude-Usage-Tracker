import Foundation

/// A lossless-enough, provider-neutral JSON value for the app-server boundary.
///
/// Account and usage domain models deliberately live above this transport.
public enum CodexJSONValue: Codable, Equatable, Sendable {
    case object([String: CodexJSONValue])
    case array([CodexJSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "JSON numbers must be finite"
                )
            }
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CodexJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: CodexJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "JSON numbers must be finite"
                    )
                )
            }
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public enum CodexRequestIDKind: String, Codable, Equatable, Sendable {
    case integer
    case string
}

/// The app-server schema permits integer or string JSON-RPC request IDs.
public enum CodexRequestID: Codable, Equatable, Hashable, Sendable {
    case integer(Int64)
    case string(String)

    public var kind: CodexRequestIDKind {
        switch self {
        case .integer: .integer
        case .string: .string
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
            return
        }
        if let value = try? container.decode(String.self),
           Self.isValidString(value)
        {
            self = .string(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Request ID must be an integer or a valid nonempty string"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .integer(value):
            try container.encode(value)
        case let .string(value):
            guard Self.isValidString(value) else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "Request ID must be nonempty and contain no control characters"
                    )
                )
            }
            try container.encode(value)
        }
    }

    private static func isValidString(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 128
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }
}

/// A validated method identifier. Validation also makes method metadata safe to
/// include in diagnostics without ever including request bodies.
public struct CodexMethod: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue.count <= 128,
              rawValue.unicodeScalars.allSatisfy(Self.isAllowedMethodScalar)
        else {
            return nil
        }
        self.rawValue = rawValue
    }

    var diagnosticLabel: String {
        switch self {
        case .initialize, .initialized, .accountRead, .accountLoginStart,
             .accountLoginCompleted, .accountLoginCancel, .accountLogout,
             .accountUpdated, .accountRateLimitsRead, .accountRateLimitsUpdated,
             .accountUsageRead:
            rawValue
        default:
            "unknown-method"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid app-server method identifier"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func known(_ rawValue: String) -> CodexMethod {
        guard let method = CodexMethod(rawValue: rawValue) else {
            preconditionFailure("Invalid known Codex method")
        }
        return method
    }

    private static func isAllowedMethodScalar(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return (48...57).contains(value)
            || (65...90).contains(value)
            || (97...122).contains(value)
            || value == 45
            || value == 47
            || value == 95
    }

    public static let initialize = known("initialize")
    public static let initialized = known("initialized")
    public static let accountRead = known("account/read")
    public static let accountLoginStart = known("account/login/start")
    public static let accountLoginCompleted = known("account/login/completed")
    public static let accountLoginCancel = known("account/login/cancel")
    public static let accountLogout = known("account/logout")
    public static let accountUpdated = known("account/updated")
    public static let accountRateLimitsRead = known("account/rateLimits/read")
    public static let accountRateLimitsUpdated = known("account/rateLimits/updated")
    public static let accountUsageRead = known("account/usage/read")
}

public struct CodexRequestFrame: Codable, Equatable, Sendable {
    public var id: CodexRequestID
    public var method: CodexMethod
    public var params: CodexJSONValue?

    public init(
        id: CodexRequestID,
        method: CodexMethod,
        params: CodexJSONValue? = nil
    ) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct CodexNotificationFrame: Codable, Equatable, Sendable {
    public var method: CodexMethod
    public var params: CodexJSONValue?

    public init(method: CodexMethod, params: CodexJSONValue? = nil) {
        self.method = method
        self.params = params
    }
}

public struct CodexRPCFailure: Codable, Equatable, Sendable {
    public var code: Int64

    public init(code: Int64) {
        self.code = code
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int64.self, forKey: .code)
        _ = try container.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode("Redacted", forKey: .message)
    }
}

public enum CodexResponseOutcome: Equatable, Sendable {
    case result(CodexJSONValue)
    case error(CodexRPCFailure)
}

public struct CodexResponseFrame: Equatable, Sendable {
    public var id: CodexRequestID
    public var outcome: CodexResponseOutcome

    public init(id: CodexRequestID, outcome: CodexResponseOutcome) {
        self.id = id
        self.outcome = outcome
    }
}

extension CodexResponseFrame: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case result
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(CodexRequestID.self, forKey: .id)
        let hasResult = container.contains(.result)
        let hasError = container.contains(.error)
        guard hasResult != hasError else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Response must contain exactly one of result or error"
                )
            )
        }
        if hasResult {
            outcome = .result(try container.decode(CodexJSONValue.self, forKey: .result))
        } else {
            outcome = .error(try container.decode(CodexRPCFailure.self, forKey: .error))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        switch outcome {
        case let .result(value):
            try container.encode(value, forKey: .result)
        case let .error(error):
            try container.encode(error, forKey: .error)
        }
    }
}

public enum CodexInboundFrame: Equatable, Sendable {
    case request(CodexRequestFrame)
    case response(CodexResponseFrame)
    case notification(CodexNotificationFrame)
}

extension CodexInboundFrame: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id
        case method
        case params
        case result
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.method) {
            guard !container.contains(.result), !container.contains(.error) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Request and notification frames cannot contain response fields"
                    )
                )
            }
            let method = try container.decode(CodexMethod.self, forKey: .method)
            let params = try container.decodeIfPresent(CodexJSONValue.self, forKey: .params)
            if container.contains(.id) {
                self = .request(
                    CodexRequestFrame(
                        id: try container.decode(CodexRequestID.self, forKey: .id),
                        method: method,
                        params: params
                    )
                )
            } else {
                self = .notification(CodexNotificationFrame(method: method, params: params))
            }
            return
        }

        self = .response(try CodexResponseFrame(from: decoder))
    }
}
