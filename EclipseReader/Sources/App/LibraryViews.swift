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
        .fullScreenCover(item: $model.incoming) { target in MangaBrowserView(start: target.url).environmentObject(model) }
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, new, reading, downloaded, manga, manhwa, manhua, webtoon, comic, books, files
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .new: "New chapters"
        case .reading: "Reading"
        case .downloaded: "Downloaded"
        case .manga: "Manga"
        case .manhwa: "Manhwa"
        case .manhua: "Manhua"
        case .webtoon: "Webtoons"
        case .comic: "Comics"
        case .books: "Boring books without pictures"
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
    @AppStorage("libraryShowQuote") private var showQuote = true
    @State private var searchingEverywhere = false
    /// Closed with × for this launch (turn it off for good in sort & display options).
    @State private var quoteClosed = false
    @State private var pickClosed = false
    @State private var bookQuoteClosed = false
    @State private var bookPickClosed = false
    @State private var bookSearch: QuoteSearch?
    @AppStorage("libraryShowPick") private var showPick = true
    @ObservedObject private var picks = PickStore.shared
    @State private var quoteSearch: QuoteSearch?
    struct QuoteSearch: Identifiable { let query: String; var id: String { query } }
    @Namespace private var zoom
    @FocusState private var searchFocused: Bool

    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .recent }
    private func matches(_ series: MangaSeries, _ filter: LibraryFilter) -> Bool {
        switch filter {
        case .all: true
        case .new: model.newCount(series) > 0
        case .downloaded: model.downloadedCount(series) > 0 || series.kind == .local
        case .reading: model.lastRead(series) != nil && model.readCount(series) < series.chapters.count
        case .manga: series.kind != .book && model.style(for: series.id) == .manga
        case .manhwa: series.kind != .book && model.style(for: series.id) == .manhwa
        case .manhua: series.kind != .book && model.style(for: series.id) == .manhua
        case .webtoon: series.kind != .book && model.style(for: series.id) == .webtoon
        case .comic: series.kind != .book && model.style(for: series.id) == .comic
        case .books: series.kind == .book
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
                GeometryReader { geometry in
                let contentWidth = min(geometry.size.width, 1280) - 28
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if query.isEmpty, showQuote, !quoteClosed, filter == .all {
                            QuoteCard(compact: geometry.size.width < 420, read: { readQuote($0) }, close: {
                                withAnimation(.snappy) { quoteClosed = true }
                            })
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        if query.isEmpty, showPick, !pickClosed, filter == .all, let pick = picks.manga {
                            PickCard(pick: pick, read: { readPick(pick) }, next: { withAnimation(.snappy) { picks.shuffle(book: false) } },
                                     close: { withAnimation(.snappy) { pickClosed = true } })
                                .transition(.opacity)
                        }
                        // Books get their own quote and pick, once there are books in the library.
                        if query.isEmpty, model.hasBooks, filter == .all || filter == .books {
                            if showQuote && !bookQuoteClosed {
                                QuoteCard(books: true, compact: geometry.size.width < 420, read: { readBook($0.work) }, close: {
                                    withAnimation(.snappy) { bookQuoteClosed = true }
                                })
                            }
                            if showPick && !bookPickClosed, let pick = picks.book {
                                PickCard(pick: pick, read: { readBook(pick.title) }, next: { withAnimation(.snappy) { picks.shuffle(book: true) } },
                                         close: { withAnimation(.snappy) { bookPickClosed = true } })
                            }
                        }
                        if query.isEmpty, showContinue, filter == .all, let chapter = model.lastChapter {
                            ContinueBar(chapter: chapter, resume: { reader = chapter },
                                        open: { openSeries = model.series(id: model.seriesID(for: chapter)) })
                        }
                        LibraryGrid(series: visible, reader: $reader, openSeries: $openSeries, zoom: zoom, width: contentWidth)
                        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button { searchingEverywhere = true } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "globe").foregroundStyle(Eclipse.highlight)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Search every site for “\(query)”").font(.subheadline.weight(.semibold))
                                        Text("MangaDex, WeebCentral, WEBTOON and your sites").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                                }
                                .padding(14).eclipseCard(cornerRadius: 14)
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityIdentifier("searchEverywhere")
                        }
                        if query.isEmpty && filter == .all && model.librarySeries.count < 12 {
                            DiscoverStrip(openSeries: $openSeries, width: contentWidth)
                        }
                        if visible.isEmpty && query.isEmpty {
                            ContentUnavailableView {
                                Label(query.isEmpty ? "Nothing here yet" : "No matches", systemImage: "books.vertical")
                            } description: {
                                Text(query.isEmpty ? "Add a series from Browse, paste a link, or import files." : "Nothing in your library by that name. Search every site below.")
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
            .sheet(isPresented: $searchingEverywhere) { GlobalSearchSheet(query: query).environmentObject(model) }
            .sheet(item: $quoteSearch) { item in GlobalSearchSheet(query: item.query).environmentObject(model) }
            .sheet(item: $bookSearch) { item in BookSearchSheet(query: item.query).environmentObject(model) }
            .task {
                let owned = Set(model.allSeries.map { $0.title.lowercased() })
                if showPick { await picks.loadManga(excluding: owned) }
                if showPick && model.hasBooks { await picks.loadBooks(excluding: owned) }
            }
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

    /// The quote's series: straight to it when it's in your library, otherwise every site is searched for it.
    private func readQuote(_ quote: MangaQuote) {
        let work = quote.work.lowercased()
        if let owned = model.librarySeries.first(where: { $0.title.lowercased() == work })
            ?? model.librarySeries.first(where: { $0.title.lowercased().contains(work) || ($0.title.count >= 4 && work.contains($0.title.lowercased())) }) {
            openSeries = owned
        } else {
            quoteSearch = QuoteSearch(query: quote.work)
        }
    }

    /// A recommended manga: open it if it's yours, otherwise search every site for it.
    private func readPick(_ pick: Recommendation) {
        let title = pick.title.lowercased()
        if let owned = model.librarySeries.first(where: { $0.title.lowercased() == title }) { openSeries = owned }
        else { quoteSearch = QuoteSearch(query: pick.title) }
    }
    /// A book from a quote or pick: open your copy, or look for it in the free libraries.
    private func readBook(_ title: String) {
        let lower = title.lowercased()
        if let owned = model.librarySeries.first(where: { $0.kind == .book && ($0.title.lowercased() == lower || $0.title.lowercased().contains(lower)) }) {
            openSeries = owned
        } else {
            bookSearch = QuoteSearch(query: title)
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
                    ViewThatFits(in: .horizontal) {
                        EclipseWordmark(size: 22)
                        EclipseMark(size: 26)
                    }
                    .accessibilityAddTraits(.isHeader)
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
                        if model.showHidden {
                            Button { model.showHidden = false } label: { Label("Hide hidden series", systemImage: "eye.slash") }
                        } else if (model.state.hiddenSeries?.count ?? 0) > 0 {
                            Button {
                                Task { if await Biometrics.unlock(reason: "Show hidden series") { model.showHidden = true } }
                            } label: { Label("Show hidden series", systemImage: "eye") }
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
    @AppStorage("libraryShowQuote") private var showQuote = true
    @AppStorage("libraryShowPick") private var showPick = true
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
                    Toggle("Quote of the launch", isOn: $showQuote)
                    Toggle("Pick of the launch", isOn: $showPick)
                }
            }
            .scrollContentBackground(.hidden).background(Eclipse.surface)
            .navigationTitle("Library").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() }.fontWeight(.semibold) }
        }.preferredColorScheme(.dark)
    }
}

/// "Find something new" under a small library: popular MangaDex titles, one tap to add.
struct DiscoverStrip: View {
    @EnvironmentObject private var model: LibraryModel
    @Binding var openSeries: MangaSeries?
    var width: CGFloat = 390
    @State private var items: [DiscoverItem] = []
    @State private var adding: String?
    @State private var error: String?
    var body: some View {
        let cardWidth = min(150, max(104, width / 3.6))
        VStack(alignment: .leading, spacing: 10) {
            if !items.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text("Discover").font(.title3.weight(.bold))
                    Text("Popular on MangaDex").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items.filter { item in !model.allSeries.contains { $0.url == item.url } }) { item in
                            Button { add(item) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    CoverView(url: item.cover, referer: nil)
                                        .aspectRatio(0.7, contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay {
                                            if adding == item.id {
                                                ZStack { Color.black.opacity(0.5); ProgressView().tint(.white) }
                                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                            }
                                        }
                                        .overlay(alignment: .bottomTrailing) {
                                            Image(systemName: "plus").font(.caption.weight(.heavy)).foregroundStyle(.black)
                                                .frame(width: 24, height: 24).background(Eclipse.highlight, in: Circle()).padding(6)
                                        }
                                    Text(item.title).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                                    if let detail = item.detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
                                }.frame(width: cardWidth)
                            }
                            .buttonStyle(PressableStyle())
                            .disabled(adding != nil)
                        }
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            }
        }
        .padding(.top, 8)
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
            #endif
            if items.isEmpty { items = (try? await Discover.mangaDex(limit: 16)) ?? [] }
        }
    }
    private func add(_ item: DiscoverItem) {
        adding = item.id; error = nil
        Task {
            defer { adding = nil }
            do {
                if case .series(let series, _) = try await model.addLink(item.url.absoluteString) { openSeries = series }
            } catch { self.error = "Couldn’t add \(item.title)." }
        }
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
    /// Width available to the grid; columns and card text scale with it.
    var width: CGFloat = 390
    @AppStorage("libraryDensity") private var densityRaw = LibraryDensity.comfortable.rawValue
    @State private var coverFor: MangaSeries?
    var body: some View {
        let density = LibraryDensity(rawValue: densityRaw) ?? .comfortable
        let spacing: CGFloat = width > 700 ? 18 : 12
        let count = density.columns(for: width, spacing: spacing)
        let cardWidth = (width - spacing * CGFloat(count - 1)) / CGFloat(count)
        let columns = Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: count)
        LazyVGrid(columns: columns, alignment: .leading, spacing: spacing + 6) {
            ForEach(series) { item in
                Button { openSeries = item } label: { SeriesCard(series: item, width: cardWidth).zoomSource(item.id, in: zoom) }
                    .buttonStyle(PressableStyle())
                    .accessibilityIdentifier(item.id == LibraryModel.berserkID ? "chapterBrowser" : "series-\(item.title)")
                    .contextMenu {
                        if let chapter = model.resume(item) {
                            Button { reader = chapter } label: { Label("Continue \(ChapterText.split(chapter.title).name)", systemImage: "book") }
                        }
                        Button { coverFor = item } label: { Label("Change cover…", systemImage: "photo") }
                        Picker("Reads as", selection: Binding(get: { model.styleOverride(item.id) },
                                                              set: { model.setStyle($0, for: item.id) })) {
                            ForEach(ReadingStyle.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                        }
                        if !model.categories.isEmpty {
                            Menu {
                                ForEach(model.categories) { category in
                                    let member = model.isIn(category, item)
                                    Button { model.set([item], in: category, !member) } label: {
                                        Label(category.name, systemImage: member ? "checkmark" : "folder")
                                    }
                                }
                            } label: { Label("Categories", systemImage: "folder") }
                        }
                        Button { model.setHidden(!model.isHidden(item), item) } label: {
                            Label(model.isHidden(item) ? "Unhide" : "Hide", systemImage: model.isHidden(item) ? "eye" : "eye.slash")
                        }
                        if item.id != LibraryModel.berserkID {
                            Button(role: .destructive) { model.remove(item) } label: { Label("Remove from library", systemImage: "trash") }
                        }
                    }
            }
        }
        .sheet(item: $coverFor) { series in CoverPicker(series: series).environmentObject(model) }
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
                    NavigationLink { StatsPage() } label: {
                        SettingsRow(title: "Reading stats", detail: "Time read, streaks, chapters finished", symbol: "chart.bar.fill", tint: .green)
                    }
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
    @AppStorage("readerPageNumber") private var showPageNumber = true
    @AppStorage("pageHaptics") private var haptics = true
    var body: some View {
        Form {
            ReaderPreferencesForm(preferences: Binding(get: { model.preferences }, set: { model.preferences = $0 }))
            Section {
                Toggle("Keep the screen on while reading", isOn: $keepScreenOn)
                Toggle("Show page number", isOn: $showPageNumber)
                Toggle("Page-turn haptics", isOn: $haptics)
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
    /// Ideal cover width; the grid fits as many as the screen holds, then stretches them to fill.
    var target: CGFloat { [116, 156, 212][rawValue] }
    func columns(for width: CGFloat, spacing: CGFloat = 12) -> Int {
        max(2, Int((width + spacing) / (target + spacing)))
    }
}

struct LibrarySettingsPage: View {
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("libraryDensity") private var density = LibraryDensity.comfortable.rawValue
    @AppStorage("libraryShowContinue") private var showContinue = true
    @AppStorage("libraryShowQuote") private var showQuote = true
    @AppStorage("libraryShowPick") private var showPick = true
    @AppStorage("libraryTitlesOnCovers") private var titlesOnCovers = true
    @State private var alertMessage: String?
    var body: some View {
        Form {
            Section("Layout") {
                Picker("Cover size", selection: $density) {
                    ForEach(LibraryDensity.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.segmented)
                Toggle("Titles on covers", isOn: $titlesOnCovers)
                Toggle("Continue reading bar", isOn: $showContinue)
                Toggle("Quote of the launch", isOn: $showQuote)
                Toggle("Pick of the launch (MyAnimeList & Open Library)", isOn: $showPick)
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
                Toggle(isOn: Binding(
                    get: { model.state.notifyNew == true },
                    set: { on in
                        Task {
                            let ok = await model.setNotifications(on)
                            alertMessage = ok ? nil : "Notifications are off for eclipsereader. Turn them on in iOS Settings › Notifications › eclipsereader."
                        }
                    })) {
                    Label("Notify me about new chapters", systemImage: "bell.badge")
                }
                if let alertMessage { Text(alertMessage).font(.footnote).foregroundStyle(.orange) }
                Toggle("Download new chapters automatically", isOn: Binding(
                    get: { model.state.autoDownloadNew == true },
                    set: { model.state.autoDownloadNew = $0; model.save() }))
                if model.totalNew > 0 {
                    Button("Mark all new chapters as seen") { for s in model.librarySeries { model.clearNew(s) } }
                }
            } header: { Text("New chapters") } footer: {
                Text("eclipsereader checks when you open it (at most every six hours) and when you pull down on the library. With notifications on, iOS also wakes it every few hours to check, shows a notification per updated series, and puts the count on the app icon.")
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
                Toggle("Download on Wi-Fi only", isOn: Binding(
                    get: { model.state.downloadWiFiOnly == true },
                    set: { model.state.downloadWiFiOnly = $0; model.save(); if !$0 { model.startDownloads() } }))
                if model.waitingForWiFi {
                    Label("Waiting for Wi-Fi to continue downloading", systemImage: "wifi.exclamationmark")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Toggle("Delete downloads after reading", isOn: Binding(
                    get: { model.state.deleteAfterReading == true },
                    set: { model.state.deleteAfterReading = $0; model.save() }))
            } footer: {
                Text("Finished chapters free their space as soon as you finish them.")
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
            let index = model.chapterIndex
            if !model.downloads.isEmpty {
                Section("Queue") {
                    ForEach(model.downloads.keys.sorted(), id: \.self) { id in
                        if let entry = index[id], let state = model.downloads[id] {
                            let series = entry.0, chapter = entry.1
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(series.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(ChapterText.split(chapter.title).name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    switch state {
                                    case .queued: Text("Waiting…").font(.caption2).foregroundStyle(.secondary)
                                    case .running(let progress): ProgressView(value: progress).tint(Eclipse.accent)
                                    case .failed(let reason): Text(reason).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 4)
                                Button { model.cancelDownload(chapter) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                    .buttonStyle(.borderless).accessibilityLabel("Cancel download")
                            }
                        }
                    }
                }
            }
            let offline = model.librarySeries.filter { model.downloadedCount($0) > 0 }
            if !offline.isEmpty {
                Section("On this device") {
                    ForEach(offline) { series in
                        HStack(spacing: 12) {
                            CoverView(url: model.cover(for: series), referer: series.chapters.first)
                                .frame(width: 34, height: 48).clipShape(RoundedRectangle(cornerRadius: 5))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(series.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text("\(model.downloadedCount(series)) chapter\(model.downloadedCount(series) == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                for chapter in series.chapters where model.isDownloaded(chapter) { model.removeDownload(chapter) }
                            } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                }
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
            Section {
                Button {
                    UIPasteboard.general.string = "javascript:location.href='eclipsereader://open?url='+encodeURIComponent(location.href)"
                    message = "Bookmarklet copied. In Safari, bookmark any page, edit the bookmark and paste this as its address."
                } label: { Label("Copy the Safari bookmarklet", systemImage: "bookmark") }
            } header: { Text("Send pages from Safari") } footer: {
                Text("Tap the bookmark on any manga page in Safari and it opens here, ready to add. Shortcuts can open eclipsereader://open?url=… too.")
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
    @State private var choosingFolder = false
    @State private var autoFolder: String?
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
            Section {
                if let folder = autoFolder {
                    LabeledContent("Folder", value: folder)
                    if let last = AutoBackup.lastBackup {
                        LabeledContent("Last backup", value: last.formatted(.relative(presentation: .named)))
                    }
                    Button { message = AutoBackup.runIfDue(model, force: true) ?? "Backed up." } label: {
                        Label("Back up now", systemImage: "arrow.clockwise.icloud")
                    }
                    Button("Stop automatic backups", role: .destructive) { AutoBackup.setFolder(nil); autoFolder = nil }
                } else {
                    Button { choosingFolder = true } label: { Label("Choose a backup folder…", systemImage: "folder.badge.plus") }
                }
            } header: { Text("Automatic backups") } footer: {
                Text("Once a day, eclipsereader saves a backup into the folder you choose (pick one in iCloud Drive to keep it safe off the device). The last seven are kept.")
            }
        }
        .settingsPage("Backup & restore")
        .task { autoFolder = AutoBackup.folderName }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                AutoBackup.setFolder(url)
                autoFolder = AutoBackup.folderName
                message = AutoBackup.runIfDue(model, force: true) ?? "Backups will be saved to \(autoFolder ?? "that folder") every day."
            }
        }
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
    @AppStorage("appLock") private var appLock = false
    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { appLock }, set: { on in
                    Task {
                        // Prove it's you before turning the lock on or off.
                        if await Biometrics.unlock(reason: on ? "Lock eclipsereader" : "Turn off the lock") { appLock = on }
                    }
                })) {
                    Label("Lock with \(Biometrics.symbol == "touchid" ? "Touch ID" : "Face ID")", systemImage: Biometrics.symbol)
                }
            } footer: { Text("Asks for Face ID, Touch ID or your passcode whenever eclipsereader opens.") }
            Section {
                LabeledContent("Hidden series", value: "\(model.state.hiddenSeries?.count ?? 0)")
                if model.showHidden {
                    Button("Hide them again") { model.showHidden = false }
                } else if (model.state.hiddenSeries?.count ?? 0) > 0 {
                    Button("Show hidden series") {
                        Task { if await Biometrics.unlock(reason: "Show hidden series") { model.showHidden = true } }
                    }
                }
            } footer: { Text("Long-press a cover in the library and choose Hide. Hidden series need Face ID to show.") }
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
            Toggle(isOn: Binding(get: { preferences.enhance ?? false }, set: { preferences.enhance = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enhance low-resolution pages")
                    Text("Upscales and sharpens blurry scans on the device").font(.caption).foregroundStyle(.secondary)
                }
            }
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
/// Text and badges scale with the card, so covers look right from the Duo's front screen to an iPad.
struct SeriesCard: View {
    @EnvironmentObject private var model: LibraryModel
    let series: MangaSeries
    var width: CGFloat = 156
    @AppStorage("libraryTitlesOnCovers") private var titlesOnCovers = true
    var body: some View {
        let read = model.readCount(series)
        let total = series.chapters.count
        let unread = max(0, total - read)
        let new = model.newCount(series)
        let offline = model.downloadedCount(series)
        let style = series.kind == .web ? Optional(model.style(for: series.id)) : nil
        let reading = model.lastRead(series) != nil && read < total
        let k = min(1.45, max(0.8, width / 156))
        let radius = 10 * min(1.3, k)
        VStack(alignment: .leading, spacing: 6 * k) {
            CoverView(url: model.cover(for: series), referer: series.chapters.first, onFail: { model.coverFailed(series) })
                .aspectRatio(0.7, contentMode: .fit)
                .overlay(alignment: .bottom) {
                    if titlesOnCovers {
                        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.55), location: 0.45),
                                               .init(color: .black.opacity(0.92), location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 90 * k)
                            .overlay(alignment: .bottomLeading) {
                                Text(series.title).font(.system(size: 13.5 * k, weight: .bold)).lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .shadow(color: .black, radius: 2)
                                    .padding(.horizontal, 8 * k).padding(.bottom, (reading ? 11 : 8) * k)
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
                        }.frame(height: 3 * k)
                    }
                }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        if offline > 0 {
                            Text("\(offline)").padding(.horizontal, 6 * k).padding(.vertical, 3 * k)
                                .background(Eclipse.accent).foregroundStyle(.white)
                                .accessibilityLabel("\(offline) downloaded")
                        }
                        if new > 0 {
                            Text("\(new) NEW").padding(.horizontal, 6 * k).padding(.vertical, 3 * k)
                                .background(Eclipse.highlight).foregroundStyle(.black)
                        } else if unread > 0 && total > 0 {
                            Text("\(unread)").padding(.horizontal, 6 * k).padding(.vertical, 3 * k)
                                .background(Color.white).foregroundStyle(.black)
                                .accessibilityLabel("\(unread) unread")
                        }
                    }
                    .font(.system(size: 11 * k, weight: .heavy)).monospacedDigit()
                    .clipShape(RoundedRectangle(cornerRadius: 5 * k))
                    .padding(6 * k)
                }
                .overlay(alignment: .topTrailing) {
                    Group {
                        if let style {
                            Text(style.tag).font(.system(size: 8.5 * k, weight: .heavy)).tracking(0.6)
                                .padding(.horizontal, 5 * k).padding(.vertical, 3 * k)
                        } else if series.kind == .book {
                            Text("BOOK").font(.system(size: 8.5 * k, weight: .heavy)).tracking(0.6)
                                .padding(.horizontal, 5 * k).padding(.vertical, 3 * k)
                        } else {
                            Image(systemName: "internaldrive.fill").font(.system(size: 9 * k, weight: .bold))
                                .padding(4 * k)
                        }
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(6 * k)
                    .accessibilityLabel(style?.title ?? (series.kind == .book ? "Book" : "On this device"))
                }
                .clipShape(RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.white.opacity(0.07)))
                .shadow(color: .black.opacity(0.5), radius: 8 * k, y: 4 * k)
            if !titlesOnCovers {
                Text(series.title).font(.system(size: 13 * k, weight: .semibold)).lineLimit(2)
            }
            Text(total == 0 ? "Loading chapters…" : reading ? "\(read) of \(total) read" : "\(total) chapter\(total == 1 ? "" : "s")")
                .font(.system(size: 11 * k)).foregroundStyle(.secondary).lineLimit(1)
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
    @State private var migrating = false
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
            .task {
                if builtIn && series.chapters.isEmpty { await model.refresh() }
                // Fresh chapter list the first time a website series is opened each session.
                if series.kind == .web && !builtIn && model.sessionRefreshed.insert(series.id).inserted {
                    try? await model.update(series)
                }
            }
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
                            if series.kind == .web && !builtIn {
                                Button { migrating = true } label: { Label("Migrate to another site…", systemImage: "arrow.triangle.swap") }
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
            .sheet(isPresented: $migrating) { MigrateSheet(series: series).environmentObject(model) }
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
        } catch {
            message = error.localizedDescription + (series.kind == .web ? " If the site moved or closed, use ⋯ › Migrate." : "")
        }
    }
}

/// Cover over a blurred copy of itself, title and facts, then the main "Continue" action.
struct SeriesHeader: View {
    @EnvironmentObject private var model: LibraryModel
    let series: MangaSeries
    @Binding var reader: Chapter?
    @Binding var website: Bool
    /// Colour from the cover; the page glows with it.
    @State private var tint: Color = Eclipse.accent
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
                    Label(builtIn ? "Built in" : series.kind == .book ? (series.author ?? "Book") : series.kind == .web ? (series.url.host?.replacingOccurrences(of: "www.", with: "") ?? "Website") : "On this device",
                          systemImage: series.kind == .local ? "internaldrive" : series.kind == .book ? "person" : "globe")
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 6) {
                        if series.kind == .book { chip("Book", symbol: "text.book.closed") } else { chip(style.title, symbol: style.symbol) }
                        if model.downloadedCount(series) > 0 { chip("\(model.downloadedCount(series))", symbol: "arrow.down.circle.fill") }
                    }
                    Text(series.chapters.isEmpty ? "Loading chapters…" : "\(read) of \(series.chapters.count) read")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let summary = series.summary, !summary.isEmpty { SynopsisText(text: summary) }
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
                    .background(LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.18)))
                    .shadow(color: tint.opacity(0.45), radius: 14, y: 6)
                }
                .buttonStyle(PressableStyle()).disabled(resume == nil)
                .accessibilityIdentifier("seriesContinue")
                if series.kind != .book {
                    Menu {
                        Picker("Reads as", selection: Binding(get: { model.styleOverride(series.id) }, set: { model.setStyle($0, for: series.id) })) {
                            ForEach(ReadingStyle.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                        }
                    } label: { squareButton(style.symbol) }
                        .accessibilityLabel("Reads as \(style.title)")
                }
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
            ZStack(alignment: .top) {
                CoverView(url: cover, referer: series.chapters.first)
                    .frame(height: 340)
                    .blur(radius: 34).opacity(0.5)
                RadialGradient(colors: [tint.opacity(0.45), .clear], center: .top, startRadius: 0, endRadius: 360)
                    .frame(height: 420)
            }
            .overlay(LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.6), .black], startPoint: .top, endPoint: .bottom))
            .padding(.top, -120)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .clipped()
        .task(id: cover) {
            guard let cover else { return }
            let page = MangaPage(url: cover, label: "Cover")
            let referer = series.chapters.first ?? Chapter(url: cover, title: "", number: "")
            guard let data = try? await model.pipeline.data(for: page, chapter: referer) else { return }
            let found = await Task.detached(priority: .utility) { CoverTint.from(data) }.value
            if let found { withAnimation(.easeOut(duration: 0.6)) { tint = found.color } }
        }
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

/// A series synopsis: three lines, tap to read it all.
struct SynopsisText: View {
    let text: String
    @State private var expanded = false
    var body: some View {
        Button { withAnimation(.snappy) { expanded.toggle() } } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(text).font(.subheadline).foregroundStyle(.white.opacity(0.82))
                    .lineLimit(expanded ? nil : 3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text(expanded ? "Less" : "More")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }.font(.caption.weight(.bold)).foregroundStyle(Eclipse.highlight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(expanded ? "Shows less" : "Shows the full description")
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
/// Full cover control: a picture from Photos or Files, an image link, any page of the series,
/// or back to the automatic cover.
struct CoverPicker: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let series: MangaSeries
    @State private var choices: [MangaPage] = []
    @State private var loading = true
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var link = ""
    @State private var working = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .bottom, spacing: 16) {
                        CoverView(url: model.cover(for: series), referer: series.chapters.first)
                            .aspectRatio(0.7, contentMode: .fit).frame(width: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay { if working { ZStack { Color.black.opacity(0.5); ProgressView() }.clipShape(RoundedRectangle(cornerRadius: 10)) } }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(series.title).font(.headline).lineLimit(3)
                            Text(model.state.customCovers?[series.id] != nil ? "Custom cover" : "Automatic cover")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    VStack(spacing: 10) {
                        PhotosPicker(selection: $photo, matching: .images) {
                            CoverOption(title: "Choose from Photos", symbol: "photo.on.rectangle.angled")
                        }.buttonStyle(PressableStyle())
                        Button { importing = true } label: { CoverOption(title: "Choose from Files", symbol: "folder") }
                            .buttonStyle(PressableStyle())
                        HStack(spacing: 8) {
                            Image(systemName: "link").foregroundStyle(.secondary)
                            TextField("Paste an image link", text: $link)
                                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .submitLabel(.done).onSubmit(useLink)
                            Button("Use", action: useLink).fontWeight(.semibold)
                                .disabled(WebLink.parse(link) == nil || working)
                        }
                        .padding(.horizontal, 14).frame(height: 52).eclipseCard(cornerRadius: 14)
                        if model.state.customCovers?[series.id] != nil {
                            Button { model.setCustomCover(nil, for: series.id); dismiss() } label: {
                                CoverOption(title: "Back to the automatic cover", symbol: "arrow.uturn.backward")
                            }.buttonStyle(PressableStyle())
                        }
                    }
                    if let error { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
                    if !series.chapters.isEmpty && series.kind != .book {
                        Text("Or use a page").font(.headline)
                        if loading { ProgressView().frame(maxWidth: .infinity) }
                        if !loading && choices.isEmpty { Text("Pages couldn’t be loaded. Check your connection.").foregroundStyle(.secondary) }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)], spacing: 12) {
                            ForEach(choices) { page in
                                Button { apply { try await model.chooseCoverPage(page, seriesID: series.id) } } label: {
                                    CoverView(url: page.url, referer: series.chapters.first)
                                        .aspectRatio(0.7, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(PressableStyle()).accessibilityLabel(page.label)
                            }
                        }
                    }
                }
                .padding(20).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
            .background(EclipseBackground())
            .navigationTitle("Cover").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() }.fontWeight(.semibold) }
            .task { if series.kind != .book { choices = await model.coverChoices(series) }; loading = false }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                apply {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw BookError.invalid("That photo couldn’t be read.") }
                    try await model.setCoverPhoto(LibraryModel.coverShaped(data), for: series.id)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
                switch result {
                case .success(let url):
                    apply {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let data = try Data(contentsOf: url)
                        guard UIImage(data: data) != nil else { throw BookError.invalid("That file isn’t a picture.") }
                        try await model.setCoverPhoto(LibraryModel.coverShaped(data), for: series.id)
                    }
                case .failure(let e): error = e.localizedDescription
                }
            }
        }.preferredColorScheme(.dark)
    }
    private func useLink() {
        guard let url = WebLink.parse(link) else { return }
        apply {
            let page = MangaPage(url: url, label: "Cover")
            let data = try await model.pipeline.data(for: page, chapter: series.chapters.first ?? Chapter(url: url, title: "", number: ""))
            try await model.setCoverPhoto(LibraryModel.coverShaped(data), for: series.id)
        }
    }
    private func apply(_ work: @escaping @MainActor () async throws -> Void) {
        working = true; error = nil
        Task {
            defer { working = false }
            do { try await work(); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct CoverOption: View {
    let title: String
    let symbol: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(Eclipse.highlight).frame(width: 24)
            Text(title).font(.body.weight(.semibold))
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).frame(height: 52).eclipseCard(cornerRadius: 14)
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
    private static let types: [UTType] = [.folder, .zip, .pdf, .image] + [UTType(filenameExtension: "cbz")].compactMap { $0 } + BookLink.types
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
                    Text(copy ? "Manga: CBZ, ZIP, PDF, images or folders. Books: EPUB, MOBI, AZW3, FB2, TXT, RTF, HTML, DOCX, ODT. Copies are readable offline; your originals are never changed."
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
