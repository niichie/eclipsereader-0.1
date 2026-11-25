import SwiftUI
import ImageIO

enum QuoteDestination: Codable, Sendable {
    case manga(URL, LinkInspection)
    case novel(URL, NovelInfo)

    @MainActor func open(in model: LibraryModel) -> MangaSeries? {
        switch self {
        case .novel(let url, let info): return model.commitNovel(info.home ?? url, info, addToShelf: false)
        case .manga(let url, let info):
            if case .series(let series, _) = model.commit(url, info, addToShelf: false) { return series }
            return nil
        }
    }
}

struct VerifiedQuote: Codable, Sendable {
    let item: Spotlight
    let destination: QuoteDestination
    var checked = Date()
    var searchCover: URL?
    var thumbnail: Data?

    /// Finish choosing the artwork before the card enters the shuffle queue.
    func preparedCover(using pipeline: ImagePipeline) async -> Self {
        var card = self
        let chapter = Chapter(url: sourceURL, title: item.work, number: "")
        let cover = try? await withDeadline(2.5) { () async throws -> Data? in
            for url in coverURLs {
                try Task.checkCancellation()
                if let bytes = try? await pipeline.data(for: MangaPage(url: url, label: "Cover"), chapter: chapter),
                   let image = Self.thumbnailData(bytes) { return image }
            }
            return nil
        }
        if let cover { card.thumbnail = cover }
        return card
    }

    static func thumbnailData(_ bytes: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 300] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.85)
    }

    var sourceURL: URL {
        switch destination {
        case .manga(let url, _), .novel(let url, _): return url
        }
    }

    var coverURLs: [URL] {
        let sourceCover: URL?
        switch destination {
        case .manga(_, let info): sourceCover = info.cover
        case .novel(_, let info): sourceCover = info.cover
        }
        var seen = Set<URL>()
        return [item.media?.cover, sourceCover, searchCover].compactMap { $0 }.filter { seen.insert($0).inserted }
    }
}

actor QuoteCache {
    static let shared = QuoteCache()
    struct Snapshot: Codable {
        let settings: String
        let cards: [VerifiedQuote]
    }
    private let url: URL
    init(url: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("verified-spotlights-v2.json")) { self.url = url }
    func read(settings: String) -> [VerifiedQuote] {
        guard let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.settings == settings else { return [] }
        return snapshot.cards.filter { Date().timeIntervalSince($0.checked) < 12 * 3600 && QuoteFeed.fitsCard($0.item) }
    }
    func write(_ cards: [VerifiedQuote], settings: String) {
        try? JSONEncoder().encode(Snapshot(settings: settings, cards: cards)).write(to: url, options: .atomic)
    }
}

/// Finds the launch card: a quote from a live anime-quote database (or the built-in list), checked on
/// AniList so it only ever recommends manga readers rate highly, with its cover and score.
@MainActor
final class SpotlightStore: ObservableObject {
    static let shared = SpotlightStore()
    @Published private(set) var manga: Spotlight?
    @Published private(set) var loadingManga = false
    private var mangaQueue: [Spotlight] = []
    private var generation = UUID()
    private var ready: [VerifiedQuote] = []
    private(set) var current: VerifiedQuote?
    private var worker: Task<Void, Never>?
    private var cacheSettings: String?
    private let cache: QuoteCache
    init(cache: QuoteCache = .shared) { self.cache = cache }

    static func settings(for model: LibraryModel) -> String {
        let sources = model.sources.filter { $0.hidden == true || $0.url.host == "mangadot.net" }
            .map { $0.id + ($0.hidden == true ? "-hidden" : "-enabled") }
        return (Interests.categories.map(\.rawValue).sorted() + Interests.origins.sorted() + sources.sorted()).joined(separator: "|")
    }
    private(set) var openVerified: (() -> MangaSeries?)?

