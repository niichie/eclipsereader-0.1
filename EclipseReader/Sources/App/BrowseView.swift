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

/// Sites shipped with the app. Anything else can be saved under "Your sites".
enum SiteCatalog {
    static func site(_ name: String, _ url: String, _ note: String, _ symbol: String, native: Bool = false) -> CatalogSite {
        CatalogSite(name: name, url: URL(string: url)!, note: note, symbol: symbol, native: native)
    }
    /// Built-in connections: chapters, covers and pages come from the site's own data.
    static let connected: [CatalogSite] = [
        site("MangaDex", "https://mangadex.org/", "Huge community library, every language · native", "books.vertical", native: true),
        site("WeebCentral", "https://weebcentral.com/", "Manga with full chapter lists · native", "square.stack.3d.up", native: true),
        site("WEBTOON", "https://www.webtoons.com/en/", "Official webtoons, every free episode · native", "iphone.gen3", native: true),
    ]
    /// Popular manga & manhwa sites: open a series and tap Add to library.
    static let popular: [CatalogSite] = [
        site("Asura Scans", "https://asurascans.com/comics", "Action manhwa, fast releases", "flame"),
        site("MangaDot", "https://mangadot.net/", "Manga, manhwa and manhua", "circle.grid.cross"),
        site("MangaBall", "https://mangaball.com/", "Large mixed library", "circle.circle"),
        site("Comix", "https://comix.to/", "Manga and manhwa, clean reader", "rectangle.on.rectangle.angled"),
        site("WEBTOON Canvas", "https://www.webtoons.com/en/canvas", "Independent creators’ webcomics", "paintpalette"),
    ]
    /// Official publishers with free chapters.
    static let official: [CatalogSite] = [
        site("MANGA Plus", "https://mangaplus.shueisha.co.jp/updates", "Shueisha’s free chapters · reads in the browser", "book"),
        site("Tapas", "https://tapas.io/", "Webcomics and novels, many free", "rectangle.stack"),
        site("Tappytoon", "https://www.tappytoon.com/en", "Licensed manhwa", "t.circle"),
        site("Manta", "https://manta.net/en", "Romance and fantasy manhwa", "m.circle"),
        site("GlobalComix", "https://globalcomix.com/", "Comics and manga, free and premium", "globe"),
        site("Comikey", "https://comikey.com/", "Licensed manga and manhwa, free chapters", "key"),
    ]
}

