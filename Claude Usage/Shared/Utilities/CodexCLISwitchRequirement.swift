//
//  CodexCLISwitchRequirement.swift
//  Claude Usage
//
//  Decides whether the "Terminal CLI Switching" shell snippet is required
//  or merely optional for the developer's current set of Codex profiles.
//

import Foundation

/// Whether the shell snippet that follows the selected Codex profile
/// (`CODEX_HOME` in non-tmux shells) actually needs to be installed.
///
/// The snippet only matters for terminals Codex doesn't already default
/// correctly for. Two arrangements are optional: no Codex home linked yet
/// (there is nothing for a shell to follow — showing "Required" here would
/// be both wrong and exactly the first-run friction this feature exists to
/// remove), and exactly one linked Codex home that IS Codex's own default
/// (`~/.codex`), since Codex already uses `~/.codex` whenever `CODEX_HOME`
/// is unset. Everything else — a single home somewhere else, or two or more
/// linked homes — needs the snippet so a plain shell can follow whichever
/// profile is active. This flips to `.required` the moment a second home is
/// linked or the one home moves outside `~/.codex`, so the badge always
/// tracks the actual arrangement rather than a first-run snapshot of it.
enum CodexCLISwitchRequirement: Equatable {
    case optional
    case required

    /// - Parameters:
    ///   - linkedHomePaths: The resolved physical path of every Codex
    ///     profile's linked home (unlinked profiles contribute nothing).
    ///   - defaultCodexHomePath: The resolved physical path of `~/.codex`,
    ///     or nil if it doesn't exist or isn't a directory.
    static func determine(
        linkedHomePaths: [String],
        defaultCodexHomePath: String?
    ) -> CodexCLISwitchRequirement {
        guard let onlyLinkedHomePath = linkedHomePaths.first else {
            // Nothing linked yet: there's no CODEX_HOME for a shell to
            // follow, so the snippet has nothing to do.
            return .optional
        }
        guard linkedHomePaths.count == 1,
              let defaultCodexHomePath,
              onlyLinkedHomePath == defaultCodexHomePath else {
            return .required
        }
        return .optional
    }
}

/// Resolves `~/.codex`'s physical path for prefill and CLI-switch-requirement
/// purposes. Both call sites need the same answer to the same question — is
/// there already a usable `~/.codex` directory, and what does it physically
/// resolve to — so it lives in one place rather than being reimplemented at
/// each call site.
enum CodexDefaultHomeResolver {
    /// Returns the resolved physical path of `~/.codex`, or nil if it
    /// doesn't exist or isn't a directory. Read-only: never creates,
    /// modifies, or links anything.
    static func resolvedPath(
        canonicalizer: CodexHomeCanonicalizer = CodexHomeCanonicalizer()
    ) -> String? {
        let defaultHomeURL = Constants.ClaudePaths.homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
        guard let home = try? canonicalizer.canonicalize(defaultHomeURL.path)
        else {
            return nil
        }
        return home.path
    }

    /// `~/.codex` is worth prefilling only when it's real and free: it must
    /// exist, be a directory, and not already be linked to another
    /// profile — proposing someone else's home would be worse than an
    /// empty field. Returns "" whenever prefilling isn't safe (no resolvable
    /// default, or some profile already links it); otherwise returns the
    /// resolved default path. Shared by both Codex home text-field prefills
    /// (initial setup and per-profile settings) so the rule can't drift
    /// between them.
    static func prefillCandidate(profiles: [Profile]) -> String {
        prefillCandidate(defaultHomePath: resolvedPath(), profiles: profiles)
    }

    /// Pure matching core behind `prefillCandidate(profiles:)`, split out
    /// so the "is this default already claimed?" rule is unit-testable on
    /// its own. `resolvedPath()` always consults the real `~/.codex` with
    /// no injectable override, so a test that only had the function above
    /// to call could never deterministically exercise both branches.
    static func prefillCandidate(
        defaultHomePath: String?,
        profiles: [Profile]
    ) -> String {
        guard let defaultHomePath else {
            return ""
        }
        let alreadyLinked = profiles.contains {
            $0.providerConfiguration.codexConfiguration?
                .linkedHome?.path == defaultHomePath
        }
        return alreadyLinked ? "" : defaultHomePath
    }
}
