import SwiftUI
import WebKit
import UniformTypeIdentifiers
import ImageIO
import PhotosUI

struct RootView: View {
    @EnvironmentObject private var model: LibraryModel
    var body: some View {
        TabView {
            // Mihon's order: your shelf, what's new, what you read, where to find more, settings.
            LibraryView().tabItem { Label("Library", systemImage: "books.vertical.fill") }
            UpdatesView().tabItem { Label("Updates", systemImage: "sparkles") }
                .badge(model.totalNew)
            HistoryView().tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            BrowseView().tabItem { Label("Browse", systemImage: "safari") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, new, reading, downloaded, manga, manhwa, comic, files
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .new: "New chapters"
        case .reading: "Reading"
        case .downloaded: "Downloaded"
        case .manga: "Manga"
        case .manhwa: "Manhwa"
        case .comic: "Comics"
        case .files: "On device"
        }
    }
}
enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, title, added
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recent: "Recently read"
        case .title: "Title"
        case .added: "Recently added"
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var reader: Chapter?
    @State private var addLink = false
    @State private var options = false
    @State private var openSeries: MangaSeries?
    @State private var query = ""
    @State private var searching = false
    @State private var filter: LibraryFilter = .all
    @AppStorage("librarySort") private var sortRaw = LibrarySort.recent.rawValue
    @AppStorage("libraryShowContinue") private var showContinue = true
    @Namespace private var zoom
    @FocusState private var searchFocused: Bool

    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .recent }
    private func matches(_ series: MangaSeries, _ filter: LibraryFilter) -> Bool {
        switch filter {
        case .all: true
        case .new: model.newCount(series) > 0
        case .downloaded: model.downloadedCount(series) > 0 || series.kind == .local
        case .reading: model.lastRead(series) != nil && model.readCount(series) < series.chapters.count
        case .manga: model.style(for: series.id) == .manga
        case .manhwa: model.style(for: series.id) == .manhwa
        case .comic: model.style(for: series.id) == .comic
        case .files: series.kind == .local
        }
    }
    private var visible: [MangaSeries] {
        let list = model.librarySeries.filter { series in
            (query.isEmpty || series.title.localizedCaseInsensitiveContains(query)) && matches(series, filter)
        }
        switch sort {
        case .title: return list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .added: return list.sorted { $0.added > $1.added }
        case .recent:
            return list.sorted { a, b in
                let x = model.lastRead(a) ?? .distantPast, y = model.lastRead(b) ?? .distantPast
                return x == y ? a.added > b.added : x > y
            }
        }
    }
    /// Tabs with something in them (All always shows), with counts like Mihon's categories.
    private var tabs: [(LibraryFilter, Int)] {
        LibraryFilter.allCases.compactMap { item in
            let count = model.librarySeries.filter { matches($0, item) }.count
            return item == .all || count > 0 || item == filter ? (item, count) : nil
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if query.isEmpty, showContinue, filter == .all, let chapter = model.lastChapter {
                            ContinueBar(chapter: chapter, resume: { reader = chapter },
                                        open: { openSeries = model.series(id: model.seriesID(for: chapter)) })
                        }
                        LibraryGrid(series: visible, reader: $reader, openSeries: $openSeries, zoom: zoom)
                        if visible.isEmpty {
                            ContentUnavailableView {
                                Label(query.isEmpty ? "Nothing here yet" : "No matches", systemImage: "books.vertical")
                            } description: {
                                Text(query.isEmpty ? "Add a series from Browse, paste a link, or import files." : "Try a different title.")
                            } actions: {
                                Button("Add manga") { addLink = true }.buttonStyle(.borderedProminent).tint(Eclipse.accent)
                            }
                        }
                        if let error = model.error, model.state.chapters.isEmpty { SourceNotice(message: error) { Task { await model.refresh() } } }
                        if let error = model.persistenceError { Text(error).foregroundStyle(.orange).font(.subheadline) }
                    }
                    .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 24)
                    .frame(maxWidth: 1280)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable { await model.checkForUpdates(force: true); await model.ensureCovers() }
            }
            .background(EclipseBackground())
            .toolbar(.hidden, for: .navigationBar)    // the bar below adapts to every screen shape
            .sheet(isPresented: $addLink) {
                AddMangaView { result in
                    addLink = false
                    switch result {
                    case .open(let chapter): reader = chapter
                    case .series(let series, let chapter): if let chapter { reader = chapter } else { openSeries = series }
                    }
                }.environmentObject(model)
            }
            .sheet(isPresented: $options) { LibraryOptionsSheet().environmentObject(model).presentationDetents([.medium, .large]) }
            .navigationDestination(item: $openSeries) { series in
                SeriesView(seriesID: series.id, reader: $reader).zoomDestination(series.id, in: zoom)
            }
            .task {
                if model.state.chapters.isEmpty && !ProcessInfo.processInfo.arguments.contains("--ui-testing") { await model.refresh() }
                await model.ensureCovers()
                await model.checkForUpdates()
            }
            .onChange(of: model.librarySeries.count) { _, _ in Task { await model.ensureCovers() } }
            .fullScreenCover(item: $reader) { chapter in ReaderView(chapter: chapter).environmentObject(model) }
        }
    }

    /// Mihon-style app bar: title (or the search field), actions, then category tabs.
    private var topBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if searching {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search your library", text: $query)
                            .focused($searchFocused).submitLabel(.search)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    .padding(.horizontal, 12).frame(height: 38)
                    .background(Eclipse.surfaceHigh, in: Capsule())
                    Button("Cancel") { withAnimation(.snappy) { query = ""; searching = false; searchFocused = false } }
                        .padding(.leading, 6)
                } else {
                    HStack(spacing: 8) {
                        EclipseMark(size: 22)
                        Text("Library").font(.title2.weight(.bold))
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 8)
                    barButton("magnifyingglass", "Search library") {
                        withAnimation(.snappy) { searching = true }
                        searchFocused = true
                    }
                    barButton("line.3.horizontal.decrease", "Sort and display") { options = true }
                    Menu {
                        Button { Task { await model.checkForUpdates(force: true) } } label: {
                            Label(model.checking ? "Checking for new chapters…" : "Check for new chapters", systemImage: "arrow.clockwise")
                        }.disabled(model.checking)
                        if model.totalNew > 0 {
                            Button { for s in model.librarySeries { model.clearNew(s) } } label: {
                                Label("Mark all new chapters as seen", systemImage: "sparkles")
                            }
                        }
                        if let random = model.librarySeries.randomElement() {
                            Button { openSeries = random } label: { Label("Open a random series", systemImage: "shuffle") }
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 40)
                    }.accessibilityLabel("More")
                    Button { addLink = true } label: {
                        Image(systemName: "plus").font(.system(size: 16, weight: .heavy)).foregroundStyle(.black)
                            .frame(width: 34, height: 34).background(Eclipse.highlight, in: Circle())
                    }
                    .padding(.leading, 4)
                    .accessibilityLabel("Add manga").accessibilityIdentifier("addManga")
                }
            }
            .padding(.horizontal, 14).frame(height: 52)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabs, id: \.0) { entry in
                        let item = entry.0, count = entry.1
                        Button { withAnimation(.snappy) { filter = item } } label: {
                            VStack(spacing: 7) {
                                HStack(spacing: 5) {
                                    Text(item.title).font(.subheadline.weight(filter == item ? .bold : .medium))
                                    Text("\(count)").font(.caption2.weight(.bold)).monospacedDigit()
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background((filter == item ? Eclipse.accent : Color.white.opacity(0.12)), in: Capsule())
                                }
                                .foregroundStyle(filter == item ? Color.white : Color.secondary)
                                Capsule().fill(filter == item ? Eclipse.accent : Color.clear).frame(height: 3)
                            }
                            .padding(.horizontal, 10).padding(.top, 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(filter == item ? .isSelected : [])
                    }
                }.padding(.horizontal, 8)
            }
            Rectangle().fill(Eclipse.hairline).frame(height: 0.5)
        }
        .background(.black.opacity(0.55))
        .background(.ultraThinMaterial)
    }
    private func barButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 40)
        }.accessibilityLabel(label)
    }
}