struct BrowseView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var address = ""
    @State private var browsing: BrowseTarget?
    @State private var addingSite = false
    @State private var newSiteName = ""
    @State private var newSiteURL = ""
    @State private var popular: [DiscoverItem] = []
    @State private var results: [DiscoverItem]?
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
                        TextField("Search MangaDex, or enter a website", text: $address)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.webSearch)
                            .submitLabel(.go)
                            .onSubmit { open(address) }
                    }
                    .padding(14).eclipseCard(cornerRadius: 14)

                    if let searchingText {
                        section("Results for “\(searchingText)”", detail: "From MangaDex · tap to add") {
                            if let results {
                                if results.isEmpty {
                                    Text("Nothing on MangaDex by that name.").font(.subheadline).foregroundStyle(.secondary)
                                } else {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 12, alignment: .top)], spacing: 16) {
                                        ForEach(results) { item in discoverCard(item) }
                                    }
                                }
                            } else {
                                ProgressView().frame(maxWidth: .infinity).padding()
                            }
                            Button { webSearch(searchingText) } label: {
                                Label("Search the web for “\(searchingText)”", systemImage: "safari")
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(14).eclipseCard(cornerRadius: 14)
                            }.buttonStyle(PressableStyle())
                            Button("Clear search") { withAnimation { self.searchingText = nil; results = nil; address = "" } }
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Search MangaDex above, or open a site below and tap **Add to library** on a series. It joins your library with every chapter, ready to read or download.")
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

                    section("Your sites", detail: (model.state.sites ?? []).isEmpty ? "Save any site from the browser’s menu" : nil) {
                        ForEach(model.state.sites ?? []) { site in
                            SiteRow(name: site.name, host: site.url.host ?? "", note: nil, symbol: "bookmark.fill") { browsing = BrowseTarget(url: site.url) }
                                .contextMenu {
                                    Button(role: .destructive) { model.removeSite(site) } label: { Label("Remove", systemImage: "trash") }
                                }
                        }
                        Button { newSiteName = ""; newSiteURL = ""; addingSite = true } label: {
                            Label("Add a site", systemImage: "plus.circle").frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14).eclipseCard(cornerRadius: 14)
                        }.buttonStyle(.plain)
                    }

                    section("Connected", detail: "Chapters, covers and pages straight from the site") {
                        siteGrid(SiteCatalog.connected)
                    }
                    section("Popular sites", detail: "Open a series, then tap Add to library") {
                        siteGrid(SiteCatalog.popular)
                    }
                    section("Official & free", detail: nil) {
                        siteGrid(SiteCatalog.official)
                    }
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
            // Words: search MangaDex natively, with a web search one tap away.
            withAnimation { searchingText = trimmed; results = nil }
            Task {
                do { let found = try await Discover.mangaDex(query: trimmed); if searchingText == trimmed { results = found } }
                catch { if searchingText == trimmed { results = []; discoverError = "MangaDex didn’t answer. Try the web search." } }
            }
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
                        if model.allSeries.contains(where: { $0.url == item.url }) {
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
        addingID = item.id
        discoverError = nil
        Task {
            defer { addingID = nil }
            do {
                if case .series(let series, _) = try await model.addLink(item.url.absoluteString) { opened = series }
            } catch {
                discoverError = "Couldn’t add \(item.title): \(error.localizedDescription)"
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
    private func siteGrid(_ sites: [CatalogSite]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
            ForEach(sites) { site in
                SiteRow(name: site.name, host: site.url.host ?? "", note: site.note, symbol: site.symbol, native: site.native) {
                    browsing = BrowseTarget(url: site.url)
                }
                .contextMenu {
                    Button { model.saveSite(name: site.name, url: site.url) } label: { Label("Add to Your sites", systemImage: "bookmark") }
                    Link(destination: site.url) { Label("Open in Safari", systemImage: "safari") }
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

            BrowserToolbar(browser: browser, adding: adding, summary: summary, checking: checking,
                           add: { addCurrent(force: false) }, guide: { guiding = true }, read: readCurrent)
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
                let result = model.commit(item.url, item.found)
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
        // Read what the page is (series, chapter, or a list of many series) so the Add button can say.
        .sheet(isPresented: $guiding) {
            AddGuideSheet(summary: summary, host: browser.currentURL?.host?.replacingOccurrences(of: "www.", with: "") ?? "",
                          tryAnyway: { addCurrent(force: true) })
                .presentationDetents([.medium, .large])
        }
        .task(id: browser.pageVersion) {
            checking = true
            defer { checking = false }
            // Read the page twice: once soon after it loads, again after scripts fill in chapter lists.
            for delay in [700, 1800] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let url = browser.currentURL, WebLink.publicHTTPS(url), let html = await browser.pageHTML() else { return }
                let result = await Task.detached(priority: .utility) { LinkedSource.summarize(html: html, url: url) }.value
                if Task.isCancelled { return }
                summary = result
                if case .series = result { return }
                if case .chapter = result { return }
                checking = false
            }
        }
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
            do {
                switch try await model.preview(url.absoluteString, html: await browser.pageHTML()) {
                case .existing(.open(let chapter)):
                    lastAdded = nil; reader = chapter
                case .existing(.series(let series, _)):
                    lastAdded = series
                    show("\(series.title) is already in your library")
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
                switch try await model.addLink(url.absoluteString, html: await browser.pageHTML()) {
                case .open(let chapter): reader = chapter
                case .series(let series, let chapter):
                    lastAdded = series
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
    let add: () -> Void
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
                if addable {
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
                            hintLabel(summary == .listing ? "Pick a series to add" : "Open a series to add")
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
            .sensoryFeedback(.success, trigger: addable) { _, now in now }
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
    private func addLabel(_ text: String?) -> some View {
        HStack(spacing: 6) {
            if adding { ProgressView().controlSize(.small).tint(.black) }
            else { Image(systemName: "plus").font(.subheadline.weight(.heavy)) }
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
                    Text(summary == .listing ? "This page lists many series" : "No series on this page yet").font(.headline)
                    Text(host).font(.footnote).foregroundStyle(.secondary)
                }
            }
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
            HStack(spacing: 10) {
                Button { dismiss(); tryAnyway() } label: {
                    Text("Try adding anyway").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(Eclipse.surfaceHigh, in: RoundedRectangle(cornerRadius: 14))
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
        let style = found.style ?? .automatic
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
                        if style != .automatic { Label(style.title, systemImage: style.symbol) }
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
                    Label("Add and read now", systemImage: "book").font(.headline)
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
