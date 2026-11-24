import SwiftUI

/// A site in the Browse catalog.
struct CatalogSite: Identifiable, Hashable {
    let name: String
    let url: URL
    let note: String
    let symbol: String
    /// Read through a dedicated connection rather than the page reader.
    var native = false
    var id: String { url.absoluteString }
}

/// Book libraries shown in the Books section. Manga, comic and novel sources live in Resources/DefaultSources.json.
enum SiteCatalog {
    static func site(_ name: String, _ url: String, _ note: String, _ symbol: String, native: Bool = false) -> CatalogSite {
        CatalogSite(name: name, url: URL(string: url)!, note: note, symbol: symbol, native: native)
    }
}

struct BrowseView: View {
    @AppStorage(Features.booksKey) private var booksOn = false
    /// Redraws Browse when novels are turned on or off.
    @AppStorage(Features.novelsKey) private var novelsOn = false
    @AppStorage(Interests.categoriesKey) private var categoriesRaw = ""
    @EnvironmentObject private var model: LibraryModel
    @State private var address = ""
    @State private var browsing: BrowseTarget?
    @State private var addingSite = false
    @State private var newSiteName = ""
    @State private var newSiteURL = ""
    @State private var popular: [DiscoverItem] = []
    @StateObject private var search = GlobalSearchModel()
    @State private var searchingText: String?
    @State private var opened: MangaSeries?
    @State private var addingID: String?
    @State private var discoverError: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search every site, or enter an address", text: $address)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.webSearch)
                            .submitLabel(.go)
                            .onSubmit { open(address) }
                    }
                    .padding(14).eclipseCard(cornerRadius: 14)

                    if let searchingText {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Results for “\(searchingText)”").font(.title3.weight(.bold)).lineLimit(2)
                                    Text("Every connected and saved site · tap to add").font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Clear") { withAnimation { self.searchingText = nil; search.cancel(); address = "" } }
                                    .font(.subheadline.weight(.semibold))
                            }
                            GlobalSearchResults(search: search, busyID: addingID) { item in add(item) }
                            Button { webSearch(searchingText) } label: {
                                Label("Search the web for “\(searchingText)”", systemImage: "safari")
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(14).eclipseCard(cornerRadius: 14)
                            }.buttonStyle(PressableStyle())
                        }
                    } else {
                        Text("Search every site at once above, or open a site below and tap **Add** on a series. It joins your library with every chapter, ready to read or download.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }

                    if !popular.isEmpty {
                        section("Popular on MangaDex", detail: nil) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 12) {
                                    ForEach(popular) { item in discoverCard(item).frame(width: 112) }
                                }.padding(.vertical, 2)
                            }
                        }
                    }
                    if let discoverError { Text(discoverError).font(.footnote).foregroundStyle(.orange) }

                    if novelsOn { NovelBrowseSection(browsing: $browsing, opened: $opened) }
                    let favorites = model.sources.filter { $0.favorite == true && $0.hidden != true }
                    if !favorites.isEmpty {
                        section("Favourite sources", detail: nil) { siteGrid(favorites) }
                    }
                    ForEach(SourceCategory.allCases.filter { Interests.categories.contains($0) }) { category in
                        let sites = model.sources.filter { $0.category == category && $0.hidden != true && $0.favorite != true }
                        if !sites.isEmpty {
                            section(category.title, detail: category == .novels ? "Chapters read as text, in the novel reader" : nil) { siteGrid(sites) }
                        }
                    }
                    let other = model.sources.filter { $0.category == nil && $0.hidden != true && $0.favorite != true }
                    section("Your sites", detail: other.isEmpty ? "Save any site from the browser’s menu, or add a whole list" : nil) {
                        if !other.isEmpty { siteGrid(other) }
                        HStack(spacing: 10) {
                            Button { newSiteName = ""; newSiteURL = ""; addingSite = true } label: {
                                Label("Add a site", systemImage: "plus.circle").frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14).eclipseCard(cornerRadius: 14)
                            }.buttonStyle(.plain)
                            NavigationLink { SourcesPage().environmentObject(model) } label: {
                                Label("Manage sources", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14).eclipseCard(cornerRadius: 14)
                            }.buttonStyle(.plain)
                        }
                    }
                    if booksOn { BooksBrowseSection(browsing: $browsing, opened: $opened) }
                }
                .padding(20)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .background(EclipseBackground())
            .navigationTitle("Browse")
            .fullScreenCover(item: $browsing) { target in MangaBrowserView(start: target.url).environmentObject(model) }
            .sheet(item: $opened) { series in SeriesSheet(series: series).environmentObject(model) }
            .task { if popular.isEmpty { popular = (try? await Discover.mangaDex(limit: 20)) ?? [] } }
            .alert("Add a site", isPresented: $addingSite) {
                TextField("Name", text: $newSiteName)
                TextField("https://…", text: $newSiteURL).textInputAutocapitalization(.never).keyboardType(.URL)
                Button("Save") { if let url = WebLink.parse(newSiteURL) { model.saveSite(name: newSiteName, url: url) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Saved sites appear here for one-tap browsing.") }
        }
    }
    private func open(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.contains("."), !trimmed.contains(" "), let url = WebLink.parse(trimmed) {
            browsing = BrowseTarget(url: url)
        } else {
            // Words: search every source at once, with a web search one tap away.
            withAnimation { searchingText = trimmed }
            discoverError = nil
            let sites = model.state.sites ?? []
            search.run(trimmed, sources: GlobalSearchModel.sources(saved: sites) + (novelsOn ? GlobalSearchModel.sources(saved: sites, novels: true) : []))
        }
    }
    private func webSearch(_ text: String) {
        var parts = URLComponents(string: "https://duckduckgo.com/")!
        parts.queryItems = [URLQueryItem(name: "q", value: text + " manga")]
        if let url = parts.url { browsing = BrowseTarget(url: url) }
    }
    private func discoverCard(_ item: DiscoverItem) -> some View {
        Button { add(item) } label: {
            VStack(alignment: .leading, spacing: 5) {
                CoverView(url: item.cover, referer: nil)
                    .aspectRatio(0.7, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        if addingID == item.id {
                            ZStack { Color.black.opacity(0.5); ProgressView().tint(.white) }
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if model.libraryMembers.contains(where: { $0.url == item.url }) {
                            Image(systemName: "checkmark.circle.fill").font(.callout).foregroundStyle(Eclipse.highlight)
                                .background(Circle().fill(.black)).padding(5)
                        }
                    }
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                Text(item.title).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                if let detail = item.detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .buttonStyle(PressableStyle())
        .disabled(addingID != nil)
    }
    private func add(_ item: DiscoverItem) {
        if let owned = model.series(id: item.id) ?? model.allSeries.first(where: { $0.url == item.url }) {
            opened = owned
            return
        }
        addingID = item.id
        discoverError = nil
        Task {
            defer { addingID = nil }
            do {
                if case .series(let series, _) = try await model.addLink(item.url.absoluteString, title: item.title, addToShelf: false) { opened = series }
            } catch {
                discoverError = "Couldn’t open \(item.title): \(error.localizedDescription)"
            }
        }
    }
    @ViewBuilder private func section<Content: View>(_ title: String, detail: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.bold))
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
            content()
        }
    }
    private func siteGrid(_ sites: [SavedSite]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
            ForEach(sites) { site in
                SiteRow(name: site.name, host: site.url.host ?? "", note: site.note, symbol: site.category?.symbol ?? "bookmark.fill",
                        native: site.native == true) {
                    browsing = BrowseTarget(url: site.url)
                }
                .contextMenu {
                    Button { var s = site; s.favorite = !(site.favorite ?? false); model.updateSource(s) } label: {
                        Label(site.favorite == true ? "Unfavourite" : "Favourite", systemImage: "star")
                    }
                    Button { var s = site; s.hidden = true; model.updateSource(s) } label: { Label("Hide", systemImage: "eye.slash") }
                    Link(destination: site.url) { Label("Open in Safari", systemImage: "safari") }
                    Button(role: .destructive) { model.removeSource(site) } label: { Label("Remove", systemImage: "trash") }
                }
            }
        }
    }
}