/// Mihon's library sheet: sort order and how the grid looks.
struct LibraryOptionsSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("librarySort") private var sortRaw = LibrarySort.recent.rawValue
    @AppStorage("libraryDensity") private var density = LibraryDensity.comfortable.rawValue
    @AppStorage("libraryTitlesOnCovers") private var titlesOnCovers = true
    @AppStorage("libraryShowContinue") private var showContinue = true
    var body: some View {
        NavigationStack {
            Form {
                Section("Sort") {
                    Picker("Sort", selection: $sortRaw) {
                        ForEach(LibrarySort.allCases) { Text($0.title).tag($0.rawValue) }
                    }.pickerStyle(.inline).labelsHidden()
                }
                Section("Display") {
                    Picker("Cover size", selection: $density) {
                        ForEach(LibraryDensity.allCases) { Text($0.title).tag($0.rawValue) }
                    }.pickerStyle(.segmented)
                    Toggle("Titles on covers", isOn: $titlesOnCovers)
                    Toggle("Continue reading bar", isOn: $showContinue)
                }
            }
            .scrollContentBackground(.hidden).background(Eclipse.surface)
            .navigationTitle("Library").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() }.fontWeight(.semibold) }
        }.preferredColorScheme(.dark)
    }
}

/// One slim row to pick up where you left off.
struct ContinueBar: View {
    @EnvironmentObject private var model: LibraryModel
    let chapter: Chapter
    let resume: () -> Void
    let open: () -> Void
    var body: some View {
        let series = model.series(id: model.seriesID(for: chapter))
        let progress = model.state.progress[chapter.id]
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    CoverView(url: series.flatMap { model.cover(for: $0) }, referer: chapter)
                        .frame(width: 42, height: 60).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("CONTINUE READING").font(.caption2.weight(.heavy)).tracking(1.2).foregroundStyle(Eclipse.highlight)
                        Text(series?.title ?? chapter.title).font(.subheadline.weight(.bold)).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(ChapterText.split(chapter.title).name).lineLimit(1)
                            if let progress { Text("· \(progress.page + 1)/\(progress.pageCount)").monospacedDigit() }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button(action: resume) {
                Image(systemName: "play.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
                    .frame(width: 42, height: 42).background(Color.white, in: Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Resume").accessibilityIdentifier("continueReading")
        }
        .padding(10)
        .background(
            LinearGradient(colors: [Eclipse.accent.opacity(0.35), Eclipse.surface], startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Eclipse.hairline))
    }
}

/// The library as a cover grid.
struct LibraryGrid: View {
    @EnvironmentObject private var model: LibraryModel
    let series: [MangaSeries]
    @Binding var reader: Chapter?
    @Binding var openSeries: MangaSeries?
    let zoom: Namespace.ID
    @AppStorage("libraryDensity") private var densityRaw = LibraryDensity.comfortable.rawValue
    var body: some View {
        let density = LibraryDensity(rawValue: densityRaw) ?? .comfortable
        let columns = [GridItem(.adaptive(minimum: density.minimum, maximum: density.maximum), spacing: 12, alignment: .top)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(series) { item in
                Button { openSeries = item } label: { SeriesCard(series: item).zoomSource(item.id, in: zoom) }
                    .buttonStyle(PressableStyle())
                    .accessibilityIdentifier(item.id == LibraryModel.berserkID ? "chapterBrowser" : "series-\(item.title)")
                    .contextMenu {
                        if let chapter = model.resume(item) {
                            Button { reader = chapter } label: { Label("Continue \(chapter.title)", systemImage: "book") }
                        }
                        Picker("Reads as", selection: Binding(get: { model.styleOverride(item.id) },
                                                              set: { model.setStyle($0, for: item.id) })) {
                            ForEach(ReadingStyle.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                        }
                        if item.id != LibraryModel.berserkID {
                            Button(role: .destructive) { model.remove(item) } label: { Label("Remove from library", systemImage: "trash") }
                        }
                    }
            }
        }
    }
}

struct ChapterBrowser: View {
    @EnvironmentObject private var model: LibraryModel
    @Binding var reader: Chapter?
    @State private var query = ""
    @State private var descending = false
    @State private var filter = "All"
    var chapters: [Chapter] {
        let chapters = model.state.chapters.filter {
            (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) &&
            (filter == "All" || (filter == "Read" ? model.state.progress[$0.id]?.completed == true : model.state.progress[$0.id]?.completed != true))
        }
        return descending ? Array(chapters.reversed()) : chapters
    }
    var body: some View {
        List {
            if let updated = model.state.catalogUpdated {
                Text("Updated \(updated.formatted(date: .abbreviated, time: .shortened))").font(.footnote).foregroundStyle(.secondary)
            }
            if let error = model.error { SourceNotice(message: error) { Task { await model.refresh() } } }
            ForEach(chapters) { chapter in
                Button { reader = chapter } label: {
                    HStack(spacing: 14) {
                        Image(systemName: model.state.progress[chapter.id]?.completed == true ? "checkmark.circle.fill" : "book.closed")
                            .foregroundStyle(.secondary).frame(width: 28)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(chapter.title).foregroundStyle(.primary)
                            if let p = model.state.progress[chapter.id] {
                                Text(p.completed ? "Read" : "Page \(p.page + 1) of \(p.pageCount)").font(.subheadline).foregroundStyle(.secondary)
                                ProgressView(value: p.fraction)
                            } else if let date = chapter.published { Text(date).font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }.padding(.vertical, 6)
                }.buttonStyle(.plain)
            }
        }.overlay {
            if chapters.isEmpty {
                ContentUnavailableView(model.loading ? "Loading chapters…" : "No chapters", systemImage: "books.vertical",
                    description: Text(query.isEmpty ? "Pull to refresh." : "Try another chapter number."))
                    .allowsHitTesting(false)
            }
        }.searchable(text: $query, prompt: "Chapter number or title")
            .navigationTitle("Chapters")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Show", selection: $filter) { ForEach(["All", "Unread", "Read"], id: \.self) { Text($0) } }
                        Toggle("Newest first", isOn: $descending)
                        Button("Refresh catalog") { Task { await model.refresh() } }
                    } label: { Label("Filter chapters", systemImage: "line.3.horizontal.decrease.circle") }
                }
            }.refreshable { await model.refresh() }
    }
}

struct SourceNotice: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Couldn’t load the source", systemImage: "wifi.exclamationmark").font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
            Button("Retry", action: retry).buttonStyle(.bordered)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: LibraryModel
    var body: some View {
        NavigationStack {
            List {
                Section { SettingsHero().listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                Section {
                    NavigationLink { ReaderSettingsPage() } label: {
                        SettingsRow(title: "Reader", detail: "Page turns, direction, webtoons, translation", symbol: "book.pages.fill", tint: Eclipse.accent)
                    }
                    NavigationLink { LibrarySettingsPage() } label: {
                        SettingsRow(title: "Library", detail: "Cover size, sorting, new chapters", symbol: "books.vertical.fill", tint: .indigo)
                    }
                    NavigationLink { DownloadSettingsPage() } label: {
                        SettingsRow(title: "Downloads", detail: model.downloaded.isEmpty ? "Offline reading" : "\(model.downloaded.count) chapters offline",
                                    symbol: "arrow.down.circle.fill", tint: .teal)
                    }
                    NavigationLink { BrowserSettingsPage() } label: {
                        SettingsRow(title: "Browser", detail: "Ad blocking, saved sites, website data", symbol: "safari.fill", tint: .blue)
                    }
                }
                Section {
                    NavigationLink { BackupSettingsPage() } label: {
                        SettingsRow(title: "Backup & restore", detail: "Move your library to another device", symbol: "externaldrive.fill", tint: .orange)
                    }
                    NavigationLink { PrivacySettingsPage() } label: {
                        SettingsRow(title: "Privacy", detail: model.state.incognito == true ? "Incognito is on" : "Incognito, history",
                                    symbol: "hand.raised.fill", tint: .pink)
                    }
                    NavigationLink { StorageSettingsPage() } label: {
                        SettingsRow(title: "Storage", detail: "Temporary images and cache", symbol: "internaldrive.fill", tint: .gray)
                    }
                }
                Section {
                    NavigationLink { AboutPage() } label: {
                        SettingsRow(title: "About eclipsereader", detail: "Version \(AboutPage.version)", symbol: "info.circle.fill", tint: Color(white: 0.35))
                    }
                }
            }
            .navigationTitle("Settings")
            .scrollContentBackground(.hidden).background(EclipseBackground())
        }
    }
}

/// Logo card at the top of Settings with a summary of the library.
private struct SettingsHero: View {
    @EnvironmentObject private var model: LibraryModel
    var body: some View {
        let series = model.librarySeries
        let read = series.reduce(0) { $0 + model.readCount($1) }
        VStack(spacing: 14) {
            EclipseWordmark(size: 30)
            HStack(spacing: 0) {
                stat("\(series.count)", "series")
                Divider().frame(height: 28).overlay(Eclipse.hairline)
                stat("\(read)", "chapters read")
                Divider().frame(height: 28).overlay(Eclipse.hairline)
                stat("\(model.downloaded.count)", "offline")
            }
        }
        .padding(.vertical, 18).padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Eclipse.accent.opacity(0.35), Eclipse.surface], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Eclipse.hairline))
    }
    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.bold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity)
    }
}

