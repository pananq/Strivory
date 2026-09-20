import XCTest
@testable import Strivory

final class StrivoryTests: XCTestCase {
    private let calendar = CalendarSupport.mondayCalendar

    func testFullRefreshReplacesRecordsMissingFromHealthSnapshot() throws {
        let football = WorkoutRecord(
            startDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 14))),
            category: .ballSports,
            duration: 1_800,
            source: .healthKit
        )
        let swimming = WorkoutRecord(
            startDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 19))),
            category: .swimming,
            duration: 1_800,
            source: .healthKit
        )
        let state = PersistedHealthState(
            records: [football, swimming],
            deletedWorkoutIDs: [],
            anchorData: Data([1]),
            reconciliationVersion: 0
        )

        let refreshed = state.applying(
            HealthKitFetchResult(workouts: [swimming], deletedWorkoutIDs: [], anchorData: Data([2])),
            isFullRefresh: true
        )

        XCTAssertEqual(refreshed.records, [swimming])
        XCTAssertEqual(refreshed.anchorData, Data([2]))
    }

    func testImportedTrainingLabelsPreferSpecificCategories() {
        XCTAssertEqual(WorkoutCategory.fromImportedLabel("swim training"), .swimming)
        XCTAssertEqual(WorkoutCategory.fromImportedLabel("football training"), .ballSports)
        XCTAssertEqual(WorkoutCategory.fromImportedLabel("strength training"), .strength)
    }

    func testDeletedImportBatchCannotBeResurrectedByClockSkew() {
        let batchID = UUID()
        let record = WorkoutRecord(startDate: .now, category: .running, duration: 0, source: .csv, batchID: batchID)
        let batch = CSVImportBatch(
            id: batchID,
            name: "sample.csv",
            createdAt: Date(timeIntervalSince1970: 9_999),
            strategy: .supplement,
            records: [record]
        )
        let local = ICloudBackupSnapshot(
            updatedAt: .now,
            healthArchive: [],
            importBatches: [],
            deletedBatchDates: [batchID.uuidString: Date(timeIntervalSince1970: 1)],
            displayName: "Local",
            displayNameUpdatedAt: .now,
            deletedHealthWorkoutIDs: []
        )
        let remote = ICloudBackupSnapshot(
            updatedAt: .now,
            healthArchive: [],
            importBatches: [batch],
            deletedBatchDates: [:],
            displayName: "Remote",
            displayNameUpdatedAt: .distantPast,
            deletedHealthWorkoutIDs: []
        )

        XCTAssertTrue(ICloudBackupSnapshot.merging(local: local, remote: remote).importBatches.isEmpty)
    }
}
