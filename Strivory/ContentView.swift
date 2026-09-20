import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingImporter = false
    @State private var showingImportStart = false
    @State private var showingSettings = false
    @State private var pendingImport: CSVParseResult?
    @State private var showingExport = false
    @State private var selectedActivity: DailyActivity?

    var body: some View {
        let summaries = homeSummaries
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    header(yearCount: summaries.count)
                    ForEach(summaries) { summary in
                        YearCalendarView(summary: summary, onSelect: { selectedActivity = $0 })
                    }
                    sourceStatus
                    ImportBatchesView()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Strivory")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await store.requestHealthAccessAndRefresh(forceFullRefresh: true) }
                    } label: {
                        if store.isLoadingHealth { ProgressView() } else { Label(L.text("action.syncHealth"), systemImage: "heart.text.square") }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showingImportStart = true } label: { Image(systemName: "square.and.arrow.down") }
                    Button { showingExport = true } label: { Image(systemName: "square.and.arrow.up") }
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
                switch result {
                case .success(let url):
                    let fileName = url.lastPathComponent
                    let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                    guard size ?? 0 <= CSVImporter.maximumFileSize else {
                        store.healthMessage = L.text("csv.readFailure", "File exceeds the 5 MB import limit.")
                        return
                    }
                    Task.detached {
                        let secured = url.startAccessingSecurityScopedResource()
                        defer { if secured { url.stopAccessingSecurityScopedResource() } }
                        do {
                            let data = try Data(contentsOf: url)
                            guard let contents = CSVImporter.decode(data) else {
                                throw CocoaError(.fileReadInapplicableStringEncoding)
                            }
                            let parsed = CSVImporter.parse(contents: contents, fileName: fileName)
                            await MainActor.run { pendingImport = parsed }
                        } catch {
                            await MainActor.run {
                                store.healthMessage = L.text("csv.readFailure", error.localizedDescription)
                            }
                        }
                    }
                case .failure(let error):
                    store.healthMessage = L.text("csv.notSelected", error.localizedDescription)
                }
            }
            .sheet(item: $pendingImport) { result in
                CSVImportReviewView(result: result)
            }
            .sheet(isPresented: $showingImportStart) {
                ImportStartView {
                    showingImportStart = false
                    showingImporter = true
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $showingExport) {
                ExportView(initialYear: homeSummaries.first?.year ?? CalendarSupport.year(for: .now))
            }
            .sheet(item: $selectedActivity) { activity in
                DayDetailView(activity: activity)
            }
            .alert(L.text("icloud.restore.title"), isPresented: $store.iCloudRestoreAvailable) {
                Button(L.text("icloud.restore.action")) {
                    Task { await store.restoreICloudBackup() }
                }
                Button(L.text("icloud.restore.later"), role: .cancel) {
                    store.dismissICloudRestorePrompt()
                }
            } message: {
                Text(L.text("icloud.restore.message"))
            }
        }
    }

    private var homeSummaries: [YearSummary] {
        let summaries = store.availableYears
            .map { store.summary(for: $0) }
            .filter { $0.activeDays > 0 }
        return summaries.isEmpty ? [store.summary(for: CalendarSupport.year(for: .now))] : summaries
    }

    private func header(yearCount: Int) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L.text("home.slogan"))
                    .font(.headline)
                Text(L.text("home.subtitle"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(L.text("home.yearCount", yearCount))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
        }
    }

    @ViewBuilder
    private var sourceStatus: some View {
        if let message = store.healthMessage {
            Label(message, systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct YearCalendarView: View {
    let summary: YearSummary
    var onSelect: ((DailyActivity) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L.text("year.card.title", CalendarSupport.yearText(summary.year)))
                        .font(.title3.weight(.bold))
                    Text(L.text("year.card.stats", summary.activeDays, CalendarSupport.daysInYear(summary.year), CalendarSupport.percentage(summary) * 100))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "calendar")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
            }
            CalendarHeatmap(summary: summary, onSelect: onSelect)
            Divider()
            LegendView(summary: summary)
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 12, y: 5)
    }
}

struct LegendView: View {
    let summary: YearSummary