struct SettingsRow: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30).background(tint.gradient, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(.vertical, 2)
    }
}

private extension View {
    func settingsPage(_ title: String) -> some View {
        navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden).background(EclipseBackground())
    }
}

struct ReaderSettingsPage: View {
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("readerWarmth") private var warmth = 0.0
    @AppStorage("keepScreenOn") private var keepScreenOn = true
    var body: some View {
        Form {
            ReaderPreferencesForm(preferences: Binding(get: { model.preferences }, set: { model.preferences = $0 }))
            Section {
                Toggle("Keep the screen on while reading", isOn: $keepScreenOn)
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("Warm night filter"); Spacer(); Text(warmth == 0 ? "Off" : "\(Int(warmth * 100))%").foregroundStyle(.secondary).monospacedDigit() }
                    Slider(value: $warmth, in: 0...0.6).tint(Eclipse.highlight)
                }
            } header: { Text("Display") } footer: {
                Text("The warm filter tints pages amber for reading at night. It stays on until you turn it off; there’s also a shortcut in the reader.")
            }
        }.settingsPage("Reader")
    }
}

/// How the library looks and when it checks for new chapters.
enum LibraryDensity: Int, CaseIterable, Identifiable {
    case compact, comfortable, large
    var id: Int { rawValue }
    var title: String { ["Compact", "Comfortable", "Large"][rawValue] }
    var minimum: CGFloat { [96, 118, 150][rawValue] }
    var maximum: CGFloat { [130, 160, 210][rawValue] }
}

