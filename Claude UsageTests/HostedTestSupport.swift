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
