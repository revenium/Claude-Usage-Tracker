//
//  QuitCredentialGuard.swift
//  Claude Usage
//

import Foundation

/// Decides what quitting should do when credentials are only in memory.
///
/// A credential the Keychain refused is usable for the session and gone at
/// quit. This is the last moment it can still be saved, so quitting attempts
/// one final write and only then asks the user to confirm losing whatever
/// remains.
///
/// Pure on purpose: the policy is unit-testable without driving AppKit, and
/// `AppDelegate` only executes the outcome.
nonisolated enum QuitCredentialGuard {
    enum Outcome: Equatable {
        /// Nothing is being held — quit without bothering the user. Also the
        /// outcome when the final write rescued everything, which is the
        /// common case and deliberately silent.
        case terminate
        /// Credentials would be lost. Names are the complete list, in the
        /// caller's profile order.
        case confirm(accountNames: [String])
    }

    /// - Parameters:
    ///   - remaining: profiles still holding a credential *after* the final
    ///     write attempt. Deciding on the pre-retry set would nag about
    ///     credentials that were just rescued.
    ///   - orderedProfiles: every known profile, in display order, so the
    ///     confirmation lists names the same way the rest of the UI does.
    static func outcome(
        remaining: Set<UUID>,
        orderedProfiles: [(id: UUID, name: String)]
    ) -> Outcome {
        guard !remaining.isEmpty else {
            return .terminate
        }
        let names = orderedProfiles
            .filter { remaining.contains($0.id) }
            .map(\.name)
        // No is-empty guard, and none is needed: `.terminate` already
        // returned above for an empty `remaining`, so a held credential whose
        // profile has since disappeared confirms with no names rather than
        // slipping through. A guard here would just return what this line
        // returns.
        return .confirm(accountNames: names)
    }
}
