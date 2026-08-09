//
//  ProfileUsageFileStore.swift
//  Claude Usage
//
//  Provider-neutral, versioned per-profile usage persistence.
//

import Foundation
import UsageCore

nonisolated enum ProfileUsageRecordKind: String, Codable {
    case currentUsage = "current-usage"
    case history
}

nonisolated struct ProfileUsageFileEnvelope<Payload: Codable>: Codable {
    static var currentSchemaVersion: Int { 1 }

    let schemaVersion: Int
    let profileID: UUID
    let providerID: String
    let recordKind: ProfileUsageRecordKind
    let writtenAt: Date
    let updatedAt: Date
    let payload: Payload

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        profileID: UUID,
        providerID: String,
        recordKind: ProfileUsageRecordKind,
        writtenAt: Date,
        updatedAt: Date,
        payload: Payload
    ) {
        self.schemaVersion = schemaVersion
        self.profileID = profileID
        self.providerID = providerID
        self.recordKind = recordKind
        self.writtenAt = writtenAt
        self.updatedAt = updatedAt
        self.payload = payload
    }
}

nonisolated enum ProfileUsageFileStoreError: Error, LocalizedError {
    case invalidProviderID
    case currentUsageReadUnresolved(UUID)
    case currentUsageWriteVerificationFailed(UUID)
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case profileMismatch(expected: UUID, found: UUID)
    case providerMismatch(expected: String, found: String)
    case recordKindMismatch(expected: ProfileUsageRecordKind, found: ProfileUsageRecordKind)
    case invalidTimestampChronology(writtenAt: Date, updatedAt: Date)

    var errorDescription: String? {
        switch self {
        case .invalidProviderID:
            return "A provider identifier is required for profile usage storage."
        case .currentUsageReadUnresolved(let profileID):
            return "Current usage is unresolved for profile \(profileID.uuidString.prefix(8))."
        case .currentUsageWriteVerificationFailed(let profileID):
            return "Current usage could not be verified for profile \(profileID)."
        case .unsupportedSchemaVersion(let found, let supported):
            return "Usage storage schema \(found) is unsupported; expected \(supported)."
        case .profileMismatch(let expected, let found):
            return "Usage storage belongs to profile \(found), not \(expected)."
        case .providerMismatch(let expected, let found):
            return "Usage storage belongs to provider \(found), not \(expected)."
        case .recordKindMismatch(let expected, let found):
            return "Usage storage contains \(found.rawValue), not \(expected.rawValue)."
        case .invalidTimestampChronology(let writtenAt, let updatedAt):
            return "Usage storage was updated at \(updatedAt) before it was written at \(writtenAt)."
        }
    }
}

/// Narrow integration surface used by ProfileStore. Keeping the generic file
/// store behind typed operations makes failure behavior directly testable and
/// prevents metadata persistence from manipulating usage records.
@MainActor
protocol ProfileCurrentUsageFileStoring: AnyObject {
    func loadCurrentUsage(for profileID: UUID) throws -> ProfileCurrentUsage?
    func saveCurrentUsage(_ usage: ProfileCurrentUsage, for profileID: UUID) throws

    @discardableResult
    func updateCurrentUsage(
        for profileID: UUID,
        transform: (inout ProfileCurrentUsage) throws -> Void
    ) throws -> ProfileCurrentUsage

    func deleteCurrentUsage(for profileID: UUID) throws
    func deleteAllData(for profileID: UUID) throws
}

