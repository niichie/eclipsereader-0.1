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
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search, or enter a website", text: $address)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.webSearch)
                            .submitLabel(.go)
                            .onSubmit { open(address) }
                    }
                    .padding(14).eclipseCard(cornerRadius: 14)

                    Text("Open any manga, manhwa or webcomic site, then tap **Add to library** on a series or chapter. It joins your library with every chapter, ready to read or download.")
                        .font(.subheadline).foregroundStyle(.secondary)

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
                        siteGrid(SiteCatalog.connected + [SiteCatalog.site("ReadBerserk", "https://readberserk.com/", "Berserk, built in · native", "moon.fill", native: true)])
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
            var parts = URLComponents(string: "https://duckduckgo.com/")!
            parts.queryItems = [URLQueryItem(name: "q", value: trimmed + " manga")]
            if let url = parts.url { browsing = BrowseTarget(url: url) }
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
                        if lastAdded != nil {
                            Button("Read") { if let s = lastAdded { reader = model.resume(s) } }.buttonStyle(.borderedProminent).tint(Eclipse.accent)
                        }
                    }
                    .padding(14).eclipseCard(cornerRadius: 16).padding(12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            if let error = browser.error { Text(error).font(.footnote).foregroundStyle(.orange).padding(8) }

            BrowserToolbar(browser: browser, adding: adding, add: addCurrent, read: readCurrent)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onChange(of: browser.currentURL) { _, url in
            if !editing, let host = url?.host { address = host.replacingOccurrences(of: "www.", with: "") }
        }
        .fullScreenCover(item: $reader) { chapter in ReaderView(chapter: chapter).environmentObject(model) }
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
    private func addCurrent() {
        guard let url = browser.currentURL ?? browser.webView.url else { return }
        adding = true
        Task {
            defer { adding = false }
            do {
                switch try await model.addLink(url.absoluteString, html: await browser.pageHTML()) {
                case .open(let chapter):
                    lastAdded = nil; reader = chapter
                case .series(let series, _):
                    lastAdded = series
                    show("Added \(series.title) · \(series.chapters.count) chapter\(series.chapters.count == 1 ? "" : "s")")
                }
            } catch {
                lastAdded = nil
                show("Couldn’t add this page. Open a series page or a chapter, then try again.")
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
    let add: () -> Void
    let read: () -> Void
    var body: some View {
        HStack(spacing: 2) {
            barButton("chevron.left", "Back") { browser.webView.goBack() }.disabled(!browser.canGoBack)
            barButton("chevron.right", "Forward") { browser.webView.goForward() }.disabled(!browser.canGoForward)
            Spacer(minLength: 6)
            Button(action: add) {
                ViewThatFits(in: .horizontal) {
                    addLabel("Add to library")
                    addLabel("Add")
                    addLabel(nil)
                }
            }
            .buttonStyle(PressableStyle())
            .disabled(adding)
            .accessibilityLabel("Add to library")
            .accessibilityIdentifier("browserAdd")
            Spacer(minLength: 6)
            barButton(browser.loading ? "xmark" : "arrow.clockwise", browser.loading ? "Stop" : "Reload") {
                browser.loading ? browser.webView.stopLoading() : browser.reload()
            }
            barButton("book", "Read this page in the reader", action: read)
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
    private func addLabel(_ text: String?) -> some View {
        HStack(spacing: 6) {
            if adding { ProgressView().controlSize(.small).tint(.black) } else { Image(systemName: "plus").font(.subheadline.weight(.heavy)) }
            if let text { Text(text).font(.subheadline.weight(.bold)).lineLimit(1).fixedSize() }
        }
        .padding(.horizontal, text == nil ? 13 : 18).frame(height: 40)
        .background(Eclipse.highlight, in: Capsule())
        .foregroundStyle(.black)
        .shadow(color: Eclipse.highlight.opacity(0.35), radius: 10, y: 2)
    }
}