struct LibrarySettingsPage: View {
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("libraryDensity") private var density = LibraryDensity.comfortable.rawValue
    @AppStorage("libraryShowContinue") private var showContinue = true
    @AppStorage("libraryTitlesOnCovers") private var titlesOnCovers = true
    var body: some View {
        Form {
            Section("Layout") {
                Picker("Cover size", selection: $density) {
                    ForEach(LibraryDensity.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.segmented)
                Toggle("Titles on covers", isOn: $titlesOnCovers)
                Toggle("Continue reading bar", isOn: $showContinue)
            }
            Section {
                Button {
                    Task { await model.checkForUpdates(force: true) }
                } label: {
                    HStack {
                        Label(model.checking ? "Checking…" : "Check for new chapters now", systemImage: "arrow.clockwise")
                        Spacer()
                        if model.checking { ProgressView() }
                    }
                }.disabled(model.checking)
                if let last = model.state.lastUpdateCheck {
                    LabeledContent("Last checked", value: last.formatted(.relative(presentation: .named)))
                }
                Toggle("Download new chapters automatically", isOn: Binding(
                    get: { model.state.autoDownloadNew == true },
                    set: { model.state.autoDownloadNew = $0; model.save() }))
                if model.totalNew > 0 {
                    Button("Mark all new chapters as seen") { for s in model.librarySeries { model.clearNew(s) } }
                }
            } header: { Text("New chapters") } footer: {
                Text("eclipsereader looks for new chapters when you open it, at most every six hours, and when you pull down on the library. Automatic downloads only cover series you’ve started.")
            }
        }.settingsPage("Library")
    }
}

struct DownloadSettingsPage: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var downloadBytes: Int64 = 0
    @State private var confirmDelete = false
    var body: some View {
        Form {
            Section {
                LabeledContent("Downloaded chapters", value: "\(model.downloaded.count)")
                LabeledContent("Space used", value: ByteCountFormatter.string(fromByteCount: downloadBytes, countStyle: .file))
                if !model.downloads.isEmpty { LabeledContent("In progress", value: "\(model.downloads.count)") }
            }
            Section {
                Toggle("Download ahead while reading", isOn: Binding(
                    get: { model.state.downloadAhead == true },
                    set: { model.state.downloadAhead = $0; model.save() }))
                Toggle("Download new chapters automatically", isOn: Binding(
                    get: { model.state.autoDownloadNew == true },
                    set: { model.state.autoDownloadNew = $0; model.save() }))
            } footer: {
                Text("Downloading ahead saves the next two chapters while you read, so you can keep going offline.")
            }
            Section {
                Button("Delete all downloads", role: .destructive) { confirmDelete = true }
                    .disabled(model.downloaded.isEmpty && model.downloads.isEmpty)
            } footer: {
                Text("Downloaded chapters open without a connection and stay until you delete them. Imported files are never affected.")
            }
        }
        .settingsPage("Downloads")
        .confirmationDialog("Delete all downloaded chapters?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete downloads", role: .destructive) { model.removeAllDownloads(); downloadBytes = 0 }
        } message: { Text("Reading progress is kept. You can download chapters again any time.") }
        .task { downloadBytes = await OfflineStore.shared.totalBytes() }
        .onChange(of: model.downloaded.count) { _, _ in Task { downloadBytes = await OfflineStore.shared.totalBytes() } }
    }
}

struct BrowserSettingsPage: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var message: String?
    var body: some View {
        Form {
            Section {
                LabeledContent("Ad & tracker blocking", value: "On")
                LabeledContent("Blocked networks", value: "\(AdBlock.domains.count)")
                LabeledContent("“Get the app” banners", value: "Hidden")
            } footer: {
                Text("The browser blocks common ad, pop-up and tracking networks and hides app-install banners. The reader itself only loads page images, so it never shows ads.")
            }
            if let sites = model.state.sites, !sites.isEmpty {
                Section("Saved sites") {
                    ForEach(sites) { site in
                        LabeledContent(site.name, value: site.url.host ?? "")
                    }.onDelete { offsets in for i in offsets { model.removeSite(sites[i]) } }
                }
            }
            Section {
                Button("Clear cookies & website data", role: .destructive) {
                    Task {
                        let store = WKWebsiteDataStore.default()
                        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
                        message = "Website cookies and storage cleared."
                    }
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("Signs you out of sites you used in the browser and clears any “are you human” checks they remembered.")
            }
        }.settingsPage("Browser")
    }
}

struct BackupSettingsPage: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var backupURL: URL?
    @State private var restoring = false
    @State private var message: String?
    var body: some View {
        Form {
            Section {
                if let backupURL {
                    ShareLink(item: backupURL) { Label("Save or share the backup file", systemImage: "square.and.arrow.up") }
                } else {
                    Button {
                        do { backupURL = try model.backupFile() } catch { message = error.localizedDescription }
                    } label: { Label("Create backup", systemImage: "externaldrive.badge.plus") }
                }
                Button { restoring = true } label: { Label("Restore from a backup…", systemImage: "arrow.down.doc") }
                if let message { Text(message).font(.subheadline).foregroundStyle(.secondary) }
            } footer: {
                Text("Saves your reading positions, series, settings and styles to one file. Save it to iCloud Drive, then restore it on your other device; newer positions win and nothing is deleted.")
            }
        }
        .settingsPage("Backup & restore")
        .fileImporter(isPresented: $restoring, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                do { message = try model.restore(from: url) } catch { message = "That file couldn’t be restored: \(error.localizedDescription)" }
            case .failure(let error): message = error.localizedDescription
            }
        }
    }
}

struct PrivacySettingsPage: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var confirmHistory = false
    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.state.incognito == true }, set: { model.state.incognito = $0; model.save() })) {
                    Label("Incognito mode", systemImage: "eyeglasses")
                }
            } footer: { Text("Read without saving progress or history.") }
            Section {
                Button("Clear reading history", role: .destructive) { confirmHistory = true }
            } footer: {
                Text("eclipsereader has no accounts, analytics or tracking. Pages come straight from the sites you add; recognized text and translations stay on this device.")
            }
        }
        .settingsPage("Privacy")
        .confirmationDialog("Clear reading history?", isPresented: $confirmHistory, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { model.clearHistory() }
        } message: { Text("Where you stopped in each chapter is forgotten. Your library, downloads and finished chapters stay.") }
    }
}

struct StorageSettingsPage: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var message = ""
    var body: some View {
        Form {
            Section {
                Button("Clear temporary images") {
                    Task {
                        do { try await model.pipeline.cache.removeAll(); message = "Temporary images cleared." }
                        catch { message = error.localizedDescription }
                    }
                }
                if !message.isEmpty { Text(message).font(.subheadline).foregroundStyle(.secondary) }
            } footer: {
                Text("Pages stream on demand and the next two are preloaded. Images are kept in a temporary 120 MB cache for up to a day; iOS may clear it sooner. Downloads are separate and stay until you delete them.")
            }
        }.settingsPage("Storage")
    }
}

struct AboutPage: View {
    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }
    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    EclipseMark(size: 64)
                    EclipseWordmark(size: 24)
                    Text("Version \(Self.version)").font(.footnote).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 12)
                    .listRowBackground(Color.clear)
            }
            Section {
                Text("A manga-first reader for iPhone and iPad. Reads manga right to left with real page turns, scrolls manhwa and webtoons, and keeps everything on your device.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("No manga is bundled with the app. Series come from websites you add or files you import; eclipsereader isn’t affiliated with any of them.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                Link(destination: URL(string: "https://mihon.app/")!) { Label("Inspired by Mihon", systemImage: "heart") }
            }
        }.settingsPage("About")
    }
}

