import Foundation

/// Fail-closed sanitization for every string that can leave the process through
/// logs, copied diagnostics, or user-facing technical details.
///
/// The redactor deliberately does not attempt to preserve raw protocol
/// payloads. A JSON-RPC-shaped value is replaced wholesale so future protocol
/// fields cannot accidentally become a new credential leak.
nonisolated enum SensitiveDataRedactor {
    static let redactedValue = "<redacted>"
    static let redactedPath = "<redacted-path>"
    static let redactedQuery = "<redacted-query>"
    static let redactedRPC = "<redacted-rpc-payload>"

    private static let maximumOutputLength = 8_192

    static func redact(_ value: String) -> String {
        guard !value.isEmpty else { return value }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if isRPCText(trimmed) {
            return redactedRPC
        }

        if let structured = redactJSONObject(trimmed) {
            return limited(structured)
        }

        return limited(redactPlainText(value))
    }

    private static func redactPlainText(_ value: String) -> String {
        if isRPCText(value) {
            return redactedRPC
        }
        var result = value
        result = replacingEmbeddedURLs(in: result)
        result = replacing(
            #"(?im)\b([A-Z][A-Z0-9_]*(?:HOME|PATH|DIR|DIRECTORY)[A-Z0-9_]*)\s*=\s*["']?[^\r\n"']+"#,
            in: result,
            with: "$1=\(redactedPath)"
        )
        result = replacing(
            #"(?im)\b([A-Z][A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSCODE|CREDENTIAL|AUTH|COOKIE|SESSION|API_KEY|APIKEY|ACCESS_KEY|ACCESSKEY|PRIVATE_KEY|PRIVATEKEY|SIGNING_KEY|SIGNINGKEY)[A-Z0-9_]*)\s*=\s*["']?[^\r\n"']+"#,
            in: result,
            with: "$1=\(redactedValue)"
        )
        result = replacing(
            #"(?im)\b(authorization|proxy-authorization|cookie|set-cookie|x-api-key|x-auth-token)\s*[:=]\s*[^\r\n]+"#,
            in: result,
            with: "$1: \(redactedValue)"
        )
        result = replacing(
            #"(?i)\b(bearer)\s+[A-Za-z0-9._~+/\-=]+"#,
            in: result,
            with: "$1 \(redactedValue)"
        )
        result = replacing(
            #"(?i)\b(session[_-]?key|session[_-]?token|access[_-]?token|refresh[_-]?token|api[_-]?key|client[_-]?secret|password|credential)["']?\s*[:=]\s*["']?[^"'\s,;}\]]+"#,
            in: result,
            with: "$1=\(redactedValue)"
        )
        result = replacing(
            #"(?i)\b(?:sk-ant|sk-proj|sk|sess|session)[-_][A-Za-z0-9._~+/\-=]{6,}"#,
            in: result,
            with: redactedValue
        )
        result = replacing(
            #"(?i)\b(CODEX_HOME|HOME|workingDirectory|homePath)\s*=\s*["']?[^\s"',;]+"#,
            in: result,
            with: "$1=\(redactedPath)"
        )
        result = replacingQueryComponents(in: result)
        result = replacing(
            #"(?:file://)?/[^\s"'?,;)\]}]*auth\.json\b"#,
            in: result,
            with: redactedPath
        )
        result = replacing(
            localPathPattern,
            in: result,
            with: redactedPath
        )
        return result
    }

    static func redact(url value: String) -> String {
        guard var components = URLComponents(string: value),
              components.scheme != nil else {
            return redact(value)
        }
        components.user = nil
        components.password = nil
        if components.query != nil {
            components.percentEncodedQuery =
                SensitiveDataRedactor.redactedQuery
                    .addingPercentEncoding(
                        withAllowedCharacters: .urlQueryAllowed
                    )
        }
        components.fragment = nil
        let sanitized = replacing(
            localPathPattern,
            in: components.string ?? value,
            with: redactedPath
        )
        return limited(sanitized)
    }

    static func redact(data: Data?) -> String? {
        guard let data,
              let value = String(data: data, encoding: .utf8) else {
            return data == nil ? nil : "<non-text-data:\(data?.count ?? 0)-bytes>"
        }
        return redact(value)
    }

    static func redact(error: Error) -> String {
        let typeName = String(reflecting: type(of: error))
        let detail = redact(error.localizedDescription)
        return detail.isEmpty ? typeName : "\(typeName): \(detail)"
    }

    static func containsSensitiveMaterial(
        _ value: String,
        fixtures: [String]
    ) -> Bool {
        fixtures.contains { !$0.isEmpty && value.contains($0) }
    }

    private static func redactJSONObject(_ value: String) -> String? {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object) else {
            return nil
        }
        if isRPCObject(object) {
            return redactedRPC
        }
        let sanitized = sanitizeJSONValue(object, key: nil)
        guard let sanitizedData = try? JSONSerialization.data(
            withJSONObject: sanitized,
            options: [.sortedKeys]
        ) else {
            return redactedValue
        }
        return String(data: sanitizedData, encoding: .utf8)
            ?? redactedValue
    }

    private static func sanitizeJSONValue(
        _ value: Any,
        key: String?
    ) -> Any {
        if let key, isSensitiveJSONKey(key) {
            return isPathJSONKey(key) ? redactedPath : redactedValue
        }
        if let dictionary = value as? [String: Any] {
            if isRPCObject(dictionary) {
                return redactedRPC
            }
            var sanitized: [String: Any] = [:]
            for (childKey, child) in dictionary {
                sanitized[childKey] = sanitizeJSONValue(
                    child,
                    key: childKey
                )
            }
            return sanitized
        }
        if let dictionary = value as? NSDictionary {
            var sanitized: [String: Any] = [:]
            for case let (key as String, child) in dictionary {
                sanitized[key] = sanitizeJSONValue(child, key: key)
            }
            return sanitized
        }
        if let array = value as? [Any] {
            return array.map { sanitizeJSONValue($0, key: nil) }
        }
        if let string = value as? String {
            return redactPlainText(string)
        }
        return value
    }

    private static func isRPCObject(_ value: Any) -> Bool {
        guard let dictionary = value as? [String: Any] else {
            return false
        }
        let keys = Set(dictionary.keys.map { $0.lowercased() })
        return keys.contains("jsonrpc")
            || keys.contains("method")
            || (
                keys.contains("id")
                    && (
                        keys.contains("result")
                            || keys.contains("error")
                            || keys.contains("params")
                    )
            )
    }

    private static func isRPCText(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        guard lowercased.contains("\"jsonrpc\"")
                || lowercased.contains("\"method\"")
                || lowercased.contains("\"params\"")
                || lowercased.contains("\"result\"") else {
            return false
        }
        return lowercased.contains("\"id\"")
            || lowercased.contains("\"method\"")
            || lowercased.contains("\"jsonrpc\"")
    }

    private static func isSensitiveJSONKey(_ key: String) -> Bool {
        let normalized = key
            .lowercased()
            .filter(\.isLetter)
        return [
            "authorization",
            "cookie",
            "setcookie",
            "token",
            "secret",
            "password",
            "credential",
            "sessionkey",
            "sessiontoken",
            "apikey",
            "accesskey",
            "refreshtoken",
            "accesstoken",
            "clientsecret",
            "codexhome",
            "home",
            "homepath",
            "workingdirectory",
            "directory",
            "path"
        ].contains { normalized.contains($0) }
    }

    private static func isPathJSONKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter(\.isLetter)
        return normalized.contains("path")
            || normalized.contains("home")
            || normalized.contains("directory")
    }

    /// URLComponents handles complete URLs. This catches query-shaped
    /// fragments attached to local paths or embedded in prose, where no URL
    /// scheme is present and therefore URLComponents cannot safely identify
    /// the boundary.
    private static func replacingQueryComponents(
        in value: String
    ) -> String {
        replacing(
            #"\?[A-Za-z0-9._~!$&'()*+,;=:@%/?-]+"#,
            in: value,
            with: "?\(redactedQuery)"
        )
    }

    private static func replacingEmbeddedURLs(in value: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"https?://[^\s"'<>]+"#,
            options: [.caseInsensitive]
        ) else {
            return value
        }
        var result = value
        let range = NSRange(result.startIndex..., in: result)
        for match in expression.matches(
            in: result,
            range: range
        ).reversed() {
            guard let matchRange = Range(match.range, in: result) else {
                continue
            }
            let original = String(result[matchRange])
            let sanitized = redact(url: original)
            result.replaceSubrange(matchRange, with: sanitized)
        }
        return result
    }

    private static func replacing(
        _ pattern: String,
        in value: String,
        with replacement: String
    ) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: []
        ) else {
            return value
        }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: replacement
        )
    }

    private static func limited(_ value: String) -> String {
        guard value.count > maximumOutputLength else {
            return value
        }
        return String(value.prefix(maximumOutputLength))
            + "…<truncated>"
    }

    /// Roots that may identify a user, machine layout, application data, or a
    /// locally installed executable. Provider homes outside these roots are
    /// still removed when attached to a path-bearing key such as CODEX_HOME.
    private static let localPathPattern =
        #"(?:file://)?/(?:Users|home|Volumes|private|tmp|var|opt|usr/local)/[^/\s"'?]+(?:/[^\s"'?,;)\]}]*)?"#
}
