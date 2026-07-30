import Foundation
import UsageCore

/// A supported Codex account is a ChatGPT subscription account.
///
/// Other Codex authentication modes can run Codex, but they do not expose the
/// subscription usage contract monitored by this provider.
public enum CodexUnsupportedAccountKind: String, Equatable, Sendable {
    case apiKey
    case amazonBedrock
    case other
    case noOpenAIAccount
}

public enum CodexAccountStatus: Equatable, Sendable {
    case supported(ProviderAccount)
    case unauthenticated
    case unsupported(CodexUnsupportedAccountKind)
}

public enum CodexLoginAppBrand: String, Equatable, Sendable {
    case codex
    case chatgpt
}

public enum CodexLoginFlow: Equatable, Sendable {
    case browser(
        useHostedSuccessPage: Bool = true,
        appBrand: CodexLoginAppBrand = .codex
    )
    case deviceCode
}

public enum CodexLoginChallenge: Equatable, Sendable {
    case browser(loginID: String, authorizationURL: URL)
    case deviceCode(
        loginID: String,
        verificationURL: URL,
        userCode: String
    )

    public var loginID: String {
        switch self {
        case let .browser(loginID, _),
             let .deviceCode(loginID, _, _):
            loginID
        }
    }
}

extension CodexLoginChallenge: CustomStringConvertible,
    CustomDebugStringConvertible
{
    public var description: String {
        switch self {
        case .browser:
            "CodexLoginChallenge.browser(<redacted>)"
        case .deviceCode:
            "CodexLoginChallenge.deviceCode(<redacted>)"
        }
    }

    public var debugDescription: String { description }
}

public enum CodexLoginOutcome: Equatable, Sendable {
    case succeeded
    case failed
}

public enum CodexLoginCancellationOutcome: Equatable, Sendable {
    case canceled
    case notFound
}

/// Result of checking authentication before starting an interactive login.
///
/// A linked Codex home can already hold a supported ChatGPT session. In that
/// case callers receive the account without opening an unnecessary login
/// session or changing credentials.
public enum CodexLoginStartResult: Sendable {
    case alreadyAuthenticated(ProviderAccount)
    case started(CodexLoginAttempt)
}

struct CodexAccountReadResponse: Decodable, Sendable {
    struct Account: Decodable, Sendable {
        var type: String
        var email: String?
        var planType: String?
    }

    var account: Account?
    var requiresOpenaiAuth: Bool
}

struct CodexRateLimitsResponse: Decodable, Sendable {
    struct Snapshot: Decodable, Sendable {
        struct Window: Decodable, Sendable {
            var usedPercent: Double
            var windowDurationMins: Int64?
            var resetsAt: Int64?

            private enum CodingKeys: String, CodingKey {
                case usedPercent
                case windowDurationMins
                case resetsAt
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                usedPercent = try container.decodeFlexibleDouble(
                    forKey: .usedPercent
                )
                windowDurationMins = try container.decodeFlexibleInt64IfPresent(
                    forKey: .windowDurationMins
                )
                resetsAt = try container.decodeFlexibleInt64IfPresent(
                    forKey: .resetsAt
                )
            }
        }

        struct Credits: Decodable, Sendable {
            var hasCredits: Bool
            var unlimited: Bool
            var balance: String?
        }

        var credits: Credits?
        var limitID: String?
        var limitName: String?
        var planType: String?
        var primary: Window?
        var secondary: Window?
        var rateLimitReachedType: String?
        var spendControlReached: Bool?

        private enum CodingKeys: String, CodingKey {
            case credits
            case limitID = "limitId"
            case limitName
            case planType
            case primary
            case secondary
            case rateLimitReachedType
            case spendControlReached
        }
    }

    struct ResetCreditsSummary: Decodable, Sendable {
        struct Credit: Decodable, Sendable {
            var id: String
            var resetType: String
            var status: String
            var grantedAt: Int64
            var expiresAt: Int64?
            var title: String?
            var description: String?
        }

        var availableCount: Int64
        var credits: [Credit]?
    }

    var rateLimits: Snapshot?
    var rateLimitsByLimitID: [String: Snapshot]
    var rateLimitResetCredits: ResetCreditsSummary?

    private enum CodingKeys: String, CodingKey {
        case rateLimits
        case rateLimitsByLimitID = "rateLimitsByLimitId"
        case rateLimitResetCredits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rateLimits = try container.decodeIfPresent(
            Snapshot.self,
            forKey: .rateLimits
        )
        rateLimitsByLimitID = try container.decodeLossyDictionary(
            Snapshot.self,
            forKey: .rateLimitsByLimitID
        )
        rateLimitResetCredits = try container.decodeIfPresent(
            ResetCreditsSummary.self,
            forKey: .rateLimitResetCredits
        )
    }
}

struct CodexAccountTokenUsageResponse: Decodable, Sendable {
    struct Summary: Decodable, Sendable {
        var currentStreakDays: Int64?
        var lifetimeTokens: Int64?
        var longestRunningTurnSec: Int64?
        var longestStreakDays: Int64?
        var peakDailyTokens: Int64?
    }

    struct DailyBucket: Decodable, Sendable {
        var startDate: String
        var tokens: Int64
    }

    var summary: Summary?
    var dailyUsageBuckets: [DailyBucket]?

    var containsRecognizedUsageSurface: Bool {
        summary != nil || dailyUsageBuckets != nil
    }
}

struct CodexLoginStartResponse: Decodable, Sendable {
    var type: String
    var loginID: String?
    var authorizationURL: String?
    var verificationURL: String?
    var userCode: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case loginID = "loginId"
        case authorizationURL = "authUrl"
        case verificationURL = "verificationUrl"
        case userCode
    }
}

struct CodexLoginCompletedNotification: Decodable, Sendable {
    var loginID: String?
    var success: Bool

    private enum CodingKeys: String, CodingKey {
        case loginID = "loginId"
        case success
    }
}

struct CodexCancelLoginResponse: Decodable, Sendable {
    var status: String
}

enum CodexDomainDecoder {
    static func decode<T: Decodable>(
        _ type: T.Type,
        from value: CodexJSONValue
    ) throws -> T {
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw UsageProviderError.malformedResponse
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleDouble(forKey key: Key) throws -> Double {
        if let double = try? decode(Double.self, forKey: key) {
            return double
        }
        if let string = try? decode(String.self, forKey: key),
           let double = Double(string)
        {
            return double
        }
        throw DecodingError.typeMismatch(
            Double.self,
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Expected a finite numeric value"
            )
        )
    }

    func decodeFlexibleInt64IfPresent(forKey key: Key) throws -> Int64? {
        guard contains(key), try !decodeNil(forKey: key) else {
            return nil
        }
        if let integer = try? decode(Int64.self, forKey: key) {
            return integer
        }
        if let string = try? decode(String.self, forKey: key),
           let integer = Int64(string)
        {
            return integer
        }
        throw DecodingError.typeMismatch(
            Int64.self,
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Expected an integer value"
            )
        )
    }

    func decodeLossyDictionary<Value: Decodable>(
        _ type: Value.Type,
        forKey key: Key
    ) throws -> [String: Value] {
        guard contains(key), try !decodeNil(forKey: key) else {
            return [:]
        }
        let nested = try nestedContainer(
            keyedBy: DynamicCodingKey.self,
            forKey: key
        )
        var result: [String: Value] = [:]
        for dynamicKey in nested.allKeys {
            if let value = try? nested.decode(Value.self, forKey: dynamicKey) {
                result[dynamicKey.stringValue] = value
            }
        }
        return result
    }
}