    private static let recentKey = "spotlightRecent"
    private static let animeChanKey = "animeChanCalls"
    /// Series shown lately (so the card keeps introducing new ones).
    private var recent: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? [] }
        // About 150 cards' worth, so the same series doesn't come back within a few days.
        set { UserDefaults.standard.set(Array(newValue.suffix(300)), forKey: Self.recentKey) }
    }
    private func remember(_ works: String...) {
        recent += works.map(QuoteFeed.workKey).filter { !$0.isEmpty }
    }

    // MARK: Manga

    /// Your kinds changed (the setup): start over with suggestions that fit.
    func reset() {
        worker?.cancel()
        worker = nil
        generation = UUID()
        loadingManga = false
        openVerified = nil
        manga = nil
        current = nil
        ready = []
        mangaQueue = []
        cacheSettings = nil
    }

    func loadManga(owned: Set<String>, model: LibraryModel) async {
        let settings = Self.settings(for: model)
        if cacheSettings != settings {
            reset()
            cacheSettings = settings
            let request = generation
            let cached = await cache.read(settings: settings)
            guard request == generation else { return }
            // Saved cards come back in a new order each launch, and never ones already shown: the card
            // on screen used to be saved too, so the same quotes returned at every launch.
            let shownWorks = Set(recent)
            let shownLines = Set(UserDefaults.standard.stringArray(forKey: "spotlightRecentLines") ?? [])
            ready = cached.filter { card in
                let work = QuoteFeed.workKey(card.item.work)
                return !owned.contains(work) && !shownWorks.contains(work) && !shownWorks.contains(QuoteFeed.workKey(card.item.quote.work))
                    && !shownLines.contains(QuoteFeed.workKey(card.item.quote.text))
            }.shuffled()
            if let fresh = ready.firstIndex(where: { !recent.contains(QuoteFeed.workKey($0.item.work)) }) {
                ready.swapAt(0, fresh)
            }
        }
        if manga == nil { await nextManga(owned: owned, model: model) }
    }

    func nextManga(owned: Set<String>, model: LibraryModel) async {
        guard !loadingManga else { return }
        ready.removeAll { owned.contains(QuoteFeed.workKey($0.item.work)) || Date().timeIntervalSince($0.checked) >= 12 * 3600 }
        if ready.isEmpty { loadingManga = true }
        else { showReady(model) }
        guard worker == nil, ready.count < 4 else { return }
        let request = generation
        worker = Task(priority: .utility) {
            defer { if generation == request { worker = nil; loadingManga = false } }
            var skip = owned.union(recent)
            if let current { skip.insert(QuoteFeed.workKey(current.item.work)) }
            // On a cold launch verify two local candidates while the live feeds are fetching.
            let bootstrap = mangaQueue.isEmpty && current == nil && Interests.categories.contains(.manga)
                && (Interests.origins.isEmpty || Interests.origins.contains("JP"))
            let seeds = bootstrap ? QuoteFeed.candidates(CuratedQuotes.shuffled(CuratedQuotes.manga), skipping: skip, limit: 2) : []
            let libraryTitles = model.libraryMembers.map(\.title)
            let feed = mangaQueue.isEmpty ? Task { await refillManga(owned: owned, library: libraryTitles) } : nil
            defer { feed?.cancel() }
            mangaQueue.insert(contentsOf: seeds.map { Spotlight(quote: $0, media: nil) }, at: 0)
            var fetched = false
            while ready.count < 4 && !Task.isCancelled && generation == request {
                if mangaQueue.isEmpty, !fetched, let feed {
                    let items = await feed.value
                    guard generation == request, !Task.isCancelled else { return }
                    mangaQueue = items
                    fetched = true
                }
                guard !mangaQueue.isEmpty else { break }
                let batch = Array(mangaQueue.prefix(2))
                mangaQueue.removeFirst(batch.count)
                await withTaskGroup(of: VerifiedQuote?.self) { group in
                    for candidate in batch {
                        let key = QuoteFeed.workKey(candidate.work)
                        let line = QuoteFeed.workKey(candidate.quote.text)
                        let lines = UserDefaults.standard.stringArray(forKey: "spotlightRecentLines") ?? []
                        guard skip.insert(key).inserted, !lines.contains(line),
                              !ready.contains(where: { QuoteFeed.workKey($0.item.work) == key }) else { continue }
                        group.addTask { [self] in
                            await verifiedDestination(candidate, model: model)
                        }
                    }
                    for await card in group {
                        guard generation == request, !Task.isCancelled else { group.cancelAll(); return }
                        guard let card else { continue }
                        ready.append(card)
                        if loadingManga { showReady(model) }
                        if let cacheSettings { await cache.write(ready, settings: cacheSettings) }
                    }
                }
            }
        }
    }

    private func showReady(_ model: LibraryModel) {
        let lastKind = UserDefaults.standard.string(forKey: "spotlightLastKind")
        let fresh = ready.indices.filter { !recent.contains(QuoteFeed.workKey(ready[$0].item.work)) }.shuffled()
        let index = fresh.first { (ready[$0].item.media?.category ?? .manga).rawValue != lastKind } ?? fresh.first ?? 0
        let card = ready.remove(at: index)
        let item = card.item
        current = card
        openVerified = { card.destination.open(in: model) }
        manga = item
        loadingManga = false
        remember(item.quote.work, item.work)
        let lines = UserDefaults.standard.stringArray(forKey: "spotlightRecentLines") ?? []
        UserDefaults.standard.set(Array((lines + [QuoteFeed.workKey(item.quote.text)]).suffix(400)), forKey: "spotlightRecentLines")
        UserDefaults.standard.set((item.media?.category ?? .manga).rawValue, forKey: "spotlightLastKind")
    }

    private func verifiedDestination(_ item: Spotlight, model: LibraryModel) async -> VerifiedQuote? {
        let novel = item.media?.category == .novels
        guard !novel || Features.novelsOn else { return nil }
        let sources = GlobalSearchModel.sources(saved: model.sources, novels: novel)
        let pipeline = model.pipeline
        var remaining = sources[...]
        while !remaining.isEmpty && !Task.isCancelled {
            let batch = remaining.prefix(6)
            remaining = remaining.dropFirst(batch.count)
            let found: VerifiedQuote? = await withTaskGroup(of: VerifiedQuote?.self) { group in
                for source in batch {
                    group.addTask {
                        try? await withDeadline(6) { try await Self.check(item, source: source, pipeline: pipeline) }
                    }
                }
                for await result in group {
                    if let result { group.cancelAll(); return Optional(result) }
                }
                return nil
            }
            if let found { return await found.preparedCover(using: pipeline) }
        }
        return nil
    }

    nonisolated private static func check(_ item: Spotlight, source: SearchSource, pipeline: ImagePipeline) async throws -> VerifiedQuote? {
        let query = source.novels ? item.media?.native ?? item.work : item.work
        let aliases = Set([item.work, item.quote.work, item.media?.native].compactMap { $0 }.map(QuoteFeed.workKey))
        let hits = try await GlobalSearch.search(source, query: query)
        for hit in hits.prefix(10) where aliases.contains(QuoteFeed.workKey(hit.title)) {
            try Task.checkCancellation()
            if source.novels {
                let novels = NovelSource()
                guard let info = try? await novels.info(hit.url), let first = info.chapters.first,
                      let text = try? await novels.chapter(first.url), !text.locked, !text.blocks(base: first.url).isEmpty else { continue }
                return VerifiedQuote(item: item, destination: .novel(hit.url, info), searchCover: hit.cover)
            }
            let reader = LinkedSource()
            guard let info = try? await reader.inspect(hit.url), let first = info.chapters.first,
                  let pages = try? await reader.pages(first.url), let page = pages.first,
                  let bytes = try? await pipeline.data(for: page, chapter: first),
                  let fallback = VerifiedQuote.thumbnailData(bytes) else { continue }
            return VerifiedQuote(item: item, destination: .manga(hit.url, info), searchCover: hit.cover, thumbnail: fallback)
        }
        return nil
    }

    private func refillManga(owned: Set<String>, library: [String]) async -> [Spotlight] {
        var skip = Set(recent).union(owned)
        for item in mangaQueue + [manga].compactMap({ $0 }) { skip.insert(QuoteFeed.workKey(item.quote.work)) }
        // Live lines (two databases at once), then the built-in list as a backup.
        let preference = SpotlightPreference(categories: Interests.categories, origins: Interests.origins)
        // Top-rated, popular, trending or fan-favourite series from a random page, and AniList readers'
        // recommendations for something in your library, so the card is a real "you might like this".
        async let picksTask = QuoteFeed.varietyPicks(preference)
        async let personalTask = QuoteFeed.personalPicks(seed: library.randomElement(), preference: preference)
        let batchTask = Task { try? await withDeadline(6) { try await QuoteFeed.yurippe(count: 30) } }
        let chanTask: Task<LaunchQuote?, Never>? = animeChanAllowed()
            ? Task { try? await withDeadline(6) { try await QuoteFeed.animeChan() } } : nil
        let chanQuote: LaunchQuote? = await chanTask?.value ?? nil
        let live = [chanQuote].compactMap { $0 } + ((await batchTask.value) ?? [])
        let fresh = QuoteFeed.candidates(live, skipping: skip, limit: 9)
        let taken = skip.union(fresh.map { QuoteFeed.workKey($0.work) })
        let curated = QuoteFeed.candidates(CuratedQuotes.shuffled(CuratedQuotes.manga), skipping: taken, limit: 12 - fresh.count)
        // Only what you're into (the setup's kinds and countries).
        var rated = await QuoteFeed.rate(fresh + curated, curated: Set(curated), preference: preference)
        // Different quotes can lead to the same series under another name: keep the first.
        var seen = Set<Int>()
        rated = rated.filter { $0.media.map { seen.insert($0.id).inserted } ?? true }
            .filter { item in item.media.map { !owned.contains(QuoteFeed.workKey($0.title)) } ?? true }
        // Quote databases are mostly anime (so manga): manhwa, manhua, webtoon and novel readers, or anyone whose quotes ran
        // thin, also get top-rated picks of their kinds.
        let personal = await personalTask.filter { pick in
            let key = QuoteFeed.workKey(pick.work)
            return !skip.contains(key) && !owned.contains(key) && !(pick.media.map { seen.contains($0.id) } ?? false)
        }
        for pick in personal { if let id = pick.media?.id { seen.insert(id) } }
        rated = Self.interleave(rated, Array(personal.prefix(4)), every: 2)
        let thin = rated.count < 4
        if thin || !preference.categories.isDisjoint(with: [.manhwa, .manhua, .webtoons, .novels]) {
            let picks = await picksTask.filter { pick in
                let key = QuoteFeed.workKey(pick.work)
                return !skip.contains(key) && !owned.contains(key) && !(pick.media.map { seen.contains($0.id) } ?? false)
            }
            rated = Self.interleave(rated, Array(picks.prefix(thin ? 8 : 4)), every: thin ? 1 : 2)
        }
        if rated.isEmpty && preference.categories.contains(.manga) {
            // Everything shown lately: start the cycle over rather than show nothing.
            rated = CuratedQuotes.shuffled(CuratedQuotes.manga).filter { QuoteFeed.usable($0) && !skip.contains(QuoteFeed.workKey($0.work)) }.prefix(6).map { Spotlight(quote: $0, media: nil) }
        }
        return rated
    }
    /// A pick after every `every` quotes, the rest at the end.
    static func interleave(_ quotes: [Spotlight], _ picks: [Spotlight], every: Int) -> [Spotlight] {
        var out: [Spotlight] = []
        var remaining = picks[...]
        for (i, quote) in quotes.enumerated() {
            out.append(quote)
            if (i + 1) % max(1, every) == 0, let pick = remaining.popFirst() { out.append(pick) }
        }
        return out + remaining
    }
    /// AnimeChan allows 5 requests an hour without a key: ask it at most 4 times an hour.
    private func animeChanAllowed() -> Bool {
        let now = Date().timeIntervalSince1970
        let calls = (UserDefaults.standard.array(forKey: Self.animeChanKey) as? [Double] ?? []).filter { now - $0 < 3600 }
        guard calls.count < 4 else { return false }
        UserDefaults.standard.set(calls + [now], forKey: Self.animeChanKey)
        return true
    }
}