/// Typed facade over AtomicJSONFileStore for per-profile provider data.
///
/// `update` serializes read-modify-write operations so independent refresh paths
/// cannot silently discard one another's history additions.
nonisolated final class ProfileUsageFileStore: @unchecked Sendable {
    private let atomicStore: AtomicJSONFileStore
    private let now: () -> Date
    private let updateLock = NSRecursiveLock()

    convenience init(
        baseURL: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        let rootURL: URL
        if let baseURL {
            rootURL = baseURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
            rootURL = applicationSupport
                .appendingPathComponent(
                    "Claude Usage" + AppBuildVariant.pathSuffix,
                    isDirectory: true
                )
                .appendingPathComponent("profile-data", isDirectory: true)
        }

        self.init(
            atomicStore: AtomicJSONFileStore(
                baseURL: rootURL,
                fileManager: fileManager,
                now: now
            ),
            now: now
        )
    }

    init(atomicStore: AtomicJSONFileStore, now: @escaping () -> Date = Date.init) {
        self.atomicStore = atomicStore
        self.now = now
    }

    func save<Payload: Codable>(
        _ payload: Payload,
        for profileID: UUID,
        providerID: String,
        kind: ProfileUsageRecordKind
    ) throws {
        updateLock.lock()
        defer { updateLock.unlock() }

        let providerID = try validatedProviderID(providerID)
        let relativePath = relativePath(for: profileID, kind: kind)
        let envelopeType = ProfileUsageFileEnvelope<Payload>.self
        let timestamp = now()
        let existingEnvelope = try atomicStore.read(envelopeType, from: relativePath)
        if let existingEnvelope {
            try validate(
                existingEnvelope,
                profileID: profileID,
                providerID: providerID,
                kind: kind
            )
        }
        let writtenAt = existingEnvelope?.writtenAt ?? timestamp
        let envelope = ProfileUsageFileEnvelope(
            profileID: profileID,
            providerID: providerID,
            recordKind: kind,
            writtenAt: writtenAt,
            updatedAt: max(timestamp, writtenAt),
            payload: payload
        )
        try atomicStore.write(envelope, to: relativePath)
    }

    func load<Payload: Codable>(
        _ type: Payload.Type,
        for profileID: UUID,
        providerID: String,
        kind: ProfileUsageRecordKind
    ) throws -> Payload? {
        updateLock.lock()
        defer { updateLock.unlock() }

        let providerID = try validatedProviderID(providerID)
        let envelopeType = ProfileUsageFileEnvelope<Payload>.self
        guard let envelope = try atomicStore.read(
            envelopeType,
            from: relativePath(for: profileID, kind: kind)
        ) else {
            return nil
        }

        try validate(
            envelope,
            profileID: profileID,
            providerID: providerID,
            kind: kind
        )
        return envelope.payload
    }

    private func validate<Payload: Codable>(
        _ envelope: ProfileUsageFileEnvelope<Payload>,
        profileID: UUID,
        providerID: String,
        kind: ProfileUsageRecordKind
    ) throws {
        guard envelope.schemaVersion == ProfileUsageFileEnvelope<Payload>.currentSchemaVersion else {
            throw ProfileUsageFileStoreError.unsupportedSchemaVersion(
                found: envelope.schemaVersion,
                supported: ProfileUsageFileEnvelope<Payload>.currentSchemaVersion
            )
        }
        guard envelope.profileID == profileID else {
            throw ProfileUsageFileStoreError.profileMismatch(
                expected: profileID,
                found: envelope.profileID
            )
        }
        guard envelope.providerID == providerID else {
            throw ProfileUsageFileStoreError.providerMismatch(
                expected: providerID,
                found: envelope.providerID
            )
        }
        guard envelope.recordKind == kind else {
            throw ProfileUsageFileStoreError.recordKindMismatch(
                expected: kind,
                found: envelope.recordKind
            )
        }
        guard envelope.updatedAt >= envelope.writtenAt else {
            throw ProfileUsageFileStoreError.invalidTimestampChronology(
                writtenAt: envelope.writtenAt,
                updatedAt: envelope.updatedAt
            )
        }
    }

    /// Loads, transforms, and saves `Payload` under the profile lock.
    ///
    /// Skips the save entirely when `transform` leaves the payload
    /// unchanged. A full save re-encodes and rewrites the whole file plus
    /// its `.bak` copy, which is wasted work for a no-op transform — and
    /// `HistorySnapshotAdmission` deliberately makes rejected-write no-ops
    /// common, so this turns a rejected history record into zero disk I/O
    /// instead of a full file rewrite.
    @discardableResult
    func update<Payload: Codable & Equatable>(
        _ type: Payload.Type,
        for profileID: UUID,
        providerID: String,
        kind: ProfileUsageRecordKind,
        initialValue: @autoclosure () -> Payload,
        transform: (inout Payload) throws -> Void
    ) throws -> Payload {
        updateLock.lock()
        defer { updateLock.unlock() }

        let original = try load(
            type,
            for: profileID,
            providerID: providerID,
            kind: kind
        ) ?? initialValue()
        var payload = original
        try transform(&payload)
        guard payload != original else {
            return payload
        }
        try save(payload, for: profileID, providerID: providerID, kind: kind)
        return payload
    }

    func delete(for profileID: UUID, kind: ProfileUsageRecordKind) throws {
        updateLock.lock()
        defer { updateLock.unlock() }
        try atomicStore.delete(at: relativePath(for: profileID, kind: kind))
    }

    /// Removes every durable record and recovery artifact owned by a profile.
    /// The throwing contract lets profile deletion avoid reporting success or
    /// clearing legacy sources after a partial filesystem failure.
    func deleteAllData(for profileID: UUID) throws {
        updateLock.lock()
        defer { updateLock.unlock() }
        try atomicStore.deleteDirectory(at: profileDirectoryPath(for: profileID))
    }

    func fileURL(for profileID: UUID, kind: ProfileUsageRecordKind) throws -> URL {
        try atomicStore.fileURL(for: relativePath(for: profileID, kind: kind))
    }

    private func validatedProviderID(_ providerID: String) throws -> String {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProfileUsageFileStoreError.invalidProviderID
        }
        return trimmed
    }

    private func relativePath(for profileID: UUID, kind: ProfileUsageRecordKind) -> String {
        let filename: String
        switch kind {
        case .currentUsage:
            filename = "current-v1.json"
        case .history:
            filename = "history-v1.json"
        }
        return "\(profileDirectoryPath(for: profileID))/\(filename)"
    }

    private func profileDirectoryPath(for profileID: UUID) -> String {
        profileID.uuidString.lowercased()
    }
}

