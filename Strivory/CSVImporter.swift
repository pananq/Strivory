import CoreFoundation
import Foundation

struct CSVImportIssue: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case invalidHeader, invalidDate, missingType, duplicateDate }

    let id = UUID()
    let line: Int
    let message: String
    let kind: Kind
}

struct CSVParseResult: Identifiable, Sendable {
    let id = UUID()
    let fileName: String
    let records: [WorkoutRecord]
    let issues: [CSVImportIssue]

    var hasBlockingIssues: Bool {
        issues.contains { $0.kind == .invalidHeader || $0.kind == .duplicateDate }
    }
}

enum CSVImporter {
    static let maximumFileSize = 5 * 1_024 * 1_024

    static func decode(_ data: Data) -> String? {
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        return [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, gb18030]
            .lazy
            .compactMap { String(data: data, encoding: $0) }
            .first
    }

    static func parse(contents: String, fileName: String) -> CSVParseResult {
        let lines = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard let header = lines.first else {
            return CSVParseResult(fileName: fileName, records: [], issues: [CSVImportIssue(line: 1, message: L.text("csvError.emptyFile"), kind: .invalidHeader)])
        }

        let normalizedHeader = parseLine(header).map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        let dateIndex = normalizedHeader.firstIndex(where: { $0 == "date" || $0 == "日期" })
        let typeIndex = normalizedHeader.firstIndex(where: { $0 == "workout_type" || $0 == "运动类型" })
        guard let dateIndex, let typeIndex else {
            return CSVParseResult(fileName: fileName, records: [], issues: [CSVImportIssue(line: 1, message: L.text("csvError.header"), kind: .invalidHeader)])
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"

        var records: [WorkoutRecord] = []
        var issues: [CSVImportIssue] = []
        var seenDates = Set<Date>()
        let today = CalendarSupport.startOfDay(.now)

        for (offset, line) in lines.dropFirst().enumerated() {
            let lineNumber = offset + 2
            let fields = parseLine(line)
            guard fields.indices.contains(dateIndex), fields.indices.contains(typeIndex) else {
                issues.append(CSVImportIssue(line: lineNumber, message: L.text("csvError.columns"), kind: .invalidHeader))
                continue
            }
            let dateText = fields[dateIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let type = fields[typeIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let date = formatter.date(from: dateText), CalendarSupport.startOfDay(date) <= today else {
                issues.append(CSVImportIssue(line: lineNumber, message: L.text("csvError.date", dateText), kind: .invalidDate))
                continue
            }
            guard !type.isEmpty else {
                issues.append(CSVImportIssue(line: lineNumber, message: L.text("csvError.type"), kind: .missingType))
                continue
            }
            let day = CalendarSupport.startOfDay(date)
            guard seenDates.insert(day).inserted else {
                issues.append(CSVImportIssue(line: lineNumber, message: L.text("csvError.duplicateDate", dateText), kind: .duplicateDate))
                continue
            }
            records.append(WorkoutRecord(startDate: day, category: WorkoutCategory.fromImportedLabel(type), duration: 0, source: .csv))
        }
        return CSVParseResult(fileName: fileName, records: records, issues: issues)
    }

    private static func parseLine(_ line: String) -> [String] {
        var values: [String] = []
        var value = ""
        var inQuotes = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                let next = line.index(after: index)
                if inQuotes, next < line.endIndex, line[next] == "\"" {
                    value.append("\"")
                    index = next
                } else {
                    inQuotes.toggle()
                }
            } else if character == ",", !inQuotes {
                values.append(value)
                value = ""
            } else {
                value.append(character)
            }
            index = line.index(after: index)
        }
        values.append(value)
        return values
    }
}