    var displayCategories: [WorkoutCategory] {
        summary.topCategories + [.other]
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                legendItems
            }
            .padding(.horizontal, 1)
        }
        .accessibilityLabel(L.text("legend.accessibility"))
    }

    @ViewBuilder
    private var legendItems: some View {
        ForEach(Array(displayCategories.enumerated()), id: \.offset) { _, category in
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(category.color)
                    .frame(width: 11, height: 11)
                Text("\(category.title) (\(summary.count(for: category)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

struct CalendarHeatmap: View {
    let summary: YearSummary
    var onSelect: ((DailyActivity) -> Void)?

    private var weeks: [[Date]] { CalendarGrid.weeks(for: summary.year) }

    var body: some View {
        let calendarWeeks = weeks
        let monthLabels = CalendarGrid.monthLabels(for: calendarWeeks)
        let weekdayLabels = CalendarGrid.weekdayLabels
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 3) {
                    Text("").frame(width: 27)
                    ForEach(Array(calendarWeeks.enumerated()), id: \.offset) { index, _ in
                        Text(monthLabels[index])
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: 15, alignment: .leading)
                    }
                }
                HStack(alignment: .top, spacing: 3) {
                    weekdayLabelsView(weekdayLabels)
                    HStack(alignment: .top, spacing: 3) {
                        ForEach(Array(calendarWeeks.enumerated()), id: \.offset) { _, week in
                            VStack(spacing: 3) {
                                ForEach(week, id: \.self) { date in
                                    dayCell(date)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func weekdayLabelsView(_ labels: [String]) -> some View {
        VStack(spacing: 3) {
            ForEach(0..<7, id: \.self) { index in
                Text(index.isMultiple(of: 2) ? labels[index] : "")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 27, height: 15, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ date: Date) -> some View {
        let isInYear = CalendarSupport.year(for: date) == summary.year
        let activity = summary.dailyActivities[CalendarSupport.startOfDay(date)]
        Button {
            if let activity { onSelect?(activity) }
        } label: {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(fillColor(for: date, isInYear: isInYear))
                .frame(width: 15, height: 15)
                .overlay {
                    if activity != nil {
                        RoundedRectangle(cornerRadius: 2.5).stroke(.white.opacity(0.35), lineWidth: 0.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(activity == nil)
        .accessibilityLabel(accessibilityText(for: date, activity: activity, isInYear: isInYear))
    }

    private func fillColor(for date: Date, isInYear: Bool) -> Color {
        guard isInYear else { return .clear }
        guard let category = summary.displayCategory(on: CalendarSupport.startOfDay(date)) else {
            return Color(uiColor: .systemGray5)
        }
        return category.color
    }

    private func accessibilityText(for date: Date, activity: DailyActivity?, isInYear: Bool) -> String {
        guard isInYear else { return L.text("calendar.outsideYear") }
        let dateText = CalendarSupport.dateText(date, style: .medium)
        return activity.map { L.text("calendar.activityAccessibility", dateText, $0.category.title) }
            ?? L.text("calendar.noActivityAccessibility", dateText)
    }
}

enum CalendarGrid {
    static var weekdayLabels: [String] {
        let formatter = DateFormatter()
        formatter.locale = L.locale
        formatter.calendar = CalendarSupport.mondayCalendar
        let labels = formatter.shortWeekdaySymbols ?? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return [2, 3, 4, 5, 6, 7, 1].map { labels[$0 - 1] }
    }

    static func weeks(for year: Int) -> [[Date]] {
        let calendar = CalendarSupport.mondayCalendar
        guard let first = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let last = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) else { return [] }
        let firstIndex = (calendar.component(.weekday, from: first) + 5) % 7
        let lastIndex = (calendar.component(.weekday, from: last) + 5) % 7
        let start = calendar.date(byAdding: .day, value: -firstIndex, to: first)!
        let end = calendar.date(byAdding: .day, value: 6 - lastIndex, to: last)!
        var result: [[Date]] = []
        var weekStart = start
        while weekStart <= end {
            result.append((0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) })
            weekStart = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        }
        return result
    }

    static func monthLabels(for weeks: [[Date]]) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = L.locale
        formatter.calendar = CalendarSupport.mondayCalendar
        formatter.setLocalizedDateFormatFromTemplate("LLL")
        return weeks.map { week in
            guard let firstOfMonth = week.first(where: { CalendarSupport.mondayCalendar.component(.day, from: $0) == 1 }) else { return "" }
            return formatter.string(from: firstOfMonth)
        }
    }
}

struct DayDetailView: View {
    let activity: DailyActivity
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                    Section(CalendarSupport.dateText(activity.date, style: .full)) {
                    LabeledContent(L.text("detail.primaryWorkout"), value: activity.category.title)
                    LabeledContent(L.text("detail.source"), value: activity.source == .healthKit ? L.text("source.health") : L.text("source.csv"))
                }
                if activity.source == .healthKit {
                    Section(L.text("detail.includedWorkouts")) {
                        ForEach(activity.records) { record in
                            VStack(alignment: .leading) {
                                Text(record.category.title)
                                Text(L.text("detail.durationMinutes", Int(record.duration / 60)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(L.text("detail.navigationTitle"))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L.text("action.done")) { dismiss() } } }
        }
    }
}