struct BrowseTarget: Identifiable { let url: URL; var id: String { url.absoluteString } }

private struct SiteRow: View {
    let name: String
    let host: String
    let note: String?
    let symbol: String
    var native = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SiteIcon(host: host, symbol: symbol)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name).font(.headline).lineLimit(1)
                        if native {
                            Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(Eclipse.highlight)
                                .accessibilityLabel("Connected")
                        }
                    }
                    Text(note ?? host).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
            .eclipseCard(cornerRadius: 14)
        }.buttonStyle(PressableStyle())
    }
}

/// The site's own icon when it has one, otherwise a symbol on the accent colour.
private struct SiteIcon: View {
    let host: String
    let symbol: String
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Eclipse.accent.opacity(0.22))
            Image(systemName: symbol).foregroundStyle(Eclipse.highlight)
            if !host.isEmpty, let url = URL(string: "https://\(host)/apple-touch-icon.png") {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                }
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }
}

/// Full-screen browser with ad blocking and a one-tap "Add to library".
struct MangaBrowserView: View {
    let start: URL
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = WebsiteBrowser(openWeb: true)
    @State private var address = ""
    @State private var editing = false
    @State private var adding = false
    @State private var toast: String?
    @State private var reader: Chapter?
    @State private var lastAdded: MangaSeries?
    @State private var summary: LinkedSource.PageSummary = .unknown
    @State private var checking = true
    @State private var guiding = false
    @State private var pending: PendingAdd?
    @State private var viewing: MangaSeries?
    /// A book file this page links to (EPUB first), offered as "Add book".
    @State private var bookLink: BookDownloadLink?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).frame(width: 36, height: 36) }
                    .accessibilityLabel("Close browser")
                HStack(spacing: 8) {
                    Image(systemName: browser.currentURL?.scheme == "https" ? "lock.fill" : "globe").font(.caption2).foregroundStyle(.secondary)
                    TextField("Search or enter a website", text: $address, onEditingChanged: { now in
                        editing = now
                        // Full address while typing, just the site name otherwise (like Safari).
                        if now, let url = browser.currentURL { address = url.absoluteString }
                        else if let host = browser.currentURL?.host { address = host.replacingOccurrences(of: "www.", with: "") }
                    })
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.webSearch)
                        .submitLabel(.go).onSubmit { browser.go(address) }
                        .font(.subheadline)
                    if browser.loading { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 12).padding(.vertical, 9).eclipseCard(cornerRadius: 12)
                Menu {
                    Button { model.saveSite(name: browser.title.isEmpty ? (browser.currentURL?.host ?? "Site") : browser.title,
                                            url: rootURL(browser.currentURL ?? start)) } label: {
                        Label("Save this site", systemImage: "bookmark")
                    }
                    if let url = browser.currentURL {
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                        Link(destination: url) { Label("Open in Safari", systemImage: "safari") }
                    }
                } label: { Image(systemName: "ellipsis.circle").font(.title3).frame(width: 36, height: 36) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(.black)

            ZStack(alignment: .bottom) {
                WebsiteSurface(browser: browser, url: start)
                if let toast {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Eclipse.highlight)
                        Text(toast).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Spacer(minLength: 4)
                        if let added = lastAdded {
                            Button("View") { viewing = added }.buttonStyle(.bordered)
                            Button("Read") { reader = model.resume(added) }.buttonStyle(.borderedProminent).tint(Eclipse.accent)
                        }
                    }
                    .padding(14).eclipseCard(cornerRadius: 16).padding(12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            if let error = browser.error { Text(error).font(.footnote).foregroundStyle(.orange).padding(8) }

            BrowserToolbar(browser: browser, adding: adding, summary: summary, checking: checking, bookLink: bookLink,
                           bookSite: onBookSite, add: { addCurrent(force: false) }, addBook: addBook,
                           guide: { guiding = true }, read: readCurrent)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onChange(of: browser.currentURL) { _, url in
            if !editing, let host = url?.host { address = host.replacingOccurrences(of: "www.", with: "") }
        }
        .fullScreenCover(item: $reader) { chapter in ReaderView(chapter: chapter).environmentObject(model) }
        .sheet(item: $pending) { item in
            AddPreviewSheet(item: item) { readNow in
                pending = nil
                if let novel = item.novel {
                    let series = model.commitNovel(item.url, novel, addToShelf: !readNow)
                    lastAdded = series
                    let here = browser.currentURL
                    if readNow { reader = series.chapters.first { $0.url == here } ?? model.resume(series) }
                    else { show("Added \(series.title) · \(series.chapters.count) chapter\(series.chapters.count == 1 ? "" : "s")") }
                    return
                }
                let result = model.commit(item.url, item.found, addToShelf: !readNow)
                if case .series(let series, let open) = result {
                    lastAdded = series
                    if readNow { reader = open ?? model.resume(series) }
                    else { show("Added \(series.title) · \(series.chapters.count) chapter\(series.chapters.count == 1 ? "" : "s")") }
                }
            }
            .environmentObject(model)
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $viewing) { series in SeriesSheet(series: series).environmentObject(model) }
        .onAppear {
            // Keep downloaded files available offline.
            browser.downloaded = { file in
                Task {
                    do {
                        let series = try await model.importFiles([file], copy: true, addToShelf: false)
                        lastAdded = series
                        show("Downloaded \(series.title)")
                    } catch {
                        show("Couldn’t open that download: \(error.localizedDescription)")
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if browser.downloading {
                Label("Downloading…", systemImage: "arrow.down.circle")
                    .font(.footnote.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule()).padding(.top, 64)
            }
        }
        // Read what the page is (series, chapter, or a list of many series) so the Add button can say.
        .sheet(isPresented: $guiding) {
            AddGuideSheet(summary: summary, host: browser.currentURL?.host?.replacingOccurrences(of: "www.", with: "") ?? "",
                          books: onBookSite, tryAnyway: { addCurrent(force: true) })
                .presentationDetents([.medium, .large])
        }
        .task(id: browser.pageVersion) {
            checking = true
            bookLink = nil
            defer { checking = false }
            // Read the page twice: once soon after it loads, again after scripts fill in chapter lists.
            for delay in [700, 1800] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let url = browser.currentURL, WebLink.publicHTTPS(url), let html = await browser.pageHTML() else { return }
                let (result, book) = await Task.detached(priority: .utility) {
                    (LinkedSource.summarize(html: html, url: url), BookLinks.best(in: html, base: url))
                }.value
                if Task.isCancelled { return }
                summary = result
                bookLink = book
                if case .series = result { return }
                if case .chapter = result { return }
                checking = false
            }
        }
    }
    /// Book libraries (Gutenberg, Standard Ebooks, Wikisource): the guide talks about books, not series.
    private var onBookSite: Bool {
        guard let host = browser.currentURL?.host?.lowercased() else { return false }
        return BookLinks.libraryHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
    /// Downloads the page's book through the browser itself (so any site check it passed still counts);
    /// the finished file goes straight into the library.
    private func addBook() {
        guard let link = bookLink else { return }
        browser.webView.load(URLRequest(url: link.url))
    }
    private func rootURL(_ url: URL) -> URL {
        var parts = URLComponents(); parts.scheme = "https"; parts.host = url.host; parts.path = "/"
        return parts.url ?? url
    }
    private func show(_ text: String) {
        withAnimation(.snappy) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(5))
            withAnimation(.snappy) { if toast == text { toast = nil } }
        }
    }
    private func addCurrent(force: Bool) {
        guard let url = browser.currentURL ?? browser.webView.url else { return }
        if summary == .listing && !force {
            show("This page lists many series. Open the one you want, then tap Add.")
            return
        }
        adding = true
        Task {
            defer { adding = false }
            let html = await browser.pageHTML()
            // Novels (a novel site, a source set to novels, or a page that's mostly running text, with novels turned on).
            if model.isNovel(url) || (Features.novelsOn && html.map { NovelText.looksLikeChapter(html: $0, url: url) } == true) {
                guard Features.novelsOn else { lastAdded = nil; show(NovelsOff().errorDescription ?? ""); return }
                if let existing = model.allSeries.first(where: { $0.kind == .novel && ($0.url == url || $0.chapters.contains { $0.url == url }) }) {
                    lastAdded = model.addToLibrary(existing)
                    show(existing.isLibraryMember ? "\(existing.title) is already in your library" : "Added \(existing.title)")
                    return
                }
                do {
                    let info = try await model.novelInfo(url, html: html)
                    pending = PendingAdd(url: info.home ?? url, found: LinkInspection(title: info.title, cover: info.cover, pages: [], chapters: info.chapters),
                                         novel: info)
                } catch {
                    lastAdded = nil
                    show("Couldn’t find a novel here. Open the novel’s page or one of its chapters, then try again.")
                }
                return
            }
            do {
                switch try await model.preview(url.absoluteString, html: html) {
                case .existing(.open(let chapter)):
                    lastAdded = nil; reader = chapter
                case .existing(.series(let series, _)):
                    lastAdded = model.addToLibrary(series)
                    show(series.isLibraryMember ? "\(series.title) is already in your library" : "Added \(series.title)")
                case .fresh(let target, let found):
                    pending = PendingAdd(url: target, found: found)
                }
            } catch SourceError.listing {
                lastAdded = nil
                show("This page lists many series. Open the one you want, then tap Add.")
            } catch {
                lastAdded = nil
                show("Couldn’t find a series here. Open a series page or a chapter, then try again.")
            }
        }
    }
    private func readCurrent() {
        guard let url = browser.currentURL ?? browser.webView.url else { return }
        adding = true
        Task {
            defer { adding = false }
            do {
                switch try await model.addLink(url.absoluteString, html: await browser.pageHTML(), addToShelf: false) {
                case .open(let chapter): reader = chapter
                case .series(let series, let chapter):
                    lastAdded = series.isLibraryMember ? series : nil
                    if let chapter { reader = chapter } else if let first = model.resume(series) { reader = first }
                }
            } catch { show("This page has no readable manga pages. Try opening a chapter.") }
        }
    }
}

/// Back, forward, a prominent "Add to library", reload and read. Sized so it never wraps:
/// the add button shortens to "Add" and then to an icon on narrow screens.
private struct BrowserToolbar: View {
    @ObservedObject var browser: WebsiteBrowser
    let adding: Bool
    let summary: LinkedSource.PageSummary
    let checking: Bool
    var bookLink: BookDownloadLink? = nil
    var bookSite = false
    let add: () -> Void
    var addBook: () -> Void = {}
    let guide: () -> Void
    let read: () -> Void
    private var addable: Bool {
        switch summary { case .series, .chapter: true; default: false }
    }
    var body: some View {
        HStack(spacing: 2) {
            barButton("chevron.left", "Back") { browser.webView.goBack() }.disabled(!browser.canGoBack)
            barButton("chevron.right", "Forward") { browser.webView.goForward() }.disabled(!browser.canGoForward)
            Spacer(minLength: 6)
            Group {
                if let bookLink, !addable {
                    // A book's page: download its EPUB (or Kindle/FB2 file) into the library.
                    Button(action: addBook) {
                        ViewThatFits(in: .horizontal) {
                            addLabel(browser.downloading ? "Downloading…" : "Download · \(bookLink.format)", symbol: "text.book.closed")
                            addLabel("Download", symbol: "text.book.closed")
                            addLabel(nil, symbol: "text.book.closed")
                        }
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(browser.downloading)
                    .accessibilityLabel("Add this book to the library")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else if addable {
                    // Only on pages a series can be read from: series pages and chapters.
                    Button(action: add) {
                        ViewThatFits(in: .horizontal) {
                            addLabel(longTitle)
                            addLabel("Add")
                            addLabel(nil)
                        }
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(adding)
                    .accessibilityLabel("Add to library")
                    .accessibilityIdentifier("browserAdd")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else if checking || browser.loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading page…").font(.footnote.weight(.semibold)).lineLimit(1).fixedSize()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14).frame(height: 40)
                    .transition(.opacity)
                } else {
                    // Wrong kind of page: explain how to get a series in, instead of a button that fails.
                    Button(action: guide) {
                        ViewThatFits(in: .horizontal) {
                            hintLabel(bookSite ? "Open a book to add" : summary == .listing ? "Pick a series to add" : "Open a series to add")
                            hintLabel("How to add")
                            hintLabel(nil)
                        }
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("How to add a series")
                    .accessibilityIdentifier("browserAddGuide")
                    .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: addable)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: bookLink)
            .sensoryFeedback(.success, trigger: addable || bookLink != nil) { _, now in now }
            Spacer(minLength: 6)
            barButton(browser.loading ? "xmark" : "arrow.clockwise", browser.loading ? "Stop" : "Reload") {
                browser.loading ? browser.webView.stopLoading() : browser.reload()
            }
            barButton("book", "Read this page in the reader", action: read)
                .disabled(!addable)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Eclipse.hairline).frame(height: 0.5) }
    }
    private func barButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 19, weight: .medium)).frame(width: 44, height: 44)
        }.accessibilityLabel(label)
    }
    private var longTitle: String {
        switch summary {
        case .series(_, let count) where count > 0: "Add · \(count) ch"
        case .chapter: "Add series"
        default: "Add to library"
        }
    }
    private func addLabel(_ text: String?, symbol: String = "plus") -> some View {
        HStack(spacing: 6) {
            if adding || (symbol != "plus" && browser.downloading) { ProgressView().controlSize(.small).tint(.black) }
            else { Image(systemName: symbol).font(.subheadline.weight(.heavy)) }
            if let text { Text(text).font(.subheadline.weight(.bold)).lineLimit(1).fixedSize() }
        }
        .padding(.horizontal, text == nil ? 13 : 18).frame(height: 40)
        .background(Eclipse.highlight, in: Capsule())
        .foregroundStyle(.black)
        .shadow(color: Eclipse.highlight.opacity(0.4), radius: 10, y: 2)
    }
    private func hintLabel(_ text: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.circle").font(.subheadline.weight(.semibold))
            if let text { Text(text).font(.footnote.weight(.semibold)).lineLimit(1).fixedSize() }
        }
        .padding(.horizontal, text == nil ? 12 : 14).frame(height: 36)
        .foregroundStyle(.white.opacity(0.8))
        .background(Color.white.opacity(0.1), in: Capsule())
        .overlay(Capsule().strokeBorder(Eclipse.hairline))
    }
}

