import SwiftUI

/// Runs one query against every source at once; each source fills in as it answers.
@MainActor
final class GlobalSearchModel: ObservableObject {
    enum Phase: Equatable { case loading, done([DiscoverItem]), failed }
    struct Section: Identifiable {
        let source: SearchSource
        var phase: Phase
        var id: String { source.id }
    }
    @Published private(set) var sections: [Section] = []
    @Published private(set) var query = ""
    /// Every site this search could use; the ones switched off in the Sites menu are not queried.
    @Published private(set) var candidates: [SearchSource] = []
    @Published private(set) var excluded: Set<String> = GlobalSearchModel.storedExclusions()
    private var queries: [String: String] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    nonisolated static let exclusionsKey = "globalSearchExcludedSources"
    nonisolated private static func storedExclusions() -> Set<String> {
        Set((UserDefaults.standard.string(forKey: exclusionsKey) ?? "").split(separator: "\n").map(String.init))
    }

    /// Use the installed catalog for membership; native adapters only choose how a site is searched.
    static func sources(saved: [SavedSite], novels: Bool = false) -> [SearchSource] {
        var seen = Set<String>()
        return saved.compactMap { site in
            guard site.hidden != true, (site.category == .novels) == novels,
                  site.category.map(Interests.categories.contains) ?? true else { return nil }
            let kind: SearchSource.Kind = switch site.url.host?.lowercased().replacingOccurrences(of: "www.", with: "") {
            case "mangadex.org": .mangaDex
            case "weebcentral.com": .weebCentral
            case "webtoons.com": .webtoons
            case "ncode.syosetu.com", "syosetu.com": .syosetu
            case "kakuyomu.jp": .kakuyomu
            default: .site(site.url)
            }
            let source = SearchSource(name: site.name, kind: kind, novels: novels)
            return seen.insert(source.id).inserted ? source : nil
        }
    }

    /// `queries`: a different search text for some sources (by id), like a Japanese title for Syosetu.
    func run(_ text: String, sources: [SearchSource], queries: [String: String] = [:]) {
        cancel()
        query = text
        candidates = sources
        self.queries = queries
        let active = sources.filter { !excluded.contains($0.id) }
        sections = active.map { Section(source: $0, phase: .loading) }
        for source in active { start(source) }
    }
    /// Switches one site in or out of every search. Turning a site on searches it now; the others keep their results.
    func setIncluded(_ source: SearchSource, _ on: Bool) {
        if on { excluded.remove(source.id) } else { excluded.insert(source.id) }
        UserDefaults.standard.set(excluded.sorted().joined(separator: "\n"), forKey: Self.exclusionsKey)
        if on {
            guard !query.isEmpty, !sections.contains(where: { $0.id == source.id }) else { return }
            let order = candidates.map(\.id)
            sections.append(Section(source: source, phase: .loading))
            sections.sort { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
            start(source)
        } else {
            tasks[source.id]?.cancel(); tasks[source.id] = nil
            sections.removeAll { $0.id == source.id }
        }
    }
    func setAll(_ on: Bool) {
        excluded = on ? [] : Set(candidates.map(\.id))
        UserDefaults.standard.set(excluded.sorted().joined(separator: "\n"), forKey: Self.exclusionsKey)
        if !query.isEmpty { run(query, sources: candidates, queries: queries) }
    }
    private func start(_ source: SearchSource) {
        let text = query
        let wanted = queries[source.id] ?? text
        tasks[source.id] = Task { [weak self] in
            let phase: Phase
            do {
                phase = .done(try await GlobalSearch.search(source, query: wanted))
            } catch {
                // Sites that only answer browsers: read their search page the way Safari would.
                if case .site = source.kind {
                    let found = await Self.rendered(source, query: wanted)
                    phase = found.isEmpty ? .failed : .done(found)
                } else {
                    phase = .failed
                }
            }
            guard let self, !Task.isCancelled, self.query == text,
                  let i = self.sections.firstIndex(where: { $0.id == source.id }) else { return }
            self.sections[i].phase = phase
        }
    }
    private static func rendered(_ source: SearchSource, query: String) async -> [DiscoverItem] {
        guard case .site(let root) = source.kind, let url = GlobalSearch.searchURLs(root: root, query: query).last,
              let html = try? await PageRenderer.searchHTML(for: url) else { return [] }
        return GlobalSearch.relevant(GlobalSearch.results(in: html, base: url), to: query)
    }
    func cancel() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
    }
    var finished: Bool { !sections.contains { $0.phase == .loading } }
}

