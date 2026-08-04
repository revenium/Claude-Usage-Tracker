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

/// A `ProfileStore` backed entirely by memory.
///
/// `ProfileStore()` defaults to `UserDefaults.standard` **and
/// `KeychainService.shared`**, so an un-injected store in a test reads and
/// writes the real user's profiles and the real login Keychain. That is not
/// hypothetical: a test in this suite once built `ProfileManager()` on the
/// shared store and came one step from writing six live session keys into the
/// developer's Keychain and rewriting their preferences file.
func makeIsolatedProfileStore(
    defaults: IsolatedProfileDefaults = IsolatedProfileDefaults(),
    secrets: IsolatedProfileSecrets = IsolatedProfileSecrets()
) -> ProfileStore {
    ProfileStore(defaults: defaults, secretStore: secrets)
}

/// A `ProfileManager` that cannot reach real user storage.
///
/// Prefer this over `ProfileManager()` in every test. The bare initialiser
/// resolves `profileStore` to `.shared`; nothing about the call site makes
/// that visible, which is exactly why it keeps happening.
@MainActor
func makeIsolatedProfileManager() -> ProfileManager {
    ProfileManager(profileStore: makeIsolatedProfileStore())
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
