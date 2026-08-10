//
//  ClaudeCodeSyncService.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation
import Security

/// The outcome of one `/usr/bin/security` invocation.
struct SecurityCommandResult {
    let exitCode: Int32

    /// `nil` when the process wrote bytes that are not valid UTF-8.
    ///
    /// Deliberately distinct from `""`. A Keychain item whose secret is
    /// binary — corrupted, or written by some other tool — is *unreadable*,
    /// not *empty*, and `readKeychainCredentials` has to answer `nil` for it
    /// so the user is told to log in rather than told their credentials are
    /// corrupt. Coalescing the decode failure to an empty string here sends
    /// it down the JSON-validation path instead and inverts that message.
    let standardOutput: String?

    /// Diagnostics only, so an undecodable byte here is worth nothing and
    /// coalescing it to empty costs nothing.
    let standardError: String
}

/// Seam over `/usr/bin/security`.
///
/// The credential write path is the one place in this app that can destroy a
/// user's Claude Code login, so it has to be exercisable in tests without
/// touching the real login Keychain.
protocol SecurityCommandRunning {
    func run(_ arguments: [String]) throws -> SecurityCommandResult
}

/// Production runner.
///
/// Both pipes are drained *concurrently*, then joined before
/// `waitUntilExit()`. Draining them one after another deadlocks as soon as
/// the child fills a pipe buffer, and the credential blobs on this path
/// routinely run to several kilobytes.
struct SecurityCLIRunner: SecurityCommandRunning {
    /// Boxes the stderr read so it can cross the background-queue boundary;
    /// the `sync` barrier below guarantees exclusive access before it's read.
    private final class ErrorReadBox: @unchecked Sendable {
        var data = Data()
    }

    func run(_ arguments: [String]) throws -> SecurityCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        // Drain stderr on a background queue while stdout drains on this
        // thread, so neither pipe's buffer can back up and stall the child.
        let errorBox = ErrorReadBox()
        let errorQueue = DispatchQueue(label: "com.claudeusage.securityclirunner.stderr")
        errorQueue.async {
            errorBox.data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        errorQueue.sync {}
        process.waitUntilExit()

        return SecurityCommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(data: outputData, encoding: .utf8),
            standardError: String(data: errorBox.data, encoding: .utf8) ?? ""
        )
    }
}

/// Manages synchronization of Claude Code CLI credentials between system Keychain and profiles
class ClaudeCodeSyncService {
    static let shared = ClaudeCodeSyncService()

    /// Exit code `security` uses for "the item is not in the keychain".
    private static let itemNotFoundExitCode: Int32 = 44

    /// Exit code `security` uses for "an item with those attributes already exists".
    private static let duplicateItemExitCode: Int32 = 45

    /// Cached resolved keychain service name (cleared per app session).
    ///
    /// Only ever holds a name that was actually *found*. A lookup that finds
    /// nothing must not be cached: it would pin the whole process lifetime to
    /// the legacy name even after the CLI writes its real item.
    private var resolvedServiceName: String?
    private let profileStore: ProfileStore
    private let systemCredentialsReader: (() throws -> String?)?
    private let securityRunner: SecurityCommandRunning

    init(
        profileStore: ProfileStore = .shared,
        systemCredentialsReader: (() throws -> String?)? = nil,
        securityRunner: SecurityCommandRunning = SecurityCLIRunner()
    ) {
        self.profileStore = profileStore
        self.systemCredentialsReader = systemCredentialsReader
        self.securityRunner = securityRunner
    }

    // MARK: - System Credentials Access (Fallback Chain)