/// Mihon-style global search: one row of covers per source, empty sources folded into a footnote.
struct GlobalSearchResults: View {
    @EnvironmentObject private var library: LibraryModel
    @ObservedObject var search: GlobalSearchModel
    /// Shows a busy overlay on the item being added or opened.
    var busyID: String?
    @State private var browser: BrowseTarget?
    var showLibrary = true
    let pick: (DiscoverItem) -> Void
    var body: some View {
        let mine = showLibrary ? library.librarySeries.filter { !search.query.isEmpty && $0.title.localizedCaseInsensitiveContains(search.query) } : []
        VStack(alignment: .leading, spacing: 20) {
            if !mine.isEmpty {
                row(title: "In your library", host: nil, count: mine.count) {
                    ForEach(mine) { series in
                        card(title: series.title, cover: library.cover(for: series), detail: library.style(for: series.id).title,
                             owned: true, busy: false, referer: series.chapters.first) {
                            pick(DiscoverItem(id: series.id, title: series.title, url: series.url, cover: nil, detail: nil))
                        }
                    }
                }
            }
            ForEach(search.sections) { section in
                switch section.phase {
                case .loading:
                    row(title: section.source.name, host: section.source.host, count: nil) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 10).fill(Eclipse.surfaceHigh)
                                .overlay(ShimmerView().clipShape(RoundedRectangle(cornerRadius: 10)))
                                .frame(width: 108, height: 154)
                        }
                    }
                case .done(let items) where !items.isEmpty:
                    row(title: section.source.name, host: section.source.host, count: items.count) {
                        ForEach(items) { item in
                            card(title: item.title, cover: cover(for: item), detail: item.detail,
                                 owned: library.libraryMembers.contains { $0.url == item.url }, busy: busyID == item.id, referer: nil) {
                                pick(item)
                            }
                        }
                    }
                default:
                    EmptyView()
                }
            }
            let empty = search.sections.filter { if case .done(let items) = $0.phase { return items.isEmpty } else { return false } }
            let failed = search.sections.filter { $0.phase == .failed }
            // One compact line for sites that didn't answer, with their browser searches in a menu,
            // instead of a separate button per site.
            if !failed.isEmpty && search.finished {
                let browsable = failed.compactMap { section -> (String, URL)? in
                    guard case .site(let root) = section.source.kind else { return nil }
                    return (section.source.name, GlobalSearch.searchURLs(root: root, query: search.query).first ?? root)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(failed.count) site\(failed.count == 1 ? "" : "s") didn’t answer")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    if !browsable.isEmpty {
                        Menu {
                            ForEach(browsable.indices, id: \.self) { i in
                                Button(browsable[i].0, systemImage: "safari") { browser = BrowseTarget(url: browsable[i].1) }
                            }
                        } label: {
                            Label("Try in browser", systemImage: "chevron.down").labelStyle(TrailingIconLabel())
                                .font(.footnote.weight(.semibold))
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11).eclipseCard(cornerRadius: 12)
            }
            if !empty.isEmpty && search.finished {
                Text("No matches on " + empty.map(\.source.name).joined(separator: ", ") + ".")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .fullScreenCover(item: $browser) { target in MangaBrowserView(start: target.url).environmentObject(library) }
    }
    /// A result's own cover, or the one already known for that series (the built-in Berserk, things in your library).
    private func cover(for item: DiscoverItem) -> URL? {
        if let cover = item.cover { return cover }
        guard let known = library.series(id: item.id) ?? library.allSeries.first(where: { $0.url == item.url }) else { return nil }
        return library.cover(for: known)
    }
    private func row<Content: View>(title: String, host: String?, count: Int?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                if let count {
                    Text("\(count)").font(.caption2.weight(.bold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Eclipse.accent.opacity(0.5), in: Capsule())
                } else {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                if let host { Text(host).font(.caption).foregroundStyle(.secondary) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) { content() }.padding(.vertical, 2)
            }
        }
    }
    private func card(title: String, cover: URL?, detail: String?, owned: Bool, busy: Bool, referer: Chapter?,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                CoverView(url: cover, referer: referer, title: title)
                    .frame(width: 108, height: 154)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        if busy {
                            ZStack { Color.black.opacity(0.5); ProgressView().tint(.white) }
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if owned {
                            Image(systemName: "checkmark.circle.fill").font(.callout).foregroundStyle(Eclipse.highlight)
                                .background(Circle().fill(.black)).padding(5)
                        }
                    }
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                Text(title).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(width: 108, alignment: .leading)
        }
        .buttonStyle(PressableStyle())
        .disabled(busy)
    }
}

