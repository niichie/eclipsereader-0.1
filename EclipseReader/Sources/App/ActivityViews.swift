import SwiftUI

/// New chapters across the whole library, newest series first.
struct UpdatesView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var reader: Chapter?
    var body: some View {
        let index = model.chapterIndex
        let items = (model.state.newChapterIDs ?? []).compactMap { index[$0] }
        let grouped = Dictionary(grouping: items, by: { $0.0.id })
        let order = grouped.keys.sorted { a, b in
            (grouped[a]?.first?.0.title ?? "").localizedCaseInsensitiveCompare(grouped[b]?.first?.0.title ?? "") == .orderedAscending
        }
        NavigationStack {
            List {
                if model.state.notifyNew == nil {
                    Section {
                        HStack(spacing: 14) {
                            Image(systemName: "bell.badge.fill").font(.title2).foregroundStyle(Eclipse.highlight)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Get notified").font(.headline)
                                Text("A notification when a series in your library gets a new chapter.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Button("Turn on") { Task { _ = await model.setNotifications(true) } }
                                .buttonStyle(.borderedProminent).tint(Eclipse.accent)
                        }
                        .swipeActions { Button("Not now") { model.state.notifyNew = false; model.save() } }
                    }
                }
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.checking ? "Checking for new chapters…" : "Up to date")
                                .font(.headline)
                            if let last = model.state.lastUpdateCheck {
                                Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if model.checking { ProgressView() } else {
                            Button("Check now") { Task { await model.checkForUpdates(force: true) } }.buttonStyle(.bordered)
                        }
                    }
                }
                if items.isEmpty && !model.checking {
                    // A row below the cards (not an overlay), so short screens like the Duo's front one never overlap them.
                    Section {
                        ContentUnavailableView("No new chapters", systemImage: "sparkles",
                                               description: Text("New chapters from the series in your library appear here. eclipsereader checks every few hours when you open it."))
                            .frame(maxWidth: .infinity)
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(order, id: \.self) { seriesID in
                    if let entries = grouped[seriesID], let series = entries.first?.0 {
                        Section {
                            ForEach(entries.map { $0.1 }.sorted { ChapterOrder.natural($0.title, $1.title) }) { chapter in
                                HStack(spacing: 12) {
                                    Button { reader = chapter } label: {
                                        HStack(spacing: 12) {
                                            CoverView(url: model.cover(for: series), referer: series.chapters.first)
                                                .frame(width: 40, height: 57).clipShape(RoundedRectangle(cornerRadius: 6))
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(ChapterText.split(chapter.title).name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                                Text(series.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                            Spacer(minLength: 0)
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    DownloadButton(chapter: chapter)
                                }
                            }
                        } header: {
                            HStack {
                                Text(series.title)
                                Spacer()
                                Button("Mark seen") { model.clearNew(series) }.font(.caption)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden).background(EclipseBackground())
            .navigationTitle("Updates")
            .refreshable { await model.checkForUpdates(force: true) }
            .fullScreenCover(item: $reader) { chapter in ReaderView(chapter: chapter).environmentObject(model) }
        }
    }
}

private struct HistoryItem: Identifiable {
    let series: MangaSeries
    let chapter: Chapter
    let progress: ChapterProgress
    var id: String { chapter.id }
}

/// Recently read chapters, like a browser history. Swipe to forget one.
struct HistoryView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var reader: Chapter?
    @State private var confirmClear = false
    var body: some View {
        let index = model.chapterIndex
        // Like Mihon: the latest chapter of each series, grouped by day.
        var seen = Set<String>()
        let items = Array(model.state.progress
            .compactMap { entry in index[entry.key].map { HistoryItem(series: $0.0, chapter: $0.1, progress: entry.value) } }
            .filter { $0.progress.updated > (model.state.historyCleared ?? .distantPast) }
            .sorted { $0.progress.updated > $1.progress.updated }
            .filter { seen.insert($0.series.id).inserted }
            .prefix(150))
        let days = Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.progress.updated) }
        let order = days.keys.sorted(by: >)
        NavigationStack {
            List {
                if model.state.incognito == true {
                    Label("Incognito is on: nothing new is added to history.", systemImage: "eyeglasses")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if items.isEmpty {
                    Section {
                        ContentUnavailableView("No history yet", systemImage: "clock", description: Text("Chapters you read show up here."))
                            .frame(maxWidth: .infinity)
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(order, id: \.self) { day in
                    Section {
                        ForEach(days[day] ?? []) { item in
                            historyRow(item)
                        }
                    } header: {
                        Text(Self.dayTitle(day)).font(.subheadline.weight(.bold)).foregroundStyle(.white).textCase(nil)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden).background(EclipseBackground())
            .navigationTitle("History")
            .toolbar {
                if !items.isEmpty {
                    Button("Clear") { confirmClear = true }
                }
            }
            .confirmationDialog("Clear reading history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear history", role: .destructive) { model.clearHistory() }
            } message: { Text("Where you stopped in each chapter is forgotten. Finished chapters stay marked as read.") }
            .fullScreenCover(item: $reader) { chapter in ReaderView(chapter: chapter).environmentObject(model) }
        }
    }
    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if let week = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: Date())), day >= week {
            return day.formatted(.dateTime.weekday(.wide))
        }
        return day.formatted(.dateTime.month(.wide).day().year())
    }
    private func historyRow(_ item: HistoryItem) -> some View {
                    Button { reader = item.chapter } label: {
                        HStack(spacing: 12) {
                            CoverView(url: model.cover(for: item.series), referer: item.series.chapters.first)
                                .frame(width: 44, height: 63).clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.series.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(ChapterText.split(item.chapter.title).name).font(.caption).lineLimit(1)
                                Text(item.progress.completed ? "Finished · \(item.progress.updated.formatted(.relative(presentation: .named)))"
                                     : "Page \(item.progress.page + 1) of \(item.progress.pageCount) · \(item.progress.updated.formatted(.relative(presentation: .named)))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: item.progress.completed ? "checkmark.circle.fill" : "play.circle")
                                .foregroundStyle(item.progress.completed ? Color.secondary : Eclipse.accent)
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) { model.removeHistory(item.chapter) } label: { Label("Remove", systemImage: "trash") }
                    }
    }
}
