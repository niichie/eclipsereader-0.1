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
                                                Text(chapter.title).font(.subheadline.weight(.semibold)).lineLimit(2)
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
            .overlay {
                if items.isEmpty && !model.checking {
                    ContentUnavailableView("No new chapters", systemImage: "sparkles",
                                           description: Text("New chapters from Berserk and your website series appear here. eclipsereader checks every few hours when you open it."))
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
        let items = Array(model.state.progress
            .compactMap { entry in index[entry.key].map { HistoryItem(series: $0.0, chapter: $0.1, progress: entry.value) } }
            .sorted { $0.progress.updated > $1.progress.updated }
            .prefix(150))
        NavigationStack {
            List {
                if model.state.incognito == true {
                    Label("Incognito is on: nothing new is added to history.", systemImage: "eyeglasses")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    Button { reader = item.chapter } label: {
                        HStack(spacing: 12) {
                            CoverView(url: model.cover(for: item.series), referer: item.series.chapters.first)
                                .frame(width: 44, height: 63).clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.series.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(item.chapter.title).font(.caption).lineLimit(1)
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
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView("No history yet", systemImage: "clock",
                                           description: Text("Chapters you read show up here."))
                }
            }
            .scrollContentBackground(.hidden).background(EclipseBackground())
            .navigationTitle("History")
            .toolbar {
                if !items.isEmpty {
                    Button("Clear") { confirmClear = true }
                }
            }
            .confirmationDialog("Clear all reading history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear history", role: .destructive) {
                    model.state.progress = [:]; model.state.lastChapterID = nil; model.save()
                }
            } message: { Text("This also resets where you stopped in every chapter.") }
            .fullScreenCover(item: $reader) { chapter in ReaderView(chapter: chapter).environmentObject(model) }
        }
    }
}
