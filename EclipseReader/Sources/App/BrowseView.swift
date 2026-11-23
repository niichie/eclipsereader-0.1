import SwiftUI

/// A site in the Browse catalog.
struct CatalogSite: Identifiable, Hashable {
    let name: String
    let url: URL
    let note: String
    let symbol: String
    var id: String { url.absoluteString }
}

/// Official, free-to-read sources shipped with the app. The user adds any other site under "Your sites".
enum SiteCatalog {
    static let official: [CatalogSite] = [
        CatalogSite(name: "WEBTOON", url: URL(string: "https://www.webtoons.com/en/")!,
                    note: "Official webtoons and manhwa, free episodes", symbol: "iphone.gen3"),
        CatalogSite(name: "WEBTOON Canvas", url: URL(string: "https://www.webtoons.com/en/canvas")!,
                    note: "Independent creators’ webcomics", symbol: "paintpalette"),
        CatalogSite(name: "MANGA Plus", url: URL(string: "https://mangaplus.shueisha.co.jp/updates")!,
                    note: "Shueisha’s official free chapters · reads in the browser", symbol: "book"),
        CatalogSite(name: "Tapas", url: URL(string: "https://tapas.io/")!,
                    note: "Webcomics and novels, many free", symbol: "rectangle.stack"),
        CatalogSite(name: "GlobalComix", url: URL(string: "https://globalcomix.com/")!,
                    note: "Comics and manga, free and premium", symbol: "globe"),
        CatalogSite(name: "Comikey", url: URL(string: "https://comikey.com/")!,
                    note: "Licensed manga and manhwa, free chapters", symbol: "key"),
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

                    section("Your sites") {
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

                    section("Built in") {
                        SiteRow(name: "ReadBerserk", host: "readberserk.com", note: "Berserk, read natively", symbol: "moon.fill") {
                            browsing = BrowseTarget(url: ReadBerserkParser.home)
                        }
                    }

                    section("Official & free") {
                        ForEach(SiteCatalog.official) { site in
                            SiteRow(name: site.name, host: site.url.host ?? "", note: site.note, symbol: site.symbol) { browsing = BrowseTarget(url: site.url) }
                        }
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
    @ViewBuilder private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.bold))
            content()
        }
    }
}

struct BrowseTarget: Identifiable { let url: URL; var id: String { url.absoluteString } }

private struct SiteRow: View {
    let name: String
    let host: String
    let note: String?
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Eclipse.accent.opacity(0.22))
                    Image(systemName: symbol).foregroundStyle(Eclipse.highlight)
                }.frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline)
                    Text(note ?? host).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }.padding(12).eclipseCard(cornerRadius: 14)
        }.buttonStyle(.plain)
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
