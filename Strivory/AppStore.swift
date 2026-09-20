import Foundation
import Combine
import CloudKit

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var healthRecords: [WorkoutRecord] = []
    @Published private(set) var healthArchive: [WorkoutRecord] = []
    @Published private(set) var importBatches: [CSVImportBatch] = []
    @Published private(set) var isLoadingHealth = false
    @Published private(set) var isSyncingICloud = false
    @Published private(set) var iCloudBackupState: ICloudBackupState = .checking
    @Published private(set) var hasICloudBackup = false
    @Published var iCloudRestoreAvailable = false
    @Published var healthMessage: String?
    @Published private(set) var iCloudErrorMessage: String?
    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: AppLanguage.storageKey) }
    }
    @Published var userName: String {
        didSet {
            guard !isApplyingBackupSnapshot else { return }
            defaults.set(userName, forKey: Self.userNameKey)
            userNameUpdatedAt = .now
            defaults.set(userNameUpdatedAt, forKey: Self.userNameUpdatedAtKey)
            backupRevision += 1
            scheduleICloudSync()
        }
    }
    @Published var iCloudBackupEnabled: Bool {
        didSet {
            defaults.set(iCloudBackupEnabled, forKey: Self.iCloudBackupEnabledKey)
            if iCloudBackupEnabled { scheduleICloudSync() }
            else {
                delayedICloudSyncTask?.cancel()
                delayedICloudSyncTask = nil
                iCloudRetryTask?.cancel()
                iCloudRetryTask = nil
                iCloudRetryAttempt = 0
                iCloudBackupState = .disabled
            }
        }
    }

    private let healthKit: any HealthKitProviding
    private let cloudBackup: any CloudBackupProviding
    private let defaults: UserDefaults
    private let archiveURL: URL?
    private let importArchiveURL: URL?
    private static let batchesKey = "strivory.csv.batches"
    private static let healthArchiveKey = "strivory.health.archive"
    private static let healthArchiveFileName = "health-archive.json"
    private static let importBatchesFileName = "import-batches.json"
    private static let healthAnchorKey = "strivory.health.anchor"
    private static let deletedBatchDatesKey = "strivory.csv.deleted-batches"
    private static let userNameKey = "strivory.user.name"
    private static let userNameUpdatedAtKey = "strivory.user.name.updated-at"
    private static let iCloudBackupEnabledKey = "strivory.icloud-backup.enabled"
    private static let lastAutomaticICloudBackupKey = "strivory.icloud-backup.last-automatic"
    private var deletedBatchDates: [String: Date] = [:]
    private var healthAnchorData: Data?
    private var deletedHealthWorkoutIDs: Set<UUID> = []
    private var healthReconciliationVersion = 0
    private var needsFullHealthRefresh = false
    private var backupRevision = 0
    private var userNameUpdatedAt: Date
    private var isApplyingBackupSnapshot = false
    private var summaryCache: [Int: YearSummary] = [:]
    private var summaryCacheIsValid = false
    private var calendarRecordsCache: [WorkoutRecord]?
    private var calendarContextIdentifier: String
    private var hasPendingICloudChanges = false
    private var delayedICloudSyncTask: Task<Void, Never>?
    private var iCloudRetryTask: Task<Void, Never>?
    private var iCloudRetryAttempt = 0

    init(healthKit: any HealthKitProviding, cloudBackup: any CloudBackupProviding,
         defaults: UserDefaults = .standard, archiveURL: URL? = nil, prepareBackupOnLaunch: Bool = true) {
        self.healthKit = healthKit
        self.cloudBackup = cloudBackup
        self.defaults = defaults
        self.archiveURL = archiveURL
        self.importArchiveURL = archiveURL.map {
            $0.deletingLastPathComponent().appendingPathComponent(Self.importBatchesFileName)
        }
        self.calendarContextIdentifier = CalendarSupport.contextIdentifier
        language = AppLanguage(rawValue: defaults.string(forKey: AppLanguage.storageKey) ?? "") ?? .simplifiedChinese
        userName = defaults.string(forKey: Self.userNameKey) ?? L.text("export.defaultName")
        userNameUpdatedAt = defaults.object(forKey: Self.userNameUpdatedAtKey) as? Date
            ?? (defaults.string(forKey: Self.userNameKey) == nil ? .distantPast : .now)
        iCloudBackupEnabled = defaults.bool(forKey: Self.iCloudBackupEnabledKey)
        loadBatches()
        loadHealthArchive()
        loadDeletedBatchDates()
        if prepareBackupOnLaunch { Task { await prepareICloudBackup() } }
    }

    func requestHealthAccessAndRefresh(forceFullRefresh: Bool = false) async {
        guard !isLoadingHealth else {
            needsFullHealthRefresh = needsFullHealthRefresh || forceFullRefresh
            return
        }
        isLoadingHealth = true
        defer {
            isLoadingHealth = false
            if needsFullHealthRefresh {
                needsFullHealthRefresh = false
                Task { await requestHealthAccessAndRefresh(forceFullRefresh: true) }
            }
        }
        do {
            try await healthKit.requestAuthorization()
            let fullRefresh = forceFullRefresh || healthAnchorData == nil
                || healthReconciliationVersion < PersistedHealthState.currentReconciliationVersion
            let result = try await healthKit.fetchWorkouts(anchorData: fullRefresh ? nil : healthAnchorData)
            // Empty reads cannot distinguish denied access from an empty store.
            // Keep restored history, and retry reconciliation after access returns.
            if fullRefresh && result.workouts.isEmpty && result.deletedWorkoutIDs.isEmpty {
                healthMessage = L.text("health.noReadableData")
                return
            }
            let current = persistedHealthState
            let next = current.applying(result, isFullRefresh: fullRefresh)
            let changed = next.records != healthArchive || next.deletedWorkoutIDs != deletedHealthWorkoutIDs
            if next != current {
                try saveHealthState(next)
                applyHealthState(next)
            }
            if changed { backupRevision += 1 }
            healthMessage = healthRecords.isEmpty
                ? L.text("health.empty")
                : L.text("health.updated", healthRecords.count)
            if changed { scheduleICloudSync() }
        } catch {
            healthMessage = error.localizedDescription
        }
    }

    func importCSV(_ result: CSVParseResult, strategy: CSVImportStrategy) {
        let batchID = UUID()
        let records = result.records.map {
            WorkoutRecord(id: $0.id, startDate: $0.startDate, category: $0.category, duration: $0.duration, activeEnergy: 0, source: .csv, batchID: batchID)
        }
        guard !records.isEmpty else { return }
        let previous = importBatches
        importBatches.append(CSVImportBatch(id: batchID, name: result.fileName, createdAt: .now, strategy: strategy, records: records))
        do {
            try saveBatches()
        } catch {
            importBatches = previous
            healthMessage = L.text("csv.persistenceFailure", error.localizedDescription)
            return
        }
        invalidateSummaryCache()
        backupRevision += 1
        scheduleICloudSync()
    }

    func deleteBatch(_ batch: CSVImportBatch) {
        let previousBatches = importBatches
        let previousDeletedDates = deletedBatchDates
        importBatches.removeAll { $0.id == batch.id }
        deletedBatchDates[batch.id.uuidString] = .now
        do {
            try saveBatches()
        } catch {
            importBatches = previousBatches
            deletedBatchDates = previousDeletedDates
            healthMessage = L.text("csv.persistenceFailure", error.localizedDescription)
            return
        }
        saveDeletedBatchDates()
        invalidateSummaryCache()
        backupRevision += 1
        scheduleICloudSync()
    }

    func summary(for year: Int) -> YearSummary {
        refreshCalendarContextIfNeeded()
        rebuildSummaryCacheIfNeeded()
        if let cached = summaryCache[year] { return cached }
        let summary = YearSummary(year: year, dailyActivities: [:], categoryCounts: [:], topCategories: [])
        summaryCache[year] = summary
        return summary
    }

    private func rebuildSummaryCacheIfNeeded() {
        guard !summaryCacheIsValid else { return }
        let calendar = CalendarSupport.mondayCalendar
        var healthByYear: [Int: [Date: [WorkoutRecord]]] = [:]
        for record in calendarRecords {
            let year = calendar.component(.year, from: record.startDate)
            healthByYear[year, default: [:]][CalendarSupport.startOfDay(record.startDate), default: []].append(record)
        }

        var importedByYear: [Int: [Date: [(record: WorkoutRecord, batch: CSVImportBatch)]]] = [:]
        for batch in importBatches {
            for record in batch.records {
                let year = calendar.component(.year, from: record.startDate)
                importedByYear[year, default: [:]][CalendarSupport.startOfDay(record.startDate), default: []].append((record, batch))
            }
        }

        summaryCache.removeAll(keepingCapacity: true)
        let years = Set(healthByYear.keys).union(importedByYear.keys)
        for year in years {
            summaryCache[year] = makeSummary(
                for: year,
                healthByDay: healthByYear[year] ?? [:],
                importedByDay: importedByYear[year] ?? [:]
            )
        }
        summaryCacheIsValid = true
    }

    private func makeSummary(
        for year: Int,
        healthByDay: [Date: [WorkoutRecord]],
        importedByDay: [Date: [(record: WorkoutRecord, batch: CSVImportBatch)]]
    ) -> YearSummary {
        let allDays = Set(healthByDay.keys).union(importedByDay.keys)
        var dailyActivities: [Date: DailyActivity] = [:]
        for day in allDays {
            let health = healthByDay[day] ?? []
            let imports = (importedByDay[day] ?? []).sorted { $0.batch.createdAt > $1.batch.createdAt }
            if let override = imports.first(where: { $0.batch.strategy == .override }) {
                dailyActivities[day] = DailyActivity(date: day, category: override.record.category, source: .csv, records: [override.record])
                continue
            }
            if !health.isEmpty, let primary = primaryHealthActivity(on: day, records: health) {
                dailyActivities[day] = primary
                continue
            }
            if let imported = imports.first {
                dailyActivities[day] = DailyActivity(date: day, category: imported.record.category, source: .csv, records: [imported.record])
            }
        }

        let counts = dailyActivities.values.reduce(into: [WorkoutCategory: Int]()) { partial, activity in
            partial[activity.category, default: 0] += 1
        }
        let top = counts.filter { $0.key != .other }.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key.rawValue < rhs.key.rawValue : lhs.value > rhs.value
        }.prefix(4).map(\.key)
        return YearSummary(year: year, dailyActivities: dailyActivities, categoryCounts: counts, topCategories: top)
    }

    var availableYears: [Int] {
        refreshCalendarContextIfNeeded()
        rebuildSummaryCacheIfNeeded()
        let years = Set(summaryCache.keys)
        let current = CalendarSupport.year(for: .now)
        return (years.isEmpty ? [current] : Array(years)).sorted(by: >)
    }

    var exportName: String {
        let cleaned = userName.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "的"))
        return cleaned.isEmpty ? L.text("export.defaultName") : cleaned
    }

    var iCloudBackupStatusText: String {
        switch iCloudBackupState {
        case .checking: return L.text("icloud.status.checking")
        case .disabled: return L.text("icloud.status.disabled")
        case .ready(let date):
            return date.map { L.text("icloud.status.ready", CalendarSupport.dateText($0, style: .short)) }
                ?? L.text("icloud.status.readyWithoutDate")
        case .unavailable: return L.text("icloud.status.unavailable")
        case .failed: return iCloudErrorMessage ?? L.text("icloud.status.failed")
        }
    }

    func prepareICloudBackup() async {
        iCloudBackupState = .checking
        iCloudErrorMessage = nil
        let needsRestoreCheck = importBatches.isEmpty && healthArchive.isEmpty
        guard iCloudBackupEnabled || needsRestoreCheck else {
            iCloudBackupState = .disabled
            return
        }
        guard await cloudBackup.isAccountAvailable() else {
            iCloudBackupState = .unavailable
            return
        }
        do {
            let remote = try await cloudBackup.load()
            hasICloudBackup = remote != nil
            if let remote, importBatches.isEmpty, healthArchive.isEmpty {
                iCloudRestoreAvailable = !remote.healthArchive.isEmpty || !remote.importBatches.isEmpty
            }
            iCloudBackupState = iCloudBackupEnabled
                ? .ready(lastBackup: remote?.updatedAt)
                : .disabled
        } catch {
            iCloudBackupState = .failed
            recordICloudFailure(error)
        }
    }

    func syncICloudBackup() async {
        await syncICloudBackup(force: true)
    }

    /// Routine checks are daily; local changes and manual backups bypass the limit.
    func syncICloudBackup(force: Bool) async {
        guard iCloudBackupEnabled else { return }
        if force {
            iCloudRetryTask?.cancel()
            iCloudRetryTask = nil
        }
        if isSyncingICloud {
            hasPendingICloudChanges = true
            return
        }
        guard force || hasPendingICloudChanges || isAutomaticICloudBackupDue else { return }
        isSyncingICloud = true
        hasPendingICloudChanges = false
        var completed = false
        defer {
            isSyncingICloud = false
            if completed && hasPendingICloudChanges { scheduleICloudSync() }
        }
        do {
            let revision = backupRevision
            let merged = try await cloudBackup.sync(local: backupSnapshot())
            // HealthKit, imports and profile edits can change while CloudKit is
            // suspended. Rebase against those changes before touching local data.
            try applyBackupSnapshot(ICloudBackupSnapshot.merging(local: backupSnapshot(), remote: merged))
            hasPendingICloudChanges = hasPendingICloudChanges || backupRevision != revision
            completed = true
            hasICloudBackup = true
            iCloudBackupState = .ready(lastBackup: merged.updatedAt)
            iCloudErrorMessage = nil
            iCloudRetryAttempt = 0
            iCloudRetryTask?.cancel()
            iCloudRetryTask = nil
            defaults.set(Date.now, forKey: Self.lastAutomaticICloudBackupKey)
        } catch let error as ICloudBackupError where error == .accountUnavailable {
            hasPendingICloudChanges = true
            iCloudBackupState = .unavailable
            recordICloudFailure(error)
            scheduleICloudRetry(after: error)
        } catch {
            hasPendingICloudChanges = true
            iCloudBackupState = .failed
            recordICloudFailure(error)
            scheduleICloudRetry(after: error)
        }
    }

    func restoreICloudBackup() async {
        guard !isSyncingICloud else { return }
        isSyncingICloud = true
        defer {
            isSyncingICloud = false
            if hasPendingICloudChanges { scheduleICloudSync() }
        }
        do {
            guard let remote = try await cloudBackup.load() else {
                throw ICloudBackupError.malformedBackup
            }
            try applyBackupSnapshot(ICloudBackupSnapshot.merging(local: backupSnapshot(), remote: remote), needsReconciliation: true)
            hasICloudBackup = true
            iCloudRestoreAvailable = false
            iCloudBackupEnabled = true
            iCloudBackupState = .ready(lastBackup: remote.updatedAt)
            healthMessage = L.text("icloud.restore.success", remote.healthArchive.count, remote.importBatches.count)
            iCloudErrorMessage = nil
        } catch let error as ICloudBackupError where error == .accountUnavailable {
            iCloudBackupState = .unavailable
            recordICloudFailure(error)
        } catch {
            iCloudBackupState = .failed
            recordICloudFailure(error)
        }
    }

    func dismissICloudRestorePrompt() {
        iCloudRestoreAvailable = false
    }

    private func primaryHealthActivity(on day: Date, records: [WorkoutRecord]) -> DailyActivity? {
        let grouped = Dictionary(grouping: records, by: \.category)
        guard let best = grouped.max(by: { lhs, rhs in
            let leftDuration = lhs.value.reduce(0) { $0 + $1.duration }
            let rightDuration = rhs.value.reduce(0) { $0 + $1.duration }
            if leftDuration == rightDuration {
                let leftEnergy = lhs.value.reduce(0) { $0 + $1.activeEnergy }
                let rightEnergy = rhs.value.reduce(0) { $0 + $1.activeEnergy }
                if leftEnergy == rightEnergy {
                    return lhs.key.rawValue < rhs.key.rawValue
                }
                return leftEnergy < rightEnergy
            }
            return leftDuration < rightDuration
        }) else { return nil }
        return DailyActivity(date: day, category: best.key, source: .healthKit, records: best.value)
    }

    private func saveBatches(_ batches: [CSVImportBatch]) throws {
        do {
            let fileURL = try importArchiveURL ?? Self.importBatchesFileURL()
            let data = try JSONEncoder().encode(batches)
            var options: Data.WritingOptions = .atomic
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try data.write(to: fileURL, options: options)
            defaults.removeObject(forKey: Self.batchesKey)
        } catch {
            throw HealthPersistenceError.saveFailed(error.localizedDescription)
        }
    }

    private func saveBatches() throws {
        try saveBatches(importBatches)
    }

    private func loadBatches() {
        do {
            let fileURL = try importArchiveURL ?? Self.importBatchesFileURL()
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                importBatches = try JSONDecoder().decode([CSVImportBatch].self, from: data)
                return
            }
            guard let legacyData = defaults.data(forKey: Self.batchesKey) else { return }
            importBatches = try JSONDecoder().decode([CSVImportBatch].self, from: legacyData)
            try saveBatches()
        } catch {
            healthMessage = L.text("csv.persistenceFailure", error.localizedDescription)
        }
    }

    private var calendarRecords: [WorkoutRecord] {
        if let calendarRecordsCache { return calendarRecordsCache }
        var byID = Dictionary(uniqueKeysWithValues: healthArchive.map { ($0.id, $0) })
        for record in healthRecords { byID[record.id] = record }
        for id in deletedHealthWorkoutIDs { byID.removeValue(forKey: id) }
        let records = byID.values.sorted { $0.startDate < $1.startDate }
        calendarRecordsCache = records
        return records
    }

    private var persistedHealthState: PersistedHealthState {
        PersistedHealthState(records: healthArchive, deletedWorkoutIDs: deletedHealthWorkoutIDs,
                             anchorData: healthAnchorData, reconciliationVersion: healthReconciliationVersion)
    }

    private func applyHealthState(_ state: PersistedHealthState) {
        healthArchive = state.records
        healthRecords = state.records
        deletedHealthWorkoutIDs = state.deletedWorkoutIDs
        healthAnchorData = state.anchorData
        healthReconciliationVersion = state.reconciliationVersion
        invalidateSummaryCache()
    }

    private func saveHealthState(_ state: PersistedHealthState) throws {
        do {
            let fileURL = try archiveURL ?? Self.healthArchiveFileURL()
            let data = try JSONEncoder().encode(state)
            var options: Data.WritingOptions = .atomic
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            try data.write(to: fileURL, options: options)
            defaults.removeObject(forKey: Self.healthArchiveKey)
            defaults.removeObject(forKey: Self.healthAnchorKey)
        } catch {
            throw HealthPersistenceError.saveFailed(error.localizedDescription)
        }
    }

    private func loadHealthArchive() {
        do {
            let fileURL = try archiveURL ?? Self.healthArchiveFileURL()
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                if let state = try? JSONDecoder().decode(PersistedHealthState.self, from: data) {
                    applyHealthState(state)
                } else {
                    try migrateLegacyHealthArchive(data)
                }
                return
            }
            if let data = defaults.data(forKey: Self.healthArchiveKey) {
                try migrateLegacyHealthArchive(data)
            }
        } catch {
            healthMessage = L.text("health.storageFailure", error.localizedDescription)
        }
    }

    private func migrateLegacyHealthArchive(_ data: Data) throws {
        let records = try JSONDecoder().decode([WorkoutRecord].self, from: data)
        let state = PersistedHealthState(records: records, deletedWorkoutIDs: [],
                                         anchorData: nil, reconciliationVersion: 0)
        // Preserve the visible legacy history even if migration cannot write yet.
        applyHealthState(state)
        try saveHealthState(state)
    }

    private static func applicationSupportDirectory() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDirectory = directory.appendingPathComponent("Strivory", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        return appDirectory
    }

    private static func healthArchiveFileURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent(healthArchiveFileName)
    }

    private static func importBatchesFileURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent(importBatchesFileName)
    }

    private func saveDeletedBatchDates() {
        if let data = try? JSONEncoder().encode(deletedBatchDates) {
            defaults.set(data, forKey: Self.deletedBatchDatesKey)
        }
    }

    private func loadDeletedBatchDates() {
        guard let data = defaults.data(forKey: Self.deletedBatchDatesKey),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data) else { return }
        deletedBatchDates = decoded
    }

    private func backupSnapshot() -> ICloudBackupSnapshot {
        ICloudBackupSnapshot(
            updatedAt: .now,
            healthArchive: calendarRecords,
            importBatches: importBatches,
            deletedBatchDates: deletedBatchDates,
            displayName: userName,
            displayNameUpdatedAt: userNameUpdatedAt,
            deletedHealthWorkoutIDs: deletedHealthWorkoutIDs
        )
    }

    private func applyBackupSnapshot(_ snapshot: ICloudBackupSnapshot, needsReconciliation: Bool = false) throws {
        let state = PersistedHealthState(
            records: snapshot.healthArchive.filter { !snapshot.deletedHealthWorkoutIDs.contains($0.id) },
            deletedWorkoutIDs: snapshot.deletedHealthWorkoutIDs,
            anchorData: healthAnchorData,
            reconciliationVersion: needsReconciliation ? 0 : healthReconciliationVersion
        )
        // Persist both archives before publishing either one to the UI. If the
        // second write fails, restore the previous import file so a restart
        // cannot observe a half-applied CloudKit snapshot.
        let previousBatches = importBatches
        try saveBatches(snapshot.importBatches)
        do {
            try saveHealthState(state)
        } catch {
            try? saveBatches(previousBatches)
            throw error
        }
        applyHealthState(state)
        importBatches = snapshot.importBatches
        deletedBatchDates = snapshot.deletedBatchDates
        isApplyingBackupSnapshot = true
        userName = snapshot.displayName
        isApplyingBackupSnapshot = false
        defaults.set(userName, forKey: Self.userNameKey)
        userNameUpdatedAt = snapshot.displayNameUpdatedAt
        defaults.set(userNameUpdatedAt, forKey: Self.userNameUpdatedAtKey)
        saveDeletedBatchDates()
        invalidateSummaryCache()
    }

    private func scheduleICloudSync() {
        guard iCloudBackupEnabled else { return }
        hasPendingICloudChanges = true
        delayedICloudSyncTask?.cancel()
        delayedICloudSyncTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.delayedICloudSyncTask = nil
            await self?.syncICloudBackup(force: true)
        }
    }

    private func scheduleICloudRetry(after error: Error) {
        guard iCloudBackupEnabled else { return }
        iCloudRetryTask?.cancel()
        iCloudRetryAttempt += 1
        let serverDelay = (error as? CKError)?.userInfo[CKErrorRetryAfterKey] as? TimeInterval
        let fallbackDelay = min(300, pow(2, Double(min(iCloudRetryAttempt, 6))) * 5)
        let delay = max(5, serverDelay ?? fallbackDelay)
        iCloudRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.iCloudRetryTask = nil
            await self?.syncICloudBackup(force: false)
        }
    }

    private func invalidateSummaryCache() {
        summaryCache.removeAll()
        summaryCacheIsValid = false
        calendarRecordsCache = nil
    }

    private func refreshCalendarContextIfNeeded() {
        let current = CalendarSupport.contextIdentifier
        guard current != calendarContextIdentifier else { return }
        calendarContextIdentifier = current
        invalidateSummaryCache()
    }

    private var isAutomaticICloudBackupDue: Bool {
        guard let lastBackup = defaults.object(forKey: Self.lastAutomaticICloudBackupKey) as? Date else {
            return true
        }
        return !Calendar.autoupdatingCurrent.isDate(lastBackup, inSameDayAs: .now)
    }

    private func iCloudFailureMessage(_ error: Error) -> String {
        if let backupError = error as? ICloudBackupError {
            return backupError.localizedDescription
        }
        guard let cloudError = error as? CKError else {
            return L.text("icloud.error.genericDiagnostic", error.localizedDescription)
        }
        switch cloudError.code {
        case .notAuthenticated:
            return L.text("icloud.error.account")
        case .permissionFailure, .missingEntitlement:
            return L.text("icloud.error.permission")
        case .badContainer:
            return L.text("icloud.error.container")
        case .badDatabase:
            return L.text("icloud.error.configuration")
        case .invalidArguments, .serverRejectedRequest:
            return detailedCloudErrorMessage(cloudError)
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy, .accountTemporarilyUnavailable:
            return L.text("icloud.error.network")
        default:
            return L.text("icloud.error.genericDiagnostic", String(describing: cloudError.code))
        }
    }

    private func recordICloudFailure(_ error: Error) {
        let message = iCloudFailureMessage(error)
        iCloudErrorMessage = message
        healthMessage = message
    }

    private func detailedCloudErrorMessage(_ error: CKError) -> String {
        let serverDescription = error.userInfo["CKErrorServerDescription"] as? String
        let underlyingDescription = (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription
        let description = serverDescription ?? underlyingDescription ?? error.localizedDescription
        return L.text("icloud.error.serverDiagnostic", description, String(error.code.rawValue))
    }
}
