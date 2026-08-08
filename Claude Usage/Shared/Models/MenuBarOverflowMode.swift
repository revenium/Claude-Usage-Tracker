//
//  MenuBarOverflowMode.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-08-07.
//

import Foundation

/// Governs whether, and when, excess selected profiles collapse into a
/// single "+N" overflow status item.
enum MenuBarOverflowMode: Equatable {
    /// Space-aware: collapse only as many profiles as the menu bar actually
    /// lacks room for. The default for every user, including everyone
    /// upgrading from a version that had no such setting — see
    /// `DataStore.loadMenuBarOverflowMode()`.
    case automatic
    /// Every selected profile always gets its own status item; no overflow
    /// item is ever created, regardless of profile count.
    case never
    /// The pre-existing fixed-threshold behavior: once more than `count`
    /// profiles are selected, the rest collapse into one overflow item.
    case afterCount(Int)

    /// The `afterCount` threshold this app shipped with before this mode
    /// became configurable — used both as the default `N` when a user
    /// switches to "after count" mode and as the fallback if a stored
    /// threshold is ever missing or non-positive.
    static let defaultAfterCountThreshold = StatusBarUIManager.overflowThreshold

    /// Stable raw identity for persistence, independent of the associated
    /// `afterCount` value. See `DataStore.saveMenuBarOverflowMode(_:)`.
    enum StorageKind: String {
        case automatic
        case never
        case afterCount
    }

    var storageKind: StorageKind {
        switch self {
        case .automatic: return .automatic
        case .never: return .never
        case .afterCount: return .afterCount
        }
    }
}
