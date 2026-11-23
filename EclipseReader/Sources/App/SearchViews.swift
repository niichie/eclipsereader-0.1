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
    private var tasks: [Task<Void, Never>] = []

    /// MangaDex, WeebCentral and WEBTOON, then the user's saved sites and the popular sites.
    static func sources(saved: [SavedSite]) -> [SearchSource] {
        var list: [SearchSource] = [
            SearchSource(name: "MangaDex", kind: .mangaDex),
            SearchSource(name: "WeebCentral", kind: .weebCentral),
            SearchSource(name: "WEBTOON", kind: .webtoons),
        ]
        var hosts = Set(list.map(\.host))
        for site in saved.map({ ($0.name, $0.url) }) + SiteCatalog.popular.map({ ($0.name, $0.url) }) {
            let source = SearchSource(name: site.0, kind: .site(site.1))
            guard !source.host.isEmpty, !source.host.hasSuffix("webtoons.com"), hosts.insert(source.host).inserted else { continue }
            list.append(source)
        }
        return list
    }

    func run(_ text: String, sources: [SearchSource]) {
        cancel()
        query = text
        sections = sources.map { Section(source: $0, phase: .loading) }
        for source in sources {
            tasks.append(Task { [weak self] in
                let phase: Phase
                do {
                    var found = try await GlobalSearch.search(source, query: text)
                    if found.isEmpty, case .site = source.kind {
                        found = await Self.rendered(source, query: text)
                    }
                    phase = .done(found)
                } catch {
                    // Sites that only answer browsers: read their search page the way Safari would.
                    if case .site = source.kind {
                        let found = await Self.rendered(source, query: text)
                        phase = found.isEmpty ? .failed : .done(found)
                    } else {
                        phase = .failed
                    }
                }
                guard let self, !Task.isCancelled, self.query == text,
                      let i = self.sections.firstIndex(where: { $0.id == source.id }) else { return }
                self.sections[i].phase = phase
            })
        }
    }
    private static func rendered(_ source: SearchSource, query: String) async -> [DiscoverItem] {
        guard case .site(let root) = source.kind, let url = GlobalSearch.searchURLs(root: root, query: query).last,
              let html = try? await PageRenderer.html(for: url, timeout: 15) else { return [] }
        return GlobalSearch.results(in: html, base: url)
    }
    func cancel() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }
    var finished: Bool { !sections.contains { $0.phase == .loading } }
}

/// Mihon-style global search: one row of covers per source, empty sources folded into a footnote.
struct GlobalSearchResults: View {
    @EnvironmentObject private var library: LibraryModel
    @ObservedObject var search: GlobalSearchModel
    /// Shows a busy overlay on the item being added or opened.
    var busyID: String?
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
                            card(title: item.title, cover: item.cover, detail: item.detail,
                                 owned: library.allSeries.contains { $0.url == item.url }, busy: busyID == item.id, referer: nil) {
                                pick(item)
                            }
                        }
                    }
                default:
                    EmptyView()
                }
            }
            let empty = search.sections.filter { if case .done(let items) = $0.phase { return items.isEmpty } else { return $0.phase == .failed } }
            if !empty.isEmpty && search.finished {
                Text("No matches on " + empty.map(\.source.name).joined(separator: ", ") + ".")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
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
                CoverView(url: cover, referer: referer)
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
    init(query: String) { _query = State(initialValue: query) }
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
                    if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
                    GlobalSearchResults(search: search, busyID: busyID) { item in open(item) }
                }
                .padding(20).frame(maxWidth: 900).frame(maxWidth: .infinity)
            }
            .background(EclipseBackground())
            .navigationTitle("Search everywhere").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { search.cancel(); dismiss() }.fontWeight(.semibold) }
            .task { if search.sections.isEmpty { run() } }
            .sheet(item: $opened) { series in SeriesSheet(series: series).environmentObject(model) }
        }
        .preferredColorScheme(.dark)
    }
    private func run() {
        error = nil
        search.run(query, sources: GlobalSearchModel.sources(saved: model.state.sites ?? []))
    }
    private func open(_ item: DiscoverItem) {
        if let owned = model.series(id: item.id) ?? model.allSeries.first(where: { $0.url == item.url }) { opened = owned; return }
        guard busyID == nil else { return }
        busyID = item.id
        Task {
            defer { busyID = nil }
            do {
                if case .series(let series, _) = try await model.addLink(item.url.absoluteString) { opened = series }
            } catch { self.error = "Couldn’t add \(item.title): \(error.localizedDescription)" }
        }
    }
}