/// The launch card: a line from a top-rated series, its cover and score, and a button to start reading it.
/// Sized to the screen: compact on phones (and the Duo's front screen), roomier on iPad.
struct SpotlightCard: View {
    let card: VerifiedQuote
    private var spotlight: Spotlight { card.item }
    let width: CGFloat
    var owned = false
    var busy = false
    var shuffling = false
    let read: () -> Void
    let next: () -> Void
    let close: () -> Void

    private var compact: Bool { width < 520 }
    private var actionTitle: String {
        owned ? "Open \(spotlight.work)" : "Read \(spotlight.work)"
    }
    private var meta: String? {
        guard let media = spotlight.media else { return nil }
        let score = media.score.map { "★ \($0)% on AniList" }
        let parts = [score, media.detail.isEmpty ? nil : media.detail].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    var body: some View {
        let quote = spotlight.quote
        let coverWidth: CGFloat = width < 330 ? 44 : (compact ? 56 : 74)
        HStack(alignment: .top, spacing: compact ? 12 : 14) {
            SpotlightCover(card: card)
                .id(card.item.id)
                .frame(width: coverWidth, height: coverWidth / 0.7)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: compact ? 5 : 7) {
                if spotlight.pick {
                    // A pick is a synopsis, not a quote: labelled, plain and smaller, and never cut off
                    // (picks only carry whole sentences of up to 140 characters).
                    Text("SYNOPSIS").font(.caption2.weight(.heavy)).tracking(1.2).foregroundStyle(.secondary)
                    Text(quote.text)
                        .font(compact ? .footnote : .body)
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("“\(quote.text)”")
                        .font(.system(compact ? .subheadline : .title3, design: .serif).italic().weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(compact ? 4 : 5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(quote.who.isEmpty || quote.who == quote.work ? quote.work : "\(quote.who) · \(quote.work)")
                    .font(.caption.weight(.semibold)).foregroundStyle(Eclipse.highlight.opacity(0.9)).lineLimit(1)
                if let meta { Text(meta).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                HStack(spacing: 8) {
                    Button(action: read) {
                        HStack(spacing: 5) {
                            if busy { ProgressView().controlSize(.mini).tint(.black) }
                            else { Image(systemName: "book.fill") }
                            Text(actionTitle).lineLimit(1)
                        }
                        .font(.caption.weight(.bold)).padding(.horizontal, 12).frame(height: 30)
                        .background(Eclipse.highlight, in: Capsule()).foregroundStyle(.black)
                    }
                    .buttonStyle(PressableStyle()).disabled(busy)
                    .accessibilityIdentifier("quoteRead")
                    Button(action: next) {
                        Group {
                            if shuffling { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "shuffle").font(.caption.weight(.bold)) }
                        }.frame(width: 30, height: 30).background(Color.white.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(shuffling)
                    .accessibilityLabel("Another series")
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    .frame(width: 26, height: 26).background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.vertical, compact ? 12 : 14).padding(.leading, compact ? 12 : 14).padding(.trailing, 8)
        .background(
            LinearGradient(colors: [Eclipse.accent.opacity(0.22), Eclipse.surface.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Eclipse.hairline))
        .contextMenu {
            Button(action: read) { Label(actionTitle, systemImage: "book") }
            Button(action: next) { Label("Another series", systemImage: "shuffle") }
            Button(action: close) { Label("Close for now", systemImage: "xmark") }
        }
    }
}

private struct SpotlightCover: View {
    let card: VerifiedQuote
    private let thumbnail: UIImage?

    init(card: VerifiedQuote) {
        self.card = card
        thumbnail = card.thumbnail.flatMap { UIImage(data: $0) }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Eclipse.accent, Eclipse.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(card.item.work).font(.system(size: 11, weight: .bold, design: .serif))
                .foregroundStyle(.white).multilineTextAlignment(.center).minimumScaleFactor(0.65).padding(4)
            if let thumbnail {
                Color.clear.overlay { Image(uiImage: thumbnail).resizable().scaledToFill() }.clipped()
            }
        }
    }
}

/// Holds the card's place while it loads, so the library doesn't jump when it arrives.
struct SpotlightPlaceholder: View {
    let width: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Eclipse.surface.opacity(0.7))
            .overlay(ShimmerView().clipShape(RoundedRectangle(cornerRadius: 16)))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Eclipse.hairline))
            .frame(height: width < 520 ? 108 : 134)
            .accessibilityHidden(true)
    }
}

/// First launch: what you read, where it's from, and what the library home shows. Everything here can be changed
/// later in Settings › Library.
struct HomeSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("libraryShowQuote") private var showQuote = true
    @AppStorage("libraryShowContinue") private var showContinue = true
    @AppStorage("libraryShowDiscover") private var showDiscover = false
    @AppStorage("libraryShowBecause") private var showBecause = false
    @AppStorage("homeSetupDone") private var done = false
    @AppStorage(Features.booksKey) private var books = false
    @AppStorage(Features.novelsKey) private var novels = false
    @State private var kinds: Set<SourceCategory> = Interests.categories
    @State private var origins: Set<String> = Interests.origins
    @State private var raws = Interests.raws
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        EclipseWordmark(size: 24)
                        Text("A few choices and the app fits what you read. Change any of it later in Settings › Library.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(SourceCategory.allCases.filter { $0 != .novels }) { kind in
                        option(Binding(get: { kinds.contains(kind) }, set: { on in if on { kinds.insert(kind) } else { kinds.remove(kind) } }),
                               kind.title, detail(kind), kind.symbol)
                    }
                } header: { Text("What are you into?") } footer: {
                    Text("Your picks come first in the library tabs and in Browse, and the launch card only suggests these.")
                }
                Section {
                    option($novels, "Light novels & web novels", "Novels too: Syosetu, Kakuyomu, Wuxiaworld or any novel site, set like a printed book.", "text.book.closed")
                    option($books, "Books", "Normal books (EPUB, Kindle, FB2, TXT…), set like a printed book. Adds a Books tab and free classics in Browse.", "books.vertical")
                } header: { Text("Reading beyond comics") } footer: {
                    Text("Both are optional; eclipsereader is a comics reader first.")
                }
                Section {
                    ForEach(Interests.allOrigins, id: \.code) { origin in
                        Toggle(origin.name, isOn: Binding(get: { origins.contains(origin.code) },
                                                          set: { on in if on { origins.insert(origin.code) } else if origins.count > 1 { origins.remove(origin.code) } }))
                            .tint(Eclipse.accent)
                    }
                    Toggle(isOn: $raws) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Raws too")
                            Text("Include novels in their original language.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.tint(Eclipse.accent)
                } header: { Text("Where from") } footer: {
                    Text("Steers suggestions on the launch card and Discover. Search still finds everything.")
                }
                Section {
                    option($showQuote, "Manga quote on launch", "A line from a top-rated series you're into each time you open the app, with a button to start reading it.", "quote.opening")
                    option($showContinue, "Continue reading", "Pick up where you left off in one tap.", "play.circle")
                    option($showDiscover, "Popular on MangaDex", "A row of what everyone's reading right now.", "flame")
                    option($showBecause, "Because you read…", "Series like the one you read last.", "sparkles")
                } header: { Text("Your library home") }
                Section {
                    NavigationLink { GuideView() } label: {
                        Label("Take the one-minute guide", systemImage: "questionmark.circle")
                    }
                } footer: {
                    Text("What every button and setting does. It's always in Settings › Guide.")
                }
            }
            .scrollContentBackground(.hidden).background(Eclipse.surface)
            .navigationTitle("Make it yours").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { finish(); dismiss() }.fontWeight(.semibold) }
            .onDisappear { finish() }
        }
    }
    private func detail(_ kind: SourceCategory) -> String {
        switch kind {
        case .manga: "Japanese comics, right to left with real page turns."
        case .manhwa: "Korean comics, one long vertical strip."
        case .manhua: "Chinese comics, vertical strips."
        case .webtoons: "Webcomics from WEBTOON, Tapas and more."
        case .comics: "Western comics, left to right."
        case .novels: ""
        }
    }
    private func finish() {
        var chosen = kinds
        if chosen.subtracting([.novels]).isEmpty { chosen.insert(.manga) }
        if novels { chosen.insert(.novels) } else { chosen.remove(.novels) }
        let changed = chosen != Interests.categories || origins != Interests.origins
        Interests.categories = chosen
        Interests.origins = origins
        Interests.raws = raws
        if changed { SpotlightStore.shared.reset() }
        done = true
    }
    private func option(_ value: Binding<Bool>, _ title: String, _ detail: String, _ symbol: String) -> some View {
        Toggle(isOn: value) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.title3).foregroundStyle(Eclipse.highlight).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(Eclipse.accent)
    }
}
