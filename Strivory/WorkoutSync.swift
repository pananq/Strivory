import Foundation

enum HealthPersistenceError: LocalizedError {
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let detail): L.text("health.storageFailure", detail)
        }
    }
}

struct HealthKitFetchResult: Sendable {
    let workouts: [WorkoutRecord]
    let deletedWorkoutIDs: Set<UUID>
    let anchorData: Data
}

@MainActor
protocol HealthKitProviding {
    func requestAuthorization() async throws
    func fetchWorkouts(anchorData: Data?) async throws -> HealthKitFetchResult
}

protocol CloudBackupProviding: Sendable {
    func isAccountAvailable() async -> Bool
    func load() async throws -> ICloudBackupSnapshot?
    func sync(local: ICloudBackupSnapshot) async throws -> ICloudBackupSnapshot
}

/// Records, deletion evidence and the device-local query anchor are one atomic
/// checkpoint. An anchor must never advance without its corresponding data.
struct PersistedHealthState: Codable {
    static let currentReconciliationVersion = 1

    var records: [WorkoutRecord]
    var deletedWorkoutIDs: Set<UUID>
    var anchorData: Data?
    var reconciliationVersion: Int

    func applying(_ result: HealthKitFetchResult, isFullRefresh: Bool) -> Self {
        let deleted = deletedWorkoutIDs.union(result.deletedWorkoutIDs)
        var byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for record in result.workouts { byID[record.id] = record }
        for id in deleted { byID.removeValue(forKey: id) }
        return Self(
            records: byID.values.sorted { $0.startDate < $1.startDate },
            deletedWorkoutIDs: deleted,
            anchorData: result.anchorData,
            reconciliationVersion: isFullRefresh ? Self.currentReconciliationVersion : reconciliationVersion
        )
    }
}

extension ICloudBackupSnapshot {
    /// Merge again against CURRENT local state after every network suspension.
    /// A stable HealthKit UUID can never be resurrected after a known deletion.
    static func merging(local: Self, remote: Self?) -> Self {
        let deletedHealthIDs = local.deletedHealthWorkoutIDs.union(remote?.deletedHealthWorkoutIDs ?? [])
        var deletedBatches = remote?.deletedBatchDates ?? [:]
        for (id, date) in local.deletedBatchDates {
            deletedBatches[id] = max(deletedBatches[id] ?? .distantPast, date)
        }

        var batches = Dictionary((remote?.importBatches ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for batch in local.importBatches {
            if let existing = batches[batch.id], existing.createdAt > batch.createdAt { continue }
            batches[batch.id] = batch
        }
        let activeBatches = batches.values.filter { batch in
            guard let deletedAt = deletedBatches[batch.id.uuidString] else { return true }
            return deletedAt < batch.createdAt
        }

        var health = Dictionary((remote?.healthArchive ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for record in local.healthArchive { health[record.id] = record }
        for id in deletedHealthIDs { health.removeValue(forKey: id) }

        let profile = remote.map { local.displayNameUpdatedAt >= $0.displayNameUpdatedAt ? local : $0 } ?? local
        return Self(
            schemaVersion: max(currentSchemaVersion, max(local.schemaVersion, remote?.schemaVersion ?? 0)),
            updatedAt: .now,
            healthArchive: health.values.sorted { $0.startDate < $1.startDate },
            importBatches: activeBatches.sorted { $0.createdAt < $1.createdAt },
            deletedBatchDates: deletedBatches,
            displayName: profile.displayName,
            displayNameUpdatedAt: profile.displayNameUpdatedAt,
            deletedHealthWorkoutIDs: deletedHealthIDs
        )
    }

    // Version 1 backups do not have Workout tombstones. Preserve their data and
    // decode missing tombstones as empty; the CloudKit record fields stay unchanged.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        healthArchive = try values.decode([WorkoutRecord].self, forKey: .healthArchive)
        importBatches = try values.decode([CSVImportBatch].self, forKey: .importBatches)
        deletedBatchDates = try values.decode([String: Date].self, forKey: .deletedBatchDates)
        displayName = try values.decode(String.self, forKey: .displayName)
        displayNameUpdatedAt = try values.decode(Date.self, forKey: .displayNameUpdatedAt)
        deletedHealthWorkoutIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .deletedHealthWorkoutIDs) ?? []
    }
}
