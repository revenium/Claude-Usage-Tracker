import Foundation

/// A provider-neutral request for a specific settings destination.
///
/// Menu and status-item code can issue these requests without depending on the
/// concrete settings sidebar. The settings composition root owns the mapping to
/// its current view hierarchy.
enum SettingsNavigationDestination: Equatable, Hashable, Sendable {
    case defaultView
    case providerAccount(profileID: UUID)
    case appearance(profileID: UUID)
    case general(profileID: UUID)
    case history(profileID: UUID)
    /// Settings → CLI Account for one profile. The popover's invitation to
    /// connect a Claude Code account lands here.
    case cliAccount(profileID: UUID)
    case manageProfiles
}
