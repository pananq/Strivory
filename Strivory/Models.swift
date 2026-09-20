import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let storageKey = "strivory.app.language"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }

    var title: String {
        switch self {
        case .simplifiedChinese: L.text("language.simplifiedChinese")
        case .english: L.text("language.english")
        }
    }
}

enum L {
    static var language: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppLanguage.storageKey) ?? "") ?? .simplifiedChinese
    }

    static var locale: Locale { language.locale }

    private static var bundle: Bundle {
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else { return .main }
        return localizedBundle
    }

    static func text(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Localizable", bundle: bundle, value: key, comment: "")
    }

    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }
}

enum WorkoutCategory: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case strength, running, cycling, swimming, ballSports, boardSports
    case outdoors, mindBody, dance, combat, rowing, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .strength: L.text("category.strength")
        case .running: L.text("category.running")
        case .cycling: L.text("category.cycling")
        case .swimming: L.text("category.swimming")
        case .ballSports: L.text("category.ballSports")
        case .boardSports: L.text("category.boardSports")
        case .outdoors: L.text("category.outdoors")
        case .mindBody: L.text("category.mindBody")
        case .dance: L.text("category.dance")
        case .combat: L.text("category.combat")
        case .rowing: L.text("category.rowing")
        case .other: L.text("category.other")
        }
    }

    var color: Color {
        switch self {
        case .strength: Color(red: 0.31, green: 0.51, blue: 0.72)
        case .running: Color(red: 0.91, green: 0.35, blue: 0.39)
        case .cycling: Color(red: 0.96, green: 0.53, blue: 0.16)
        case .swimming: Color(red: 0.93, green: 0.74, blue: 0.19)
        case .ballSports: Color(red: 0.48, green: 0.70, blue: 0.69)
        case .boardSports: Color(red: 0.56, green: 0.42, blue: 0.74)
        case .outdoors: Color(red: 0.28, green: 0.64, blue: 0.45)
        case .mindBody: Color(red: 0.78, green: 0.49, blue: 0.66)
        case .dance: Color(red: 0.85, green: 0.35, blue: 0.59)
        case .combat: Color(red: 0.70, green: 0.24, blue: 0.25)
        case .rowing: Color(red: 0.20, green: 0.58, blue: 0.72)
        case .other: Color(red: 0.69, green: 0.47, blue: 0.30)
        }
    }

    static func fromImportedLabel(_ label: String) -> WorkoutCategory {
        let value = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        func contains(_ values: [String]) -> Bool { values.contains { value.contains($0) } }

        if contains(["run", "running", "跑", "treadmill"]) { return .running }
        if contains(["cycling", "cycle", "bike", "骑行", "单车"]) { return .cycling }
        if contains(["swim", "swimming", "游泳"]) { return .swimming }
        if contains(["足球", "篮球", "羽毛球", "网球", "乒乓", "排球", "棒球", "橄榄", "football", "basketball", "badminton", "tennis", "volleyball", "baseball", "rugby", "squash", "pickleball"]) { return .ballSports }
        if contains(["滑板", "陆冲", "冲浪", "单板", "skate", "surf", "snowboard"]) { return .boardSports }
        if contains(["徒步", "步行", "登山", "攀岩", "滑雪", "远足", "皮划", "hiking", "walking", "climbing", "ski", "kayak", "outdoor"]) { return .outdoors }
        if contains(["瑜伽", "普拉提", "太极", "拉伸", "yoga", "pilates", "tai chi", "stretch"]) { return .mindBody }
        if contains(["舞", "dance", "aerobic", "操课"]) { return .dance }
        if contains(["拳", "武术", "搏击", "boxing", "martial", "kickbox"]) { return .combat }
        if contains(["划船", "rowing", "rower"]) { return .rowing }
        if contains(["hiit", "strength training", "functional training", "cross training", "crossfit", "weight training", "力量", "功能性", "核心", "weightlifting"]) { return .strength }
        return .other
    }
}

enum RecordSource: String, Codable, Hashable, Sendable {
    case healthKit
    case csv
}

struct WorkoutRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let startDate: Date
    let category: WorkoutCategory
    let duration: TimeInterval
    let activeEnergy: Double
    let source: RecordSource
    let batchID: UUID?

    init(id: UUID = UUID(), startDate: Date, category: WorkoutCategory, duration: TimeInterval, activeEnergy: Double = 0, source: RecordSource, batchID: UUID? = nil) {
        self.id = id
        self.startDate = startDate
        self.category = category
        self.duration = duration
        self.activeEnergy = activeEnergy
        self.source = source
        self.batchID = batchID
    }
}

