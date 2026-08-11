import XCTest
@testable import Claude_Usage

/// Seeds profile storage through the same explicit creation primitives used
/// by production. Tests must not rely on the ordinary metadata-save API to
/// create or remove identities.
func seedProfilesForTesting(
    _ profiles: [Profile],
    in store: ProfileStore
) throws {
    guard let first = profiles.first else {
        return
    }
    try store.createInitialProfile(first)
    var existingIDs: Set<UUID> = [first.id]
    for profile in profiles.dropFirst() {
        try store.appendProfile(
            profile,
            expectedExistingIDs: existingIDs
        )
        existingIDs.insert(profile.id)
    }
}

/// The app target uses main-actor default isolation. On the current macOS
/// XCTest runtime, releasing injected actor-isolated app services from the
/// Objective-C test thunk triggers a runtime allocator bug. Production uses
/// process-lifetime singletons, so hosted integration tests mirror that lifetime.
class HostedAppTestCase: XCTestCase {
    private static var processLifetimeServices: [AnyObject] = []

    func retain<T: AnyObject>(_ service: T) -> T {
        HostedAppTestCase.processLifetimeServices.append(service)
        return service
    }
}

final class FaultingProfileDefaults: ProfileDefaultsStore {
    var storage: [String: Any] = [:]
    var corruptNextProfileWrite = false

    func data(forKey defaultName: String) -> Data? {
        storage[defaultName] as? Data
    }

    func string(forKey defaultName: String) -> String? {
        storage[defaultName] as? String
    }

    func set(_ value: Any?, forKey defaultName: String) {
        if corruptNextProfileWrite, defaultName == "profiles_v3" {
            corruptNextProfileWrite = false
            storage[defaultName] = Data("corrupt".utf8)
        } else {
            storage[defaultName] = value
        }
    }

    func removeObject(forKey defaultName: String) {
        storage.removeValue(forKey: defaultName)
    }
}

// MARK: - Isolation from real user storage

/// In-memory stand-in for the preferences domain.
///
/// Unlike `FaultingProfileDefaults` this injects no faults; it exists purely
/// so a test never reaches `UserDefaults.standard`.
final class IsolatedProfileDefaults: ProfileDefaultsStore {
    private var storage: [String: Any] = [:]

    func data(forKey defaultName: String) -> Data? {
        storage[defaultName] as? Data
    }

    func string(forKey defaultName: String) -> String? {
        storage[defaultName] as? String
    }

    func set(_ value: Any?, forKey defaultName: String) {
        storage[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        storage.removeValue(forKey: defaultName)
    }
}

/// In-memory stand-in for the Keychain, with the same read semantics: a
/// missing item is `.absent`, never an error.
final class IsolatedProfileSecrets: ProfileSecretStore {
    private var values: [ProfileSecretLocator: String] = [:]

    func read(_ locator: ProfileSecretLocator) throws
        -> ProfileSecretReadResult {
        values[locator].map(ProfileSecretReadResult.value) ?? .absent
    }

    func write(_ value: String, to locator: ProfileSecretLocator) throws {
        values[locator] = value
    }

    func delete(_ locator: ProfileSecretLocator) throws {
        values.removeValue(forKey: locator)
    }
}

/// In-memory stand-in for per-profile usage files.
///
/// `ProfileStore` defaults this to `ProfileUsageFileStore()`, which resolves
/// to the real `~/Library/Application Support/Claude Usage/profile-data`.
/// Leaving it un-injected made "isolated" cover the defaults and the Keychain
/// but not the disk — the Codex branch of `loadProfilesWithVerifiedMigration`
/// reads it, so the isolation held only for as long as no test happened to
/// take that path.
final class IsolatedProfileUsageFiles: ProfileCurrentUsageFileStoring {
    private var usage: [UUID: ProfileCurrentUsage] = [:]

    func loadCurrentUsage(for profileID: UUID) throws -> ProfileCurrentUsage? {
        usage[profileID]
    }

    func saveCurrentUsage(
        _ value: ProfileCurrentUsage,
        for profileID: UUID
    ) throws {
        usage[profileID] = value
    }

    @discardableResult
    func updateCurrentUsage(
        for profileID: UUID,
        transform: (inout ProfileCurrentUsage) throws -> Void
    ) throws -> ProfileCurrentUsage {
        var value = usage[profileID] ?? ProfileCurrentUsage()
        try transform(&value)
        usage[profileID] = value
        return value
    }

    func deleteCurrentUsage(for profileID: UUID) throws {
        usage.removeValue(forKey: profileID)
    }

