import CloudKit
import Foundation

enum ICloudBackupError: LocalizedError, Equatable {
    case accountUnavailable
    case malformedBackup

    var errorDescription: String? {
        switch self {
        case .accountUnavailable: return L.text("icloud.error.account")
        case .malformedBackup: return L.text("icloud.error.malformed")
        }
    }
}

/// CloudKit private-database storage for the user's complete Strivory archive.
/// A private database is scoped to the signed-in iCloud account and is never a
/// shared/public app database.
actor CloudBackupService: CloudBackupProviding {
    static let containerIdentifier = "iCloud.com.pananq.strivory"

    private let container = CKContainer(identifier: containerIdentifier)
    private let recordID = CKRecord.ID(recordName: "strivory-backup-v1")
    private let recordType = "StrivoryBackup"
    private let payloadField = "payload"

    func isAccountAvailable() async -> Bool {
        do {
            return try await container.accountStatus() == .available
        } catch {
            return false
        }
    }

    func load() async throws -> ICloudBackupSnapshot? {
        guard try await container.accountStatus() == .available else {
            throw ICloudBackupError.accountUnavailable
        }
        guard let record = try await loadRecord() else { return nil }
        return try decode(record)
    }

    private func loadRecord() async throws -> CKRecord? {
        do {
            return try await container.privateCloudDatabase.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private func decode(_ record: CKRecord) throws -> ICloudBackupSnapshot {
        guard let asset = record[payloadField] as? CKAsset, let fileURL = asset.fileURL else {
            throw ICloudBackupError.malformedBackup
        }
        return try JSONDecoder().decode(ICloudBackupSnapshot.self, from: Data(contentsOf: fileURL))
    }

    func sync(local: ICloudBackupSnapshot) async throws -> ICloudBackupSnapshot {
        guard try await container.accountStatus() == .available else {
            throw ICloudBackupError.accountUnavailable
        }

        for attempt in 0..<3 {
            let serverRecord = try await loadRecord()
            let remote = try serverRecord.map { try decode($0) }
            let merged = ICloudBackupSnapshot.merging(local: local, remote: remote)
            let record = serverRecord ?? CKRecord(recordType: recordType, recordID: recordID)
            do {
                // Save the SAME revision whose payload was merged. Fetching a
                // fresh change tag here would silently overwrite another device.
                try await save(merged, to: record)
                return merged
            } catch let error as CKError where error.code == .serverRecordChanged && attempt < 2 {
                continue
            }
        }
        throw CKError(.serverRecordChanged)
    }

    private func save(_ snapshot: ICloudBackupSnapshot, to record: CKRecord) async throws {
        let data = try JSONEncoder().encode(snapshot)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("strivory-cloud-backup", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("\(UUID().uuidString).json")
        try data.write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        record[payloadField] = CKAsset(fileURL: fileURL)
        record["updatedAt"] = snapshot.updatedAt as NSDate
        record["schemaVersion"] = snapshot.schemaVersion as NSNumber
        let result = try await container.privateCloudDatabase.modifyRecords(
            saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true
        )
        guard let saved = result.saveResults[record.recordID] else { throw ICloudBackupError.malformedBackup }
        _ = try saved.get()
    }
}
