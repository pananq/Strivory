import Foundation
import HealthKit

enum HealthKitServiceError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: L.text("health.unavailable")
        }
    }
}

@MainActor
final class HealthKitService: HealthKitProviding {
    private let store = HKHealthStore()

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthKitServiceError.unavailable }
        try await store.requestAuthorization(toShare: [], read: [HKObjectType.workoutType()])
    }

    /// Fetches changes since the last saved HealthKit anchor. Passing `nil`
    /// performs the one-time initial history import.
    func fetchWorkouts(anchorData: Data?) async throws -> HealthKitFetchResult {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthKitServiceError.unavailable }
        let type = HKObjectType.workoutType()
        let anchor = Self.decodeAnchor(anchorData)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: HKObjectQueryNoLimit) { _, samples, deletedObjects, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let workouts = (samples as? [HKWorkout] ?? []).compactMap { workout -> WorkoutRecord? in
                    let duration = workout.duration
                    guard duration >= 600 else { return nil }
                    let energy = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0
                    return WorkoutRecord(id: workout.uuid, startDate: workout.startDate, category: Self.category(for: workout.workoutActivityType), duration: duration, activeEnergy: energy, source: .healthKit)
                }
                guard let newAnchor, let encodedAnchor = Self.encodeAnchor(newAnchor) else {
                    continuation.resume(throwing: HealthKitServiceError.unavailable)
                    return
                }
                continuation.resume(returning: HealthKitFetchResult(
                    workouts: Self.deduplicated(workouts),
                    deletedWorkoutIDs: Set((deletedObjects ?? []).map(\.uuid)),
                    anchorData: encodedAnchor
                ))
            }
            self.store.execute(query)
        }
    }

    nonisolated private static func category(for type: HKWorkoutActivityType) -> WorkoutCategory {
        switch type {
        case .traditionalStrengthTraining, .functionalStrengthTraining, .highIntensityIntervalTraining, .crossTraining, .coreTraining, .mixedCardio:
            return .strength
        case .running, .wheelchairRunPace:
            return .running
        case .cycling, .handCycling:
            return .cycling
        case .swimming, .waterFitness:
            return .swimming
        case .americanFootball, .australianFootball, .badminton, .baseball, .basketball, .cricket, .handball, .hockey, .lacrosse, .pickleball, .racquetball, .rugby, .soccer, .softball, .squash, .tableTennis, .tennis, .volleyball, .waterPolo:
            return .ballSports
        case .skatingSports, .surfingSports, .snowboarding:
            return .boardSports
        case .hiking, .walking, .climbing, .crossCountrySkiing, .downhillSkiing, .snowSports, .paddleSports, .sailing, .wheelchairWalkPace:
            return .outdoors
        case .yoga, .pilates, .taiChi, .mindAndBody, .barre, .flexibility:
            return .mindBody
        case .dance, .danceInspiredTraining, .cardioDance, .socialDance:
            return .dance
        case .boxing, .martialArts, .kickboxing, .wrestling, .fencing:
            return .combat
        case .rowing:
            return .rowing
        default:
            return .other
        }
    }

    nonisolated private static func deduplicated(_ records: [WorkoutRecord]) -> [WorkoutRecord] {
        var seenIDs = Set<UUID>()
        return records
            .filter { seenIDs.insert($0.id).inserted }
            .sorted { $0.startDate < $1.startDate }
    }

    nonisolated private static func decodeAnchor(_ data: Data?) -> HKQueryAnchor? {
        guard let data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    nonisolated private static func encodeAnchor(_ anchor: HKQueryAnchor) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }
}
