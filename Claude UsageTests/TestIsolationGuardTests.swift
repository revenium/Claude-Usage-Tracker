import XCTest
@testable import Claude_Usage

/// Isolation is a property that stops holding silently.
///
/// `ProfileStore()` resolves to `UserDefaults.standard` and
/// `KeychainService.shared`, and `ProfileManager()` resolves to the shared
/// store. Nothing at those call sites looks wrong, which is why a test in
/// this suite once built `ProfileManager()` on the shared store and came one
/// step from writing six live session keys into the developer's Keychain and
/// rewriting their preferences file.
///
/// The helpers in `HostedTestSupport` prevent that. These assert the helpers
/// actually do, so removing the injection fails here instead of quietly
/// reaching real user storage again.
/// Subclasses `HostedAppTestCase` and retains the stores it builds: releasing
/// an injected actor-isolated service from the Objective-C test thunk trips a
/// runtime allocator bug on the current macOS XCTest, which shows up as
/// `pointer being freed was not allocated` rather than as a test failure.
final class TestIsolationGuardTests: HostedAppTestCase {
    private static let profilesKey = "profiles_v3"

    /// Deliberately read-only: it seeds the *injected* defaults and checks the
    /// store reads them back. If the helper stopped injecting, the store would
    /// return the developer's real profiles and this fails — without having
    /// written anything anywhere.
    func testTheIsolatedStoreReadsInjectedDefaultsNotTheRealOnes() throws {
        let defaults = IsolatedProfileDefaults()
        let marker = "Isolated-\(UUID().uuidString)"
        defaults.set(
            try JSONEncoder().encode([Profile(name: marker)]),
            forKey: Self.profilesKey
        )
        let store = retain(makeIsolatedProfileStore(defaults: defaults))

        let profiles = try store.loadProfilesWithVerifiedMigration()

        XCTAssertEqual(
            profiles.map(\.name),
            [marker],
            "The store read something other than the injected defaults — "
                + "isolation is not in effect"
        )
    }

    /// The real preferences domain must be untouched by the above.
    func testTheIsolatedStoreDoesNotWriteToRealDefaults() throws {
        let before = UserDefaults.standard.data(forKey: Self.profilesKey)
        let defaults = IsolatedProfileDefaults()
        defaults.set(
            try JSONEncoder().encode([Profile(name: "Isolated")]),
            forKey: Self.profilesKey
        )

        _ = try retain(makeIsolatedProfileStore(defaults: defaults))
            .loadProfilesWithVerifiedMigration()

        XCTAssertEqual(
            UserDefaults.standard.data(forKey: Self.profilesKey),
            before,
            "A test mutated the real preferences domain"
        )
    }

    /// Secrets go to memory, never the login Keychain.
    func testTheIsolatedSecretStoreKeepsSecretsInMemory() throws {
        let secrets = retain(IsolatedProfileSecrets())
        let locator = ProfileSecretLocator(
            profileID: UUID(),
            field: .claudeSessionKey
        )

        try secrets.write("sk-ant-sid01-ISOLATION-CHECK", to: locator)

        XCTAssertEqual(
            try secrets.read(locator),
            .value("sk-ant-sid01-ISOLATION-CHECK")
        )
        // A missing item is absent, not an error — the same distinction the
        // real store makes, and the one whose absence caused the original
        // rollback bug.
        XCTAssertEqual(
            try secrets.read(
                ProfileSecretLocator(profileID: UUID(), field: .apiSessionKey)
            ),
            .absent
        )
    }

    /// A manager from the helper must not be sitting on the shared store.
    @MainActor
    func testTheIsolatedManagerDoesNotSeeRealProfiles() throws {
        let manager = retain(makeIsolatedProfileManager())

        // The shared store is the developer's real profile list, which on any
        // configured machine is non-empty. A freshly injected in-memory store
        // has nothing in it.
        XCTAssertTrue(
            manager.profiles.isEmpty,
            "The manager loaded profiles from somewhere — expected an empty "
                + "in-memory store, got \(manager.profiles.count)"
        )
    }
}