/// Move a series when its site dies or changes address. Reading progress follows by chapter number.
struct MigrateSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let series: MangaSeries
    @StateObject private var search = GlobalSearchModel()
    @State private var query: String
    @State private var link = ""
    @State private var address = ""
    @State private var busyID: String?
    @State private var candidate: Candidate?
    @State private var message: String?
    struct Candidate: Identifiable {
        let url: URL
        let found: LinkInspection
        var id: String { url.absoluteString }
    }
    init(series: MangaSeries) {
        self.series = series
        _query = State(initialValue: series.title)
    }
    var body: some View {
        let tracked = series.chapters.filter { model.state.progress[$0.id] != nil }.count
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 14) {
                        CoverView(url: model.cover(for: series), referer: series.chapters.first)
                            .frame(width: 64, height: 91).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(series.title).font(.headline).lineLimit(2)
                            Label(series.url.host?.replacingOccurrences(of: "www.", with: "") ?? "", systemImage: "globe")
                                .font(.footnote).foregroundStyle(.secondary)
                            Text("\(series.chapters.count) chapters · progress on \(tracked)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let message {
                        Label(message, systemImage: "info.circle").font(.footnote).foregroundStyle(Eclipse.highlight)
                    }
                    group("Same site, new address", detail: "Sites often move domains. Enter the new one and every chapter follows, progress included.") {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.swap").foregroundStyle(.secondary)
                            TextField("new-address.com", text: $address)
                                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Move") {
                                if model.moveSite(series, to: address) { dismiss() }
                                else { message = "That doesn’t look like a web address." }
                            }
                            .fontWeight(.semibold).disabled(WebLink.parse(address) == nil)
                        }
                        .padding(.horizontal, 14).frame(height: 50).eclipseCard(cornerRadius: 14)
                    }
                    group("Find it on another site", detail: "Pick the same series anywhere; chapters you’ve read stay read.") {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Title", text: $query).submitLabel(.search).onSubmit(runSearch)
                            Button("Search", action: runSearch).fontWeight(.semibold)
                        }
                        .padding(.horizontal, 14).frame(height: 50).eclipseCard(cornerRadius: 14)
                        GlobalSearchResults(search: search, busyID: busyID, showLibrary: false) { item in choose(item.url, id: item.id) }
                        HStack(spacing: 8) {
                            Image(systemName: "link").foregroundStyle(.secondary)
                            TextField("Or paste the series link", text: $link)
                                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Use") { if let url = WebLink.parse(link) { choose(url, id: url.absoluteString) } }
                                .fontWeight(.semibold).disabled(WebLink.parse(link) == nil || busyID != nil)
                        }
                        .padding(.horizontal, 14).frame(height: 50).eclipseCard(cornerRadius: 14)
                    }
                }
                .padding(20).frame(maxWidth: 720).frame(maxWidth: .infinity)
            }
            .background(EclipseBackground())
            .navigationTitle("Migrate").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { search.cancel(); dismiss() } }
            .task { if search.sections.isEmpty { runSearch() } }
            .sheet(item: $candidate) { item in
                MigrateConfirm(series: series, item: item, cancel: { candidate = nil }) {
                    model.migrate(series, to: item.url, found: item.found)
                    candidate = nil
                    search.cancel()
                    dismiss()
                }
                .environmentObject(model)
                .presentationDetents([.medium])
            }
        }
        .preferredColorScheme(.dark)
    }
    private func group<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.bold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            content()
        }
    }
    private func runSearch() {
        let here = series.url.host.map(LinkedSource.root) ?? ""
        let sources = GlobalSearchModel.sources(saved: model.state.sites ?? []).filter { LinkedSource.root($0.host) != here }
        search.run(query, sources: sources)
    }
    private func choose(_ url: URL, id: String) {
        guard busyID == nil else { return }
        busyID = id; message = nil
        Task {
            defer { busyID = nil }
            do {
                let found = try await model.inspect(url)
                if found.chapters.isEmpty { message = "No chapter list on that page. Pick the series page itself."; return }
                candidate = Candidate(url: url, found: found)
            } catch {
                message = "Couldn’t read that page: \(error.localizedDescription)"
            }
        }
    }
}

