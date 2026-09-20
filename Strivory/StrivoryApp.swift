import SwiftUI

@main
struct StrivoryApp: App {
    @StateObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
#if targetEnvironment(simulator)
        _store = StateObject(wrappedValue: AppStore(
            healthKit: SimulatorHealthKitService(),
            cloudBackup: SimulatorCloudBackupService()
        ))
#else
        _store = StateObject(wrappedValue: AppStore(
            healthKit: HealthKitService(),
            cloudBackup: CloudBackupService()
        ))
#endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environment(\.locale, store.language.locale)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    guard phase == .active else { return }
                    Task {
                        await store.requestHealthAccessAndRefresh()
                        await store.syncICloudBackup(force: false)
                    }
                }
        }
    }
}

#if targetEnvironment(simulator)
enum SimulatorTestConfiguration {
    static func hasFlag(_ flag: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
            || ProcessInfo.processInfo.environment[flag.replacingOccurrences(of: "-", with: "STRIVORY_").uppercased()] == "1"
    }
}
/// Deterministic, device-local sample data used only by simulator UI checks.
/// App Store and Release builds always use HealthKitService.
@MainActor
private final class SimulatorHealthKitService: HealthKitProviding {
    private let records = SimulatorHealthKitService.makeRecords()

    func requestAuthorization() async throws {}

    func fetchWorkouts(anchorData: Data?) async throws -> HealthKitFetchResult {
        HealthKitFetchResult(
            workouts: anchorData == nil ? records : [],
            deletedWorkoutIDs: [],
            anchorData: Data("strivory-simulator-v1".utf8)
        )
    }

    private static func makeRecords() -> [WorkoutRecord] {
        let calendar = CalendarSupport.mondayCalendar
        let categories: [WorkoutCategory] = [.strength, .swimming, .outdoors, .ballSports, .running, .cycling]
        var records: [WorkoutRecord] = []

        for year in 2023...2026 {
            guard let firstDay = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else { continue }
            let numberOfDays = year == 2026 ? 255 : (calendar.range(of: .day, in: .year, for: firstDay)?.count ?? 365)
            for offset in 0..<numberOfDays where offset % 3 == 0 || offset % 11 == 0 {
                guard let date = calendar.date(byAdding: .day, value: offset, to: firstDay) else { continue }
                records.append(WorkoutRecord(
                    startDate: date,
                    category: categories[(offset / 3 + year) % categories.count],
                    duration: TimeInterval(1_800 + (offset % 5) * 900),
                    activeEnergy: Double(180 + offset % 420),
                    source: .healthKit
                ))
            }
        }
        return records
    }
}

private actor SimulatorCloudBackupService: CloudBackupProviding {
    func isAccountAvailable() async -> Bool { false }
    func load() async throws -> ICloudBackupSnapshot? { nil }
    func sync(local: ICloudBackupSnapshot) async throws -> ICloudBackupSnapshot { local }
}
#endif
