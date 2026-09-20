import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Photos

/// Keeps the Photos change block outside SwiftUI's `MainActor`.
/// `PHPhotoLibrary` runs this closure on its own serial queue, so a closure
/// inherited from a `@MainActor` view method will trigger a dispatch assertion.
private enum PhotoLibraryWriter {
    static func savePNGData(_ data: Data, completion: @escaping @Sendable (Bool, Error?) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }, completionHandler: completion)
    }
}

struct CSVTemplateDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    let text: String

    init() { text = L.text("csv.template") }
    init(configuration: ReadConfiguration) throws { text = "" }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: text.data(using: .utf8) ?? Data())
    }
}

struct ImportStartView: View {
    @Environment(\.dismiss) private var dismiss
    let chooseFile: () -> Void
    @State private var exportingTemplate = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "tablecells.badge.ellipsis")
                    .font(.system(size: 42))
                    .foregroundStyle(Color.accentColor)
                Text(L.text("importStart.title"))
                    .font(.title2.weight(.bold))
                Text(L.text("importStart.description"))
                    .foregroundStyle(.secondary)
                Text(L.text("csv.template.preview"))
                    .font(.system(.footnote, design: .monospaced))
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .systemGray6), in: RoundedRectangle(cornerRadius: 12))
                Button { exportingTemplate = true } label: {
                    Label(L.text("importStart.downloadTemplate"), systemImage: "arrow.down.doc")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(action: chooseFile) {
                    Label(L.text("importStart.chooseFile"), systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .navigationTitle(L.text("importStart.navigationTitle"))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L.text("action.close")) { dismiss() } } }
            .fileExporter(isPresented: $exportingTemplate, document: CSVTemplateDocument(), contentType: .commaSeparatedText, defaultFilename: "strivory-workout-template") { _ in }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(L.text("settings.languageSection")) {
                    Picker(L.text("settings.language"), selection: $store.language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    Text(L.text("settings.languageHint"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section(L.text("settings.exportSection")) {
                    TextField(L.text("settings.displayName"), text: $store.userName)
                    Text(L.text("settings.displayNameHint"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section(L.text("settings.iCloudSection")) {
                    Toggle(L.text("settings.iCloudBackup"), isOn: $store.iCloudBackupEnabled)
                    Text(L.text("settings.iCloudBackupHint"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Label(store.iCloudBackupStatusText, systemImage: store.isSyncingICloud ? "arrow.triangle.2.circlepath" : "icloud")
                        .foregroundStyle(.secondary)
                    if store.iCloudBackupEnabled {
                        Button {
                            Task { await store.syncICloudBackup() }
                        } label: {
                            Label(L.text("icloud.syncNow"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(store.isSyncingICloud)
                    }
                    if store.hasICloudBackup && !store.iCloudBackupEnabled {
                        Button {
                            Task { await store.restoreICloudBackup() }
                        } label: {
                            Label(L.text("icloud.restore.action"), systemImage: "arrow.clockwise.icloud")
                        }
                    }
                }
                Section(L.text("settings.privacySection")) {
                    Label(L.text("settings.privacyLocal"), systemImage: "lock.shield")
                    Label(L.text("settings.privacyNoWrite"), systemImage: "heart.slash")
                }
            }
            .navigationTitle(L.text("settings.navigationTitle"))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L.text("action.done")) { dismiss() } } }
        }
    }
}

struct CSVImportReviewView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let result: CSVParseResult
    @State private var strategy: CSVImportStrategy = .supplement

    private var healthConflictCount: Int {
        let healthDays = Set(store.healthRecords.map { CalendarSupport.startOfDay($0.startDate) })
        return result.records.filter { healthDays.contains(CalendarSupport.startOfDay($0.startDate)) }.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section(L.text("csvReview.previewSection")) {
                    LabeledContent(L.text("csvReview.file"), value: result.fileName)
                    LabeledContent(L.text("csvReview.importable"), value: "\(result.records.count)")
                    LabeledContent(L.text("csvReview.healthConflicts"), value: "\(healthConflictCount)")
                    LabeledContent(L.text("csvReview.issues"), value: "\(result.issues.count)")
                }
                Section(L.text("csvReview.strategySection")) {
                    Picker(L.text("csvReview.strategy"), selection: $strategy) {
                        ForEach(CSVImportStrategy.allCases) { strategy in
                            Text(strategy.title).tag(strategy)
                        }
                    }
                    .pickerStyle(.inline)
                    Text(strategy.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !result.issues.isEmpty {
                    Section(L.text("csvReview.actionRequired")) {
                        ForEach(result.issues) { issue in
                            Label(L.text("csvReview.issueLine", issue.line, issue.message), systemImage: issue.kind == .duplicateDate ? "exclamationmark.triangle" : "info.circle")
                                .foregroundStyle(issue.kind == .duplicateDate || issue.kind == .invalidHeader ? .red : .secondary)
                        }
                    }
                }
                if !result.records.isEmpty {
                    Section(L.text("csvReview.samples")) {
                        ForEach(result.records.prefix(8)) { record in
                            LabeledContent(CalendarSupport.dateText(record.startDate, style: .medium), value: record.category.title)
                        }
                    }
                }
            }
            .navigationTitle(L.text("csvReview.navigationTitle"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L.text("action.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.text("action.import")) {
                        store.importCSV(result, strategy: strategy)
                        dismiss()
                    }
                    .disabled(result.records.isEmpty || result.hasBlockingIssues)
                }
            }
        }
    }
}

struct ImportBatchesView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        if !store.importBatches.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(L.text("batches.title"))
                    .font(.headline)
                ForEach(store.importBatches.sorted { $0.createdAt > $1.createdAt }) { batch in
                    HStack(spacing: 12) {
                        Image(systemName: "tablecells")
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(batch.name).lineLimit(1)
                            Text(L.text("batches.summary", batch.records.count, batch.strategy.title))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { store.deleteBatch(batch) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(12)
                    .background(.background, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }
}

struct ExportView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let initialYear: Int
    @State private var selectedYears: Set<Int> = []
    @State private var generatedImage: UIImage?
    @State private var isGeneratingImage = false
    @State private var showingShareSheet = false
    @State private var saveResult: SaveResult?
    @State private var selectedTemplate: ExportPosterTemplate = .editorial

    private var years: [Int] { store.availableYears }
    private var summaries: [YearSummary] {
        selectedYears.sorted(by: >).map { store.summary(for: $0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section(L.text("export.yearsSection")) {
                    Button(selectedYears.count == years.count ? L.text("action.deselectAll") : L.text("action.selectAll")) {
                        selectedYears = selectedYears.count == years.count ? [] : Set(years.prefix(10))
                    }
                    ForEach(years, id: \.self) { year in
                        Toggle(L.text("export.yearToggle", CalendarSupport.yearText(year)), isOn: Binding(
                            get: { selectedYears.contains(year) },
                            set: { isSelected in
                                if isSelected, selectedYears.count < 10 { selectedYears.insert(year) }
                                else { selectedYears.remove(year) }
                            }
                        ))
                        .disabled(!selectedYears.contains(year) && selectedYears.count >= 10)
                    }
                    Text(L.text("export.yearsHint"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section(L.text("export.templateSection")) {
                    Picker(L.text("export.templatePicker"), selection: $selectedTemplate) {
                        ForEach(ExportPosterTemplate.allCases) { template in
                            Label(template.title, systemImage: template.symbolName)
                                .tag(template)
                        }
                    }
                    .pickerStyle(.inline)
                    Text(selectedTemplate.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section(L.text("export.previewSection")) {
                    if let image = generatedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        HStack(spacing: 12) {
                            Button { saveToPhotoLibrary(image) } label: {
                                Label(L.text("export.savePhoto"), systemImage: "photo.badge.arrow.down")
                            }
                            .buttonStyle(.borderedProminent)
                            Button { showingShareSheet = true } label: {
                                Label(L.text("export.sharePNG"), systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.bordered)
                        }
                    } else {
                        Text(L.text("export.previewHint"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(L.text("export.navigationTitle"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L.text("action.close")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        generateImage()
                    } label: {
                        if isGeneratingImage { ProgressView() }
                        else { Text(L.text("export.generatePNG")) }
                    }
                    .disabled(selectedYears.isEmpty || isGeneratingImage)
                }
            }
            .onAppear { if selectedYears.isEmpty { selectedYears = [initialYear] } }
            .onChange(of: selectedTemplate) { _, _ in generatedImage = nil }
            .sheet(isPresented: $showingShareSheet) {
                if let generatedImage { ShareSheet(items: [generatedImage]) }
            }
            .alert(item: $saveResult) { result in
                Alert(title: Text(result.title), message: Text(result.message), dismissButton: .default(Text(L.text("action.ok"))))
            }
        }
    }

    @MainActor
    private func generateImage() {
        guard !isGeneratingImage else { return }
        isGeneratingImage = true
        let exportSummaries = summaries
        let scale: CGFloat = exportSummaries.count > 5 ? 1.25 : 2
        Task { @MainActor in
            await Task.yield()
            let content = MultiYearExportView(name: store.exportName, summaries: exportSummaries, template: selectedTemplate)
                .frame(width: 1_320)
                .background(.white)
            let renderer = ImageRenderer(content: content)
            renderer.scale = scale
            generatedImage = renderer.uiImage
            isGeneratingImage = false
        }
    }

    @MainActor
    private func saveToPhotoLibrary(_ image: UIImage) {
        let authorization = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if authorization == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { authorization in
                Task { @MainActor in
                    completePhotoAuthorization(authorization, image: image)
                }
            }
        } else {
            completePhotoAuthorization(authorization, image: image)
        }
    }

    @MainActor
    private func completePhotoAuthorization(_ authorization: PHAuthorizationStatus, image: UIImage) {
        guard authorization == .authorized || authorization == .limited else {
            saveResult = SaveResult(title: L.text("photoSave.unavailable.title"), message: L.text("photoSave.unavailable.message"))
            return
        }

        guard let imageData = image.pngData() else {
            saveResult = SaveResult(title: L.text("photoSave.failed.title"), message: L.text("photoSave.imageDataFailure"))
            return
        }

        PhotoLibraryWriter.savePNGData(imageData) { success, error in
            Task { @MainActor in
                saveResult = success
                    ? SaveResult(title: L.text("photoSave.success.title"), message: L.text("photoSave.success.message"))
                    : SaveResult(title: L.text("photoSave.failed.title"), message: error?.localizedDescription ?? L.text("photoSave.failed.message"))
            }
        }
    }
}

struct SaveResult: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum ExportPosterTemplate: String, CaseIterable, Identifiable {
    case editorial
    case nightAtlas

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editorial: L.text("export.template.editorial.title")
        case .nightAtlas: L.text("export.template.nightAtlas.title")
        }
    }

    var detail: String {
        switch self {
        case .editorial: L.text("export.template.editorial.detail")
        case .nightAtlas: L.text("export.template.nightAtlas.detail")
        }
    }

    var symbolName: String {
        switch self {
        case .editorial: "newspaper"
        case .nightAtlas: "moon.stars"
        }
    }
}

struct MultiYearExportView: View {
    let name: String
    let summaries: [YearSummary]
    let template: ExportPosterTemplate

    private var activeDayTotal: Int { summaries.reduce(0) { $0 + $1.activeDays } }
    private var yearRange: String {
        guard let newest = summaries.map(\.year).max(), let oldest = summaries.map(\.year).min() else { return "" }
        if newest == oldest {
            return L.text("export.poster.kicker.single", CalendarSupport.yearText(newest))
        }
        return L.text("export.poster.kicker", CalendarSupport.yearText(oldest), CalendarSupport.yearText(newest))
    }

    var body: some View {
        switch template {
        case .editorial:
            EditorialPosterView(name: name, summaries: summaries, yearRange: yearRange, activeDayTotal: activeDayTotal)
        case .nightAtlas:
            NightAtlasPosterView(name: name, summaries: summaries, yearRange: yearRange, activeDayTotal: activeDayTotal)
        }
    }
}

private struct EditorialPosterView: View {
    let name: String
    let summaries: [YearSummary]
    let yearRange: String
    let activeDayTotal: Int

    private let theme = ExportPosterTheme.editorial

    var body: some View {
        VStack(spacing: 0) {
            ExportPosterHeader(
                name: name,
                yearRange: yearRange,
                activeDayTotal: activeDayTotal,
                yearCount: summaries.count,
                theme: theme
            )
            .padding(.bottom, 46)

            VStack(spacing: 0) {
                ForEach(Array(summaries.enumerated()), id: \.element.id) { index, summary in
                    if index > 0 {
                        Rectangle()
                            .fill(theme.divider)
                            .frame(height: 1)
                    }
                    ExportYearCard(
                        summary: summary,
                        heatmapOpacity: max(0.48, pow(0.84, Double(index))),
                        theme: theme
                    )
                }
            }

            GlobalExportLegendView(summaries: summaries, theme: theme)
                .padding(.top, 34)

            Text(L.text("export.generatedBy"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 28)
        }
        .padding(.horizontal, 54)
        .padding(.vertical, 70)
        .foregroundStyle(theme.primaryText)
        .background(theme.canvas)
    }
}

private struct ExportPosterTheme {
    let canvas: Color
    let primaryText: Color
    let secondaryText: Color
    let divider: Color
    let emptyCell: Color

    static let editorial = ExportPosterTheme(
        canvas: Color(red: 0.995, green: 0.982, blue: 0.963),
        primaryText: Color(red: 0.08, green: 0.08, blue: 0.08),
        secondaryText: Color(red: 0.34, green: 0.33, blue: 0.31),
        divider: Color.black.opacity(0.18),
        emptyCell: Color(red: 0.93, green: 0.91, blue: 0.88)
    )

    static let nightAtlas = ExportPosterTheme(
        canvas: Color(red: 0.055, green: 0.067, blue: 0.075),
        primaryText: Color(red: 0.94, green: 0.95, blue: 0.93),
        secondaryText: Color(red: 0.64, green: 0.68, blue: 0.66),
        divider: Color.white.opacity(0.18),
        emptyCell: Color(red: 0.15, green: 0.17, blue: 0.18)
    )
}

private struct NightAtlasPosterView: View {
    let name: String
    let summaries: [YearSummary]
    let yearRange: String
    let activeDayTotal: Int

    private let theme = ExportPosterTheme.nightAtlas

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L.text("export.nightAtlas.kicker"))
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .tracking(3)
                    Text(yearRange)
                        .font(.system(size: 24, weight: .medium, design: .rounded))
                    Text(name)
                        .font(.system(size: 28, weight: .regular, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 36)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(String(activeDayTotal))
                        .font(.system(size: 118, weight: .regular, design: .serif))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(L.text("export.poster.activeDays"))
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .tracking(4)
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(.bottom, 34)

            Rectangle()
                .fill(theme.divider)
                .frame(height: 1)

            ForEach(Array(summaries.enumerated()), id: \.element.id) { index, summary in
                if index > 0 {
                    Rectangle()
                        .fill(theme.divider)
                        .frame(height: 1)
                }
                NightAtlasYearBand(
                    summary: summary,
                    heatmapOpacity: max(0.48, pow(0.84, Double(index))),
                    theme: theme
                )
            }

            Rectangle()
                .fill(theme.divider)
                .frame(height: 1)
                .padding(.top, 6)

            GlobalExportLegendView(summaries: summaries, theme: theme)
                .padding(.top, 30)

            HStack {
                Text("STRIVORY")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .tracking(2)
                Spacer()
                Text(L.text("export.generatedBy"))
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(theme.secondaryText)
            .padding(.top, 30)
        }
        .padding(.horizontal, 54)
        .padding(.vertical, 58)
        .foregroundStyle(theme.primaryText)
        .background(theme.canvas)
    }
}

private struct NightAtlasYearBand: View {
    let summary: YearSummary
    let heatmapOpacity: Double
    let theme: ExportPosterTheme

    private var stats: String {
        L.text(
            "export.yearCard.stats",
            summary.activeDays,
            CalendarSupport.daysInYear(summary.year),
            CalendarSupport.percentage(summary) * 100
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 34) {
            VStack(alignment: .leading, spacing: 8) {
                Text(CalendarSupport.yearText(summary.year))
                    .font(.system(size: 54, weight: .regular, design: .serif))
                Text(stats)
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(width: 220, alignment: .leading)

            ExportCalendarHeatmap(summary: summary, theme: theme, density: .compact)
                .opacity(heatmapOpacity)
        }
        .padding(.vertical, 30)
    }
}

private struct ExportPosterHeader: View {
    let name: String
    let yearRange: String
    let activeDayTotal: Int
    let yearCount: Int
    let theme: ExportPosterTheme

    var body: some View {
        VStack(spacing: 14) {
            Text(yearRange)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .tracking(5)
            Rectangle()
                .fill(theme.divider)
                .frame(width: 74, height: 1)
                .padding(.vertical, 4)
            Text(name)
                .font(.system(size: 30, weight: .regular, design: .monospaced))
                .tracking(3)
            Text(String(activeDayTotal))
                .font(.system(size: 210, weight: .regular, design: .serif))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 12)
            Text(L.text("export.poster.activeDays"))
                .font(.system(size: 27, weight: .medium, design: .rounded))
                .tracking(10)
            Rectangle()
                .fill(theme.divider)
                .frame(width: 74, height: 1)
                .padding(.top, 10)
            Text(L.text("export.poster.subtitle", yearCount))
                .font(.system(size: 20, weight: .regular, design: .serif))
                .italic()
                .foregroundStyle(theme.secondaryText)
                .padding(.top, 2)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

private struct ExportYearCard: View {
    let summary: YearSummary
    let heatmapOpacity: Double
    let theme: ExportPosterTheme

    private var stats: String {
        L.text(
            "export.yearCard.stats",
            summary.activeDays,
            CalendarSupport.daysInYear(summary.year),
            CalendarSupport.percentage(summary) * 100
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .lastTextBaseline, spacing: 42) {
                Text(CalendarSupport.yearText(summary.year))
                    .font(.system(size: 58, weight: .regular, design: .serif))
                Text(stats)
                    .font(.system(size: 21, weight: .medium, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ExportCalendarHeatmap(summary: summary, theme: theme)
                .frame(maxWidth: .infinity, alignment: .center)
                .opacity(heatmapOpacity)
        }
        .padding(.vertical, 28)
    }
}

/// `ImageRenderer` does not lay out the contents of a nested ScrollView reliably.
/// Exports therefore use this fixed-width, non-interactive version of the calendar.
private struct ExportCalendarHeatmap: View {
    let summary: YearSummary
    let theme: ExportPosterTheme
    let density: Density

    enum Density {
        case standard
        case compact
    }

    init(summary: YearSummary, theme: ExportPosterTheme, density: Density = .standard) {
        self.summary = summary
        self.theme = theme
        self.density = density
    }

    private var cellSize: CGFloat { density == .standard ? 16 : 12 }
    private var spacing: CGFloat { density == .standard ? 4 : 3 }
    private var labelWidth: CGFloat { density == .standard ? 42 : 36 }
    private var monthFontSize: CGFloat { density == .standard ? 12 : 10 }
    private var weekdayFontSize: CGFloat { density == .standard ? 12 : 10 }

    private var weeks: [[Date]] { CalendarGrid.weeks(for: summary.year) }

    var body: some View {
        let calendarWeeks = weeks
        let monthLabels = CalendarGrid.monthLabels(for: calendarWeeks)
        let weekdayLabels = CalendarGrid.weekdayLabels
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: spacing) {
                Color.clear.frame(width: labelWidth, height: 18)
                ForEach(Array(calendarWeeks.enumerated()), id: \.offset) { index, _ in
                    Text(monthLabels[index])
                        .font(.system(size: monthFontSize, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                        .textCase(.uppercase)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: cellSize, alignment: .leading)
                }
            }
            HStack(alignment: .top, spacing: spacing) {
                VStack(spacing: spacing) {
                    ForEach(0..<7, id: \.self) { index in
                        Text(index.isMultiple(of: 2) ? weekdayLabels[index] : "")
                            .font(.system(size: weekdayFontSize, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                            .frame(width: labelWidth, height: cellSize, alignment: .trailing)
                    }
                }
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(Array(calendarWeeks.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: spacing) {
                            ForEach(week, id: \.self) { date in
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(cellColor(for: date))
                                    .frame(width: cellSize, height: cellSize)
                            }
                        }
                    }
                }
            }
        }
    }

    private func cellColor(for date: Date) -> Color {
        guard CalendarSupport.year(for: date) == summary.year else { return .clear }
        guard let category = summary.displayCategory(on: CalendarSupport.startOfDay(date)) else {
            return theme.emptyCell
        }
        return category.color
    }
}

private struct GlobalExportLegendView: View {
    let summaries: [YearSummary]
    let theme: ExportPosterTheme

    private var categories: [WorkoutCategory] {
        let visibleCategories = WorkoutCategory.allCases
            .filter { category in
                category != .other && summaries.contains(where: { summary in summary.topCategories.contains(category) })
            }
            .sorted { lhs, rhs in
                let lhsCount = summaries.reduce(0) { $0 + ($1.topCategories.contains(lhs) ? $1.count(for: lhs) : 0) }
                let rhsCount = summaries.reduce(0) { $0 + ($1.topCategories.contains(rhs) ? $1.count(for: rhs) : 0) }
                return lhsCount == rhsCount ? lhs.rawValue < rhs.rawValue : lhsCount > rhsCount
            }
        return summaries.contains(where: { $0.otherCount > 0 }) ? visibleCategories + [.other] : visibleCategories
    }

    var body: some View {
        CenteredFlowLayout(itemSpacing: 30, rowSpacing: 16) {
            ForEach(categories) { category in
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(category.color)
                        .frame(width: 16, height: 16)
                    Text(category.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CenteredFlowLayout: Layout {
    let itemSpacing: CGFloat
    let rowSpacing: CGFloat

    private struct Row {
        var subviews: [LayoutSubview] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = makeRows(maxWidth: proposal.width ?? .greatestFiniteMagnitude, subviews: subviews)
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + rowSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = makeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for subview in row.subviews {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + itemSpacing
            }
            y += row.height + rowSpacing
        }
    }

    private func makeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var currentRow = Row()
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let proposedWidth = currentRow.subviews.isEmpty ? size.width : currentRow.width + itemSpacing + size.width
            if !currentRow.subviews.isEmpty, proposedWidth > maxWidth {
                rows.append(currentRow)
                currentRow = Row()
            }
            currentRow.width += currentRow.subviews.isEmpty ? size.width : itemSpacing + size.width
            currentRow.height = max(currentRow.height, size.height)
            currentRow.subviews.append(subview)
        }
        if !currentRow.subviews.isEmpty { rows.append(currentRow) }
        return rows
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
