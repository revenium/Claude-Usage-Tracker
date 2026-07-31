//
//  CodexSwitchService.swift
//  Claude Usage
//
//  Switches the active Codex CLI home by setting CODEX_HOME via tmux
//  environment propagation and persisting the choice for new shells. Mirrors
//  ClaudeSwitchService's CLAUDE_CONFIG_DIR mechanism, but is deliberately
//  narrower: Codex owns its own credentials, so this service only ever reads
//  or writes a directory *path*. It never opens, reads, copies, or logs
//  anything inside a Codex home (in particular, never auth.json/tokens).
//

import Foundation

/// Manages CLI home switching for Codex using the same `.last-account`-style
/// persistence and tmux propagation `ClaudeSwitchService` uses for Claude,
/// scoped to a single pointer file since Codex has no per-account directory
/// tree to create or symlink.
class CodexSwitchService {
    static let shared = CodexSwitchService()

    /// Serial queue for all tmux operations, matching ClaudeSwitchService's
    /// use of a dedicated queue to avoid interleaving env mutations.
    private let tmuxQueue = DispatchQueue(
        label: "io.revenium.claude-usage.codex-tmux",
        qos: .utility
    )

    private init() {}

    // MARK: - Paths

    private var tokensDir: URL {
        Constants.ClaudePaths.homeDirectory
            .appendingPathComponent(".claude-tokens")
    }

    private var lastCodexHomeFile: URL {
        tokensDir.appendingPathComponent(".last-codex-home")
    }

    /// Returns the currently persisted CODEX_HOME path, if any.
    func currentHomePath() -> String? {
        guard let data = try? String(
            contentsOf: lastCodexHomeFile,
            encoding: .utf8
        ) else {
            return nil
        }
        let path = data.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    // MARK: - Switching

    /// Switches the active Codex CLI home by:
    /// 1. Writing the canonical home path to
    ///    ~/.claude-tokens/.last-codex-home (shell auto-restore)
    /// 2. Setting CODEX_HOME in tmux global environment (propagates to new
    ///    panes)
    func switchToHome(_ home: CanonicalCodexHome) throws {
        try writeLastCodexHome(home.path)
        propagateToTmux(codexHome: home.path)

        LoggingService.shared.log(
            "CodexSwitchService: Switched CODEX_HOME to '\(home.path)'"
        )
    }

    /// Clears the persisted home and unsets CODEX_HOME in tmux. Used when
    /// the active Codex profile is unlinked or deleted.
    func clearHome() {
        try? FileManager.default.removeItem(at: lastCodexHomeFile)
        unpropagateFromTmux()
    }

    // MARK: - Private Helpers

    private func writeLastCodexHome(_ path: String) throws {
        let dir = lastCodexHomeFile.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        }
        try path.write(to: lastCodexHomeFile, atomically: true, encoding: .utf8)
    }

    private func propagateToTmux(codexHome: String) {
        let tmuxPaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        guard let tmuxPath = tmuxPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            LoggingService.shared.log("CodexSwitchService: tmux not found — skipping env propagation")
            return
        }

        // Fire-and-forget on serial queue: don't block the calling thread waiting for tmux
        tmuxQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmuxPath)
            process.arguments = ["set-environment", "-g", "CODEX_HOME", codexHome]
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    LoggingService.shared.log("CodexSwitchService: tmux environment propagated")
                } else {
                    LoggingService.shared.log(
                        "CodexSwitchService: tmux set-environment failed "
                        + "(exit \(process.terminationStatus)) — ignored")
                }
            } catch {
                LoggingService.shared.log("CodexSwitchService: tmux command failed — ignored")
            }
        }
    }

    private func unpropagateFromTmux() {
        let tmuxPaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        guard let tmuxPath = tmuxPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            LoggingService.shared.log("CodexSwitchService: tmux not found — skipping env unset")
            return
        }

        tmuxQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmuxPath)
            process.arguments = ["set-environment", "-gu", "CODEX_HOME"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    LoggingService.shared.log(
                        "CodexSwitchService: tmux CODEX_HOME unset")
                } else {
                    LoggingService.shared.log(
                        "CodexSwitchService: tmux set-environment -gu failed "
                        + "(exit \(process.terminationStatus)) — ignored")
                }
            } catch {
                LoggingService.shared.log("CodexSwitchService: tmux unset command failed — ignored")
            }
        }
    }
}