struct ReaderPreferencesForm: View {
    @Binding var preferences: ReaderPreferences
    var body: some View {
        Section {
            Picker("Direction", selection: $preferences.direction) {
                ForEach(ReadingDirection.allCases, id: \.self) { Text($0.title) }
            }
            Picker("Layout", selection: $preferences.mode) {
                ForEach(ReadingMode.allCases, id: \.self) { Text($0.title) }
            }
            Picker("Page turn", selection: $preferences.transition) {
                ForEach(PageTransition.allCases, id: \.self) { Text($0.title) }
            }
            Toggle("Swipe left to go forward", isOn: $preferences.advanceOnLeftSwipe)
            Toggle("Tap page edges to turn", isOn: Binding(get: { preferences.tapZones ?? true }, set: { preferences.tapZones = $0 }))
        } header: { Text("Manga") } footer: {
            Text("Manga reads right to left, like a printed volume: drag the page to the right, or tap its left edge, to go forward. Tap the middle to show the controls. Manhwa and comics adjust automatically per series.")
        }
        Section("Pages") {
            Picker("Page size", selection: $preferences.fit) {
                ForEach(PageFit.allCases, id: \.self) { Text($0.title) }
            }
            Toggle("Two-page spreads in landscape", isOn: $preferences.landscapeSpreads)
            Toggle("Keep wide artwork on one page", isOn: $preferences.detectWidePages)
            Toggle("Trim white scan margins", isOn: Binding(get: { preferences.trimMargins ?? true }, set: { preferences.trimMargins = $0 }))
            Picker("Image quality", selection: Binding(get: { preferences.quality ?? .automatic }, set: { preferences.quality = $0 })) {
                ForEach(ImageQuality.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Stepper(value: $preferences.doubleTapZoom, in: 1.5...4, step: 0.5) {
                LabeledContent("Double-tap zoom", value: "\(preferences.doubleTapZoom.formatted())×")
            }
        }
        Section {
            Toggle("Detect webtoons automatically", isOn: Binding(get: { preferences.autoWebtoon ?? true }, set: { preferences.autoWebtoon = $0 }))
            Toggle("Gap between pages", isOn: Binding(get: { preferences.verticalGap ?? false }, set: { preferences.verticalGap = $0 }))
        } header: { Text("Manhwa & webtoons") } footer: {
            Text("Series tagged as manhwa, or with tall strip pages, scroll vertically. Strips join seamlessly unless you add a gap. Set any series by hand on its page.")
        }
        Section("Translation") {
            Picker("Translate into", selection: Binding(get: { preferences.translateTarget ?? "en" }, set: { preferences.translateTarget = $0 })) {
                ForEach([("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"),
                         ("ru", "Russian"), ("ja", "Japanese"), ("ko", "Korean"), ("zh-Hans", "Chinese (Simplified)")], id: \.0) { item in
                    Text(item.1).tag(item.0)
                }
            }
        }
    }
}

/// A library cover in Mihon's compact style: artwork edge to edge, the title on a dark gradient,
/// unread / downloaded counts as one badge, reading progress along the bottom edge.
struct SeriesCard: View {
    @EnvironmentObject private var model: LibraryModel
    let series: MangaSeries
    @AppStorage("libraryTitlesOnCovers") private var titlesOnCovers = true
    var body: some View {
        let read = model.readCount(series)
        let total = series.chapters.count
        let unread = max(0, total - read)
        let new = model.newCount(series)
        let offline = model.downloadedCount(series)
        let style = model.style(for: series.id)
        let reading = model.lastRead(series) != nil && read < total
        VStack(alignment: .leading, spacing: 6) {
            CoverView(url: model.cover(for: series), referer: series.chapters.first, onFail: { model.coverFailed(series) })
                .aspectRatio(0.7, contentMode: .fit)
                .overlay(alignment: .bottom) {
                    if titlesOnCovers {
                        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.55), location: 0.45),
                                               .init(color: .black.opacity(0.92), location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 86)
                            .overlay(alignment: .bottomLeading) {
                                Text(series.title).font(.footnote.weight(.bold)).lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .shadow(color: .black, radius: 2)
                                    .padding(.horizontal, 8).padding(.bottom, reading ? 11 : 8)
                            }
                    }
                }
                .overlay(alignment: .bottom) {
                    if reading {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(Color.white.opacity(0.18))
                                Rectangle().fill(Eclipse.accent)
                                    .frame(width: max(4, g.size.width * Double(read) / Double(max(total, 1))))
                            }
                        }.frame(height: 3)
                    }
                }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        if offline > 0 {
                            Text("\(offline)").padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Eclipse.accent).foregroundStyle(.white)
                                .accessibilityLabel("\(offline) downloaded")
                        }
                        if new > 0 {
                            Text("\(new) NEW").padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Eclipse.highlight).foregroundStyle(.black)
                        } else if unread > 0 && total > 0 {
                            Text("\(unread)").padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Color.white).foregroundStyle(.black)
                                .accessibilityLabel("\(unread) unread")
                        }
                    }
                    .font(.caption2.weight(.heavy)).monospacedDigit()
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: series.kind == .local ? "internaldrive.fill" : style.symbol)
                        .font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22)
                        .background(.ultraThinMaterial, in: Circle()).padding(6)
                        .accessibilityLabel(series.kind == .local ? "On this device" : style.title)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.06)))
                .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
            if !titlesOnCovers {
                Text(series.title).font(.footnote.weight(.semibold)).lineLimit(2)
            }
            Text(total == 0 ? "Loading chapters…" : reading ? "\(read) of \(total) read" : "\(total) chapter\(total == 1 ? "" : "s")")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(series.title), \(total) chapters, \(unread) unread")
    }
}

/// Small cover thumbnails, decoded at display size and loaded through the same rules as pages.
struct CoverView: View {
    @EnvironmentObject private var model: LibraryModel
    let url: URL?
    let referer: Chapter?
    /// Called when the cover can't be loaded, so the library can pick another one.
    var onFail: (() -> Void)? = nil
    @State private var image: UIImage?
    @MainActor private static let cache = NSCache<NSURL, UIImage>()
    @State private var failed = false
    var body: some View {
        // The base shape takes the size it is offered; the artwork is an overlay so it can never
        // stretch the card, whatever the image's shape (webtoon strips are very tall).
        Rectangle()
            .fill(LinearGradient(colors: [Eclipse.surfaceHigh, Eclipse.surface], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .top) {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .transition(.opacity)
                } else if failed || url == nil {
                    EclipseMark(size: 30).opacity(0.55)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ShimmerView()
                }
            }
            .clipped()
            .animation(.easeOut(duration: 0.25), value: image != nil)
            .task(id: url) {
            guard let url else { return }
            failed = false
            if let hit = Self.cache.object(forKey: url as NSURL) { image = hit; return }
            let chapter = referer ?? Chapter(url: url, title: "", number: "")
            guard let data = try? await model.pipeline.data(for: MangaPage(url: url, label: "Cover"), chapter: chapter) else {
                if !Task.isCancelled { failed = true; onFail?() }
                return
            }
            let thumb = await Task.detached(priority: .utility) { () -> CoverThumb? in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 720] as CFDictionary) else { return nil }
                // A webtoon strip used as a cover: keep its top, in cover proportions.
                if cg.height > cg.width * 2, let top = cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width, height: Int(Double(cg.width) / 0.7))) {
                    return CoverThumb(image: UIImage(cgImage: top))
                }
                return CoverThumb(image: UIImage(cgImage: cg))
            }.value
            if let thumb { Self.cache.setObject(thumb.image, forKey: url as NSURL); image = thumb.image }
        }
    }
}

