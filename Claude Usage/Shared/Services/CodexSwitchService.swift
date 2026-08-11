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
    /// The singleton is made inert under hosted unit tests: both flags below
    /// are false whenever `AppDelegate.isRunningHostedUnitTests` is true.
    /// This is the backstop for `ProfileManager`, whose `activationCodexEffects`
    /// defaults to `.live` (which routes here) at ~65 call sites in the test
    /// target, only 2 of which inject a no-op. No unit test, present or
    /// future, may write the developer's real `.last-codex-home` pointer
    /// file or mutate their real tmux server — reaching this singleton from
    /// a hosted test must always be a safe no-op for writes, whatever the
    /// individual test did or didn't inject.
    static let shared = CodexSwitchService(
        propagatesToTmux: !AppDelegate.isRunningHostedUnitTests,
        persistsPointerFile: !AppDelegate.isRunningHostedUnitTests
    )

    /// Serial queue for all tmux operations, matching ClaudeSwitchService's
    /// use of a dedicated queue to avoid interleaving env mutations.
    private let tmuxQueue = DispatchQueue(
        label: "io.revenium.claude-usage.codex-tmux",
        qos: .utility
    )

    /// Tests may write an isolated pointer file, but must never mutate the
    /// user's real tmux server.
    private let propagatesToTmux: Bool

    /// Tests may exercise the tmux propagation path, but must never mutate
    /// the developer's real `.last-codex-home` pointer file. Reads
    /// (`currentHomePath()`) are unaffected — this only gates writes.
    private let persistsPointerFile: Bool

    init(propagatesToTmux: Bool = true, persistsPointerFile: Bool = true) {
        self.propagatesToTmux = propagatesToTmux
        self.persistsPointerFile = persistsPointerFile
    }

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
        // Re-canonicalize and let `.missing`/`.notDirectory`/etc. propagate —
        // that's the "does this path still exist and is it still a
        // directory" check. What must NOT propagate as a false rejection is
        // a plain identity mismatch when `home.filesystemIdentity` is nil:
        // that's a legacy path-only persisted link (decoded before this app
        // recorded filesystem identity), and re-canonicalizing always
        // produces a non-nil identity. Comparing the full structs would
        // reject every legacy link with `.changedSinceVerification` and
        // silently leave the user's CODEX_HOME never updated. Only compare
        // identities when the caller actually verified one.
        let recanonicalized = try CodexHomeCanonicalizer().canonicalize(home.path)
        if let verifiedIdentity = home.filesystemIdentity,
           verifiedIdentity != recanonicalized.filesystemIdentity {
            throw CodexHomeCanonicalizationError.changedSinceVerification
        }

        try writeLastCodexHome(home.path)
        propagateToTmux(codexHome: home.path)

        LoggingService.shared.log(
            "CodexSwitchService: Switched CODEX_HOME to '\(home.path)'"
        )
    }

    /// Clears the persisted home and unsets CODEX_HOME in tmux. Used when
    /// the active Codex profile is unlinked or deleted.
    func clearHome() {
        guard persistsPointerFile else {
            LoggingService.shared.log(
                "CodexSwitchService: pointer-file mutation suppressed "
                + "(persistsPointerFile=false) — not removing pointer file"
            )
            unpropagateFromTmux()
            return
        }
        try? FileManager.default.removeItem(at: lastCodexHomeFile)
        unpropagateFromTmux()
    }

    /// Startup self-heal: if the persisted pointer names a directory that no
    /// longer exists, discard it rather than let a future `codex` invocation
    /// in a new tmux pane fail with "CODEX_HOME points to ... but that path
    /// does not exist." Never touches a pointer whose directory still
    /// exists — this only removes state that is already unusable.
    func discardStaleHomeIfMissing() {
        guard let path = currentHomePath() else { return }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: path, isDirectory: &isDirectory
        )
        guard !exists || !isDirectory.boolValue else { return }

        LoggingService.shared.log(
            "CodexSwitchService: discarding stale CODEX_HOME pointer "
            + "'\(path)' — directory no longer exists"
        )
        clearHome()
    }

    // MARK: - Private Helpers

    private func writeLastCodexHome(_ path: String) throws {
        guard persistsPointerFile else {
            LoggingService.shared.log(
                "CodexSwitchService: pointer-file mutation suppressed "
                + "(persistsPointerFile=false) — not writing '\(path)'"
            )
            return
        }
        let dir = lastCodexHomeFile.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        }
        try path.write(to: lastCodexHomeFile, atomically: true, encoding: .utf8)
    }

    private func propagateToTmux(codexHome: String) {
        guard propagatesToTmux else { return }

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
        guard propagatesToTmux else { return }

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