/// "Move to …?" with how much reading progress carries over.
private struct MigrateConfirm: View {
    @EnvironmentObject private var model: LibraryModel
    let series: MangaSeries
    let item: MigrateSheet.Candidate
    let cancel: () -> Void
    let move: () -> Void
    var body: some View {
        let match = model.migrationMatches(series, to: item.found)
        VStack(alignment: .leading, spacing: 16) {
            Text("Move to \(item.url.host?.replacingOccurrences(of: "www.", with: "") ?? "this site")?").font(.title3.weight(.bold))
            HStack(spacing: 14) {
                CoverView(url: item.found.cover, referer: item.found.chapters.first)
                    .frame(width: 70, height: 100).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.found.title).font(.headline).lineLimit(2)
                    Label("\(item.found.chapters.count) chapters", systemImage: "list.number").font(.footnote).foregroundStyle(.secondary)
                    Label(match.total == 0 ? "No reading progress to move" : "Progress on \(match.matched) of \(match.total) chapters carries over",
                          systemImage: "checkmark.circle").font(.footnote).foregroundStyle(match.matched == match.total ? Eclipse.highlight : .orange)
                }
            }
            Text("Your cover choice, reading style and place in the library stay. Downloads from the old site are removed.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(action: cancel) {
                    Text("Back").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 46)
                        .background(Eclipse.surfaceHigh, in: RoundedRectangle(cornerRadius: 14))
                }
                Button(action: move) {
                    Text("Move series").font(.subheadline.weight(.bold)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(Eclipse.highlight, in: RoundedRectangle(cornerRadius: 14))
                }
                .accessibilityIdentifier("confirmMigrate")
            }
            .buttonStyle(PressableStyle())
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Eclipse.surface.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

/// Global search from anywhere in the app (the library's search box, say).
struct GlobalSearchSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = GlobalSearchModel()
    @State private var query: String
    @State private var busyID: String?
    @State private var opened: MangaSeries?
    @State private var error: String?
    /// Search the novel sources instead (with the title in its own language for Japanese sites).
    let novels: Bool
    let nativeQuery: String?
    @State private var browsing: BrowseTarget?
    @AppStorage(Features.booksKey) private var booksOn = false
    init(query: String, novels: Bool = false, nativeQuery: String? = nil) {
        _query = State(initialValue: query); self.novels = novels; self.nativeQuery = nativeQuery
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Title", text: $query).submitLabel(.search).onSubmit(run)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    .padding(.horizontal, 14).frame(height: 50).eclipseCard(cornerRadius: 14)
                    HStack { Spacer(); SearchSitesMenu(search: search) }
                    if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
                    if !novels, booksOn, !search.query.isEmpty {
                        BooksBrowseSection(browsing: $browsing, opened: $opened, externalQuery: search.query)
                    }
                    GlobalSearchResults(search: search, busyID: busyID) { item in open(item) }
                }
                .padding(20).frame(maxWidth: 900).frame(maxWidth: .infinity)
            }
            .background(EclipseBackground())
            .navigationTitle("Search everywhere").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { search.cancel(); dismiss() }.fontWeight(.semibold) }
            .task { if search.sections.isEmpty { run() } }
            .fullScreenCover(item: $browsing) { target in MangaBrowserView(start: target.url).environmentObject(model) }
            .sheet(item: $opened) { series in SeriesSheet(series: series).environmentObject(model) }
        }
        .preferredColorScheme(.dark)
    }
    private func run() {
        error = nil
        if novels {
            var queries: [String: String] = [:]
            if let native = nativeQuery { for id in ["syosetu", "kakuyomu"] { queries[id] = QuoteFeed.searchable(native: native) } }
            search.run(query, sources: GlobalSearchModel.sources(saved: model.state.sites ?? [], novels: true), queries: queries)
        } else {
            search.run(query, sources: GlobalSearchModel.sources(saved: model.sources) + (Features.novelsOn ? GlobalSearchModel.sources(saved: model.sources, novels: true) : []))
        }
    }
    private func open(_ item: DiscoverItem) {
        if let owned = model.series(id: item.id) ?? model.allSeries.first(where: { $0.url == item.url }) { opened = owned; return }
        guard busyID == nil else { return }
        busyID = item.id
        Task {
            defer { busyID = nil }
            do {
                if case .series(let series, _) = try await model.addLink(item.url.absoluteString, title: item.title, addToShelf: false) { opened = series }
            } catch { self.error = "Couldn’t open \(item.title): \(error.localizedDescription)" }
        }
    }
}