private struct CoverThumb: @unchecked Sendable { let image: UIImage }

/// A series' details and full chapter list. Works for Berserk and anything added.
enum ChapterFilter: String, CaseIterable, Identifiable {
    case all, unread, downloaded
    var id: String { rawValue }
    var title: String { self == .all ? "All chapters" : self == .unread ? "Unread" : "Downloaded" }
}

/// Splits a site's chapter label ("Chapter 12 Mar 20, 2023") into the name and its date.
enum ChapterText {
    static func split(_ title: String) -> (name: String, date: String?) {
        let patterns = [
            #"\s*[-–·|]?\s*((?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.? \d{1,2},? \d{4})\s*$"#,
            #"\s*[-–·|]?\s*(\d{4}[-/.]\d{1,2}[-/.]\d{1,2})\s*$"#,
            #"\s*[-–·|]?\s*(\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4})\s*$"#,
            #"\s*[-–·|]?\s*(\d+ (?:second|minute|hour|day|week|month|year)s? ago|yesterday|today)\s*$"#,
        ]
        for pattern in patterns {
            if let range = title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                let name = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { break }
                let date = String(title[range]).trimmingCharacters(in: CharacterSet(charactersIn: " -–·|"))
                return (name, date)
            }
        }
        return (title, nil)
    }
}

struct SeriesView: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let seriesID: String
    @Binding var reader: Chapter?
    @State private var query = ""
    @State private var searching = false
    @AppStorage("chaptersNewestFirst") private var newestFirst = false
    @State private var filter: ChapterFilter = .all
    @State private var updating = false
    @State private var message: String?
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var website = false
    @State private var pickingCover = false
    @FocusState private var searchFocused: Bool
    var body: some View {
        if let series = model.series(id: seriesID) {
            let builtIn = series.id == LibraryModel.berserkID
            let list = series.chapters.filter { chapter in
                (query.isEmpty || chapter.title.localizedCaseInsensitiveContains(query)) && {
                    switch filter {
                    case .all: true
                    case .unread: model.state.progress[chapter.id]?.completed != true
                    case .downloaded: model.isDownloaded(chapter)
                    }
                }()
            }
            List {
                Section {
                    SeriesHeader(series: series, reader: $reader, website: $website)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                    if let message {
                        Label(message, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                    if builtIn, let error = model.error {
                        SourceNotice(message: error) { Task { await model.refresh() } }
                            .listRowBackground(Color.clear)
                    }
                }
                Section {
                    if searching {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Find a chapter", text: $query).focused($searchFocused)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button { query = ""; searching = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.borderless).accessibilityLabel("Close search")
                        }
                    }
                    if series.chapters.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(model.loading ? "Loading chapters…" : "No chapters yet. Pull to refresh.").foregroundStyle(.secondary)
                        }
                    } else if list.isEmpty {
                        Text(query.isEmpty ? "No \(filter.title.lowercased()) chapters." : "No chapters match “\(query)”.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(newestFirst ? Array(list.reversed()) : list) { chapter in
                        ChapterRow(chapter: chapter, builtIn: builtIn) { reader = chapter }
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing) {
                                if model.state.progress[chapter.id]?.completed == true {
                                    Button { model.state.progress[chapter.id] = nil; model.save() } label: { Label("Unread", systemImage: "eye.slash") }
                                        .tint(.indigo)
                                } else {
                                    Button { model.record(chapter, page: 0, count: 1, completed: true) } label: { Label("Read", systemImage: "checkmark") }
                                        .tint(Eclipse.accent)
                                }
                            }
                            .swipeActions(edge: .leading) {
                                if model.isDownloaded(chapter) {
                                    Button(role: .destructive) { model.removeDownload(chapter) } label: { Label("Remove download", systemImage: "trash") }
                                } else if model.canDownload(chapter) {
                                    Button { model.download([chapter]) } label: { Label("Download", systemImage: "arrow.down.circle") }.tint(.teal)
                                }
                            }
                            .contextMenu {
                                Button { reader = chapter } label: { Label("Read", systemImage: "book") }
                                if model.state.progress[chapter.id]?.completed == true {
                                    Button { model.state.progress[chapter.id] = nil; model.save() } label: { Label("Mark as unread", systemImage: "eye.slash") }
                                } else {
                                    Button { model.record(chapter, page: 0, count: 1, completed: true) } label: { Label("Mark as read", systemImage: "checkmark.circle") }
                                }
                                if let i = series.chapters.firstIndex(of: chapter), i > 0 {
                                    Button {
                                        for earlier in series.chapters[..<i] where model.state.progress[earlier.id]?.completed != true {
                                            model.record(earlier, page: 0, count: 1, completed: true)
                                        }
                                    } label: { Label("Mark earlier chapters as read", systemImage: "checkmark.circle.badge.questionmark") }
                                }
                                if model.canDownload(chapter) && !model.isDownloaded(chapter) {
                                    Button { model.download([chapter]) } label: { Label("Download", systemImage: "arrow.down.circle") }
                                }
                            }
                    }
                } header: {
                    HStack(spacing: 12) {
                        Text("\(series.chapters.count) chapter\(series.chapters.count == 1 ? "" : "s")")
                            .font(.headline).foregroundStyle(.primary).textCase(nil)
                        Spacer()
                        Button { searching.toggle(); searchFocused = searching; if !searching { query = "" } } label: {
                            Image(systemName: "magnifyingglass")
                        }.accessibilityLabel("Find a chapter")
                        Menu {
                            Picker("Show", selection: $filter) {
                                ForEach(ChapterFilter.allCases) { Text($0.title).tag($0) }
                            }
                            Picker("Order", selection: $newestFirst) {
                                Text("Oldest first").tag(false)
                                Text("Newest first").tag(true)
                            }
                        } label: {
                            Image(systemName: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                        }.accessibilityLabel("Filter and sort chapters")
                    }
                    .font(.title3).foregroundStyle(.white).textCase(nil)
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden).background(EclipseBackground())
            .navigationTitle(series.title).navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .refreshable { await update(series) }
            .task { if builtIn && series.chapters.isEmpty { await model.refresh() } }
            .toolbar {
                ToolbarItem(placement: .principal) { Text("") }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { Task { await update(series) } } label: { Label("Check for new chapters", systemImage: "arrow.clockwise") }
                        if model.newCount(series) > 0 {
                            Button { model.clearNew(series) } label: { Label("Mark new chapters as seen", systemImage: "sparkles") }
                        }
                        Button {
                            for chapter in series.chapters where model.state.progress[chapter.id]?.completed != true {
                                model.record(chapter, page: 0, count: 1, completed: true)
                            }
                        } label: { Label("Mark all as read", systemImage: "checkmark.circle") }
                        if series.kind == .web {
                            Section("Offline") {
                                Button {
                                    let start = model.resume(series).flatMap { series.chapters.firstIndex(of: $0) } ?? 0
                                    model.download(Array(series.chapters.dropFirst(start).prefix(5)))
                                } label: { Label("Download next 5 chapters", systemImage: "arrow.down.circle") }
                                Button {
                                    model.download(series.chapters.filter { model.state.progress[$0.id]?.completed != true })
                                } label: { Label("Download all unread", systemImage: "arrow.down.circle.dotted") }
                                if model.downloadedCount(series) > 0 {
                                    Button(role: .destructive) {
                                        for chapter in series.chapters where model.isDownloaded(chapter) { model.removeDownload(chapter) }
                                    } label: { Label("Remove downloads", systemImage: "trash") }
                                }
                            }
                        }
                        Section {
                            Button { pickingCover = true } label: { Label("Change cover…", systemImage: "photo") }
                            if series.kind == .web {
                                Button { website = true } label: { Label("Open website", systemImage: "safari") }
                                ShareLink(item: series.url) { Label("Share link", systemImage: "square.and.arrow.up") }
                            }
                            if !builtIn {
                                Button { newTitle = series.title; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                                Button(role: .destructive) { model.remove(series); dismiss() } label: { Label("Remove from library", systemImage: "trash") }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.headline).frame(width: 34, height: 34)
                            .background(.ultraThinMaterial, in: Circle())
                    }.accessibilityLabel("Series options")
                }
            }
            .sheet(isPresented: $website) { WebsiteView(url: series.url) }
            .sheet(isPresented: $pickingCover) { CoverPicker(series: series).environmentObject(model) }
            .alert("Rename", isPresented: $renaming) {
                TextField("Title", text: $newTitle)
                Button("Save") { model.rename(series, to: newTitle) }
                Button("Cancel", role: .cancel) {}
            }
            .onChange(of: message) { _, text in
                guard text != nil else { return }
                Task { try? await Task.sleep(for: .seconds(4)); withAnimation { message = nil } }
            }
        } else {
            ContentUnavailableView("Removed", systemImage: "books.vertical")
        }
    }
    private func update(_ series: MangaSeries) async {
        guard !updating else { return }
        updating = true; defer { updating = false }
        let before = series.chapters.count
        do {
            try await model.update(series)
            let after = model.series(id: series.id)?.chapters.count ?? before
            message = after > before ? "\(after - before) new chapter\(after - before == 1 ? "" : "s")" : "No new chapters."
        } catch { message = error.localizedDescription }
    }
}

