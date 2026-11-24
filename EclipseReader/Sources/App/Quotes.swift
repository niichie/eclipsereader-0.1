import SwiftUI

/// Finds the launch card: a quote from a live anime-quote database (or the built-in list), checked on
/// AniList so it only ever recommends manga readers rate highly, with its cover and score.
@MainActor
final class SpotlightStore: ObservableObject {
    static let shared = SpotlightStore()
    @Published private(set) var manga: Spotlight?
    @Published private(set) var loadingManga = false
    private var mangaQueue: [Spotlight] = []

    private static let recentKey = "spotlightRecent"
    private static let animeChanKey = "animeChanCalls"
    /// Series shown lately (so the card keeps introducing new ones).
    private var recent: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.suffix(80)), forKey: Self.recentKey) }
    }
    private func remember(_ works: String...) {
        recent += works.map(QuoteFeed.workKey).filter { !$0.isEmpty }
    }

    // MARK: Manga

    /// Your kinds changed (the setup): start over with suggestions that fit.
    func reset() {
        manga = nil
        mangaQueue = []
    }
    func loadManga(owned: Set<String>) async {
        guard manga == nil, !loadingManga else { return }
        await refillManga(owned: owned)
        showNextManga()
    }
    func nextManga(owned: Set<String>) async {
        if mangaQueue.isEmpty { await refillManga(owned: owned) }
        showNextManga()
    }
    private func showNextManga() {
        guard !mangaQueue.isEmpty else { return }
        let next = mangaQueue.removeFirst()
        manga = next
        remember(next.quote.work, next.work)
    }
    private func refillManga(owned: Set<String>) async {
        loadingManga = true
        defer { loadingManga = false }
        var skip = Set(recent).union(owned)
        for item in mangaQueue + [manga].compactMap({ $0 }) { skip.insert(QuoteFeed.workKey(item.quote.work)) }
        // Live lines (two databases at once), then the built-in list as a backup.
        let batchTask = Task { try? await withDeadline(6) { try await QuoteFeed.yurippe(count: 30) } }
        let chanTask: Task<LaunchQuote?, Never>? = animeChanAllowed()
            ? Task { try? await withDeadline(6) { try await QuoteFeed.animeChan() } } : nil
        let chanQuote: LaunchQuote? = await chanTask?.value ?? nil
        let live = [chanQuote].compactMap { $0 } + ((await batchTask.value) ?? [])
        let fresh = QuoteFeed.candidates(live, skipping: skip, limit: 9)
        let taken = skip.union(fresh.map { QuoteFeed.workKey($0.work) })
        let curated = QuoteFeed.candidates(CuratedQuotes.shuffled(CuratedQuotes.manga), skipping: taken, limit: 12 - fresh.count)
        // Only what you're into (the setup's kinds and countries).
        let preference = SpotlightPreference(categories: Interests.categories, origins: Interests.origins)
        var rated = await QuoteFeed.rate(fresh + curated, curated: Set(curated), preference: preference)
        // Different quotes can lead to the same series under another name: keep the first.
        var seen = Set<Int>()
        rated = rated.filter { $0.media.map { seen.insert($0.id).inserted } ?? true }
            .filter { item in item.media.map { !owned.contains(QuoteFeed.workKey($0.title)) } ?? true }
        // Quote databases are mostly anime (so manga): manhwa, manhua, webtoon and novel readers, or anyone whose quotes ran
        // thin, also get top-rated picks of their kinds.
        let thin = rated.count < 4
        if thin || !preference.categories.isDisjoint(with: [.manhwa, .manhua, .webtoons, .novels]) {
            let picks = await QuoteFeed.picks(preference, page: Int.random(in: 1...4)).filter { pick in
                let key = QuoteFeed.workKey(pick.work)
                return !skip.contains(key) && !owned.contains(key) && !(pick.media.map { seen.contains($0.id) } ?? false)
            }
            rated = Self.interleave(rated, Array(picks.prefix(thin ? 8 : 4)), every: thin ? 1 : 2)
        }
        if rated.isEmpty && preference.categories.contains(.manga) {
            // Everything shown lately: start the cycle over rather than show nothing.
            recent = []
            rated = CuratedQuotes.shuffled(CuratedQuotes.manga).filter(QuoteFeed.usable).prefix(6).map { Spotlight(quote: $0, media: nil) }
        }
        mangaQueue += rated
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
    let spotlight: Spotlight
    let width: CGFloat
    var owned = false
    var busy = false
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
        let cover = CGSize(width: compact ? 56 : 74, height: compact ? 80 : 106)
        HStack(alignment: .top, spacing: compact ? 12 : 14) {
            if width >= 330, let url = spotlight.media?.cover {
                CoverView(url: url, referer: nil)
                    .frame(width: cover.width, height: cover.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: compact ? 5 : 7) {
                Text(spotlight.pick ? quote.text : "“\(quote.text)”")
                    .font(spotlight.pick ? .system(compact ? .subheadline : .title3, design: .serif).weight(.semibold)
                                         : .system(compact ? .subheadline : .title3, design: .serif).italic().weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(compact ? 4 : 5)
                    .fixedSize(horizontal: false, vertical: true)
                Text(quote.who.isEmpty || quote.who == quote.work ? quote.work : "\(quote.who) · \(quote.work)")
                    .font(.caption.weight(.semibold)).foregroundStyle(Eclipse.highlight.opacity(0.9)).lineLimit(1)
                if let meta {
                    Text(meta).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
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
                        Image(systemName: "shuffle").font(.caption.weight(.bold))
                            .frame(width: 30, height: 30).background(Color.white.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(PressableStyle())
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
        .id(spotlight.id)
        .transition(.opacity)
        .contextMenu {
            Button(action: read) { Label(actionTitle, systemImage: "book") }
            Button(action: next) { Label("Another series", systemImage: "shuffle") }
            Button(action: close) { Label("Close for now", systemImage: "xmark") }
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
