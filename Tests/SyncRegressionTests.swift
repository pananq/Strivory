import Foundation

// Runs the production AppStore and merge/persistence code with deterministic
// HealthKit/CloudKit substitutes. No Health permissions or iCloud writes needed.
@MainActor
private final class FakeHealthKit: HealthKitProviding {
    var results: [HealthKitFetchResult] = []
    var requestedAnchors: [Data?] = []

    func requestAuthorization() async throws {}

    func fetchWorkouts(anchorData: Data?) async throws -> HealthKitFetchResult {
        requestedAnchors.append(anchorData)
        precondition(!results.isEmpty, "Unexpected HealthKit query")
        return results.removeFirst()
    }
}

private actor FakeCloud: CloudBackupProviding {
    var remote: ICloudBackupSnapshot?
    private var pauseNext = false
    private var pauseLoad = false
    private var blocked = false
    private var gate: CheckedContinuation<Void, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var completedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var completedSyncs = 0

    init(remote: ICloudBackupSnapshot? = nil) { self.remote = remote }
    func isAccountAvailable() async -> Bool { true }
    func pauseNextSync() { pauseNext = true }
    func pauseNextLoad() { pauseLoad = true }

    func load() async throws -> ICloudBackupSnapshot? {
        let captured = remote
        if pauseLoad {
            pauseLoad = false
            await block()
        }
        return captured
    }

    func sync(local: ICloudBackupSnapshot) async throws -> ICloudBackupSnapshot {
        let captured = ICloudBackupSnapshot.merging(local: local, remote: remote)
        if pauseNext {
            pauseNext = false
            await block()
        }
        remote = captured
        completedSyncs += 1
        let ready = completedWaiters.filter { completedSyncs >= $0.0 }
        completedWaiters.removeAll { completedSyncs >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
        return captured
    }

    private func block() async {
        await withCheckedContinuation { continuation in
            gate = continuation
            blocked = true
            for waiter in startedWaiters { waiter.resume() }
            startedWaiters.removeAll()
        }
    }

    func waitUntilBlocked() async {
        if blocked { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        blocked = false
        gate?.resume()
        gate = nil
    }

    func waitForSyncCount(_ count: Int) async {
        if completedSyncs >= count { return }
        await withCheckedContinuation { completedWaiters.append((count, $0)) }
    }
}

@MainActor
private final class Fixture {
    let directory: URL
    let archiveURL: URL
    let defaults: UserDefaults
    let suiteName = "Strivory.SyncRegression.\(UUID().uuidString)"
    let health = FakeHealthKit()
    let cloud: FakeCloud

    init(records: [WorkoutRecord] = [], reconciliationVersion: Int = 1,
         cloudEnabled: Bool = false, remote: ICloudBackupSnapshot? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("strivory-sync-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        archiveURL = directory.appendingPathComponent("health.json")
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(cloudEnabled, forKey: "strivory.icloud-backup.enabled")
        cloud = FakeCloud(remote: remote)
        let state = PersistedHealthState(records: records, deletedWorkoutIDs: [],
                                         anchorData: Data([1]), reconciliationVersion: reconciliationVersion)
        try JSONEncoder().encode(state).write(to: archiveURL)
    }

    func makeStore() -> AppStore {
        AppStore(healthKit: health, cloudBackup: cloud, defaults: defaults,
                 archiveURL: archiveURL, prepareBackupOnLaunch: false)
    }

    func cleanup(_ store: AppStore? = nil) {
        store?.iCloudBackupEnabled = false
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    func savedState() throws -> PersistedHealthState {
        try JSONDecoder().decode(PersistedHealthState.self, from: Data(contentsOf: archiveURL))
    }
}

@main
private struct SyncRegressionTests {
    static func day(_ day: Int) -> Date {
        CalendarSupport.mondayCalendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: 12))!
    }

    static func record(_ day: Int, _ category: WorkoutCategory) -> WorkoutRecord {
        WorkoutRecord(startDate: self.day(day), category: category, duration: 1800, source: .healthKit)
    }

    static func snapshot(_ records: [WorkoutRecord]) -> ICloudBackupSnapshot {
        var result = ICloudBackupSnapshot.empty(displayName: "Backup Name", displayNameUpdatedAt: Date(timeIntervalSince1970: 1))
        result.healthArchive = records
        return result
    }

    @MainActor static func main() async throws {
        let timeout = Task {
            try await Task.sleep(for: .seconds(30))
            fatalError("Sync regression tests timed out")
        }
        defer { timeout.cancel() }
        try legacyBackupAndTombstones()
        try await delayedCloudResponse()
        try await deletionSurvivesRestart()
        try await reconciliationRecoversMissingWorkout()
        try await fullRefreshRemovesMissingWorkoutWithoutTombstone()
        try await emptyFullReadPreservesHistory()
        try await failedSaveDoesNotAdvanceAnchor()
        try await restorePreservesConcurrentHealthChange()
        try await legacyLocalMigration()
        try yearlyOtherAggregation()
        try categoryMappingSpecificity()
        try batchDeletionIgnoresClockSkew()
        try legacyImportMigration()
        print("PASS: all 13 sync and data regression scenarios")
    }

    static func legacyBackupAndTombstones() throws {
        let football = record(14, .ballSports)
        let swimming = record(19, .swimming)
        let old = snapshot([football, swimming])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json.removeValue(forKey: "deletedHealthWorkoutIDs")
        json["schemaVersion"] = 1
        let decoded = try JSONDecoder().decode(ICloudBackupSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        assert(decoded.deletedHealthWorkoutIDs.isEmpty && decoded.healthArchive.count == 2)
        var local = snapshot([swimming])
        local.deletedHealthWorkoutIDs = [football.id]
        for merged in [ICloudBackupSnapshot.merging(local: local, remote: decoded),
                       ICloudBackupSnapshot.merging(local: decoded, remote: local)] {
            assert(merged.healthArchive == [swimming])
            let roundTrip = try JSONDecoder().decode(ICloudBackupSnapshot.self, from: JSONEncoder().encode(merged))
            assert(roundTrip.deletedHealthWorkoutIDs == [football.id])
        }
        print("PASS: v1 backups decode; Workout deletions win in both merge directions")
    }

    @MainActor static func delayedCloudResponse() async throws {
        let first = record(14, .ballSports), second = record(14, .ballSports), swimming = record(19, .swimming)
        let fixture = try Fixture(records: [first, second], cloudEnabled: true, remote: snapshot([first, second]))
        let store = fixture.makeStore()
        defer { fixture.cleanup(store) }
        store.importCSV(CSVParseResult(fileName: "old.csv", records: [record(12, .running)], issues: []), strategy: .supplement)
        let oldBatch = store.importBatches[0]
        assert(store.summary(for: 2026).dailyActivities[CalendarSupport.startOfDay(day(19))] == nil)

        await fixture.cloud.pauseNextSync()
        let pending = Task { await store.syncICloudBackup() }
        await fixture.cloud.waitUntilBlocked()
        fixture.health.results = [HealthKitFetchResult(workouts: [swimming], deletedWorkoutIDs: [first.id], anchorData: Data([2]))]
        await store.requestHealthAccessAndRefresh()
        store.deleteBatch(oldBatch)
        store.importCSV(CSVParseResult(fileName: "new.csv", records: [record(13, .running)], issues: []), strategy: .supplement)
        store.userName = "New Name"
        await fixture.cloud.release()
        await pending.value

        assert(Set(store.healthRecords.map(\.id)) == [second.id, swimming.id])
        assert(store.summary(for: 2026).dailyActivities[CalendarSupport.startOfDay(day(19))]?.category == .swimming)
        assert(store.importBatches.map(\.name) == ["new.csv"] && store.userName == "New Name")
        let saved = try fixture.savedState()
        assert(saved.anchorData == Data([2]))
        // Confirm that the queued retry actually uploads the changes, not merely
        // that the first delayed response preserves the on-screen data.
        await fixture.cloud.waitForSyncCount(2)
        let uploaded = await fixture.cloud.remote!
        assert(Set(uploaded.healthArchive.map(\.id)) == [second.id, swimming.id])
        assert(uploaded.deletedHealthWorkoutIDs.contains(first.id))
        assert(uploaded.importBatches.map(\.name) == ["new.csv"] && uploaded.displayName == "New Name")
        print("PASS: delayed cloud response preserves Sep 19 swim, Sep 14 deletion, CSV and name; retry uploads them")
    }

    @MainActor static func deletionSurvivesRestart() async throws {
        let football = record(14, .ballSports), swimming = record(19, .swimming)
        let fixture = try Fixture(records: [football, swimming], remote: snapshot([football, swimming]))
        let store = fixture.makeStore()
        defer { fixture.cleanup(store) }
        fixture.health.results = [HealthKitFetchResult(workouts: [], deletedWorkoutIDs: [football.id], anchorData: Data([2]))]
        await store.requestHealthAccessAndRefresh()
        let restarted = fixture.makeStore()
        restarted.iCloudBackupEnabled = true
        await restarted.syncICloudBackup()
        restarted.iCloudBackupEnabled = false
        assert(restarted.healthRecords == [swimming])
        let saved = try fixture.savedState()
        assert(saved.deletedWorkoutIDs == [football.id])
        print("PASS: deletion persists across restart and stale backup merge")
    }

    @MainActor static func reconciliationRecoversMissingWorkout() async throws {
        let first = record(14, .ballSports), second = record(14, .ballSports), swimming = record(19, .swimming)
        let fixture = try Fixture(records: [first, second], reconciliationVersion: 0)
        let store = fixture.makeStore()
        defer { fixture.cleanup(store) }
        fixture.health.results = [
            HealthKitFetchResult(workouts: [second, swimming], deletedWorkoutIDs: [first.id], anchorData: Data([5])),
            HealthKitFetchResult(workouts: [], deletedWorkoutIDs: [], anchorData: Data([6])),
            HealthKitFetchResult(workouts: [second, swimming], deletedWorkoutIDs: [], anchorData: Data([7]))
        ]
        await store.requestHealthAccessAndRefresh()
        assert(fixture.health.requestedAnchors[0] == nil)
        assert(Set(store.healthRecords.map(\.id)) == [second.id, swimming.id])
        await store.requestHealthAccessAndRefresh()
        assert(fixture.health.requestedAnchors[1] == Data([5]))
        await store.requestHealthAccessAndRefresh(forceFullRefresh: true)
        assert(fixture.health.requestedAnchors[2] == nil)
        print("PASS: one-time full recovery finds swim and deletion; later automatic reads are incremental; manual reads recheck history")
    }

    @MainActor static func emptyFullReadPreservesHistory() async throws {
        let swimming = record(19, .swimming)
        let fixture = try Fixture(records: [swimming], reconciliationVersion: 0)
        let store = fixture.makeStore()
        defer { fixture.cleanup(store) }
        fixture.health.results = [HealthKitFetchResult(workouts: [], deletedWorkoutIDs: [], anchorData: Data([9]))]
        await store.requestHealthAccessAndRefresh()
        let saved = try fixture.savedState()
        assert(store.healthRecords == [swimming] && saved.anchorData == Data([1]))
        assert(saved.reconciliationVersion == 0)
        print("PASS: empty/denied full read preserves history and does not mark reconciliation complete")
    }

    @MainActor static func fullRefreshRemovesMissingWorkoutWithoutTombstone() async throws {
        let football = record(14, .ballSports), swimming = record(19, .swimming)
        let fixture = try Fixture(records: [football, swimming], reconciliationVersion: 0)
        let store = fixture.makeStore()
        defer { fixture.cleanup(store) }
        fixture.health.results = [HealthKitFetchResult(workouts: [swimming], deletedWorkoutIDs: [], anchorData: Data([8]))]
        await store.requestHealthAccessAndRefresh()
        assert(store.healthRecords == [swimming])
        let saved = try fixture.savedState()
        assert(saved.records == [swimming])
        print("PASS: a non-empty full Health snapshot removes archived workouts that no longer exist")
    }

    @MainActor static func failedSaveDoesNotAdvanceAnchor() async throws {
        let football = record(14, .ballSports), swimming = record(19, .swimming)
        let fixture = try Fixture(records: [football])
        let store = fixture.makeStore()
        defer { fixture.cleanup(store) }
        let result = HealthKitFetchResult(workouts: [swimming], deletedWorkoutIDs: [football.id], anchorData: Data([2]))
        fixture.health.results = [result, result]
        // Turn only this test's destination into a directory to force an I/O error.
        try FileManager.default.removeItem(at: fixture.archiveURL)
        try FileManager.default.createDirectory(at: fixture.archiveURL, withIntermediateDirectories: false)
        await store.requestHealthAccessAndRefresh()
        assert(store.healthRecords == [football] && store.healthMessage != nil)
        try FileManager.default.removeItem(at: fixture.archiveURL)
        await store.requestHealthAccessAndRefresh()
        assert(fixture.health.requestedAnchors == [Data([1]), Data([1])])
        assert(store.healthRecords == [swimming])
        let saved = try fixture.savedState()
        assert(saved.anchorData == Data([2]))
        print("PASS: failed save retains old anchor; retry reads the same delta and commits records plus deletion")
    }

    @MainActor static func restorePreservesConcurrentHealthChange() async throws {
        let football = record(14, .ballSports), swimming = record(19, .swimming)
        let fixture = try Fixture(records: [football], remote: snapshot([football]))
        let store = fixture.makeStore()
        defer { fixture.cleanup(store) }
        await fixture.cloud.pauseNextLoad()
        let pending = Task { await store.restoreICloudBackup() }
        await fixture.cloud.waitUntilBlocked()
        fixture.health.results = [HealthKitFetchResult(workouts: [swimming], deletedWorkoutIDs: [football.id], anchorData: Data([2]))]
        await store.requestHealthAccessAndRefresh()
        await fixture.cloud.release()
        await pending.value
        assert(store.healthRecords == [swimming] && store.userName == "Backup Name")
        let saved = try fixture.savedState()
        assert(saved.reconciliationVersion == 0)
        print("PASS: delayed restore preserves concurrent HealthKit changes and restores the backed-up name")
    }

    @MainActor static func legacyLocalMigration() async throws {
        let football = record(14, .ballSports), swimming = record(19, .swimming)
        for fromDefaults in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let oldData = try JSONEncoder().encode([football])
            if fromDefaults {
                try FileManager.default.removeItem(at: fixture.archiveURL)
                fixture.defaults.set(oldData, forKey: "strivory.health.archive")
            } else {
                try oldData.write(to: fixture.archiveURL)
            }
            fixture.defaults.set(Data([99]), forKey: "strivory.health.anchor")
            let store = fixture.makeStore()
            assert(store.healthRecords == [football])
            fixture.health.results = [HealthKitFetchResult(workouts: [football, swimming], deletedWorkoutIDs: [], anchorData: Data([100]))]
            await store.requestHealthAccessAndRefresh()
            assert(fixture.health.requestedAnchors[0] == nil)
            assert(store.healthRecords.count == 2)
            assert(fixture.defaults.data(forKey: "strivory.health.anchor") == nil)
        }
        print("PASS: legacy file/UserDefaults archives migrate without trusting the old, possibly advanced anchor")
    }

    @MainActor static func yearlyOtherAggregation() throws {
        let categories: [WorkoutCategory] = [
            .other, .other, .other, .other, .other,
            .strength, .strength, .strength, .strength,
            .swimming, .swimming, .swimming,
            .outdoors, .outdoors,
            .ballSports, .running
        ]
        let records = categories.enumerated().map { index, category in record(index + 1, category) }
        let fixture = try Fixture(records: records)
        let store = fixture.makeStore()
        defer { fixture.cleanup(store) }
        let summary = store.summary(for: 2026)
        assert(!summary.topCategories.contains(.other))
        assert(summary.topCategories.count == 4)
        assert(summary.otherCount == 6)
        assert(summary.count(for: .other) == 6)
        print("PASS: raw Other plus categories outside the top four aggregate into one legend value")
    }

    static func categoryMappingSpecificity() throws {
        assert(WorkoutCategory.fromImportedLabel("Running Training") == .running)
        assert(WorkoutCategory.fromImportedLabel("Football Training") == .ballSports)
        assert(WorkoutCategory.fromImportedLabel("Cycling Training") == .cycling)
        assert(WorkoutCategory.fromImportedLabel("Functional Training") == .strength)
        print("PASS: generic training labels no longer override specific workout categories")
    }

    static func batchDeletionIgnoresClockSkew() throws {
        let batchID = UUID()
        let batch = CSVImportBatch(
            id: batchID,
            name: "future.csv",
            createdAt: Date(timeIntervalSince1970: 4_000_000_000),
            strategy: .supplement,
            records: [WorkoutRecord(startDate: day(10), category: .running, duration: 0, source: .csv, batchID: batchID)]
        )
        var remote = snapshot([])
        remote.importBatches = [batch]
        var local = snapshot([])
        local.deletedBatchDates = [batchID.uuidString: Date(timeIntervalSince1970: 1)]
        assert(ICloudBackupSnapshot.merging(local: local, remote: remote).importBatches.isEmpty)
        print("PASS: CSV deletion tombstones win even when device clocks disagree")
    }

    @MainActor static func legacyImportMigration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let batchID = UUID()
        let batch = CSVImportBatch(
            id: batchID,
            name: "legacy.csv",
            createdAt: .now,
            strategy: .supplement,
            records: [WorkoutRecord(startDate: day(11), category: .running, duration: 0, source: .csv, batchID: batchID)]
        )
        fixture.defaults.set(try JSONEncoder().encode([batch]), forKey: "strivory.csv.batches")
        let store = fixture.makeStore()
        assert(store.importBatches == [batch])
        assert(fixture.defaults.data(forKey: "strivory.csv.batches") == nil)
        let fileURL = fixture.archiveURL.deletingLastPathComponent().appendingPathComponent("import-batches.json")
        assert(FileManager.default.fileExists(atPath: fileURL.path))
        print("PASS: legacy CSV data migrates from UserDefaults to the protected archive file")
    }
}