/// Why there's no Add button here, and how to get a series into the library.
private struct AddGuideSheet: View {
    let summary: LinkedSource.PageSummary
    let host: String
    var books = false
    let tryAnyway: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Capsule().fill(Color.white.opacity(0.25)).frame(width: 40, height: 5).frame(maxWidth: .infinity).padding(.top, 8)
            HStack(spacing: 12) {
                Image(systemName: summary == .listing ? "square.grid.2x2" : "doc.text.magnifyingglass")
                    .font(.title2).foregroundStyle(Eclipse.highlight)
                    .frame(width: 48, height: 48).background(Eclipse.accent.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(books ? "No book on this page yet" : summary == .listing ? "This page lists many series" : "No series on this page yet").font(.headline)
                    Text(host).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if books {
                VStack(alignment: .leading, spacing: 14) {
                    step(1, "Open a book", "Tap a title to go to the book's own page, the one with its download links.")
                    step(2, "Tap Download", "Open the downloaded book to read it or add it to your library.")
                    step(3, "Or tap a download link", "EPUB, Kindle (AZW3/MOBI) and FB2 links on any site go straight into your library.")
                }
                Label("These libraries only have books that are out of copyright. Newer books aren't free here.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    step(1, "Open a series", "Tap a title to go to its own page: the one with the cover and the list of chapters.")
                    step(2, "Let it finish loading", "Some sites show their chapter list a moment after the page appears.")
                    step(3, "Tap Add", "The yellow Add button appears with the chapter count when eclipsereader can read the series.")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label("A chapter page works too: the whole series is added from its chapter menu.", systemImage: "book")
                    Label("If a site asks whether you're human, answer it once here, then the page can be added.", systemImage: "checkmark.shield")
                    Label("Home, latest, genre and search pages can't be added: they're lists of many series.", systemImage: "list.bullet")
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if !books {
                    Button { dismiss(); tryAnyway() } label: {
                        Text("Try adding anyway").font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(Eclipse.surfaceHigh, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                Button { dismiss() } label: {
                    Text("Got it").font(.subheadline.weight(.bold)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(Eclipse.highlight, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .buttonStyle(PressableStyle())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: 560).frame(maxWidth: .infinity)
        .background(Eclipse.surface.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.subheadline.weight(.heavy)).foregroundStyle(.black)
                .frame(width: 26, height: 26).background(Eclipse.highlight, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.bold))
                Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PendingAdd: Identifiable {
    let url: URL
    let found: LinkInspection
    /// Set when what's being added is a novel (read as text).
    var novel: NovelInfo? = nil
    var id: String { url.absoluteString }
}

/// What will be added: cover, title, chapter count and reading style, before it joins the library.
private struct AddPreviewSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let item: PendingAdd
    let confirm: (_ readNow: Bool) -> Void
    var body: some View {
        let found = item.found
        let style = item.novel == nil ? (found.style ?? .automatic) : .automatic
        VStack(spacing: 18) {
            Capsule().fill(Color.white.opacity(0.25)).frame(width: 40, height: 5).padding(.top, 8)
            HStack(alignment: .top, spacing: 16) {
                CoverView(url: found.cover ?? found.pages.first?.url, referer: found.chapters.first)
                    .aspectRatio(0.7, contentMode: .fit).frame(width: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                VStack(alignment: .leading, spacing: 8) {
                    Text(found.title).font(.title3.weight(.heavy)).lineLimit(4)
                    Label(item.url.host?.replacingOccurrences(of: "www.", with: "") ?? "Website", systemImage: "globe")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Label("\(found.chapters.count) chapter\(found.chapters.count == 1 ? "" : "s")", systemImage: "list.number")
                        if item.novel != nil { Label("Novel", systemImage: "text.book.closed") }
                        else if style != .automatic { Label(style.title, systemImage: style.symbol) }
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if let first = found.chapters.first, let last = found.chapters.last, found.chapters.count > 1 {
                        Text("\(ChapterText.split(first.title).name) – \(ChapterText.split(last.title).name)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            if found.chapters.isEmpty && !found.pages.isEmpty {
                Label("This is a single chapter. Its series list wasn’t on the page, so it’s added on its own.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                Button { confirm(false) } label: {
                    Label("Add to library", systemImage: "plus").font(.headline)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(Eclipse.highlight, in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(.black)
                }.buttonStyle(PressableStyle()).accessibilityIdentifier("confirmAdd")
                Button { confirm(true) } label: {
                    Label("Read now", systemImage: "book").font(.headline)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(Eclipse.surfaceHigh, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Eclipse.hairline))
                }.buttonStyle(PressableStyle())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(Eclipse.surface.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

/// A series opened from Browse: its page in a sheet, with the reader on top.
struct SeriesSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let series: MangaSeries
    @State private var reader: Chapter?
    var body: some View {
        NavigationStack {
            SeriesView(seriesID: series.id, reader: $reader)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }.fontWeight(.semibold)
                    }
                }
        }
        .fullScreenCover(item: $reader) { chapter in ReaderView(chapter: chapter).environmentObject(model) }
        .preferredColorScheme(.dark)
    }
}