extension ProfileUsageFileStore: ProfileCurrentUsageFileStoring {
    func loadCurrentUsage(for profileID: UUID) throws -> ProfileCurrentUsage? {
        updateLock.lock()
        defer { updateLock.unlock() }

        let envelopeType =
            ProfileUsageFileEnvelope<ProfileCurrentUsage>.self
        let envelope = try atomicStore.read(
            envelopeType,
            from: relativePath(for: profileID, kind: .currentUsage)
        )
        let usage: ProfileCurrentUsage?
        if let envelope {
            let envelopeProviderID = try validatedProviderID(
                envelope.providerID
            )
            try validate(
                envelope,
                profileID: profileID,
                providerID: envelopeProviderID,
                kind: .currentUsage
            )
            let providerID = try ProviderID(envelopeProviderID)
            try envelope.payload.validate(
                expectedProviderID: providerID,
                expectedProviderRevision:
                    envelope.payload.providerRevision
            )
            usage = envelope.payload
        } else {
            usage = nil
        }
        if usage == nil, try hasCurrentUsageRecoveryArtifacts(for: profileID) {
            // AtomicJSONFileStore quarantines an unreadable primary. Its
            // absence on a later read must not become permission to replace
            // unresolved data with an empty payload.
            throw ProfileUsageFileStoreError.currentUsageReadUnresolved(profileID)
        }
        return usage
    }

    func saveCurrentUsage(_ usage: ProfileCurrentUsage, for profileID: UUID) throws {
        try usage.validate(
            expectedProviderID: usage.providerID,
            expectedProviderRevision: usage.providerRevision
        )
        try save(
            usage,
            for: profileID,
            providerID: usage.providerID.rawValue,
            kind: .currentUsage
        )
        guard try loadCurrentUsage(for: profileID) == usage else {
            throw ProfileUsageFileStoreError.currentUsageWriteVerificationFailed(profileID)
        }
    }

    func deleteCurrentUsage(for profileID: UUID) throws {
        try delete(for: profileID, kind: .currentUsage)
        guard try loadCurrentUsage(for: profileID) == nil else {
            throw ProfileUsageFileStoreError
                .currentUsageWriteVerificationFailed(profileID)
        }
    }

    @discardableResult
    func updateCurrentUsage(
        for profileID: UUID,
        transform: (inout ProfileCurrentUsage) throws -> Void
    ) throws -> ProfileCurrentUsage {
        updateLock.lock()
        defer { updateLock.unlock() }

        var updated = try loadCurrentUsage(for: profileID)
            ?? ProfileCurrentUsage()
        try transform(&updated)
        try saveCurrentUsage(updated, for: profileID)
        guard try loadCurrentUsage(for: profileID) == updated else {
            throw ProfileUsageFileStoreError.currentUsageWriteVerificationFailed(profileID)
        }
        return updated
    }

    private func hasCurrentUsageRecoveryArtifacts(for profileID: UUID) throws -> Bool {
        let currentURL = try fileURL(for: profileID, kind: .currentUsage)
        let directoryURL = currentURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return false
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
        let filename = currentURL.lastPathComponent
        return names.contains { name in
            name == "\(filename).bak"
                || name.hasPrefix("\(filename).corrupt-")
                || (name.hasPrefix(".\(filename).") && name.hasSuffix(".tmp"))
                || (name.hasPrefix(".\(filename).bak.") && name.hasSuffix(".tmp"))
        }
    }
}
