//
//  ClaudeSwitchService.swift
//  Claude Usage
//
//  Switches the active Claude Code CLI account by setting CLAUDE_CONFIG_DIR
//  via tmux environment propagation and persisting the choice for new shells.
//

import Foundation

/// Manages CLI account switching using the claude-switch mechanism.
/// Each account has its own config directory at ~/.claude-accounts/<name>/
/// containing a .credentials.json with OAuth tokens.
class ClaudeSwitchService {
    static let shared = ClaudeSwitchService()

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

    // MARK: - Discovery

    /// Lists available account names from ~/.claude-accounts/ that have valid credentials
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
                let credFile = url.appendingPathComponent(".credentials.json")
                return FileManager.default.fileExists(atPath: credFile.path)
            }
            .map { $0.lastPathComponent }
            .sorted()
    }

    /// Checks whether an account name has a valid directory with credentials
    func isValidAccountName(_ name: String) -> Bool {
        let credFile = accountsDir
            .appendingPathComponent(name)
            .appendingPathComponent(".credentials.json")
        return FileManager.default.fileExists(atPath: credFile.path)
    }

    /// Returns the currently persisted account name, if any
    func currentAccountName() -> String? {
        guard let data = try? String(contentsOf: lastAccountFile, encoding: .utf8) else {
            return nil
        }
        let name = data.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    // MARK: - Switching

    /// Switches the active CLI account by:
    /// 1. Writing the account name to ~/.claude-tokens/.last-account (shell auto-restore)
    /// 2. Setting CLAUDE_CONFIG_DIR in tmux global environment (propagates to new panes)
    func switchToAccount(_ accountName: String) throws {
        guard isValidAccountName(accountName) else {
            throw ClaudeSwitchError.invalidAccountName(accountName)
        }

        let configDir = accountsDir.appendingPathComponent(accountName).path

        // Persist for shell auto-restore on new terminal startup
        try writeLastAccount(accountName)

        // Propagate to tmux (best-effort — tmux may not be running)
        propagateToTmux(configDir: configDir)

        LoggingService.shared.log(
            "ClaudeSwitchService: Switched CLI account to '\(accountName)' "
            + "(CLAUDE_CONFIG_DIR=\(configDir))")
    }

    // MARK: - Private

    private func writeLastAccount(_ name: String) throws {
        let dir = lastAccountFile.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        }
        try name.write(to: lastAccountFile, atomically: true, encoding: .utf8)
    }

    private func propagateToTmux(configDir: String) {
        // Try common tmux paths
        let tmuxPaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        guard let tmuxPath = tmuxPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            LoggingService.shared.log("ClaudeSwitchService: tmux not found — skipping env propagation")
            return
        }

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

// MARK: - Errors

enum ClaudeSwitchError: LocalizedError {
    case invalidAccountName(String)

    var errorDescription: String? {
        switch self {
        case .invalidAccountName(let name):
            return "No CLI account directory found for '\(name)'. "
                 + "Expected ~/.claude-accounts/\(name)/.credentials.json"
        }
    }
}