    func deleteAllData(for profileID: UUID) throws {
        usage.removeValue(forKey: profileID)
    }
}

/// A `ProfileStore` backed entirely by memory.
///
/// Every one of `ProfileStore`'s three dependencies defaults to real user
/// storage — `UserDefaults.standard`, `KeychainService.shared`, and the real
/// Application Support directory — so an un-injected store in a test reads
/// and writes all three. That is not hypothetical: a test in this suite once
/// built `ProfileManager()` on the shared store and came one step from
/// writing six live session keys into the developer's Keychain and rewriting
/// their preferences file.
///
/// All three are injected here. If `ProfileStore` ever gains a fourth
/// dependency, it must be injected too, or "isolated" quietly becomes
/// partial again.
@MainActor
func makeIsolatedProfileStore(
    defaults: IsolatedProfileDefaults = IsolatedProfileDefaults(),
    secrets: IsolatedProfileSecrets = IsolatedProfileSecrets(),
    usageFiles: IsolatedProfileUsageFiles? = nil
) -> ProfileStore {
    // Built here rather than as a default argument: default expressions are
    // evaluated in a nonisolated context, and this type is main-actor bound
    // through `ProfileCurrentUsageFileStoring`.
    ProfileStore(
        defaults: defaults,
        secretStore: secrets,
        usageFileStore: usageFiles ?? IsolatedProfileUsageFiles()
    )
}

/// A `ProfileManager` whose **profile storage** is isolated.
///
/// Prefer this over `ProfileManager()` in every test. The bare initialiser
/// resolves `profileStore` to `.shared`; nothing about the call site makes
/// that visible, which is exactly why it keeps happening.
///
/// Scope, stated precisely so the next author is not misled: only
/// `profileStore` and `activationCodexEffects` are injected here.
/// `historyService`, `cliSyncService` — which touches
/// `~/.claude/.credentials.json` — `lifecycleEventSink`, and
/// `activationClaudeEffects` still resolve to their shared, live
/// implementations. A test that activates a Codex profile through this
/// helper is safe from writing the developer's real
/// `~/.claude-tokens/.last-codex-home` pointer file or mutating their real
/// tmux server either way: `CodexSwitchService.shared` is independently
/// inert under hosted unit tests (see `AppDelegate.isRunningHostedUnitTests`
/// and `CodexSwitchService.shared`'s init). The injection here exists so
/// codex-activation assertions in this suite don't have to reason about that
/// backstop — they observe a plain counted no-op instead. A test that
/// activates a *Claude* profile still needs `activationClaudeEffects`
/// injected too; nothing here covers it.
@MainActor
func makeIsolatedProfileManager() -> ProfileManager {
    ProfileManager(
        profileStore: makeIsolatedProfileStore(),
        activationCodexEffects: .noOp
    )
}

extension ProfileActivationCodexEffects {
    /// Shared no-op used by hosted tests that don't care about codex
    /// activation side effects but must not fall through to `.live` (which
    /// routes to `CodexSwitchService.shared`).
    static var noOp: ProfileActivationCodexEffects {
        ProfileActivationCodexEffects(
            switchToLinkedHome: { _ in },
            clearHome: {}
        )
    }
}

/// Builds `profiles_v3` data in the **frozen legacy on-disk format**: the v3
/// profile record plus the `credentialMigrationRetry` plaintext envelope.
///
/// Deliberately not produced with `Profile`'s encoder. Current code cannot
/// emit that envelope — that is the whole point of the change — and legacy
/// data was written by an *older* encoder anyway. Synthesising it keeps this
/// helper pinned to the format it exists to model, instead of drifting toward
/// whatever the current encoder happens to do.
///
/// Frozen format v3. Do not "modernise" it; add a new helper if the on-disk
/// shape ever gains another legacy variant to migrate.
func legacyProfilesData(
    _ entries: [(profile: Profile, retry: ProfileCredentialMigrationRetry)]
) throws -> Data {
    var objects: [[String: Any]] = []
    for entry in entries {
        let encoded = try JSONEncoder().encode(entry.profile)
        guard var object = try JSONSerialization.jsonObject(
            with: encoded
        ) as? [String: Any] else {
            throw LegacyFixtureError.notAnObject
        }
        var envelope: [String: Any] = [:]
        if let value = entry.retry.claudeSessionKey {
            envelope["claude-session-key"] = value
        }
        if let value = entry.retry.apiSessionKey {
            envelope["api-session-key"] = value
        }
        if let value = entry.retry.cliCredentialsJSON {
            envelope["cli-credentials"] = value
        }
        if !envelope.isEmpty {
            object["credentialMigrationRetry"] = envelope
        }
        objects.append(object)
    }
    return try JSONSerialization.data(withJSONObject: objects)
}

enum LegacyFixtureError: Error {
    case notAnObject
}
