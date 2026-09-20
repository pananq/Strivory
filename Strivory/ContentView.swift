import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingImporter = false
    @State private var showingImportStart = false
#if targetEnvironment(simulator)
    @State private var showingSettings = SimulatorTestConfiguration.hasFlag("-ShowSettings")
#else
    @State private var showingSettings = false
#endif
    @State private var pendingImport: CSVParseResult?
#if targetEnvironment(simulator)
    @State private var showingExport = SimulatorTestConfiguration.hasFlag("-ShowPoster")
#else
    @State private var showingExport = false
#endif
    @State private var selectedActivity: DailyActivity?
    @State private var simulatorTemplate: ExportPosterTemplate = .editorial
    @State private var showingSimulatorTemplateGallery: Bool = {
#if targetEnvironment(simulator)
        SimulatorTestConfiguration.hasFlag("-ShowTemplateGallery")
#else
        false
#endif
    }()

    var body: some View {
        let summaries = homeSummaries
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    homeTitleBar
                    syncStatus
                    overviewHeader(summaries: summaries)

                    HStack {
                        Text(L.text("home.allYears"))
                            .font(.headline)
                        Spacer()
                        Text(L.text("home.newestFirst"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(summaries) { summary in
                        YearCalendarView(summary: summary, onSelect: { selectedActivity = $0 })
                    }
                    sourceStatus
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                Button { showingExport = true } label: {
                    Label(L.text("home.createPoster"), systemImage: "photo.on.rectangle.angled")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .background(.ultraThinMaterial)
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
            .sheet(isPresented: $showingSettings) {
                SettingsView {
                    showingSettings = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showingImportStart = true
                    }
                }
            }
            .sheet(isPresented: $showingExport) {
                ExportView(initialYear: homeSummaries.first?.year ?? CalendarSupport.year(for: .now))
            }
            .sheet(isPresented: $showingSimulatorTemplateGallery) {
                PosterTemplateGallery(selection: $simulatorTemplate)
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

    private var homeTitleBar: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("Strivory")
                .font(.system(size: 38, weight: .bold, design: .default))
                .tracking(-1)

            Spacer(minLength: 12)

            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 21, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color(uiColor: .separator).opacity(0.2), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L.text("settings.title"))
        }
        .padding(.top, 2)
    }

    private var homeSummaries: [YearSummary] {
        let summaries = store.availableYears
            .map { store.summary(for: $0) }
            .filter { $0.activeDays > 0 }
        return summaries.isEmpty ? [store.summary(for: CalendarSupport.year(for: .now))] : summaries
    }

    private var syncStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.isLoadingHealth ? Color.orange : Color.accentColor)
                .frame(width: 7, height: 7)
            Text(store.isLoadingHealth ? L.text("home.syncing") : L.text("home.synced"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await store.requestHealthAccessAndRefresh(forceFullRefresh: true) }
            } label: {
                if store.isLoadingHealth {
                    ProgressView().controlSize(.small)
                } else {
                    Label(L.text("home.sync"), systemImage: "arrow.clockwise")
                        .font(.caption.weight(.medium))
                }
            }
            .disabled(store.isLoadingHealth)
        }
    }

    private func overviewHeader(summaries: [YearSummary]) -> some View {
        let activeSummaries = summaries.filter { $0.activeDays > 0 }
        let totalDays = activeSummaries.reduce(0) { $0 + $1.activeDays }
        let currentYear = CalendarSupport.year(for: .now)
        let currentDays = activeSummaries.first(where: { $0.year == currentYear })?.activeDays ?? 0

        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.exportName + L.text("home.archiveSuffix"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(L.text("home.slogan"))
                    .font(.title3.weight(.semibold))
                Text(L.text("home.subtitle"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .lastTextBaseline, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(totalDays)")
                        .font(.system(size: 58, weight: .regular, design: .serif))
                        .monospacedDigit()
                    Text(L.text("home.totalActiveDays"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                homeStat(value: currentDays, label: L.text("home.thisYear"))
                homeStat(value: activeSummaries.count, label: L.text("home.loggedYears"))
            }
        }
    }

    private func homeStat(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private let cellSize: CGFloat = 15
    private let cellSpacing: CGFloat = 3

    var body: some View {
        let layout = CalendarGrid.layout(for: summary.year)
        let step = cellSize + cellSpacing
        let gridWidth = CGFloat(layout.weeks.count) * step - cellSpacing
        let gridHeight = 7 * step - cellSpacing
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 3) {
                    Text("").frame(width: 27)
                    ForEach(Array(layout.weeks.enumerated()), id: \.offset) { index, _ in
                        Text(layout.monthLabels[index])
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: 15, alignment: .leading)
                    }
                }
                HStack(alignment: .top, spacing: 3) {
                    weekdayLabelsView(layout.weekdayLabels)
                    heatmapCanvas(
                        weeks: layout.weeks,
                        step: step,
                        width: gridWidth,
                        height: gridHeight
                    )
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

    private func heatmapCanvas(weeks: [[Date]], step: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        Canvas(rendersAsynchronously: true) { context, _ in
            for (weekIndex, week) in weeks.enumerated() {
                for (dayIndex, date) in week.enumerated() {
                    let isInYear = CalendarSupport.year(for: date) == summary.year
                    let day = CalendarSupport.startOfDay(date)
                    let rect = CGRect(
                        x: CGFloat(weekIndex) * step,
                        y: CGFloat(dayIndex) * step,
                        width: cellSize,
                        height: cellSize
                    )
                    let path = Path(roundedRect: rect, cornerRadius: 2.5)
                    context.fill(path, with: .color(fillColor(for: day, isInYear: isInYear)))
                    if summary.dailyActivities[day] != nil {
                        context.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
                    }
                }
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .gesture(
            SpatialTapGesture().onEnded { value in
                let weekIndex = Int(value.location.x / step)
                let dayIndex = Int(value.location.y / step)
                guard weeks.indices.contains(weekIndex),
                      weeks[weekIndex].indices.contains(dayIndex),
                      value.location.x.truncatingRemainder(dividingBy: step) <= cellSize,
                      value.location.y.truncatingRemainder(dividingBy: step) <= cellSize else { return }
                let day = CalendarSupport.startOfDay(weeks[weekIndex][dayIndex])
                if let activity = summary.dailyActivities[day] {
                    onSelect?(activity)
                }
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L.text("year.card.title", CalendarSupport.yearText(summary.year)))
    }

    private func fillColor(for date: Date, isInYear: Bool) -> Color {
        guard isInYear else { return .clear }
        guard let category = summary.displayCategory(on: CalendarSupport.startOfDay(date)) else {
            return Color(uiColor: .systemGray5)
        }
        return category.color
    }

}

@MainActor
enum CalendarGrid {
    struct Layout {
        let weeks: [[Date]]
        let monthLabels: [String]
        let weekdayLabels: [String]
    }

    private static var layoutCache: [String: Layout] = [:]

    static func layout(for year: Int) -> Layout {
        let key = "\(year)|\(L.locale.identifier)"
        if let cached = layoutCache[key] { return cached }
        let weeks = makeWeeks(for: year)
        let layout = Layout(
            weeks: weeks,
            monthLabels: makeMonthLabels(for: weeks),
            weekdayLabels: makeWeekdayLabels()
        )
        layoutCache[key] = layout
        return layout
    }

    private static func makeWeekdayLabels() -> [String] {
        let formatter = DateFormatter()
        formatter.locale = L.locale
        formatter.calendar = CalendarSupport.mondayCalendar
        let labels = formatter.shortWeekdaySymbols ?? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return [2, 3, 4, 5, 6, 7, 1].map { labels[$0 - 1] }
    }

    private static func makeWeeks(for year: Int) -> [[Date]] {
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

    private static func makeMonthLabels(for weeks: [[Date]]) -> [String] {
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
