//
//  AtomicJSONFileStore.swift
//  Claude Usage
//
//  Durable JSON persistence with verification, backup recovery, and quarantine.
//

import Darwin
import Foundation

nonisolated enum AtomicJSONFileStoreError: Error, LocalizedError {
    case invalidRelativePath(String)
    case createDirectoryFailed(URL, underlying: Error)
    case encodeFailed(underlying: Error)
    case writeTemporaryFileFailed(URL, underlying: Error)
    case verifyTemporaryFileFailed(URL, underlying: Error)
    case installFailed(URL, underlying: Error)
    case setPermissionsFailed(URL, underlying: Error)
    case readFailed(URL, underlying: Error)
    case corrupted(primary: URL, backup: URL?, underlying: Error)
    case quarantineFailed(URL, underlying: Error)
    case deleteFailed(URL, underlying: Error)
    case deleteVerificationFailed(URL)

    var errorDescription: String? {
        switch self {
        case .invalidRelativePath(let path):
            return "The storage path is not a safe relative path: \(path)"
        case .createDirectoryFailed(let url, let error):
            return "Could not create the storage directory at \(url.path): \(error.localizedDescription)"
        case .encodeFailed(let error):
            return "Could not encode JSON: \(error.localizedDescription)"
        case .writeTemporaryFileFailed(let url, let error):
            return "Could not write the temporary file at \(url.path): \(error.localizedDescription)"
        case .verifyTemporaryFileFailed(let url, let error):
            return "Could not verify the temporary file at \(url.path): \(error.localizedDescription)"
        case .installFailed(let url, let error):
            return "Could not atomically install the file at \(url.path): \(error.localizedDescription)"
        case .setPermissionsFailed(let url, let error):
            return "Could not secure permissions for \(url.path): \(error.localizedDescription)"
        case .readFailed(let url, let error):
            return "Could not read the file at \(url.path): \(error.localizedDescription)"
        case .corrupted(let primary, let backup, let error):
            let backupDescription = backup.map { " and backup \($0.path)" } ?? ""
            return "The stored JSON at \(primary.path)\(backupDescription) is corrupt: \(error.localizedDescription)"
        case .quarantineFailed(let url, let error):
            return "Could not quarantine the corrupt file at \(url.path): \(error.localizedDescription)"
        case .deleteFailed(let url, let error):
            return "Could not delete the stored file at \(url.path): \(error.localizedDescription)"
        case .deleteVerificationFailed(let url):
            return "The stored file still exists after deletion: \(url.path)"
        }
    }
}

