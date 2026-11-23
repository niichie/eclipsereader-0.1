import SwiftUI
import Charts

/// Reading time, chapters finished, streaks and the last two weeks at a glance.
struct StatsPage: View {
    @EnvironmentObject private var model: LibraryModel
    private struct Day: Identifiable {
        let date: Date
        let minutes: Double
        let finished: Int
        var id: Date { date }
    }
    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let readingLog = model.state.readingLog ?? [:]
        let finishedLog = model.state.finishedLog ?? [:]
        let days: [Day] = (0..<14).reversed().compactMap { back -> Day? in
            guard let date = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            let key = LibraryModel.day(date)
            return Day(date: date, minutes: (readingLog[key] ?? 0) / 60, finished: finishedLog[key] ?? 0)
        }
        let week = days.suffix(7)
        let totalMinutes = readingLog.values.reduce(0, +) / 60
        let totalFinished = finishedLog.values.reduce(0, +)
        let streak = Self.streak(readingLog, calendar: calendar, today: today)
        Form {
            Section {
                HStack(spacing: 0) {
                    stat(Self.duration(week.reduce(0.0) { $0 + $1.minutes }), "this week")
                    stat("\(week.reduce(0) { $0 + $1.finished })", "chapters this week")
                    stat("\(streak)", "day streak")
                }
                .listRowBackground(Color.clear)
            }
            Section("Last two weeks") {
                Chart(days) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Minutes", day.minutes))
                        .foregroundStyle(LinearGradient(colors: [Eclipse.highlight, Eclipse.accent], startPoint: .top, endPoint: .bottom))
                        .cornerRadius(4)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                    }
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 180)
                .padding(.vertical, 6)
                .accessibilityLabel("Minutes read per day over the last two weeks")
            }
            Section("All time") {
                LabeledContent("Time reading", value: Self.duration(totalMinutes))
                LabeledContent("Chapters finished", value: "\(totalFinished)")
                LabeledContent("Series in your library", value: "\(model.librarySeries.count)")
                LabeledContent("Chapters read", value: "\(model.librarySeries.reduce(0) { $0 + model.readCount($1) })")
            }
        }
        .navigationTitle("Reading stats").navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).background(EclipseBackground())
    }
    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.title2.weight(.heavy)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
            Text(label).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Eclipse.surface, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 3)
    }
    static func duration(_ minutes: Double) -> String {
        if minutes < 1 { return "0 min" }
        if minutes < 60 { return "\(Int(minutes.rounded())) min" }
        let hours = Int(minutes / 60), rest = Int(minutes.truncatingRemainder(dividingBy: 60))
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
    /// Consecutive days with at least a minute of reading, ending today (or yesterday).
    static func streak(_ log: [String: Double], calendar: Calendar, today: Date) -> Int {
        var count = 0
        var day = today
        if (log[LibraryModel.day(day)] ?? 0) < 60, let yesterday = calendar.date(byAdding: .day, value: -1, to: day) { day = yesterday }
        while (log[LibraryModel.day(day)] ?? 0) >= 60 {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }
}