/// Cover over a blurred copy of itself, title and facts, then the main "Continue" action.
struct SeriesHeader: View {
    @EnvironmentObject private var model: LibraryModel
    let series: MangaSeries
    @Binding var reader: Chapter?
    @Binding var website: Bool
    var body: some View {
        let builtIn = series.id == LibraryModel.berserkID
        let cover = model.cover(for: series)
        let read = model.readCount(series)
        let style = model.style(for: series.id)
        let resume = model.resume(series)
        let started = resume.map { model.state.progress[$0.id] != nil } ?? false
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom, spacing: 16) {
                CoverView(url: cover, referer: series.chapters.first)
                    .aspectRatio(0.7, contentMode: .fit)
                    .frame(width: 116)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08)))
                    .shadow(color: .black.opacity(0.6), radius: 16, y: 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text(series.title).font(.title2.weight(.heavy)).lineLimit(4).minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(builtIn ? "Built in" : series.kind == .web ? (series.url.host?.replacingOccurrences(of: "www.", with: "") ?? "Website") : "On this device",
                          systemImage: series.kind == .local ? "internaldrive" : "globe")
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 6) {
                        chip(style.title, symbol: style.symbol)
                        if model.downloadedCount(series) > 0 { chip("\(model.downloadedCount(series))", symbol: "arrow.down.circle.fill") }
                    }
                    Text(series.chapters.isEmpty ? "Loading chapters…" : "\(read) of \(series.chapters.count) read")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Button { if let resume { reader = resume } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(resume == nil ? "No chapters yet" : started ? "Continue" : "Start reading").font(.headline)
                            if let resume {
                                Text(ChapterText.split(resume.title).name).font(.caption).opacity(0.8).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18).frame(height: 54)
                    .foregroundStyle(.white)
                    .background(LinearGradient(colors: [Eclipse.accent, Eclipse.accent.opacity(0.75)], startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 16))
                    .shadow(color: Eclipse.accent.opacity(0.4), radius: 14, y: 6)
                }
                .buttonStyle(PressableStyle()).disabled(resume == nil)
                .accessibilityIdentifier("seriesContinue")
                Menu {
                    Picker("Reads as", selection: Binding(get: { model.styleOverride(series.id) }, set: { model.setStyle($0, for: series.id) })) {
                        ForEach(ReadingStyle.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                } label: { squareButton(style.symbol) }
                    .accessibilityLabel("Reads as \(style.title)")
                if series.kind == .web {
                    Menu {
                        Button {
                            let start = resume.flatMap { series.chapters.firstIndex(of: $0) } ?? 0
                            model.download(Array(series.chapters.dropFirst(start).prefix(5)))
                        } label: { Label("Next 5 chapters", systemImage: "arrow.down.circle") }
                        Button {
                            model.download(series.chapters.filter { model.state.progress[$0.id]?.completed != true })
                        } label: { Label("All unread", systemImage: "arrow.down.circle.dotted") }
                    } label: { squareButton("arrow.down.to.line") }
                        .accessibilityLabel("Download")
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 14)
        .background(alignment: .top) {
            CoverView(url: cover, referer: series.chapters.first)
                .frame(height: 340)
                .blur(radius: 34).opacity(0.5)
                .overlay(LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.65), .black], startPoint: .top, endPoint: .bottom))
                .padding(.top, -120)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .clipped()
    }
    private func chip(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.caption2.weight(.semibold)).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.white.opacity(0.1), in: Capsule())
    }
    private func squareButton(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 54, height: 54)
            .background(Eclipse.surfaceHigh, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Eclipse.hairline))
    }
}

