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