/// "Similar series": what AniList readers recommend for this one (Neko-style), best rated first.
/// Tap one to find it on every site.
struct SimilarSheet: View {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State private var items: [AniListMedia] = []
    @State private var matched: String?
    @State private var loading = true
    @State private var failure: String?
    @State private var searching: LibraryView.QuoteSearch?
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let columns = max(2, Int((geometry.size.width - 24) / 128))
                ScrollView {
                    if loading {
                        ProgressView().padding(.top, 60).frame(maxWidth: .infinity)
                    } else if let failure {
                        ContentUnavailableView("Couldn’t load recommendations", systemImage: "wifi.exclamationmark", description: Text(failure))
                    } else if items.isEmpty {
                        ContentUnavailableView("No recommendations yet", systemImage: "sparkles",
                                               description: Text("AniList readers haven’t recommended anything for \(matched ?? title) yet."))
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columns), spacing: 16) {
                            ForEach(items) { item in
                                Button { searching = LibraryView.QuoteSearch(query: item.title) } label: { card(item) }
                                    .buttonStyle(PressableStyle())
                            }
                        }
                        .padding(12)
                        Text("Recommendations from AniList readers. Tap one to find it on every site.")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 20)
                    }
                }
            }
            .background(EclipseBackground())
            .navigationTitle("Like \(matched ?? title)").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $searching) { item in GlobalSearchSheet(query: item.query).environmentObject(model) }
            .task { await load() }
        }
    }
    private func card(_ item: AniListMedia) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            CoverView(url: item.cover, referer: nil)
                .aspectRatio(0.7, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    if let score = item.score {
                        Text("\(score)%").font(.caption2.weight(.heavy)).monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.7), in: Capsule()).padding(6)
                    }
                }
            Text(item.title).font(.footnote.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
            Text([item.kind, item.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
    }
    private func load() async {
        defer { loading = false }
        do {
            let data = try await AniList.post(AniListAPI.similarQuery, variables: ["search": title], auth: false)
            let result = try AniListAPI.parseSimilar(data)
            matched = result.matched
            items = result.items
        } catch {
            failure = error.localizedDescription
        }
    }
}


/// The one place to choose which sites a search uses: a checklist in a dropdown beside the results.
struct SearchSitesMenu: View {
    @ObservedObject var search: GlobalSearchModel
    var body: some View {
        let total = search.candidates.count
        let on = search.candidates.filter { !search.excluded.contains($0.id) }.count
        Menu {
            Button("All sites", systemImage: "checkmark.circle") { search.setAll(true) }
            Button("No sites", systemImage: "circle") { search.setAll(false) }
            Divider()
            ForEach(search.candidates) { source in
                Toggle(isOn: Binding(get: { !search.excluded.contains(source.id) },
                                     set: { search.setIncluded(source, $0) })) {
                    Text(source.name)
                    Text(source.host)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(on == total ? "All \(total) sites" : "\(on) of \(total) sites")
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Eclipse.surfaceHigh, in: Capsule())
        }
        .menuActionDismissBehavior(.disabled)
        .disabled(total == 0)
        .accessibilityLabel("Sites to search")
    }
}

/// Text first, icon after it (for "Try in browser ▾").
struct TrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.title; configuration.icon.font(.caption2.weight(.bold)) }
    }
}