enum CSVImportStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
    case supplement
    case override

    var id: String { rawValue }
    var title: String { self == .supplement ? L.text("csv.strategy.supplement.title") : L.text("csv.strategy.override.title") }
    var detail: String { self == .supplement ? L.text("csv.strategy.supplement.detail") : L.text("csv.strategy.override.detail") }
}

struct CSVImportBatch: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let name: String
    let createdAt: Date
    let strategy: CSVImportStrategy
    let records: [WorkoutRecord]
}

struct DailyActivity: Identifiable, Hashable {
    let date: Date
    let category: WorkoutCategory
    let source: RecordSource
    let records: [WorkoutRecord]

    var id: Date { date }
}

struct YearSummary: Identifiable {
    let year: Int
    let dailyActivities: [Date: DailyActivity]
    let categoryCounts: [WorkoutCategory: Int]
    let topCategories: [WorkoutCategory]

    var id: Int { year }
    var activeDays: Int { dailyActivities.count }
    var otherCount: Int { categoryCounts.filter { !topCategories.contains($0.key) }.map(\.value).reduce(0, +) }

    func count(for category: WorkoutCategory) -> Int {
        category == .other ? otherCount : (topCategories.contains(category) ? categoryCounts[category, default: 0] : 0)
    }

    func displayCategory(on date: Date) -> WorkoutCategory? {
        guard let category = dailyActivities[date]?.category else { return nil }
        return topCategories.contains(category) ? category : .other
    }
}

/// The complete app-owned history required to restore Strivory after an app
/// deletion. Apple Health remains the source of truth for live workouts; this
/// snapshot is an app-local archive that lets the calendar be restored before
/// Health access is granted again.
struct ICloudBackupSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int = currentSchemaVersion
    var updatedAt: Date
    var healthArchive: [WorkoutRecord]
    var importBatches: [CSVImportBatch]
    /// UUID strings are used because they encode predictably as dictionary keys.
    var deletedBatchDates: [String: Date]
    var displayName: String
    var displayNameUpdatedAt: Date
    var deletedHealthWorkoutIDs: Set<UUID> = []

    enum CodingKeys: String, CodingKey {
        case schemaVersion, updatedAt, healthArchive, importBatches, deletedBatchDates
        case displayName, displayNameUpdatedAt, deletedHealthWorkoutIDs
    }

    static func empty(displayName: String, displayNameUpdatedAt: Date = .now) -> Self {
        Self(
            updatedAt: .now,
            healthArchive: [],
            importBatches: [],
            deletedBatchDates: [:],
            displayName: displayName,
            displayNameUpdatedAt: displayNameUpdatedAt
        )
    }
}

enum ICloudBackupState: Equatable {
    case checking
    case disabled
    case ready(lastBackup: Date?)
    case unavailable
    case failed
}

enum CalendarSupport {
    static let mondayCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }()

    static func startOfDay(_ date: Date) -> Date {
        mondayCalendar.startOfDay(for: date)
    }

    static var contextIdentifier: String {
        let zone = TimeZone.autoupdatingCurrent
        return "\(zone.identifier)|\(zone.secondsFromGMT(for: .now))"
    }

    static func year(for date: Date) -> Int {
        mondayCalendar.component(.year, from: date)
    }

    static func yearText(_ year: Int) -> String {
        String(format: "%04d", locale: Locale(identifier: "en_US_POSIX"), year)
    }

    static func daysInYear(_ year: Int, until date: Date = .now) -> Int {
        let calendar = mondayCalendar
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else { return 365 }
        let currentYear = calendar.component(.year, from: date)
        if year == currentYear {
            let today = calendar.startOfDay(for: min(date, end))
            let elapsedDays = calendar.dateComponents([.day], from: start, to: today).day ?? 0
            let totalDays = calendar.dateComponents([.day], from: start, to: end).day ?? 365
            return min(totalDays, max(1, elapsedDays + 1))
        }
        return calendar.dateComponents([.day], from: start, to: end).day ?? 365
    }

    static func percentage(_ summary: YearSummary) -> Double {
        Double(summary.activeDays) / Double(daysInYear(summary.year))
    }

    static func dateText(_ date: Date, style: DateFormatter.Style) -> String {
        let format: Date.FormatStyle
        switch style {
        case .short:
            format = .dateTime.year().month().day()
        case .medium:
            format = .dateTime.year().month(.abbreviated).day()
        case .long:
            format = .dateTime.year().month(.wide).day()
        case .full:
            format = .dateTime.weekday(.wide).year().month(.wide).day()
        case .none:
            format = .dateTime.year().month().day()
        @unknown default:
            format = .dateTime.year().month().day()
        }
        return date.formatted(format.locale(L.locale))
    }
}
