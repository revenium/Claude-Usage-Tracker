//
//  ClaudeSwitchService.swift
//  Claude Usage
//
//  Switches the active Claude Code CLI account by setting CLAUDE_CONFIG_DIR
//  via tmux environment propagation and persisting the choice for new shells.
//  Also handles account directory creation, symlinks, and credential detection.
//

import Foundation

/// Manages CLI account switching using the claude-switch mechanism.
/// Each account has its own config directory at ~/.claude-accounts/<name>/
/// with per-account credentials while sharing settings via symlinks from ~/.claude/.
class ClaudeSwitchService {
    static let shared = ClaudeSwitchService()

    /// Files that are per-account and should NOT be symlinked from ~/.claude/
    private let perAccountFiles: Set<String> = [".credentials.json", ".claude.json"]

    private init() {}

    // MARK: - Paths

    private var accountsDir: URL {
        Constants.ClaudePaths.homeDirectory
            .appendingPathComponent(".claude-accounts")
    }

    private var tokensDir: URL {
        Constants.ClaudePaths.homeDirectory
            .appendingPathComponent(".claude-tokens")
    }

    private var lastAccountFile: URL {
        tokensDir.appendingPathComponent(".last-account")
    }

    private var claudeDir: URL {
        Constants.ClaudePaths.homeDirectory
            .appendingPathComponent(".claude")
    }

    /// The user-level ~/.claude.json where `claude mcp add` stores MCP server config.
    /// This is distinct from ~/.claude/.claude.json (inside the config directory).
    private var homeClaudeJson: URL {
        Constants.ClaudePaths.homeDirectory
            .appendingPathComponent(".claude.json")
    }

    /// Returns the full path for an account directory
    func accountDirectoryPath(for name: String) -> URL {
        accountsDir.appendingPathComponent(name)
    }

    // MARK: - Name Sanitization

    /// Converts a profile name to a filesystem-safe directory name.
    /// Lowercases, replaces non-alphanumeric characters with hyphens,
    /// collapses consecutive hyphens, and strips leading/trailing hyphens.
    func sanitizeProfileName(_ name: String) -> String {
        let lowered = name.lowercased()
        let replaced = lowered.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let collapsed = replaced.replacingOccurrences(
            of: "-{2,}", with: "-",
            options: .regularExpression
        )
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? UUID().uuidString.prefix(8).lowercased() : trimmed
    }

    // MARK: - Discovery