/// Stores Codable values beneath one private directory.
///
/// Writes are staged and decoded before a same-directory POSIX rename installs
/// them atomically. The previous valid value is retained as a backup. A corrupt
/// primary is quarantined and the backup is restored automatically when possible.
nonisolated final class AtomicJSONFileStore: @unchecked Sendable {
    private let baseURL: URL
    private let fileManager: FileManager
    private let now: () -> Date
    private let makeIdentifier: () -> String
    private let renameOperation: ((URL, URL) throws -> Void)?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSRecursiveLock()

    init(
        baseURL: URL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        makeIdentifier: @escaping () -> String = { UUID().uuidString },
        renameOperation: ((URL, URL) throws -> Void)? = nil
    ) {
        self.baseURL = baseURL.standardizedFileURL
        self.fileManager = fileManager
        self.now = now
        self.makeIdentifier = makeIdentifier
        self.renameOperation = renameOperation

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    func fileURL(for relativePath: String) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw AtomicJSONFileStoreError.invalidRelativePath(relativePath)
        }

        let candidate = baseURL.appendingPathComponent(relativePath).standardizedFileURL
        let basePath = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
        guard candidate.path.hasPrefix(basePath) else {
            throw AtomicJSONFileStoreError.invalidRelativePath(relativePath)
        }
        return candidate
    }

    func write<Value: Codable>(_ value: Value, to relativePath: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let targetURL = try fileURL(for: relativePath)
        try ensurePrivateDirectory(targetURL.deletingLastPathComponent())

        let encoded: Data
        do {
            encoded = try encoder.encode(value)
        } catch {
            throw AtomicJSONFileStoreError.encodeFailed(underlying: error)
        }

        let temporaryURL = temporaryURL(for: targetURL)
        do {
            try encoded.write(to: temporaryURL, options: [])
            try setPermissions(0o600, at: temporaryURL)
        } catch let error as AtomicJSONFileStoreError {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw AtomicJSONFileStoreError.writeTemporaryFileFailed(temporaryURL, underlying: error)
        }

        do {
            _ = try decode(Value.self, from: temporaryURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw AtomicJSONFileStoreError.verifyTemporaryFileFailed(temporaryURL, underlying: error)
        }

        // Backup preparation is deliberately outside the install rollback
        // region. A failure while staging the backup must never quarantine or
        // otherwise disturb the still-valid primary.
        do {
            try preserveValidPrimaryAsBackup(Value.self, targetURL: targetURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            if let typedError = error as? AtomicJSONFileStoreError {
                throw typedError
            }
            throw AtomicJSONFileStoreError.installFailed(
                backupURL(for: targetURL),
                underlying: error
            )
        }

        var didInstallTarget = false
        do {
            try atomicRename(from: temporaryURL, to: targetURL)
            didInstallTarget = true
            try setPermissions(0o600, at: targetURL)
            _ = try decode(Value.self, from: targetURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            if didInstallTarget {
                try restoreBackupAfterFailedInstall(Value.self, targetURL: targetURL)
            }
            if let typedError = error as? AtomicJSONFileStoreError {
                throw typedError
            }
            throw AtomicJSONFileStoreError.installFailed(targetURL, underlying: error)
        }
    }

    func read<Value: Decodable>(_ type: Value.Type, from relativePath: String) throws -> Value? {
        lock.lock()
        defer { lock.unlock() }

        let targetURL = try fileURL(for: relativePath)
        guard fileManager.fileExists(atPath: targetURL.path) else {
            return nil
        }

        do {
            return try decode(type, from: targetURL)
        } catch {
            let primaryError = error
            do {
                try quarantine(targetURL)
            } catch {
                throw AtomicJSONFileStoreError.quarantineFailed(targetURL, underlying: error)
            }

            let backupURL = self.backupURL(for: targetURL)
            guard fileManager.fileExists(atPath: backupURL.path) else {
                throw AtomicJSONFileStoreError.corrupted(
                    primary: targetURL,
                    backup: nil,
                    underlying: primaryError
                )
            }

            let backupValue: Value
            do {
                backupValue = try decode(type, from: backupURL)
            } catch {
                let backupError = error
                if fileManager.fileExists(atPath: backupURL.path) {
                    do {
                        try quarantine(backupURL)
                    } catch {
                        throw AtomicJSONFileStoreError.quarantineFailed(backupURL, underlying: error)
                    }
                }
                throw AtomicJSONFileStoreError.corrupted(
                    primary: targetURL,
                    backup: backupURL,
                    underlying: backupError
                )
            }

            // A valid backup remains intact if restoration itself fails.
            try installExistingData(from: backupURL, to: targetURL, verifying: type)
            return backupValue
        }
    }

    func delete(at relativePath: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let targetURL = try fileURL(for: relativePath)
        let parentURL = targetURL.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parentURL.path) else {
            return
        }

        let backupURL = backupURL(for: targetURL)
        let ownedURLs: [URL]
        do {
            ownedURLs = try fileManager.contentsOfDirectory(
                at: parentURL,
                includingPropertiesForKeys: nil
            ).filter { url in
                let name = url.lastPathComponent
                return name == targetURL.lastPathComponent
                    || name == backupURL.lastPathComponent
                    || (name.hasPrefix(".\(targetURL.lastPathComponent).") && name.hasSuffix(".tmp"))
                    || (name.hasPrefix(".\(backupURL.lastPathComponent).") && name.hasSuffix(".tmp"))
                    || name.hasPrefix("\(targetURL.lastPathComponent).corrupt-")
                    || name.hasPrefix("\(backupURL.lastPathComponent).corrupt-")
            }
        } catch {
            throw AtomicJSONFileStoreError.deleteFailed(parentURL, underlying: error)
        }

        for url in ownedURLs {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                throw AtomicJSONFileStoreError.deleteFailed(url, underlying: error)
            }
        }
        if let remainingURL = ownedURLs.first(where: {
            fileManager.fileExists(atPath: $0.path)
        }) {
            throw AtomicJSONFileStoreError.deleteVerificationFailed(remainingURL)
        }
    }

    /// Removes an owned subtree after applying the same path containment rules
    /// as individual records. Intended for verified per-profile cleanup.
    func deleteDirectory(at relativePath: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let directoryURL = try fileURL(for: relativePath)
        guard directoryURL != baseURL,
              fileManager.fileExists(atPath: directoryURL.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: directoryURL)
        } catch {
            throw AtomicJSONFileStoreError.deleteFailed(directoryURL, underlying: error)
        }
        guard !fileManager.fileExists(atPath: directoryURL.path) else {
            throw AtomicJSONFileStoreError.deleteVerificationFailed(directoryURL)
        }
    }

    private func ensurePrivateDirectory(_ directoryURL: URL) throws {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            var currentURL = directoryURL.standardizedFileURL
            while currentURL.path.hasPrefix(baseURL.path), currentURL.path.count >= baseURL.path.count {
                try setPermissions(0o700, at: currentURL)
                if currentURL == baseURL {
                    break
                }
                currentURL.deleteLastPathComponent()
            }
        } catch let error as AtomicJSONFileStoreError {
            throw error
        } catch {
            throw AtomicJSONFileStoreError.createDirectoryFailed(directoryURL, underlying: error)
        }
    }

    private func preserveValidPrimaryAsBackup<Value: Decodable>(
        _ type: Value.Type,
        targetURL: URL
    ) throws {
        guard fileManager.fileExists(atPath: targetURL.path) else {
            return
        }

        do {
            _ = try decode(type, from: targetURL)
        } catch {
            try quarantine(targetURL)
            return
        }

        try installExistingData(
            from: targetURL,
            to: backupURL(for: targetURL),
            verifying: type
        )
    }

    private func restoreBackupAfterFailedInstall<Value: Decodable>(
        _ type: Value.Type,
        targetURL: URL
    ) throws {
        let backupURL = backupURL(for: targetURL)
        if fileManager.fileExists(atPath: targetURL.path) {
            _ = try? quarantine(targetURL)
        }
        guard fileManager.fileExists(atPath: backupURL.path) else {
            return
        }
        try installExistingData(from: backupURL, to: targetURL, verifying: type)
    }

    private func installExistingData<Value: Decodable>(
        from sourceURL: URL,
        to targetURL: URL,
        verifying type: Value.Type
    ) throws {
        let temporaryURL = temporaryURL(for: targetURL)
        do {
            let data = try Data(contentsOf: sourceURL)
            try data.write(to: temporaryURL, options: [])
            try setPermissions(0o600, at: temporaryURL)
            _ = try decode(type, from: temporaryURL)
            try atomicRename(from: temporaryURL, to: targetURL)
            try setPermissions(0o600, at: targetURL)
            _ = try decode(type, from: targetURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AtomicJSONFileStoreError.readFailed(url, underlying: error)
        }

        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw error
        }
    }

    private func atomicRename(from sourceURL: URL, to targetURL: URL) throws {
        if let renameOperation {
            try renameOperation(sourceURL, targetURL)
            return
        }
        guard Darwin.rename(sourceURL.path, targetURL.path) == 0 else {
            let code = errno
            let message = String(cString: strerror(code))
            let error = NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
            throw AtomicJSONFileStoreError.installFailed(targetURL, underlying: error)
        }
    }

    private func setPermissions(_ permissions: Int, at url: URL) throws {
        do {
            try fileManager.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: url.path
            )
        } catch {
            throw AtomicJSONFileStoreError.setPermissionsFailed(url, underlying: error)
        }
    }

    private func backupURL(for targetURL: URL) -> URL {
        targetURL.appendingPathExtension("bak")
    }

    private func temporaryURL(for targetURL: URL) -> URL {
        targetURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(targetURL.lastPathComponent).\(makeIdentifier()).tmp")
    }

    @discardableResult
    private func quarantine(_ url: URL) throws -> URL {
        let milliseconds = Int64(now().timeIntervalSince1970 * 1_000)
        let quarantineURL = url
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(url.lastPathComponent).corrupt-\(milliseconds)-\(makeIdentifier())"
            )
        do {
            try atomicRename(from: url, to: quarantineURL)
            try setPermissions(0o600, at: quarantineURL)
            return quarantineURL
        } catch {
            throw AtomicJSONFileStoreError.quarantineFailed(url, underlying: error)
        }
    }
}