    /// Reads Claude Code credentials using a fallback chain:
    /// 1. ~/.claude/.credentials.json (always complete, not subject to keychain truncation)
    /// 2. System Keychain (may be truncated for large payloads >2KB)
    /// 3. Regex extraction of accessToken from truncated keychain data (last resort)
    func readSystemCredentials() throws -> String? {
        if let systemCredentialsReader {
            return try systemCredentialsReader()
        }

        // 1. Try credentials file first (most reliable)
        if let fileJSON = readCredentialsFile() {
            LoggingService.shared.log("Read credentials from .credentials.json file")
            return fileJSON
        }

        // 2. Try keychain
        let keychainData = try readKeychainCredentials()

        guard let rawJSON = keychainData else {
            // No credentials anywhere
            return nil
        }

        // 3. Validate keychain JSON
        if let data = rawJSON.data(using: .utf8),
           let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return rawJSON
        }

        // 4. Keychain data is truncated/invalid — try regex extraction
        LoggingService.shared.log("Keychain JSON is invalid (likely truncated), attempting regex extraction")
        if let token = extractAccessTokenViaRegex(from: rawJSON) {
            let minimalJSON = "{\"claudeAiOauth\":{\"accessToken\":\"\(token)\"}}"
            LoggingService.shared.log("Built minimal credentials from regex-extracted token")
            return minimalJSON
        }