/// One chapter: name (dimmed once read), date or progress below, download state on the right.
struct ChapterRow: View {
    @EnvironmentObject private var model: LibraryModel
    let chapter: Chapter
    let builtIn: Bool
    let open: () -> Void
    var body: some View {
        let progress = model.state.progress[chapter.id]
        let done = progress?.completed == true
        let parts = ChapterText.split(chapter.title)
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if model.isNew(chapter) {
                                Circle().fill(Eclipse.highlight).frame(width: 7, height: 7).accessibilityLabel("New")
                            }
                            Text(parts.name).font(.subheadline.weight(done ? .regular : .semibold)).lineLimit(2)
                        }
                        HStack(spacing: 6) {
                            if let date = parts.date ?? (builtIn ? chapter.published : nil) { Text(date) }
                            if let progress, !progress.completed {
                                if parts.date != nil || (builtIn && chapter.published != nil) { Text("·") }
                                Text("Page \(progress.page + 1) of \(progress.pageCount)").foregroundStyle(Eclipse.accent)
                            }
                            if model.isDownloaded(chapter) {
                                Image(systemName: "arrow.down.circle.fill").imageScale(.small).accessibilityLabel("Downloaded")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }
                .opacity(done ? 0.5 : 1)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            DownloadButton(chapter: chapter)
        }
        .padding(.vertical, 4)
    }
}

/// Download control for one chapter: download, live progress (tap to cancel), retry, or done.
struct DownloadButton: View {
    @EnvironmentObject private var model: LibraryModel
    let chapter: Chapter
    var body: some View {
        Group {
            if model.isDownloaded(chapter) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary)
                    .accessibilityLabel("Downloaded")
            } else if let state = model.downloads[chapter.id] {
                switch state {
                case .queued:
                    Button { model.cancelDownload(chapter) } label: { ProgressView().controlSize(.small) }
                        .accessibilityLabel("Waiting to download. Double-tap to cancel")
                case .running(let progress):
                    Button { model.cancelDownload(chapter) } label: {
                        ZStack {
                            Circle().stroke(Color.white.opacity(0.25), lineWidth: 3)
                            Circle().trim(from: 0, to: progress).stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Image(systemName: "stop.fill").font(.system(size: 8))
                        }.frame(width: 22, height: 22)
                    }.accessibilityLabel("Downloading, \(Int(progress * 100)) percent. Double-tap to cancel")
                case .failed(let reason):
                    Button { model.cancelDownload(chapter); model.download([chapter]) } label: {
                        Image(systemName: "exclamationmark.arrow.circlepath").foregroundStyle(.orange)
                    }.accessibilityLabel("Download failed: \(reason). Double-tap to retry")
                }
            } else if model.canDownload(chapter) {
                Button { model.download([chapter]) } label: { Image(systemName: "arrow.down.circle") }
                    .accessibilityLabel("Download for offline reading")
            }
        }
        .buttonStyle(.borderless).font(.title3).frame(width: 30)
    }
}

/// Pick a cover: any of the first pages, or a picture from Photos.
struct CoverPicker: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let series: MangaSeries
    @State private var choices: [MangaPage] = []
    @State private var loading = true
    @State private var photo: PhotosPickerItem?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Choose from Photos", systemImage: "photo.on.rectangle.angled").font(.headline)
                            .frame(maxWidth: .infinity).padding(16)
                            .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 14))
                    }
                    if model.state.customCovers?[series.id] != nil {
                        Button { model.setCustomCover(nil, for: series.id); dismiss() } label: {
                            Label("Use the automatic cover", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered)
                    }
                    Text("Or choose a page").font(.headline)
                    if loading { ProgressView().frame(maxWidth: .infinity) }
                    if !loading && choices.isEmpty { Text("Pages couldn’t be loaded. Check your connection.").foregroundStyle(.secondary) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 12) {
                        ForEach(choices) { page in
                            Button {
                                Task {
                                    do { try await model.chooseCoverPage(page, seriesID: series.id); dismiss() }
                                    catch { self.error = error.localizedDescription }
                                }
                            } label: {
                                CoverView(url: page.url, referer: series.chapters.first)
                                    .aspectRatio(0.7, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).accessibilityLabel(page.label)
                        }
                    }
                    if let error { Text(error).foregroundStyle(.orange) }
                }.padding(20)
            }
            .navigationTitle("Cover").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() } }
            .task { choices = await model.coverChoices(series); loading = false }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { return }
                        try await model.setCoverPhoto(data, for: series.id)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
        }.preferredColorScheme(.dark)
    }
}

/// Add manga from a link (whole series) or from Files.
struct AddMangaView: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let done: (LibraryModel.LinkResult) -> Void
    @State private var text = ""
    @State private var working = false
    @State private var error: String?
    @State private var browse: URL?
    @State private var importing = false
    @State private var copy = true
    private static let types: [UTType] = [.folder, .zip, .pdf, .image] + [UTType(filenameExtension: "cbz")].compactMap { $0 }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $text)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.go).onSubmit { submit(text) }
                        .accessibilityIdentifier("linkField")
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first { text = first.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }.labelStyle(.titleAndIcon).tint(Eclipse.accent)
                    Button { submit(text) } label: {
                        HStack { Label("Add series", systemImage: "plus.circle.fill"); Spacer(); if working { ProgressView() } }
                    }.disabled(working || text.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: { Text("From a website") } footer: {
                    Text("Paste the series page (the one listing all chapters) to add the whole manga or manhwa. A chapter link also works. Pages are fetched directly by this device.")
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.orange)
                        if let url = WebLink.parse(text) {
                            Button { browse = url } label: { Label("Open in browser instead", systemImage: "safari") }
                        }
                    } footer: { Text("In the browser, open the series page and tap Add to library. Sites that check for bots work there.") }
                }
                Section {
                    Button { importing = true } label: { Label("Import from Files…", systemImage: "folder.badge.plus") }
                        .disabled(working)
                    Toggle("Copy into eclipsereader", isOn: $copy)
                } header: { Text("From Files, iCloud or a drive") } footer: {
                    Text(copy ? "CBZ, ZIP, PDF, images or folders. Copies are readable offline; your originals are never changed."
                              : "Reads straight from the original location (good for large collections on an external SSD). The drive must be connected while reading.")
                }
            }
            .scrollContentBackground(.hidden).background(EclipseBackground())
            .navigationTitle("Add manga").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() } }
            .fileImporter(isPresented: $importing, allowedContentTypes: Self.types, allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): importFiles(urls)
                case .failure(let e): error = e.localizedDescription
                }
            }
            .fullScreenCover(item: $browse) { url in MangaBrowserView(start: url).environmentObject(model) }
        }.preferredColorScheme(.dark)
    }
    private func submit(_ value: String) {
        guard !working else { return }
        working = true; error = nil
        Task {
            defer { working = false }
            do { done(try await model.addLink(value)) }
            catch let e as SourceError where e == .unsupportedStructure {
                error = "Couldn’t find chapters or pages on that page. The site may build its pages with scripts. Try the series page, or open it in the browser."
            }
            catch { self.error = error.localizedDescription }
        }
    }
    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        working = true; error = nil
        Task {
            defer { working = false }
            do {
                let series = try await model.importFiles(urls, copy: copy)
                done(.series(series, open: nil))
            } catch { self.error = error.localizedDescription }
        }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }
