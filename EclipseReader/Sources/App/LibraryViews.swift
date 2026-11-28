import SwiftUI
import WebKit
import CoreSpotlight
import UniformTypeIdentifiers
import ImageIO
import PhotosUI

/// The app's sections, in Mihon's order: your shelf, what's new, what you read, where to find more, settings.
enum AppTab: Int, CaseIterable, Identifiable {
    case library, updates, history, browse, settings
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .library: "Library"
        case .updates: "Updates"
        case .history: "History"
        case .browse: "Browse"
        case .settings: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .library: "books.vertical.fill"
        case .updates: "sparkles"
        case .history: "clock.arrow.circlepath"
        case .browse: "safari"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var tab = 0
    /// Tapping the tab you're already on goes back to its start, like the system tab bar.
    @State private var resets = [Int](repeating: 0, count: AppTab.allCases.count)
    /// iPhones (both screens of the Duo) get our own bottom bar. The system one turns into a
    /// vertical rail inside the Duo front screen's side column and covers the right edge of
    /// every page; ours always sits along the bottom, inside the safe area.
    private var phoneBar: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    var body: some View {
        sections
        .fullScreenCover(item: $model.requestedChapter) { chapter in ReaderView(chapter: chapter).environmentObject(model) }
        .background {
            Color.clear.fullScreenCover(item: $model.incoming) { target in MangaBrowserView(start: target.url).environmentObject(model) }
        }
        // Spotlight: tapping a series in iPhone search opens it in the library.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                tab = 0
                model.requestedSeriesID = id
            }
        }
        // Handoff: carry on reading the chapter (and page) another device was on.
        .onContinueUserActivity(Handoff.readingType) { activity in
            guard let raw = activity.userInfo?["chapter"] as? String,
                  let chapter = model.chapterIndex[raw]?.1 ?? model.state.chapters.first(where: { $0.id == raw }) else { return }
            if let page = activity.userInfo?["page"] as? Int, let count = activity.userInfo?["count"] as? Int,
               (model.state.progress[chapter.id]?.page ?? -1) < page {
                model.record(chapter, page: page, count: count)
            }
            if let section = activity.userInfo?["section"] as? Int, let offset = activity.userInfo?["offset"] as? Int,
               let series = model.series(containing: chapter) {
                model.setBookPosition(BookPosition(section: section, offset: offset), for: series.id)
            }
            model.requestedChapter = chapter
        }
        .onAppear {
            ControllerInput.shared.start()
            // Libraries that already hold books keep the Books tab when books became an option.
            if UserDefaults.standard.object(forKey: Features.booksKey) == nil {
                UserDefaults.standard.set(model.hasBooks, forKey: Features.booksKey)
            }
            // The bundled destinations (Resources/DefaultSources.json), and any source lists you subscribed to.
            model.seedBundledSources()
            Task { await model.refreshSourceLists() }
        }
        .task(id: model.libraryMembers.count) {
            SpotlightIndex.update(model.libraryMembers, hidden: Set(model.state.hiddenSeries ?? []))
        }
    }
}

extension RootView {
    @ViewBuilder fileprivate var sections: some View {
        if phoneBar {
            // The standard tab container (its own bar hidden) keeps each tab's life cycle exactly
            // as before: tabs you leave stop drawing and get their usual appear/disappear calls.
            PhoneTabContainer(selected: tab, resets: resets, barHeight: PhoneTabBar.height) { item in
                AnyView(section(item).environmentObject(model).tint(.white))
            }
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                // Always there, like the system tab bar: the keyboard simply covers it while it's up.
                // (Hiding it on keyboard notifications could leave it hidden when a keyboard went
                // away without saying so, for example when a sheet closed with the keyboard up.)
                PhoneTabBar(selected: tab, badge: model.totalNew) { choice in
                    if choice == tab { resets[choice] += 1 } else { tab = choice }
                }
                .ignoresSafeArea(.keyboard)
            }
            .sensoryFeedback(.selection, trigger: tab)
        } else {
            TabView(selection: $tab) {
                ForEach(AppTab.allCases) { item in
                    if item == .updates {
                        section(item).tabItem { Label(item.title, systemImage: item.symbol) }.badge(model.totalNew).tag(item.rawValue)
                    } else {
                        section(item).tabItem { Label(item.title, systemImage: item.symbol) }.tag(item.rawValue)
                    }
                }
            }
        }
    }
    @ViewBuilder fileprivate func section(_ item: AppTab) -> some View {
        switch item {
        case .library: LibraryView()
        case .updates: UpdatesView()
        case .history: HistoryView()
        case .browse: BrowseView()
        case .settings: SettingsView()
        }
    }
}

/// A UITabBarController with its bar hidden: it switches tabs, and makes room for our bar.
struct PhoneTabContainer: UIViewControllerRepresentable {
    let selected: Int
    let resets: [Int]
    let barHeight: CGFloat
    let page: (AppTab) -> AnyView
    final class Coordinator { var resets: [Int] = [] }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> UITabBarController {
        let controller = UITabBarController()
        controller.viewControllers = AppTab.allCases.map { item in
            let host = UIHostingController(rootView: page(item))
            host.view.backgroundColor = .black
            host.overrideUserInterfaceStyle = .dark
            return host
        }
        if #available(iOS 18.0, *) { controller.setTabBarHidden(true, animated: false) }
        controller.tabBar.isHidden = true
        controller.view.backgroundColor = .black
        context.coordinator.resets = resets
        return controller
    }
    func updateUIViewController(_ controller: UITabBarController, context: Context) {
        if controller.selectedIndex != selected { controller.selectedIndex = selected }
        controller.tabBar.isHidden = true
        for item in AppTab.allCases where context.coordinator.resets[safe: item.rawValue] != resets[item.rawValue] {
            // Same tab tapped again: start that tab over (back to its first screen, scrolled to the top).
            if let host = controller.viewControllers?[safe: item.rawValue] as? UIHostingController<AnyView> {
                host.rootView = AnyView(page(item).id(resets[item.rawValue]))
            }
        }
        context.coordinator.resets = resets
        for child in controller.viewControllers ?? [] where child.additionalSafeAreaInsets.bottom != barHeight {
            child.additionalSafeAreaInsets.bottom = barHeight
        }
    }
}

/// A bottom tab bar that keeps to the bottom edge on every iPhone screen shape.
struct PhoneTabBar: View {
    /// The bar's height above the home indicator; tab pages leave this much room at the bottom.
    static let height: CGFloat = 51
    let selected: Int
    let badge: Int
    let select: (Int) -> Void
    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { item in
                let on = selected == item.rawValue
                Button { select(item.rawValue) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 19, weight: on ? .semibold : .regular))
                            .frame(height: 24)
                            .overlay(alignment: .topTrailing) {
                                if item == .updates && badge > 0 {
                                    Text(badge > 99 ? "99+" : "\(badge)")
                                        .font(.system(size: 10, weight: .bold)).monospacedDigit()
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4)
                                        .frame(minWidth: 16, minHeight: 16)
                                        .background(Color.red, in: Capsule())
                                        .fixedSize()
                                        .offset(x: 11, y: -4)
                                }
                            }
                        Text(item.title)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(on ? Color.white : Color.white.opacity(0.45))
                    .frame(maxWidth: .infinity, minHeight: Self.height - 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityIdentifier("tab-\(item.title)")
                .accessibilityValue(item == .updates && badge > 0 ? "\(badge) new" : "")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.top, 3)
        .frame(height: Self.height)
        .background(.ultraThinMaterial, ignoresSafeAreaEdges: .bottom)
        .overlay(alignment: .top) { Rectangle().fill(Eclipse.hairline).frame(height: 0.5) }
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, favorites, new, reading, downloaded, manga, manhwa, manhua, webtoon, comic, novels, books, files
    var id: String { rawValue }
    /// The kind of content a tab shows (the setup's choices put these tabs first).
    var category: SourceCategory? {
        switch self {
        case .manga: .manga
        case .manhwa: .manhwa
        case .manhua: .manhua
        case .webtoon: .webtoons
        case .comic: .comics
        case .novels: .novels
        default: nil
        }
    }
    var title: String {
        switch self {
        case .all: "All"
        case .favorites: "Favourites"
        case .novels: "Light novels"
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
    @State private var categoryID: String?
    @AppStorage("libraryShowBecause") private var showBecause = false
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var confirmRemove = false
    @State private var newCategoryForSelection = false
    @State private var newCategoryName = ""
    /// Closed with × for this launch (turn it off for good in sort & display options).
    @State private var quoteClosed = false
    /// Normal books are an option (Settings › Library, or the first-launch setup).
    @AppStorage(Features.booksKey) private var booksOn = false
    /// So are novels (redraws the tabs when switched), and the kinds chosen in the setup order the tabs.
    @AppStorage(Features.novelsKey) private var novelsOn = false
    @AppStorage(Interests.categoriesKey) private var categoriesRaw = ""
    @AppStorage("libraryShowDiscover") private var showDiscover = false
    @AppStorage("homeSetupDone") private var setupDone = false
    @State private var settingUp = false
    @State private var showingBookmarks = false
    @State private var bookSearch: QuoteSearch?
    @ObservedObject private var spotlights = SpotlightStore.shared
    struct QuoteSearch: Identifiable {
        let query: String
        var novels = false
        var native: String? = nil
        /// Search one site only (a search source id).
        var site: String? = nil
        var id: String { query + (novels ? "|novels" : "") + (site.map { "|" + $0 } ?? "") }
    }
    /// A search started from a recommendation shelf. Kept here, outside the shelves, so the search
    /// page stays open while the shelves reload around it.
    @State private var shelfSearch: QuoteSearch?
    @Namespace private var zoom
    @FocusState private var searchFocused: Bool

    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .recent }
    private func matches(_ series: MangaSeries, _ filter: LibraryFilter) -> Bool {
        switch filter {
        case .all: true
        case .new: model.newCount(series) > 0
        case .downloaded: model.downloadedCount(series) > 0 || series.kind == .local
        case .reading: model.lastRead(series) != nil && model.readCount(series) < series.chapters.count
        case .favorites: model.isFavorite(series)
        case .manga: !series.readsAsText && model.style(for: series.id) == .manga
        case .manhwa: !series.readsAsText && model.style(for: series.id) == .manhwa
        case .manhua: !series.readsAsText && model.style(for: series.id) == .manhua
        case .webtoon: !series.readsAsText && model.style(for: series.id) == .webtoon
        case .comic: !series.readsAsText && model.style(for: series.id) == .comic
        case .novels: series.isNovel
        case .books: series.isPlainBook
        case .files: series.kind == .local
        }
    }
    private var visible: [MangaSeries] {
        let shelf = categoryID.flatMap { id in model.categories.first { $0.id == id } }.map { Set($0.seriesIDs) }
        let list = model.librarySeries.filter { series in
            (booksOn || !series.isPlainBook) && (Features.novelsOn || !series.isNovel)
                && (query.isEmpty || series.title.localizedCaseInsensitiveContains(query)) && matches(series, filter)
                && (shelf?.contains(series.id) ?? true)
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
        // Content tabs follow the setup: the kinds you chose come first.
        let chosen = Interests.categories
        let content = LibraryFilter.allCases.filter { $0.category != nil }
        let ordered = LibraryFilter.allCases.filter { $0.category == nil && $0 != .books && $0 != .files }
            + content.filter { chosen.contains($0.category!) } + content.filter { !chosen.contains($0.category!) } + [.books, .files]
        return ordered.compactMap { item in
            if item == .books && !booksOn { return nil }
            if item == .novels && !Features.novelsOn { return nil }
            let count = model.librarySeries.filter { matches($0, item) && (booksOn || !$0.isPlainBook) && (Features.novelsOn || !$0.isNovel) }.count
            return item == .all || count > 0 || item == filter ? (item, count) : nil
        }
    }

    /// Follow the reader’s current chapter, including unshelved titles.
    private var recentSeries: MangaSeries? {
        guard let chapter = model.lastChapter, let series = model.series(id: model.seriesID(for: chapter)), (!series.isNovel || novelsOn), (!series.isPlainBook || booksOn),
              !model.isHidden(series) else { return nil }
        if model.state.ignoredRecommendationSeries?.contains(series.id) != true { return series }
        return ([model.berserk] + model.allSeries).filter {
            !model.isHidden($0) && (!$0.isNovel || novelsOn) && (!$0.isPlainBook || booksOn)
                && model.state.ignoredRecommendationSeries?.contains($0.id) != true
        }.compactMap { candidate in model.lastRead(candidate).map { (candidate, $0) } }.max { $0.1 < $1.1 }?.0
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                topBar
                GeometryReader { geometry in
                let contentWidth = min(geometry.size.width, 1280) - 28
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // One card: a line from a top-rated series is the recommendation.
                        if query.isEmpty, showQuote, !quoteClosed, filter == .all, categoryID == nil {
                            if let card = spotlights.current {
                                let spotlight = card.item
                                SpotlightCard(card: card, width: contentWidth, owned: ownedSeries(spotlight) != nil, shuffling: spotlights.loadingManga,
                                              read: { readSpotlight(spotlight) },
                                              next: { Task { await spotlights.nextManga(owned: ownedKeys, model: model) } },
                                              close: { withAnimation(.snappy) { quoteClosed = true } })
                            } else if spotlights.loadingManga {
                                SpotlightPlaceholder(width: contentWidth)
                            }
                        }
                        if query.isEmpty, showContinue, filter == .all, categoryID == nil, let chapter = model.lastChapter {
                            ContinueBar(chapter: chapter, resume: { reader = chapter },
                                        open: { openSeries = model.series(id: model.seriesID(for: chapter)) })
                        }
                        LibraryGrid(series: visible, reader: $reader, openSeries: $openSeries, zoom: zoom, width: contentWidth,
                                    selection: selecting ? $selection : nil, startSelecting: { id in
                                        withAnimation(.snappy) { selecting = true; selection = [id] }
                                    })
                        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button { searchingEverywhere = true } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "globe").foregroundStyle(Eclipse.highlight)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Search every site for “\(query)”").font(.subheadline.weight(.semibold))
                                        Text("Search your enabled sources").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                                }
                                .padding(14).eclipseCard(cornerRadius: 14)
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityIdentifier("searchEverywhere")
                            if booksOn {
                                Button { bookSearch = QuoteSearch(query: query) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "text.book.closed").foregroundStyle(Eclipse.highlight)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Find the book “\(query)”").font(.subheadline.weight(.semibold))
                                            Text("Search all \(BookCatalog.allCases.count) book catalogs").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                                    }
                                    .padding(14).eclipseCard(cornerRadius: 14)
                                }
                                .buttonStyle(PressableStyle())
                            }
                        }
                        if query.isEmpty && filter == .all && categoryID == nil && showDiscover {
                            DiscoverStrip(openSeries: $openSeries, search: $shelfSearch, width: contentWidth)
                        }
                        // Recreate the shelf when the reader switches works, including identically titled adaptations.
                        if query.isEmpty && categoryID == nil && showBecause, let recent = recentSeries,
                           filter == .all || matches(recent, filter) {
                            if recent.readsAsText {
                                TextRecommendationStrip(series: recent, width: contentWidth, openSeries: $openSeries, search: $shelfSearch)
                                    .id(recent.id)
                            } else {
                                DiscoverStrip(openSeries: $openSeries, search: $shelfSearch, width: contentWidth, similarTo: recent.title, seedID: recent.id,
                                              style: model.knownStyle(for: recent.id))
                                    .id(recent.id)
                            }
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
            .overlay(alignment: .bottom) {
                if selecting { selectionBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            .confirmationDialog("Remove \(selection.count) series from the library?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    for series in model.librarySeries where selection.contains(series.id) {
                        model.remove(series)
                    }
                    endSelection()
                }
            } message: { Text("Reading progress and downloads for them are removed too.") }
            .alert("New category", isPresented: $newCategoryForSelection) {
                TextField("Name", text: $newCategoryName)
                Button("Create") {
                    model.addCategory(newCategoryName)
                    if let category = model.categories.last {
                        model.set(model.librarySeries.filter { selection.contains($0.id) }, in: category, true)
                    }
                    newCategoryName = ""
                    endSelection()
                }
                Button("Cancel", role: .cancel) { newCategoryName = "" }
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
            .sheet(item: $bookSearch) { item in BookSearchSheet(query: item.query).environmentObject(model) }
            .sheet(item: $shelfSearch) { item in
                GlobalSearchSheet(query: item.query, novels: item.novels, nativeQuery: item.native, site: item.site).environmentObject(model)
            }
            .task {
                if !setupDone && !ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                    try? await Task.sleep(for: .seconds(0.6))
                    settingUp = true
                }
            }
            .task(id: "\(showQuote)|\(SpotlightStore.settings(for: model))") {
                guard showQuote, !ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
                await spotlights.loadManga(owned: ownedKeys, model: model)
            }
            .sheet(isPresented: $showingBookmarks) {
                BookmarksSheet { chapter in showingBookmarks = false; reader = chapter }.environmentObject(model)
            }
            .sheet(isPresented: $settingUp, onDismiss: { setupDone = true }) {
                HomeSetupSheet().presentationDetents([.medium, .large])
            }
            .navigationDestination(item: $openSeries) { series in
                SeriesView(seriesID: series.id, reader: $reader).zoomDestination(series.id, in: zoom)
            }
            .task {
                if model.state.showsBerserk == true && model.state.chapters.isEmpty && !ProcessInfo.processInfo.arguments.contains("--ui-testing") { await model.refresh() }
                await model.ensureCovers()
                await model.checkForUpdates()
            }
            .onChange(of: model.librarySeries.count) { _, _ in Task { await model.ensureCovers() } }
            .onChange(of: model.requestedSeriesID) { _, id in
                guard let id, let series = model.series(id: id) else { return }
                model.requestedSeriesID = nil
                openSeries = series
            }
            .fullScreenCover(item: $reader) { chapter in ReaderView(chapter: chapter).environmentObject(model) }
        }
    }

    /// The quote's series: straight to it when it's in your library, otherwise every site is searched for it.
    /// Series and books already in the library, the way the launch card recognises them.
    private var ownedKeys: Set<String> { Set(model.libraryMembers.map { QuoteFeed.workKey($0.title) }) }
    private func ownedSeries(_ spotlight: Spotlight) -> MangaSeries? {
        let keys = [spotlight.work, spotlight.quote.work].map(QuoteFeed.workKey)
        return model.librarySeries.first { !$0.isPlainBook && keys.contains(QuoteFeed.workKey($0.title)) }
    }
    /// The launch card's series: open it if it's yours, otherwise search every site for it.
    private func readSpotlight(_ spotlight: Spotlight) {
        if let owned = ownedSeries(spotlight) { openSeries = owned }
        else { openSeries = spotlights.openVerified?() }
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
                        EclipseWordmark(size: 18)
                        EclipseWordmark(size: 15)
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
                        Button { withAnimation(.snappy) { selecting = true; selection = [] } } label: {
                            Label("Select…", systemImage: "checkmark.circle")
                        }
                        Button { showingBookmarks = true } label: {
                            Label("Bookmarks" + ((model.state.bookmarks ?? []).isEmpty ? "" : " (\(model.state.bookmarks?.count ?? 0))"), systemImage: "bookmark")
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
                    ForEach(Array(tabs.prefix(1)), id: \.0) { entry in
                        tabButton(entry.0.title, count: entry.1, selected: categoryID == nil && filter == entry.0) {
                            categoryID = nil; filter = entry.0
                        }
                    }
                    // Your own shelves come right after "All".
                    ForEach(model.categories) { category in
                        tabButton(category.name, count: category.seriesIDs.filter { id in model.librarySeries.contains { $0.id == id } }.count,
                                  selected: categoryID == category.id) {
                            categoryID = category.id; filter = .all
                        }
                    }
                    ForEach(Array(tabs.dropFirst()), id: \.0) { entry in
                        tabButton(entry.0.title, count: entry.1, selected: categoryID == nil && filter == entry.0) {
                            categoryID = nil; filter = entry.0
                        }
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
    private func tabButton(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy) { action() } } label: {
            VStack(spacing: 7) {
                HStack(spacing: 5) {
                    Text(title).font(.subheadline.weight(selected ? .bold : .medium)).lineLimit(1)
                    Text("\(count)").font(.caption2.weight(.bold)).monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background((selected ? Eclipse.accent : Color.white.opacity(0.12)), in: Capsule())
                }
                .foregroundStyle(selected ? Color.white : Color.secondary)
                Capsule().fill(selected ? Eclipse.accent : Color.clear).frame(height: 3)
            }
            .padding(.horizontal, 10).padding(.top, 4)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    /// Bulk actions for the selected series.
    private var selectionBar: some View {
        let chosen = model.librarySeries.filter { selection.contains($0.id) }
        return HStack(spacing: 4) {
            Text("\(selection.count) selected").font(.subheadline.weight(.semibold)).monospacedDigit().padding(.leading, 8)
            Spacer(minLength: 4)
            selectionAction("checkmark.circle", "Mark read") { model.markAllRead(chosen); endSelection() }
            selectionAction("arrow.down.circle", "Download unread") {
                for series in chosen where series.kind == .web {
                    model.download(series.chapters.filter { model.state.progress[$0.id]?.completed != true })
                }
                endSelection()
            }
            Menu {
                ForEach(model.categories) { category in
                    Button(category.name) { model.set(chosen, in: category, true); endSelection() }
                }
                Button { newCategoryForSelection = true } label: { Label("New category…", systemImage: "plus") }
            } label: {
                Image(systemName: "folder.badge.plus").font(.system(size: 18, weight: .semibold)).frame(width: 42, height: 42)
            }.accessibilityLabel("Add to category")
            selectionAction("eye.slash", "Hide") { for series in chosen { model.setHidden(true, series) }; endSelection() }
            selectionAction("trash", "Remove") { confirmRemove = true }
            Button("Done") { endSelection() }.font(.subheadline.weight(.bold)).padding(.horizontal, 8)
        }
        .padding(.horizontal, 8).frame(height: 56)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Eclipse.hairline))
        .padding(.horizontal, 12).padding(.bottom, 8)
        .frame(maxWidth: 640)
    }
    private func selectionAction(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).frame(width: 42, height: 42)
        }
        .disabled(selection.isEmpty)
        .accessibilityLabel(label)
    }
    private func endSelection() {
        withAnimation(.snappy) { selecting = false; selection = [] }
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
    @AppStorage("libraryShowDiscover") private var showDiscover = false
    @AppStorage("libraryShowBecause") private var showBecause = false
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
                    Toggle("Manga quote on launch", isOn: $showQuote)
                    Toggle("Popular on MangaDex", isOn: $showDiscover)
                    Toggle("Because you read…", isOn: $showBecause)
                }
            }
            .scrollContentBackground(.hidden).background(Eclipse.surface)
            .navigationTitle("Library").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() }.fontWeight(.semibold) }
        }.preferredColorScheme(.dark)
    }
}

/// "Find something new" under a small library: popular MangaDex titles, one tap to add.
/// With `similarTo`, it is "Because you read …" for the series you read last, in that series' medium.
struct DiscoverStrip: View {
    @EnvironmentObject private var model: LibraryModel
    @Binding var openSeries: MangaSeries?
    /// Searches are shown by the library, so they stay open while this shelf reloads.
    @Binding var search: LibraryView.QuoteSearch?
    var width: CGFloat = 390
    /// nil: popular on MangaDex. A title: "Because you read …" that series.
    var similarTo: String? = nil
    var seedID: String? = nil
    /// The medium of the series you read (manga, manhwa, manhua, webtoon, comic); recommendations stay in it.
    var style: ReadingStyle? = nil
    private enum Phase: Equatable { case loading, loaded, failed }
    @State private var items: [DiscoverItem] = []
    @State private var phase: Phase = .loading
    @State private var adding: String?
    @State private var error: String?
    /// Results per seed for this launch, so coming back to the library shows them at once
    /// instead of the shelf vanishing while it reloads.
    @MainActor private static var memory: [String: [DiscoverItem]] = [:]
    private var memoryKey: String { "\(seedID ?? similarTo ?? "popular")|\(style?.rawValue ?? "")" }
    var body: some View {
        let cardWidth = Eclipse.cardWidth(available: width)
        let shown = items.filter { item in (similarTo == nil || model.state.hiddenRecommendationTitles?.contains(QuoteFeed.workKey(item.title)) != true) && !model.ownsWork(title: item.title, url: item.url) }
        VStack(alignment: .leading, spacing: 10) {
            if similarTo != nil || !items.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    if let similarTo {
                        // Two lines, so narrow screens (the Duo's front screen) show the whole title.
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("BECAUSE YOU READ").font(.caption.weight(.heavy)).tracking(1).foregroundStyle(.secondary)
                                if let style, style != .automatic {
                                    Text(style.title).font(.caption2.weight(.heavy)).foregroundStyle(.secondary)
                                        .padding(.horizontal, 6).padding(.vertical, 2).background(Eclipse.surfaceHigh, in: Capsule())
                                }
                            }
                            Text(similarTo).font(.title3.weight(.bold)).lineLimit(2)
                        }
                        .contextMenu { if let seedID { Button("Ignore this series for recommendations") { model.ignoreRecommendationSeed(seedID) } } }
                    } else {
                        Text("Discover").font(.title3.weight(.bold))
                        Text("Popular on MangaDex").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if !shown.isEmpty {
                    FadingRow {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(shown) { item in card(item, width: cardWidth) }
                        }
                    }
                } else if phase == .loading {
                    FadingRow {
                        HStack(spacing: 12) {
                            // Loading: the same shape as a real card (cover, title, year), gently shimmering.
                            ForEach(0..<4, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 7) {
                                    RoundedRectangle(cornerRadius: Eclipse.cardRadius).fill(Eclipse.surfaceHigh)
                                        .overlay(EclipseMark(size: 26).opacity(0.25))
                                        .frame(width: cardWidth, height: cardWidth / 0.7)
                                    Capsule().fill(Eclipse.surfaceHigh).frame(width: cardWidth * 0.85, height: 10)
                                    Capsule().fill(Eclipse.surfaceHigh.opacity(0.7)).frame(width: cardWidth * 0.45, height: 8)
                                }
                                .overlay(ShimmerView())
                            }
                        }
                    }.disabled(true)
                } else if similarTo != nil {
                    HStack(spacing: 10) {
                        Text(phase == .failed ? "Couldn’t reach the recommendation services." : "Nothing close to this one yet.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button("Retry") { Task { await load(force: true) } }.font(.footnote.weight(.semibold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11).eclipseCard(cornerRadius: 12)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            }
        }
        .padding(.top, 8)
        .task(id: memoryKey) {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
            #endif
            await load(force: false)
        }
    }
    private func card(_ item: DiscoverItem, width cardWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { select(item, add: false) } label: {
                CoverView(url: item.cover, referer: nil, title: item.title)
                    .aspectRatio(0.7, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        if adding == item.id {
                            ZStack { Color.black.opacity(0.5); ProgressView().tint(.white) }
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
            }.buttonStyle(PressableStyle())
            .overlay(alignment: .bottomTrailing) {
                if !Self.isAniList(item) {
                    Button { select(item, add: true) } label: {
                        Image(systemName: "plus").font(.caption.weight(.heavy)).foregroundStyle(.black)
                            .frame(width: 24, height: 24).background(Eclipse.highlight, in: Circle()).padding(6)
                    }.buttonStyle(.plain).accessibilityLabel("Add to Library")
                }
            }
            Button { select(item, add: false) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    if let detail = item.detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
                }
            }.buttonStyle(PressableStyle())
        }
        .frame(width: cardWidth)
        .contextMenu {
            if !Self.isAniList(item) {
                Button { select(item, add: false) } label: { Label("Preview", systemImage: "book") }
                Button { select(item, add: true) } label: { Label("Add to Library", systemImage: "plus") }
            }
            FindOnSitesMenu(sources: GlobalSearchModel.sources(saved: model.sources)) { site in
                find(item.title, site: site)
            }
            if similarTo != nil {
                Button { model.hideSuggestion(item.title) } label: { Label("Less like this", systemImage: "hand.thumbsdown") }
            }
        }
        .disabled(adding != nil)
    }
    /// Recommendations kept between launches, so the shelf shows at once when the app opens.
    private struct Saved: Codable {
        struct Item: Codable { var id: String; var title: String; var url: URL; var cover: URL?; var detail: String? }
        var date: Date
        var items: [Item]
    }
    private static let savedKey = "becauseYouReadShelves"
    private static func saved(_ key: String) -> Saved? {
        guard let data = UserDefaults.standard.data(forKey: savedKey),
              let all = try? JSONDecoder().decode([String: Saved].self, from: data) else { return nil }
        return all[key]
    }
    private static func save(_ items: [DiscoverItem], for key: String) {
        var all = (UserDefaults.standard.data(forKey: savedKey)).flatMap { try? JSONDecoder().decode([String: Saved].self, from: $0) } ?? [:]
        all[key] = Saved(date: Date(), items: items.map { .init(id: $0.id, title: $0.title, url: $0.url, cover: $0.cover, detail: $0.detail) })
        // Only the most recent few series are kept.
        if all.count > 8, let oldest = all.min(by: { $0.value.date < $1.value.date })?.key { all[oldest] = nil }
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: savedKey) }
    }
    private func load(force: Bool) async {
        let key = memoryKey
        if !force, let cached = Self.memory[key] { items = cached; phase = .loaded; return }
        // From the last launch: show it at once, and refresh it quietly when it's more than six hours old.
        var refreshingSaved = false
        if !force, similarTo != nil, let saved = Self.saved(key), Date().timeIntervalSince(saved.date) < 24 * 3600 {
            items = saved.items.map { DiscoverItem(id: $0.id, title: $0.title, url: $0.url, cover: $0.cover, detail: $0.detail) }
            phase = .loaded
            Self.memory[key] = items
            guard Date().timeIntervalSince(saved.date) > 6 * 3600 else { return }
            refreshingSaved = true
        }
        guard let similarTo else {
            if items.isEmpty { items = (try? await Discover.mangaDex(limit: 24)) ?? [] }
            phase = .loaded
            return
        }
        if !refreshingSaved { phase = .loading }
        let skip = Set(model.librarySeries.map(\.title))
        var reached = false
        var found: [DiscoverItem] = []
        // A busy MangaDex (rate limit, slow network) used to empty the shelf until a manual refresh.
        for delay in [0, 2, 5] {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            do {
                found = try await Discover.similar(to: similarTo, excluding: skip, style: style, verify: false)
                reached = true
                break
            } catch {}
        }
        // Not on MangaDex (or nothing there in this medium): AniList readers' recommendations, same medium.
        if found.isEmpty, let fallback = await aniList(similarTo, skip: skip) {
            reached = true
            found = fallback
        }
        guard !Task.isCancelled else { return }
        if refreshingSaved && !reached { return } // keep showing last launch's shelf
        // Show the matches now; then drop titles MangaDex can't actually show (licensed series that
        // only link out to the publisher) as those checks finish, instead of waiting for all of them.
        items = Array(found.prefix(16))
        phase = reached ? .loaded : .failed
        guard reached else { return }
        if found.contains(where: { !Self.isAniList($0) }) {
            let checked = await Discover.readable(found)
            guard !Task.isCancelled else { return }
            found = Array(checked.prefix(16))
            items = found
        }
        Self.memory[key] = found
        Self.save(found, for: key)
    }
    private func aniList(_ title: String, skip: Set<String>) async -> [DiscoverItem]? {
        let medium = style ?? .automatic
        guard medium != .comic else { return nil }
        // The library title can be worded differently from AniList's: try shorter forms too.
        var parsed: (matched: String?, items: [AniListMedia])?
        for query in Discover.lookupQueries(title) {
            if let data = try? await AniList.post(AniListAPI.similarQuery, variables: ["search": query], auth: false),
               let found = try? AniListAPI.parseSimilar(data), !found.items.isEmpty {
                parsed = found
                break
            }
        }
        guard let parsed else { return nil }
        let seedKey = Discover.franchiseKey(title)
        let kind: String? = switch medium {
        case .manga: "Manga"
        case .manhwa, .webtoon: "Manhwa"
        case .manhua: "Manhua"
        case .comic, .automatic: nil
        }
        let items = parsed.items
            .filter { item in item.format != "NOVEL" && (kind == nil || item.kind == kind) && !skip.contains { Discover.titleMatches($0, item.title) }
                && Discover.franchiseKey(item.title) != seedKey }
            .compactMap { item -> DiscoverItem? in
                URL(string: "https://anilist.co/manga/\(item.id)").map {
                    DiscoverItem(id: "anilist-\(item.id)", title: item.title, url: $0, cover: item.cover,
                                 detail: [item.kind, item.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                }
            }
        return Array(Discover.onePerFranchise(items).prefix(16))
    }
    private static func isAniList(_ item: DiscoverItem) -> Bool { item.url.host == "anilist.co" }
    /// Opens the search once the long-press menu has closed (opening it while the menu is still
    /// animating away could drop it).
    private func find(_ title: String, site: String?) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            search = LibraryView.QuoteSearch(query: title, site: site)
        }
    }
    private func select(_ item: DiscoverItem, add: Bool) {
        // AniList knows the work but not where to read it: find it on your sources.
        if Self.isAniList(item) { search = LibraryView.QuoteSearch(query: item.title); return }
        adding = item.id; error = nil
        Task {
            defer { adding = nil }
            do {
                if case .series(let series, _) = try await model.addLink(item.url.absoluteString, title: item.title, addToShelf: add), !add { openSeries = series }
            } catch { self.error = "Couldn’t load \(item.title)." }
        }
    }
}

private struct TextRecommendationStrip: View {
    @EnvironmentObject private var model: LibraryModel
    let series: MangaSeries
    let width: CGFloat
    @Binding var openSeries: MangaSeries?
    @Binding var search: LibraryView.QuoteSearch?
    @State private var novels: [AniListMedia] = []
    @State private var books: [FreeBook] = []

    var body: some View {
        let owned = Set((model.libraryMembers.map(\.title) + [series.title]).map(QuoteFeed.workKey)).union(model.state.hiddenRecommendationTitles ?? [])
        let suggestions = novels.filter { !owned.contains(QuoteFeed.workKey($0.title)) }
        let classics = books.filter { !owned.contains(QuoteFeed.workKey($0.title)) }
        VStack(alignment: .leading, spacing: 0) {
            if !suggestions.isEmpty || !classics.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("BECAUSE YOU READ").font(.caption.weight(.heavy)).tracking(1).foregroundStyle(.secondary)
                        Text(series.title).font(.title3.weight(.bold)).lineLimit(2)
                    }
                    .contextMenu { Button("Ignore this series for recommendations") { model.ignoreRecommendationSeed(series.id) } }
                    FadingRow {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(suggestions) { item in
                                card(item.title, cover: item.cover, detail: "Novel") {
                                    search = LibraryView.QuoteSearch(query: item.title, novels: true, native: item.nativeTitle)
                                }
                            }
                            ForEach(classics) { book in
                                card(book.title, cover: book.cover, detail: book.author ?? book.source) {
                                    if let page = book.page, let download = book.download {
                                        openSeries = model.previewBook(book, page: page, download: download)
                                    }
                                }
                            }
                        }
                    }
                }.padding(.top, 8)
            }
        }
        .task(id: series.title) {
            if series.isNovel {
                guard let data = try? await AniList.post(AniListAPI.similarNovelsQuery, variables: ["search": series.title], auth: false),
                      !Task.isCancelled else { return }
                novels = (try? AniListAPI.novelRecommendations(data, for: series.title)) ?? []
            } else if let author = series.author, !author.isEmpty {
                let results = (try? await FreeBooks.standardEbooks(query: author)) ?? []
                guard !Task.isCancelled else { return }
                books = results.filter { $0.author == author && $0.page != nil && $0.download != nil }
            }
        }
    }

    private func card(_ title: String, cover: URL?, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                CoverView(url: cover, referer: nil).aspectRatio(0.7, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(title).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }.frame(width: Eclipse.cardWidth(available: width))
        }.buttonStyle(PressableStyle()).contextMenu { Button("Less like this") { model.hideSuggestion(title) } }
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
                            if let series, series.kind == .book {
                                // A book: how far through it you are, not a page count within one part.
                                let parts = max(1, series.chapters.count)
                                let index = series.chapters.firstIndex { $0.id == chapter.id } ?? 0
                                let within = progress.map { Double($0.page + 1) / Double(max(1, $0.pageCount)) } ?? 0
                                Text("\(min(100, Int((Double(index) + within) / Double(parts) * 100)))% read").monospacedDigit()
                            } else {
                                Text(ChapterText.split(chapter.title).name).lineLimit(1)
                                if let progress { Text("· \(progress.page + 1)/\(progress.pageCount)").monospacedDigit() }
                            }
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
    /// Picking several covers for bulk actions (nil when not selecting).
    var selection: Binding<Set<String>>? = nil
    var startSelecting: ((String) -> Void)? = nil
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
                Button {
                    if let selection {
                        if selection.wrappedValue.contains(item.id) { selection.wrappedValue.remove(item.id) } else { selection.wrappedValue.insert(item.id) }
                    } else {
                        openSeries = item
                    }
                } label: {
                    SeriesCard(series: item, width: cardWidth).zoomSource(item.id, in: zoom)
                        .overlay(alignment: .center) {
                            if let selection {
                                let on = selection.wrappedValue.contains(item.id)
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(on ? 0.35 : 0.15))
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 30, weight: .semibold))
                                        .foregroundStyle(on ? Eclipse.highlight : Color.white.opacity(0.85))
                                        .shadow(radius: 4)
                                }
                                .allowsHitTesting(false)
                            }
                        }
                }
                    .buttonStyle(PressableStyle())
                    .accessibilityIdentifier(item.id == LibraryModel.berserkID ? "chapterBrowser" : "series-\(item.title)")
                    .contextMenu {
                        if let chapter = model.resume(item) {
                            Button { reader = chapter } label: { Label("Continue \(ChapterText.split(chapter.title).name)", systemImage: "book") }
                        }
                        Button { coverFor = item } label: { Label("Change cover…", systemImage: "photo") }
                        if let startSelecting {
                            Button { startSelecting(item.id) } label: { Label("Select", systemImage: "checkmark.circle") }
                        }
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
                        Button(role: .destructive) { model.remove(item) } label: { Label("Remove from library", systemImage: "trash") }
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
                    NavigationLink { GuideView() } label: {
                        SettingsRow(title: "Guide", detail: "What every button and setting does", symbol: "questionmark.circle.fill", tint: .pink)
                    }
                }
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
                    NavigationLink { TrackingSettingsPage() } label: {
                        SettingsRow(title: "Tracking", detail: model.state.aniListUser.map { "AniList · \($0)" } ?? "Sync progress to AniList",
                                    symbol: "arrow.triangle.2.circlepath.circle.fill", tint: .cyan)
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
                LabeledSlider(title: "Warm night filter", symbol: "flame", value: $warmth, range: 0...0.6)
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

/// Create, rename, reorder and delete library categories.
struct CategoriesPage: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var adding = false
    @State private var name = ""
    @State private var renaming: LibraryCategory?
    var body: some View {
        List {
            if model.categories.isEmpty {
                Text("No categories yet. Make shelves like Reading, Plan to read or Favourites.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.categories) { category in
                Button {
                    name = category.name; renaming = category
                } label: {
                    HStack {
                        Label(category.name, systemImage: "folder")
                        Spacer()
                        Text("\(category.seriesIDs.count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
                .swipeActions {
                    Button("Delete", role: .destructive) { model.removeCategory(category) }
                }
            }
            .onMove { model.moveCategories(from: $0, to: $1) }
            .onDelete { offsets in offsets.map { model.categories[$0] }.forEach(model.removeCategory) }
        }
        .navigationTitle("Categories")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { name = ""; adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("New category")
            }
            if !model.categories.isEmpty { ToolbarItem(placement: .topBarLeading) { EditButton() } }
        }
        .alert("New category", isPresented: $adding) {
            TextField("Name", text: $name)
            Button("Create") { model.addCategory(name) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename category", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $name)
            Button("Save") { if let renaming { model.renameCategory(renaming, to: name) } }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct LibrarySettingsPage: View {
    @EnvironmentObject private var model: LibraryModel
    @AppStorage("libraryDensity") private var density = LibraryDensity.comfortable.rawValue
    @AppStorage("libraryShowContinue") private var showContinue = true
    @AppStorage("libraryShowQuote") private var showQuote = true
    @AppStorage("libraryShowDiscover") private var showDiscover = false
    @AppStorage("libraryShowBecause") private var showBecause = false
    @AppStorage("homeSetupDone") private var setupDone = false
    @AppStorage(Features.booksKey) private var booksOn = false
    @AppStorage(Features.novelsKey) private var novelsOn = false
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
                Toggle(isOn: $showQuote) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Manga quote on launch")
                        Text("A line from a top-rated manga (live from AnimeChan and Yurippe, checked on AniList), with a button to read it")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Popular on MangaDex", isOn: $showDiscover)
                Toggle("“Because you read…” recommendations", isOn: $showBecause)
                Button("Reset recommendation feedback") { model.state.hiddenRecommendationTitles = nil; model.state.ignoredRecommendationSeries = nil; model.save() }
                Button("Show the home setup again") { setupDone = false }
            }
            Section {
                Toggle(isOn: $novelsOn) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Light novels & web novels")
                        Text("Read novels from Syosetu, Kakuyomu, Wuxiaworld and any novel site, set like a printed book, with on-device translation for raws. Adds a Light novels tab and novel sources in Browse.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $booksOn) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Books too")
                        Text("Read normal books (EPUB, Kindle, FB2, TXT and more), set like a printed book. Adds a Books tab and free classics in Browse.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Reading beyond comics") } footer: {
                Text("eclipsereader is a manga, manhwa, manhua, webtoon and comics reader first; these add text reading on top.")
            }
            Section {
                NavigationLink { CategoriesPage() } label: {
                    LabeledContent("Categories", value: model.categories.isEmpty ? "None" : "\(model.categories.count)")
                }
            } footer: {
                Text("Your own shelves, shown as tabs in the library. Long-press a cover, or choose Select… in the library menu, to file series.")
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
    @State private var offlineDetails: MangaSeries?
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
                                if case .failed = state {
                                    Button("Resume") { model.download([chapter]) }.buttonStyle(.borderless)
                                }
                                Button { model.cancelDownload(chapter) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                    .buttonStyle(.borderless).accessibilityLabel("Cancel download")
                            }
                        }
                    }
                }
            }
            let offline = (model.librarySeries + model.allSeries.filter { !$0.isLibraryMember }).filter { model.downloadedCount($0) > 0 || (!$0.isLibraryMember && !$0.isOnline && !$0.isCatalogBookPreview) }
            if !offline.isEmpty {
                Section("On this device") {
                    ForEach(offline) { series in
                        HStack(spacing: 12) {
                            CoverView(url: model.cover(for: series), referer: series.chapters.first)
                                .frame(width: 34, height: 48).clipShape(RoundedRectangle(cornerRadius: 5))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(series.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(series.isOnline ? "\(model.downloadedCount(series)) chapter\(model.downloadedCount(series) == 1 ? "" : "s")" : "Downloaded file")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { offlineDetails = series }
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
        .sheet(item: $offlineDetails) { SeriesSheet(series: $0).environmentObject(model) }
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
    @AppStorage("readerPositionSync") private var syncPositions = false
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
                    Toggle("Sync reading positions in this folder", isOn: $syncPositions)
                        .onChange(of: syncPositions) { _, on in if on { Task { await model.syncPositions() } } }
                    if syncPositions { Text("Choose the same shared folder on each device. Positions update when you leave or reopen the app.").font(.footnote) }
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
        // The commit a build came from (set by CI), so each installed build can be told apart.
        let commit = (Bundle.main.object(forInfoDictionaryKey: "EclipseCommit") as? String).flatMap { $0.isEmpty ? nil : $0 }
        return "\(short) (\(build)\(commit.map { " · \($0)" } ?? ""))"
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
            CrashReportsSection()
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
            Toggle(isOn: Binding(get: { preferences.splitSpreads ?? false }, set: { preferences.splitSpreads = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Split double pages in portrait")
                    Text("A two-page spread shows as two pages, in reading order").font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(get: { preferences.guided ?? false }, set: { preferences.guided = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Guided view")
                    Text("Tapping the page edge moves panel by panel, then turns the page").font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(get: { preferences.trimMargins ?? true }, set: { preferences.trimMargins = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trim blank scan borders")
                    Text("Removes plain white or black borders around scanned pages so the art fills the screen. Clean digital pages are left as they are.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(get: { preferences.enhance ?? true }, set: { preferences.enhance = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enhance scanned pages")
                    Text("Whiter paper, solid ink and crisp lettering; small pages are upscaled to your screen").font(.caption).foregroundStyle(.secondary)
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
                        } else if series.readsAsText {
                            Text(series.isNovel ? "NOVEL" : "BOOK").font(.system(size: 8.5 * k, weight: .heavy)).tracking(0.6)
                                .padding(.horizontal, 5 * k).padding(.vertical, 3 * k)
                        } else {
                            Image(systemName: "internaldrive.fill").font(.system(size: 9 * k, weight: .bold))
                                .padding(4 * k)
                        }
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(6 * k)
                    .accessibilityLabel(style?.title ?? (series.isNovel ? "Novel" : series.kind == .book ? "Book" : "On this device"))
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
    /// When given, a missing or broken cover shows a designed title card instead of the empty mark.
    var title: String? = nil
    @State private var image: UIImage?
    @MainActor private static let cache = NSCache<NSURL, UIImage>()
    /// Covers that just failed are not retried for a few minutes, so scrolling back doesn't spin again.
    @MainActor private static var recentFailures: [URL: Date] = [:]
    /// A cover that hasn't arrived by then is treated as missing; slow sites can't spin forever.
    private static let timeout: Duration = .seconds(10)
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
                    if let title, !title.isEmpty {
                        TitleCover(title: title)
                    } else {
                        EclipseMark(size: 30).opacity(0.55)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
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
            if let when = Self.recentFailures[url], Date().timeIntervalSince(when) < 300 { failed = true; return }
            let chapter = referer ?? Chapter(url: url, title: "", number: "")
            let pipeline = model.pipeline, timeout = Self.timeout
            // nil means it timed out; .some(nil) means the site really failed.
            let fetched: Data?? = await withTaskGroup(of: Data??.self) { group in
                group.addTask { .some(try? await pipeline.data(for: MangaPage(url: url, label: "Cover"), chapter: chapter)) }
                group.addTask { try? await Task.sleep(for: timeout); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard !Task.isCancelled else { return }
            guard let result = fetched else {
                // Slow, not broken: show the title card now; a later appearance tries again.
                failed = true
                return
            }
            guard let data = result else {
                Self.recentFailures[url] = Date(); failed = true; onFail?()
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
            guard !Task.isCancelled else { return }
            if let thumb { Self.cache.setObject(thumb.image, forKey: url as NSURL); image = thumb.image }
            else { Self.recentFailures[url] = Date(); failed = true; onFail?() }
        }
    }
}

private struct CoverThumb: @unchecked Sendable { let image: UIImage }

/// A designed cover for works whose site publishes no artwork (most web novels) or whose cover
/// failed: the title set in type on a tint chosen from the title, so each work looks distinct.
struct TitleCover: View {
    let title: String
    var body: some View {
        let hue = Double(UInt(bitPattern: title.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }) % 360) / 360
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.42),
                                    Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.16)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 10)
                .frame(width: 120, height: 120).offset(x: 40, y: -90)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            VStack(alignment: .leading, spacing: 6) {
                Rectangle().fill(Eclipse.highlight.opacity(0.85)).frame(width: 22, height: 2)
                Text(title)
                    .font(.system(.subheadline, design: .serif).weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(5).minimumScaleFactor(0.6)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
        }
        .accessibilityHidden(true)
    }
}

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
    @State private var similar = false
    @State private var migrating = false
    @State private var tracking = false
    /// The chapter list has been fetched at least once since this page opened (or earlier this session).
    @State private var checked = false
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
                    SeriesHeader(series: series, reader: $reader, website: $website, checking: series.isOnline && !checked, downloading: updating, downloadBook: {
                        if let url = series.bookDownloadURL { downloadBook(url) }
                    })
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                    // A catalog book joins the Library when it downloads, so it doesn't get its own
                    // Add button here (saving it without the file is in the … menu).
                    if (!builtIn || !series.isLibraryMember) && !series.isCatalogBookPreview {
                        Button { model.addToLibrary(series) } label: {
                            Label(series.isLibraryMember ? "In Library" : "Add to Library",
                                  systemImage: series.isLibraryMember ? "checkmark.circle" : "plus.circle")
                        }
                        .disabled(series.isLibraryMember)
                    }
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
                        if series.isCatalogBookPreview {
                            // The Download button is in the header just above.
                            Text(updating ? "Downloading… the contents appear here when it's done."
                                          : "The contents appear here once the book is downloaded.")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .listRowBackground(Color.clear)
                        } else if builtIn || (series.isOnline && (!checked || updating)) {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(builtIn && !model.loading ? "No chapters yet. Pull to refresh." : "Loading chapters…").foregroundStyle(.secondary)
                            }
                        } else {
                            NoChaptersCard(series: series) { migrating = true }
                                .listRowBackground(Color.clear)
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
                        Text(series.kind == .book ? "Contents" : "\(series.chapters.count) chapter\(series.chapters.count == 1 ? "" : "s")")
                            .font(.headline).foregroundStyle(.primary).textCase(nil)
                        Spacer()
                        if !series.chapters.isEmpty {
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
                if let notice = model.notice, notice.seriesID == seriesID { message = notice.text; model.notice = nil }
                if builtIn && series.chapters.isEmpty { await model.refresh() }
                // Fresh chapter list the first time a website series is opened each session.
                if series.isOnline && !builtIn && model.sessionRefreshed.insert(series.id).inserted {
                    try? await model.update(series)
                }
                checked = true
            }
            .toolbar {
                ToolbarItem(placement: .principal) { Text("") }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if series.isCatalogBookPreview && !series.isLibraryMember {
                            Button { model.addToLibrary(series) } label: {
                                Label("Save to Library without downloading", systemImage: "plus.circle")
                            }
                        }
                        if !series.chapters.isEmpty {
                        Button { Task { await update(series) } } label: { Label("Check for new chapters", systemImage: "arrow.clockwise") }
                        if model.newCount(series) > 0 {
                            Button { model.clearNew(series) } label: { Label("Mark new chapters as seen", systemImage: "sparkles") }
                        }
                        Button {
                            for chapter in series.chapters where model.state.progress[chapter.id]?.completed != true {
                                model.record(chapter, page: 0, count: 1, completed: true)
                            }
                        } label: { Label("Mark all as read", systemImage: "checkmark.circle") }
                        }
                        // Downloading is the header's download button; only removing them lives here.
                        if series.isOnline && model.downloadedCount(series) > 0 {
                            Section("Offline") {
                                Button(role: .destructive) {
                                    for chapter in series.chapters where model.isDownloaded(chapter) { model.removeDownload(chapter) }
                                } label: { Label("Remove downloads", systemImage: "trash") }
                            }
                        }
                        Section {
                            Button { pickingCover = true } label: { Label("Change cover…", systemImage: "photo") }
                            Button { model.toggleFavorite(series) } label: {
                                Label(model.isFavorite(series) ? "Remove from favourites" : "Add to favourites", systemImage: model.isFavorite(series) ? "star.slash" : "star")
                            }
                            if series.isOnline {
                                Button { website = true } label: { Label("Open website", systemImage: "safari") }
                                ShareLink(item: series.url) { Label("Share link", systemImage: "square.and.arrow.up") }
                            }
                            if series.kind != .book || series.isNovel {
                                Button { similar = true } label: { Label("Similar series…", systemImage: "sparkles.rectangle.stack") }
                            }
                            if series.kind == .book && Features.novelsOn {
                                Button { model.setLightNovel(!(series.lightNovel ?? false), series) } label: {
                                    Label(series.lightNovel == true ? "Shelve with books" : "Shelve with light novels", systemImage: "books.vertical")
                                }
                            }
                            if series.kind == .web && !builtIn {
                                if let merged = series.merged {
                                    Button { model.stopMerging(series); message = "Stopped filling in chapters from \(merged.host ?? "the other site")." } label: {
                                        Label("Stop filling from \(merged.host?.replacingOccurrences(of: "www.", with: "") ?? "other site")", systemImage: "square.stack.3d.down.forward")
                                    }
                                } else {
                                    Button { fillMissing(series) } label: { Label("Fill missing chapters…", systemImage: "square.stack.3d.up.badge.automatic") }
                                }
                                Button { migrating = true } label: { Label("Migrate to another site…", systemImage: "arrow.triangle.swap") }
                            }
                            if series.kind != .book {
                                Button { tracking = true } label: {
                                    Label(AniList.linkedID(series, model: model) == nil ? "Track on AniList…" : "AniList tracking…",
                                          systemImage: "arrow.triangle.2.circlepath")
                                }
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
            .sheet(isPresented: $tracking) { AniListLinkSheet(series: series).environmentObject(model) }
            .sheet(isPresented: $similar) { SimilarSheet(title: series.title).environmentObject(model) }
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
    /// Neko-style merge: the same series on another site fills in the chapters this one lacks.
    private func downloadBook(_ url: URL) {
        guard !updating else { return }
        updating = true
        Task {
            defer { updating = false }
            do { _ = try await model.downloadBook(url) }
            catch { message = error.localizedDescription }
        }
    }
    private func fillMissing(_ series: MangaSeries) {
        updating = true
        message = "Looking for the missing chapters on other sites…"
        Task {
            defer { updating = false }
            if let result = await model.fillMissing(series) {
                message = result.count > 0
                    ? "Added \(result.count) missing chapter\(result.count == 1 ? "" : "s") from \(result.host). New ones are filled in on every update."
                    : "\(result.host) has nothing this site is missing right now. It's checked again on every update."
            } else {
                message = "No other site has chapters this one is missing."
            }
        }
    }
    private func update(_ series: MangaSeries) async {
        guard !updating else { return }
        updating = true; defer { updating = false }
        let before = series.chapters.count
        do {
            try await model.update(series)
            let after = model.series(id: series.id)?.chapters.count ?? before
            // An empty list explains itself below; "No new chapters" would only confuse.
            message = after > before ? "\(after - before) new chapter\(after - before == 1 ? "" : "s")" : after == 0 ? nil : "No new chapters."
        } catch {
            message = error.localizedDescription + (series.kind == .web ? " If the site moved or closed, use ⋯ › Migrate." : "")
        }
    }
}

/// A series with no chapters to read where it was added from: says why, and finds it elsewhere.
struct NoChaptersCard: View {
    let series: MangaSeries
    let findElsewhere: () -> Void
    var body: some View {
        let host = series.url.host?.replacingOccurrences(of: "www.", with: "") ?? "this site"
        VStack(alignment: .leading, spacing: 10) {
            Label("Nothing to read on \(host)", systemImage: "books.vertical").font(.headline)
            Text(host.hasSuffix("mangadex.org")
                 ? "MangaDex doesn’t host English chapters of this series (it’s licensed, so MangaDex only links to the official app)."
                 : "\(host) isn’t listing any chapters for this series right now.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(action: findElsewhere) {
                Label("Find it on another site", systemImage: "arrow.triangle.swap")
                    .font(.subheadline.weight(.bold)).frame(maxWidth: .infinity).frame(height: 44)
                    .background(Eclipse.highlight, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.black)
            }
            .buttonStyle(PressableStyle())
            Text("Your place carries over to the site you pick.").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(16).eclipseCard(cornerRadius: 16)
        .padding(.vertical, 6)
    }
}

/// Cover over a blurred copy of itself, title and facts, then the main "Continue" action.
struct SeriesHeader: View {
    @EnvironmentObject private var model: LibraryModel
    let series: MangaSeries
    @Binding var reader: Chapter?
    @Binding var website: Bool
    /// The chapter list is still being fetched.
    var checking = false
    let downloading: Bool
    let downloadBook: () -> Void
    /// Colour from the cover; the page glows with it.
    @State private var tint: Color = Eclipse.accent
    /// Pale cover colours (cream, sand, pastel) need dark lettering on the button.
    @State private var lightTint = false
    var body: some View {
        let builtIn = series.id == LibraryModel.berserkID
        let cover = model.cover(for: series)
        let read = model.readCount(series)
        let style = model.style(for: series.id)
        let resume = model.resume(series)
        let started = resume.map { model.state.progress[$0.id] != nil } ?? false
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom, spacing: 16) {
                // A fixed size: a long title must not squash the cover.
                CoverView(url: cover, referer: series.chapters.first)
                    .frame(width: 116, height: 166)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08)))
                    .shadow(color: .black.opacity(0.6), radius: 16, y: 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text(series.title).font(.title2.weight(.heavy)).lineLimit(4).minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(builtIn ? "Built in" : series.kind == .book ? (series.author ?? "Book")
                          : series.isOnline ? ([series.author, series.url.host?.replacingOccurrences(of: "www.", with: "")].compactMap { $0 }.joined(separator: " · "))
                          : "On this device",
                          systemImage: series.kind == .local ? "internaldrive" : series.kind == .book ? "person" : "globe")
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 6) {
                        if series.isNovel { chip(series.kind == .book ? "Light novel" : "Novel", symbol: "text.book.closed") }
                        else if series.kind == .book { chip("Book", symbol: "text.book.closed") }
                        else { chip(style.title, symbol: style.symbol) }
                        if model.downloadedCount(series) > 0 { chip("\(model.downloadedCount(series))", symbol: "arrow.down.circle.fill") }
                    }
                    Text(series.chapters.isEmpty ? (series.isCatalogBookPreview ? "Must download to read" : checking ? "Loading chapters…" : "No chapters to read")
                         : series.kind == .book ? (read == 0 ? "Not started" : read >= series.chapters.count ? "Finished" : "\(Int(Double(read) / Double(series.chapters.count) * 100))% read")
                         : "\(read) of \(series.chapters.count) read")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let summary = series.summary, !summary.isEmpty { SynopsisText(text: BookText.richText(summary)) }
            HStack(spacing: 10) {
                Button {
                    if series.isCatalogBookPreview { downloadBook() }
                    else if let resume { reader = resume }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: series.isCatalogBookPreview ? "arrow.down.circle" : "play.fill")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(series.isCatalogBookPreview ? (downloading ? "Downloading…" : "Download book") : resume == nil ? "No chapters yet" : started ? "Continue" : "Start reading").font(.headline)
                            if let resume {
                                Text(ChapterText.split(resume.title).name).font(.caption).opacity(0.8).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18).frame(height: 54)
                    .foregroundStyle(lightTint ? Color.black : Color.white)
                    .background(LinearGradient(colors: [tint, tint.opacity(lightTint ? 0.85 : 0.7)], startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(lightTint ? 0 : 0.18)))
                    .shadow(color: tint.opacity(0.45), radius: 14, y: 6)
                }
                .buttonStyle(PressableStyle()).disabled(series.isCatalogBookPreview ? downloading : resume == nil)
                .accessibilityIdentifier("seriesContinue")
                if series.kind != .book {
                    Menu {
                        Picker("Reads as", selection: Binding(get: { model.styleOverride(series.id) }, set: { model.setStyle($0, for: series.id) })) {
                            ForEach(ReadingStyle.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                        }
                        if !series.readsAsText {
                            Picker("Enhance scans", selection: Binding(get: { model.state.seriesEnhance?[series.id] }, set: { value in
                                var map = model.state.seriesEnhance ?? [:]
                                map[series.id] = value
                                model.state.seriesEnhance = map
                                model.save()
                            })) {
                                Text("Enhance: use global setting").tag(Bool?.none)
                                Label("Enhance: on", systemImage: "wand.and.stars").tag(Bool?.some(true))
                                Text("Enhance: off").tag(Bool?.some(false))
                            }
                        }
                    } label: { squareButton(style.symbol) }
                        .accessibilityLabel("Reads as \(style.title)")
                }
                if series.isOnline && !series.chapters.isEmpty {
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
            if let found { withAnimation(.easeOut(duration: 0.6)) { tint = found.color; lightTint = found.isLight } }
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
                    if !series.chapters.isEmpty && !series.readsAsText {
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
            .task { if !series.readsAsText { choices = await model.coverChoices(series) }; loading = false }
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
    private static let types: [UTType] = [.folder, .zip, .pdf, .image] + [UTType(filenameExtension: "cbz"), UTType(filenameExtension: "cbr"), UTType(filenameExtension: "rar")].compactMap { $0 } + BookLink.types
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


/// Every place you marked, newest first, by series. Tap to open the chapter right there.
struct BookmarksSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let open: (Chapter) -> Void
    var body: some View {
        NavigationStack {
            List {
                let marks = model.state.bookmarks ?? []
                if marks.isEmpty {
                    ContentUnavailableView("No bookmarks yet", systemImage: "bookmark",
                                           description: Text("Tap the bookmark at the top of the reader to mark a page."))
                        .listRowBackground(Color.clear)
                }
                let groups = Dictionary(grouping: marks, by: \.seriesID)
                ForEach(groups.keys.sorted { (groups[$0]?.first?.created ?? .distantPast) > (groups[$1]?.first?.created ?? .distantPast) }, id: \.self) { id in
                    Section(model.series(id: id)?.title ?? "Removed series") {
                        ForEach(groups[id] ?? []) { mark in
                            Button {
                                if let chapter = model.prepareToOpen(mark) { open(chapter) }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    if let note = mark.note { Text(note).font(.body).lineLimit(4) }
                                    Text(ChapterText.split(mark.chapterTitle).name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    Text("Page \(mark.page + 1)\(mark.pageCount > 0 ? " of \(mark.pageCount)" : "") · \(mark.created.formatted(.relative(presentation: .named)))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(model.series(id: id) == nil)
                            .swipeActions { Button("Delete", role: .destructive) { model.removeBookmark(mark) } }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden).background(Eclipse.surface)
            .navigationTitle("Bookmarks").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// "Find on…": every site at once, or one site you pick from the same list the search uses.
struct FindOnSitesMenu: View {
    let sources: [SearchSource]
    let pick: (String?) -> Void
    var body: some View {
        Menu {
            Button { pick(nil) } label: { Label("Every site", systemImage: "square.grid.2x2") }
            Divider()
            ForEach(sources) { source in
                Button(source.name) { pick(source.id) }
            }
        } label: { Label("Find on…", systemImage: "magnifyingglass") }
    }
}