        // 5. All attempts failed
        throw ClaudeCodeError.invalidJSON
    }

    // MARK: - Private Credential Sources

    /// Reads credentials from ~/.claude/.credentials.json or ~/.claude/credentials.json file
    private func readCredentialsFile() -> String? {
        let paths = [
            Constants.ClaudePaths.claudeDirectory.appendingPathComponent(".credentials.json"),
            Constants.ClaudePaths.claudeDirectory.appendingPathComponent("credentials.json")
        ]

        for fileURL in paths {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            guard let data = try? Data(contentsOf: fileURL),
                  let jsonString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !jsonString.isEmpty else {
                LoggingService.shared.log("credentials file exists but could not be read: \(fileURL.lastPathComponent)")
                continue
            }

            // Validate it's actually valid JSON
            guard let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                LoggingService.shared.log("credentials file contains invalid JSON: \(fileURL.lastPathComponent)")
                continue
            }

            LoggingService.shared.log("Read credentials from \(fileURL.lastPathComponent)")
            return jsonString
        }

        return nil
    }

    /// Reads Claude Code credentials from system Keychain using security command.
    ///
    /// This one stays on the `security` CLI rather than `SecItemCopyMatching`:
    /// the item's ACL trusts `/usr/bin/security`, which wrote it, so reading it
    /// from inside this app would raise a Keychain access prompt.
    ///
    /// Not `private`: `readSystemCredentials` reaches it only after the
    /// credentials file misses, which on a developer machine depends on
    /// whether `~/.claude/.credentials.json` happens to exist. Tests address
    /// it directly so their coverage of the failure codes does not vary by
    /// machine.
    func readKeychainCredentials() throws -> String? {
        let serviceName = resolveServiceName()
        let result = try securityRunner.run([
            "find-generic-password",
            "-s", serviceName,
            "-a", NSUserName(),
            "-w"  // Print password only
        ])

        if result.exitCode == 0 {
            // Undecodable bytes read as absent, not as an empty credential:
            // letting `""` through would fail JSON validation upstream and
            // tell the user their credentials are corrupt, when the actionable
            // answer is that there is nothing here to read.
            guard let value = result.standardOutput else {
                LoggingService.shared.log(
                    "Keychain item is not valid UTF-8; treating as absent"
                )
                return nil
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if result.exitCode == Self.itemNotFoundExitCode {
            return nil
        } else {
            let message = Self.describe(result)
            LoggingService.shared.log("Failed to read keychain: \(message)")
            throw ClaudeCodeError.keychainReadFailed(
                exitCode: result.exitCode,
                message: message
            )
        }
    }

    /// Renders a failed `security` invocation as something a support
    /// conversation can act on.
    ///
    /// The previous code threw `OSStatus(exitCode)`, which silently retyped a
    /// *process exit status* as a Security framework status — so every real
    /// failure surfaced as the uninformative "status: 1" and the CLI's own
    /// explanation, the only diagnostic that existed, was discarded.
    private static func describe(_ result: SecurityCommandResult) -> String {
        let stderr = result.standardError
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stderr.isEmpty else {
            return "security exited with code \(result.exitCode)"
        }
        return "security exited with code \(result.exitCode): \(stderr)"
    }

    /// Extracts accessToken from potentially truncated JSON using regex
    private func extractAccessTokenViaRegex(from rawString: String) -> String? {
        let pattern = "\"accessToken\"\\s*:\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: rawString, range: NSRange(rawString.startIndex..., in: rawString)),
              let tokenRange = Range(match.range(at: 1), in: rawString) else {
            return nil
        }
        return String(rawString[tokenRange])
    }

    // MARK: - Keychain Service Name Discovery

    private static let legacyServiceName = "Claude Code-credentials"

    /// Resolves the correct keychain service name for Claude Code credentials.
    /// Claude Code v2.1.52+ changed from "Claude Code-credentials" to "Claude Code-credentials-HASH".
    /// Tries legacy name first, then falls back to prefix search.
    private func resolveServiceName() -> String {
        if let cached = resolvedServiceName {
            return cached
        }

        // Try legacy name first (fast path)
        if keychainItemExists(serviceName: Self.legacyServiceName) {
            resolvedServiceName = Self.legacyServiceName
            return Self.legacyServiceName
        }

        // Fall back to searching for "Claude Code-credentials-" prefix
        if let hashedName = findHashedServiceName() {
            resolvedServiceName = hashedName
            LoggingService.shared.log("Resolved hashed keychain service name: \(hashedName)")
            return hashedName
        }

        // Nothing on this machine yet. Answer with the legacy name so the
        // caller still has something to try, but deliberately do NOT cache it:
        // "not found yet" is a transient state, and caching it would keep the
        // app writing the legacy item for the rest of the process lifetime even
        // after the CLI creates its real per-config-dir item.
        return Self.legacyServiceName
    }

    /// Checks if a keychain item exists with the given service name.
    ///
    /// Attributes only — no `kSecReturnData`, so this cannot raise a Keychain
    /// access prompt, and it costs no subprocess.
    private func keychainItemExists(serviceName: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: NSUserName(),
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Searches the keychain for a hashed service name matching
    /// "Claude Code-credentials-*".
    ///
    /// Deliberately not `security dump-keychain`: that dumps the attributes of
    /// every item in the user's login Keychain — every service name, account,
    /// and comment they have ever saved — into this process, to learn one
    /// string. This query is scoped to generic passwords owned by the current
    /// account and returns attributes only.
    private func findHashedServiceName() -> String? {
        let prefix = "Claude Code-credentials-"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: NSUserName(),
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return nil
        }

        // Sorted so a machine with several config directories resolves to the
        // same item on every launch rather than whichever one the Keychain
        // happened to return first.
        let matches = items
            .compactMap { $0[kSecAttrService as String] as? String }
            .filter { $0.hasPrefix(prefix) }
            .sorted()

        if matches.count > 1 {
            LoggingService.shared.log(
                "Found \(matches.count) hashed Claude Code keychain items; "
                    + "using the first by name"
            )
        }
        return matches.first
    }

    /// Invalidates the cached service name, forcing re-discovery on next access
    func invalidateServiceNameCache() {
        resolvedServiceName = nil
    }

    /// Writes Claude Code credentials to system Keychain using security command.
    ///
    /// The write is a single `add-generic-password -U`, which updates the item
    /// in place when it already exists. It deliberately does *not* delete first.
    ///
    /// The previous implementation ran `delete-generic-password` and only then
    /// re-added, which opened a window with no CLI login at all: any failure of
    /// the add — a locked Keychain, a denied ACL, a SecurityAgent prompt the
    /// user dismisses — left the user logged out of Claude Code, and cost a
    /// second full atomic rewrite of the login Keychain on every profile
    /// switch. `-U` was already being passed, so the delete bought nothing.
    func writeSystemCredentials(_ jsonData: String) throws {
        let serviceName = resolveServiceName()
        LoggingService.shared.log("Writing credentials to keychain using security command (service: \(serviceName))")

        let result = try addGenericPassword(jsonData, serviceName: serviceName)
        if result.exitCode == 0 {
            LoggingService.shared.log("✅ Added Claude Code system credentials successfully using security command")
            return
        }

        // `-U` should make this unreachable. If some Keychain state defeats it
        // anyway, fall back to the old delete-then-add — but only from here, as
        // recovery from an already-failed write, never on the happy path.
        guard result.exitCode == Self.duplicateItemExitCode else {
            let message = Self.describe(result)
            LoggingService.shared.log("❌ Failed to add credentials: \(message)")
            throw ClaudeCodeError.keychainWriteFailed(
                exitCode: result.exitCode,
                message: message
            )
        }

        LoggingService.shared.log(
            "Update-in-place was refused as a duplicate; retrying via delete"
        )
        let deleteResult = try securityRunner.run([
            "delete-generic-password",
            "-s", serviceName,
            "-a", NSUserName()
        ])
        if deleteResult.exitCode != 0 {
            LoggingService.shared.log(
                "No existing keychain item to delete "
                    + "(\(Self.describe(deleteResult)))"
            )
        }

        let retry = try addGenericPassword(jsonData, serviceName: serviceName)
        guard retry.exitCode == 0 else {
            let message = Self.describe(retry)
            // The delete above already ran, so this path really can leave the
            // system without a CLI login. Say so plainly in the log.
            LoggingService.shared.log(
                "❌ Failed to add credentials after delete; the system has no "
                    + "Claude Code login until this is retried: \(message)"
            )
            throw ClaudeCodeError.keychainWriteFailed(
                exitCode: retry.exitCode,
                message: message
            )
        }
        LoggingService.shared.log("✅ Added Claude Code system credentials successfully using security command")
    }

    private func addGenericPassword(
        _ jsonData: String,
        serviceName: String
    ) throws -> SecurityCommandResult {
        try securityRunner.run([
            "add-generic-password",
            "-s", serviceName,
            "-a", NSUserName(),
            "-w", jsonData,
            "-U"  // Update if exists
        ])
    }

    // MARK: - Profile Sync Operations

    /// Syncs credentials from system to profile (one-time copy)
    func syncToProfile(_ profileId: UUID) throws {
        guard let jsonData = try readSystemCredentials() else {
            throw ClaudeCodeError.noCredentialsFound
        }

        // Validate JSON format
        guard let data = jsonData.data(using: .utf8),
              let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeCodeError.invalidJSON
        }

        let previous = try profileStore
            .loadProfileCredentials(profileId)
            .cliCredentialsJSON
        // This explicit credential API performs a verified Keychain write.
        try profileStore.saveCLIProfileCredential(jsonData, for: profileId)
        if previous != jsonData {
            postCLIChange(profileID: profileId)
        }

        LoggingService.shared.log("Synced CLI credentials to profile: \(profileId)")
    }

    /// Applies profile's CLI credentials to system (overwrites current login)
    func applyProfileCredentials(_ profileId: UUID) throws {
        LoggingService.shared.log("🔄 Applying CLI credentials for profile: \(profileId)")

        guard let jsonData = try profileStore
            .loadProfileCredentials(profileId).cliCredentialsJSON else {
            LoggingService.shared.log("❌ No CLI credentials found for profile: \(profileId)")
            throw ClaudeCodeError.noProfileCredentials
        }

        LoggingService.shared.log("📦 Found CLI credentials, writing to keychain...")
        try writeSystemCredentials(jsonData)

        LoggingService.shared.log("✅ Applied profile CLI credentials to system: \(profileId)")
    }

    /// Removes CLI credentials from profile (doesn't affect system)
    func removeFromProfile(_ profileId: UUID) throws {
        let previous = try profileStore
            .loadProfileCredentials(profileId)
            .cliCredentialsJSON
        try profileStore.saveCLIProfileCredential(nil, for: profileId)
        if previous != nil {
            postCLIChange(profileID: profileId)
        }

        LoggingService.shared.log("Removed CLI credentials from profile: \(profileId)")
    }

    // MARK: - Access Token Extraction

    func extractAccessToken(from jsonData: String) -> String? {
        guard let data = jsonData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            return nil
        }
        return token
    }

    func extractSubscriptionInfo(from jsonData: String) -> (type: String, scopes: [String])? {
        guard let data = jsonData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any] else {
            return nil
        }

        let subType = oauth["subscriptionType"] as? String ?? "unknown"
        let scopes = oauth["scopes"] as? [String] ?? []

        return (subType, scopes)
    }

    /// Extracts the token expiry date from CLI credentials JSON
    func extractTokenExpiry(from jsonData: String) -> Date? {
        guard let data = jsonData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let expiresAt = oauth["expiresAt"] as? TimeInterval else {
            return nil
        }
        // Claude Code CLI stores expiresAt in milliseconds since epoch
        // Values > 1e12 are definitely milliseconds (year 2001+ in ms vs year 33658 in seconds)
        let epochSeconds = expiresAt > 1e12 ? expiresAt / 1000.0 : expiresAt
        return Date(timeIntervalSince1970: epochSeconds)
    }

    /// Checks if the OAuth token in the credentials JSON is expired
    func isTokenExpired(_ jsonData: String) -> Bool {
        guard let expiryDate = extractTokenExpiry(from: jsonData) else {
            // No expiry info = assume valid
            return false
        }
        return Date() > expiryDate
    }

    // MARK: - Auto Re-sync Before Switching

    /// Re-syncs credentials from system Keychain before profile switching
    /// This ensures we always have the latest CLI login when switching profiles
    func resyncBeforeSwitching(for profileId: UUID) throws {
        LoggingService.shared.log("Re-syncing CLI credentials before profile switch: \(profileId)")

        // Read fresh credentials from system (if user is logged in)
        guard let freshJSON = try readSystemCredentials() else {
            // No credentials in system - user not logged into CLI anymore
            LoggingService.shared.log("No system credentials found - skipping re-sync")
            return
        }

        // Validate JSON before saving (defense-in-depth against truncated data)
        guard let data = freshJSON.data(using: .utf8),
              let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            LoggingService.shared.log("Re-synced credentials contain invalid JSON - skipping save")
            return
        }

        let previous = try profileStore
            .loadProfileCredentials(profileId)
            .cliCredentialsJSON
        try profileStore.saveCLIProfileCredential(
            freshJSON,
            for: profileId,
            syncedAt: Date()
        )
        if previous != freshJSON {
            postCLIChange(profileID: profileId)
        }

        LoggingService.shared.log("✓ Re-synced CLI credentials from system and updated timestamp")
    }

    private func postCLIChange(profileID: UUID) {
        NotificationCenter.default.post(
            name: .credentialsChanged,
            object: profileID,
            userInfo: [
                "profileID": profileID,
                "component": "cli"
            ]
        )
    }
}

// MARK: - ClaudeCodeError

enum ClaudeCodeError: LocalizedError {
    case noCredentialsFound
    case invalidJSON
    /// Carries the `security` process exit code plus whatever the CLI wrote to
    /// stderr. Both are needed: the exit code alone is not an `OSStatus` and
    /// says almost nothing about why the Keychain refused the operation.
    case keychainReadFailed(exitCode: Int32, message: String)
    case keychainWriteFailed(exitCode: Int32, message: String)
    case noProfileCredentials

    var errorDescription: String? {
        switch self {
        case .noCredentialsFound:
            return "No Claude Code credentials found in system Keychain. Please log in to Claude Code first."
        case .invalidJSON:
            return "Claude Code credentials are corrupted or invalid."
        case .keychainReadFailed(_, let message):
            return "Failed to read credentials from system Keychain (\(message))."
        case .keychainWriteFailed(_, let message):
            return "Failed to write credentials to system Keychain (\(message))."
        case .noProfileCredentials:
            return "This profile has no synced CLI account."
        }
    }
}