    /// Lists available account names from ~/.claude-accounts/ that have credentials
    func availableAccountNames() -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: accountsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .filter { url in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                guard isDir.boolValue else { return false }
                return hasCredentialFiles(in: url)
            }
            .map { $0.lastPathComponent }
            .sorted()
    }

    /// Checks whether an account name has a valid directory with credentials.
    /// Supports both .credentials.json (legacy) and .claude.json (v2.1.52+).
    func isValidAccountName(_ name: String) -> Bool {
        let dir = accountDirectoryPath(for: name)
        return hasCredentialFiles(in: dir)
    }

    /// Checks whether an account directory exists (even without credentials yet)
    func accountDirectoryExists(_ name: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: accountDirectoryPath(for: name).path,
            isDirectory: &isDir
        ) && isDir.boolValue
    }

    /// Returns the currently persisted account name, if any
    func currentAccountName() -> String? {
        guard let data = try? String(contentsOf: lastAccountFile, encoding: .utf8) else {
            return nil
        }
        let name = data.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    // MARK: - Linking

    /// Creates a dedicated CLI account directory for a profile and symlinks shared config.
    /// - Parameter profileName: The display name of the profile (will be sanitized)
    /// - Returns: Result with directory info and symlink count
    func linkAccount(profileName: String) throws -> LinkAccountResult {
        let dirName = sanitizeProfileName(profileName)
        let accountDir = accountDirectoryPath(for: dirName)

        // Handle name collision with existing directory
        let finalDirName = try resolveDirectoryName(baseName: dirName)
        let finalAccountDir = accountDirectoryPath(for: finalDirName)

        // Create account directory
        try FileManager.default.createDirectory(
            at: finalAccountDir, withIntermediateDirectories: true)

        // Create tokens directory if needed
        if !FileManager.default.fileExists(atPath: tokensDir.path) {
            try FileManager.default.createDirectory(
                at: tokensDir, withIntermediateDirectories: true)
        }

        // Symlink shared config from ~/.claude/
        let (symlinkCount, skippedFiles) = try createSymlinks(
            from: claudeDir, to: finalAccountDir)

        // Copy .claude.json as a starting point if it exists (from ~/.claude/.claude.json)
        let sourceClaudeJson = claudeDir.appendingPathComponent(".claude.json")
        let destClaudeJson = finalAccountDir.appendingPathComponent(".claude.json")
        if FileManager.default.fileExists(atPath: sourceClaudeJson.path)
            && !FileManager.default.fileExists(atPath: destClaudeJson.path) {
            try FileManager.default.copyItem(at: sourceClaudeJson, to: destClaudeJson)
        }

        // Merge mcpServers from ~/.claude.json (where `claude mcp add` stores config)
        // into the account's .claude.json so MCP servers carry over seamlessly.
        mergeMcpServers(into: destClaudeJson)

        LoggingService.shared.log(
            "ClaudeSwitchService: Linked account '\(finalDirName)' "
            + "(\(symlinkCount) symlinks, \(skippedFiles.count) skipped)")

        return LinkAccountResult(
            directoryName: finalDirName,
            directoryPath: finalAccountDir.path,
            symlinkCount: symlinkCount,
            skippedFiles: skippedFiles
        )
    }

    /// Removes an account directory and clears .last-account if it references this account.
    func unlinkAccount(directoryName: String) throws {
        let dir = accountDirectoryPath(for: directoryName)

        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }

        // Clear .last-account if it references this account
        if currentAccountName() == directoryName {
            try? FileManager.default.removeItem(at: lastAccountFile)
        }

        LoggingService.shared.log(
            "ClaudeSwitchService: Unlinked account '\(directoryName)'")
    }

    // MARK: - Credential Detection

    /// Checks whether the linked directory has valid credentials.
    func checkForCredentials(directoryName: String) -> CredentialCheckResult {
        let dir = accountDirectoryPath(for: directoryName)
        let credFile = dir.appendingPathComponent(".credentials.json")
        let claudeJson = dir.appendingPathComponent(".claude.json")

        let hasLegacy = FileManager.default.fileExists(atPath: credFile.path)
        let hasModern = hasOAuthAccountInClaudeJson(at: claudeJson)

        switch (hasLegacy, hasModern) {
        case (true, true): return .both
        case (true, false): return .legacyCredentials
        case (false, true): return .modernCredentials
        case (false, false): return .notFound
        }
    }

    /// Reads credentials JSON from the linked account directory.
    /// Tries .credentials.json first, falls back to extracting from .claude.json.
    func readLinkedAccountCredentials(directoryName: String) -> String? {
        let dir = accountDirectoryPath(for: directoryName)

        // Try .credentials.json first
        let credFile = dir.appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: credFile),
           let json = String(data: data, encoding: .utf8),
           !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return json
        }

        // Fall back to .claude.json — extract OAuth if present
        let claudeJson = dir.appendingPathComponent(".claude.json")
        if let data = try? Data(contentsOf: claudeJson),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauthAccount = parsed["oauthAccount"] as? [String: Any],
           let accessToken = oauthAccount["accessToken"] as? String {
            // Build credentials JSON safely using JSONSerialization (not string interpolation)
            let dict: [String: Any] = ["claudeAiOauth": ["accessToken": accessToken]]
            if let jsonData = try? JSONSerialization.data(withJSONObject: dict),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                return jsonString
            }
        }

        return nil
    }

    // MARK: - Switching

    /// Switches the active CLI account by:
    /// 1. Writing the account name to ~/.claude-tokens/.last-account (shell auto-restore)
    /// 2. Setting CLAUDE_CONFIG_DIR in tmux global environment (propagates to new panes)
    func switchToAccount(_ accountName: String) throws {
        let configDir = accountDirectoryPath(for: accountName).path

        // Verify directory exists (don't require credentials — user may not have logged in yet)
        guard accountDirectoryExists(accountName) else {
            throw ClaudeSwitchError.invalidAccountName(accountName)
        }

        // Persist for shell auto-restore on new terminal startup
        try writeLastAccount(accountName)

        // Propagate to tmux (best-effort — tmux may not be running)
        propagateToTmux(configDir: configDir)

        LoggingService.shared.log(
            "ClaudeSwitchService: Switched CLI account to '\(accountName)' "
            + "(CLAUDE_CONFIG_DIR=\(configDir))")
    }

    // MARK: - MCP Server Sync

    /// Syncs mcpServers from ~/.claude.json into a single account's .claude.json.
    /// Safe to call repeatedly — merges without overwriting existing per-account MCPs.
    func syncMcpServers(forAccount name: String) -> Int {
        let destJson = accountDirectoryPath(for: name).appendingPathComponent(".claude.json")
        return mergeMcpServers(into: destJson)
    }

    /// Syncs mcpServers from ~/.claude.json into ALL linked accounts.
    /// Returns the number of accounts updated.
    func syncMcpServersToAllAccounts() -> Int {
        var updatedCount = 0
        for name in availableAccountNames() {
            let merged = syncMcpServers(forAccount: name)
            if merged > 0 { updatedCount += 1 }
        }
        if updatedCount > 0 {
            LoggingService.shared.log(
                "ClaudeSwitchService: Synced MCP servers to \(updatedCount) account(s)")
        }
        return updatedCount
    }

    // MARK: - Private Helpers

    /// Reads mcpServers from ~/.claude.json and merges them into a destination .claude.json.
    /// Returns the number of MCP servers merged (0 if nothing to merge or source missing).
    @discardableResult
    private func mergeMcpServers(into destClaudeJson: URL) -> Int {
        // Read source mcpServers from ~/.claude.json
        guard FileManager.default.fileExists(atPath: homeClaudeJson.path),
              let sourceData = try? Data(contentsOf: homeClaudeJson),
              let sourceDict = try? JSONSerialization.jsonObject(with: sourceData) as? [String: Any],
              let sourceMcps = sourceDict["mcpServers"] as? [String: Any],
              !sourceMcps.isEmpty else {
            return 0
        }

        // Read or initialize destination .claude.json
        var destDict: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: destClaudeJson.path),
           let destData = try? Data(contentsOf: destClaudeJson),
           let parsed = try? JSONSerialization.jsonObject(with: destData) as? [String: Any] {
            destDict = parsed
        }

        // Merge: source MCPs fill in what's missing, existing account MCPs take precedence
        var existingMcps = destDict["mcpServers"] as? [String: Any] ?? [:]
        var mergedCount = 0
        for (name, config) in sourceMcps where existingMcps[name] == nil {
            existingMcps[name] = config
            mergedCount += 1
        }

        guard mergedCount > 0 else { return 0 }

        destDict["mcpServers"] = existingMcps

        // Write back
        do {
            let jsonData = try JSONSerialization.data(
                withJSONObject: destDict, options: [.prettyPrinted, .sortedKeys])
            try jsonData.write(to: destClaudeJson, options: .atomic)
            LoggingService.shared.log(
                "ClaudeSwitchService: Merged \(mergedCount) MCP server(s) into \(destClaudeJson.lastPathComponent)")
        } catch {
            LoggingService.shared.log(
                "ClaudeSwitchService: Failed to merge MCP servers: \(error.localizedDescription)")
            return 0
        }

        return mergedCount
    }

    private func hasCredentialFiles(in dir: URL) -> Bool {
        let credFile = dir.appendingPathComponent(".credentials.json")
        if FileManager.default.fileExists(atPath: credFile.path) {
            return true
        }
        // For .claude.json, verify it actually contains oauthAccount (not just a copied template)
        let claudeJson = dir.appendingPathComponent(".claude.json")
        return hasOAuthAccountInClaudeJson(at: claudeJson)
    }

    private func hasOAuthAccountInClaudeJson(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return parsed["oauthAccount"] != nil
    }

    private func resolveDirectoryName(baseName: String) throws -> String {
        let baseDir = accountDirectoryPath(for: baseName)
        if !FileManager.default.fileExists(atPath: baseDir.path) {
            return baseName
        }

        // Directory exists but has no credentials — safe to reuse (e.g., previous failed link)
        if !hasCredentialFiles(in: baseDir) {
            return baseName
        }

        // Directory exists with credentials — find a unique suffix
        for suffix in 2...99 {
            let candidate = "\(baseName)-\(suffix)"
            let candidateDir = accountDirectoryPath(for: candidate)
            if !FileManager.default.fileExists(atPath: candidateDir.path) {
                return candidate
            }
        }

        throw ClaudeSwitchError.directoryCreationFailed(
            "Could not find a unique directory name for '\(baseName)'"
        )
    }

    private func createSymlinks(from source: URL, to destination: URL) throws -> (Int, [String]) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return (0, [])
        }

        var symlinkCount = 0
        var skippedFiles: [String] = []

        for item in contents {
            let name = item.lastPathComponent

            // Skip per-account files
            if perAccountFiles.contains(name) {
                skippedFiles.append(name)
                continue
            }

            let destPath = destination.appendingPathComponent(name)

            // Skip if already exists in destination
            if FileManager.default.fileExists(atPath: destPath.path) {
                skippedFiles.append(name)
                continue
            }

            do {
                try FileManager.default.createSymbolicLink(
                    at: destPath, withDestinationURL: item)
                symlinkCount += 1
            } catch {
                LoggingService.shared.log(
                    "ClaudeSwitchService: Failed to symlink \(name): \(error.localizedDescription)")
                skippedFiles.append(name)
            }
        }

        return (symlinkCount, skippedFiles)
    }

    private func writeLastAccount(_ name: String) throws {
        let dir = lastAccountFile.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        }
        try name.write(to: lastAccountFile, atomically: true, encoding: .utf8)
    }

    private func propagateToTmux(configDir: String) {
        let tmuxPaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        guard let tmuxPath = tmuxPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            LoggingService.shared.log("ClaudeSwitchService: tmux not found — skipping env propagation")
            return
        }

        // Fire-and-forget: don't block the calling thread waiting for tmux
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmuxPath)
            process.arguments = ["set-environment", "-g", "CLAUDE_CONFIG_DIR", configDir]
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    LoggingService.shared.log("ClaudeSwitchService: tmux environment propagated")
                } else {
                    LoggingService.shared.log(
                        "ClaudeSwitchService: tmux set-environment failed "
                        + "(exit \(process.terminationStatus)) — ignored")
                }
            } catch {
                LoggingService.shared.log("ClaudeSwitchService: tmux command failed — ignored")
            }
        }
    }
}

// MARK: - Result Types

struct LinkAccountResult {
    let directoryName: String
    let directoryPath: String
    let symlinkCount: Int
    let skippedFiles: [String]
}

enum CredentialCheckResult {
    case notFound
    case legacyCredentials
    case modernCredentials
    case both

    var hasCredentials: Bool {
        switch self {
        case .notFound: return false
        default: return true
        }
    }
}

// MARK: - Errors

enum ClaudeSwitchError: LocalizedError {
    case invalidAccountName(String)
    case directoryCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAccountName(let name):
            return "No CLI account directory found for '\(name)'. "
                 + "Expected ~/.claude-accounts/\(name)/"
        case .directoryCreationFailed(let path):
            return "Failed to create account directory at \(path)"
        }
    }
}
