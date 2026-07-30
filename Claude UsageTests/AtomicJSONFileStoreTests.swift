import Darwin
import Foundation
import XCTest
@testable import Claude_Usage

final class AtomicJSONFileStoreTests: XCTestCase {
    nonisolated private enum InjectedFailure: Error {
        case expected
    }

    nonisolated private struct Fixture: Codable, Equatable {
        let value: String
    }

    nonisolated private struct CannotDecode: Codable {
        nonisolated private enum TestError: Error {
            case expected
        }

        init() {}

        init(from decoder: Decoder) throws {
            throw TestError.expected
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode("encoded")
        }
    }

    func testWriteLoadAndPrivatePermissions() throws {
        let rootURL = try makeTemporaryRoot()
        let store = AtomicJSONFileStore(baseURL: rootURL)

        try store.write(Fixture(value: "saved"), to: "profile/history.json")

        let loaded = try store.read(Fixture.self, from: "profile/history.json")
        XCTAssertEqual(loaded, Fixture(value: "saved"))

        let fileURL = try store.fileURL(for: "profile/history.json")
        XCTAssertEqual(try permissions(at: rootURL), 0o700)
        XCTAssertEqual(try permissions(at: fileURL.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try permissions(at: fileURL), 0o600)
    }

    func testCorruptPrimaryIsQuarantinedAndBackupIsRestored() throws {
        let rootURL = try makeTemporaryRoot()
        let store = AtomicJSONFileStore(
            baseURL: rootURL,
            now: { Date(timeIntervalSince1970: 123) },
            makeIdentifier: { UUID().uuidString }
        )
        let relativePath = "profile/history.json"

        try store.write(Fixture(value: "first"), to: relativePath)
        try store.write(Fixture(value: "second"), to: relativePath)

        let fileURL = try store.fileURL(for: relativePath)
        try Data("{not-json".utf8).write(to: fileURL)

        let recovered = try store.read(Fixture.self, from: relativePath)
        XCTAssertEqual(recovered, Fixture(value: "first"))
        XCTAssertEqual(try store.read(Fixture.self, from: relativePath), Fixture(value: "first"))

        let names = try FileManager.default.contentsOfDirectory(
            atPath: fileURL.deletingLastPathComponent().path
        )
        let quarantineName = try XCTUnwrap(
            names.first { $0.hasPrefix("history.json.corrupt-123000-") }
        )
        XCTAssertTrue(names.contains("history.json.bak"))
        XCTAssertEqual(
            try permissions(
                at: fileURL.deletingLastPathComponent().appendingPathComponent(quarantineName)
            ),
            0o600
        )
        XCTAssertEqual(try permissions(at: fileURL.appendingPathExtension("bak")), 0o600)
    }

    func testCorruptPrimaryWithoutBackupIsQuarantinedAndThrowsTypedError() throws {
        let rootURL = try makeTemporaryRoot()
        let store = AtomicJSONFileStore(
            baseURL: rootURL,
            now: { Date(timeIntervalSince1970: 321) },
            makeIdentifier: { "test-id" }
        )
        let fileURL = try store.fileURL(for: "profile/history.json")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("invalid".utf8).write(to: fileURL)

        XCTAssertThrowsError(try store.read(Fixture.self, from: "profile/history.json")) { error in
            guard case AtomicJSONFileStoreError.corrupted(let primary, let backup, _) = error else {
                return XCTFail("Expected corrupted error, got \(error)")
            }
            XCTAssertEqual(primary, fileURL)
            XCTAssertNil(backup)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fileURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("history.json.corrupt-321000-test-id")
                    .path
            )
        )
    }

    func testFailedTemporaryDecodeNeverInstallsTarget() throws {
        let rootURL = try makeTemporaryRoot()
        let store = AtomicJSONFileStore(baseURL: rootURL)
        let fileURL = try store.fileURL(for: "profile/history.json")

        XCTAssertThrowsError(try store.write(CannotDecode(), to: "profile/history.json")) { error in
            guard case AtomicJSONFileStoreError.verifyTemporaryFileFailed = error else {
                return XCTFail("Expected temporary verification error, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let remainingNames = try FileManager.default.contentsOfDirectory(
            atPath: fileURL.deletingLastPathComponent().path
        )
        XCTAssertFalse(remainingNames.contains { $0.hasSuffix(".tmp") })
    }

    func testBackupPreparationFailureLeavesValidPrimaryOnline() throws {
        let rootURL = try makeTemporaryRoot()
        let relativePath = "profile/history.json"
        let originalStore = AtomicJSONFileStore(baseURL: rootURL)
        try originalStore.write(Fixture(value: "original"), to: relativePath)

        var attemptedTargetInstall = false
        let failingStore = AtomicJSONFileStore(
            baseURL: rootURL,
            renameOperation: { _, targetURL in
                if targetURL.pathExtension == "bak" {
                    throw InjectedFailure.expected
                }
                attemptedTargetInstall = true
                throw InjectedFailure.expected
            }
        )

        XCTAssertThrowsError(
            try failingStore.write(Fixture(value: "replacement"), to: relativePath)
        )
        XCTAssertFalse(attemptedTargetInstall)
        XCTAssertEqual(
            try originalStore.read(Fixture.self, from: relativePath),
            Fixture(value: "original")
        )

        let fileURL = try originalStore.fileURL(for: relativePath)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: fileURL.deletingLastPathComponent().path
        )
        XCTAssertTrue(names.contains(fileURL.lastPathComponent))
        XCTAssertFalse(names.contains { $0.contains(".corrupt-") })
        XCTAssertFalse(names.contains { $0.hasSuffix(".tmp") })
    }

    func testTargetRenameFailureLeavesValidPrimaryOnline() throws {
        let rootURL = try makeTemporaryRoot()
        let relativePath = "profile/history.json"
        let originalStore = AtomicJSONFileStore(baseURL: rootURL)
        try originalStore.write(Fixture(value: "original"), to: relativePath)

        let failingStore = AtomicJSONFileStore(
            baseURL: rootURL,
            renameOperation: { sourceURL, targetURL in
                guard targetURL.pathExtension == "bak" else {
                    throw InjectedFailure.expected
                }
                guard Darwin.rename(sourceURL.path, targetURL.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        )

        XCTAssertThrowsError(
            try failingStore.write(Fixture(value: "replacement"), to: relativePath)
        )
        XCTAssertEqual(
            try originalStore.read(Fixture.self, from: relativePath),
            Fixture(value: "original")
        )

        let fileURL = try originalStore.fileURL(for: relativePath)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: fileURL.deletingLastPathComponent().path
        )
        XCTAssertTrue(names.contains(fileURL.lastPathComponent))
        XCTAssertTrue(names.contains(fileURL.appendingPathExtension("bak").lastPathComponent))
        XCTAssertFalse(names.contains { $0.contains(".corrupt-") })
        XCTAssertFalse(names.contains { $0.hasSuffix(".tmp") })
    }

    func testRejectsPathsOutsideBaseDirectory() throws {
        let store = AtomicJSONFileStore(baseURL: try makeTemporaryRoot())

        for path in ["", "/tmp/value.json", "../value.json", "profile/../value.json"] {
            XCTAssertThrowsError(try store.fileURL(for: path)) { error in
                guard case AtomicJSONFileStoreError.invalidRelativePath = error else {
                    return XCTFail("Expected invalid path error for \(path), got \(error)")
                }
            }
        }
    }

    private func makeTemporaryRoot() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtomicJSONFileStoreTests-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }
        return rootURL
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}
