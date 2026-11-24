import SwiftUI

/// Finds the launch card: a quote from a live anime-quote database (or the built-in list), checked on
/// AniList so it only ever recommends manga readers rate highly, with its cover and score.
@MainActor
final class SpotlightStore: ObservableObject {
    static let shared = SpotlightStore()
    @Published private(set) var manga: Spotlight?
    @Published private(set) var book: Spotlight?
    @Published private(set) var loadingManga = false
    @Published private(set) var loadingBook = false
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
        var rated = await QuoteFeed.rate(fresh + curated, curated: Set(curated))
        // Different quotes can lead to the same series under another name: keep the first.
        var seen = Set<Int>()
        rated = rated.filter { $0.media.map { seen.insert($0.id).inserted } ?? true }
            .filter { item in item.media.map { !owned.contains(QuoteFeed.workKey($0.title)) } ?? true }
        if rated.isEmpty {
            // Everything shown lately: start the cycle over rather than show nothing.
            recent = []
            rated = CuratedQuotes.shuffled(CuratedQuotes.manga).filter(QuoteFeed.usable).prefix(6).map { Spotlight(quote: $0, media: nil) }
        }
        mangaQueue += rated
    }
    /// AnimeChan allows 5 requests an hour without a key: ask it at most 4 times an hour.
    private func animeChanAllowed() -> Bool {
        let now = Date().timeIntervalSince1970
        let calls = (UserDefaults.standard.array(forKey: Self.animeChanKey) as? [Double] ?? []).filter { now - $0 < 3600 }
        guard calls.count < 4 else { return false }
        UserDefaults.standard.set(calls + [now], forKey: Self.animeChanKey)
        return true
    }

    // MARK: Books

    func loadBook(owned: Set<String>) async {
        guard book == nil, !loadingBook else { return }
        await nextBook(owned: owned)
    }
    func nextBook(owned: Set<String>) async {
        loadingBook = true
        defer { loadingBook = false }
        let skip = Set(recent).union(owned).union([book.map { QuoteFeed.workKey($0.quote.work) }].compactMap { $0 })
        let pool = CuratedQuotes.shuffled(CuratedQuotes.books)
        guard let quote = pool.first(where: { !skip.contains(QuoteFeed.workKey($0.work)) }) ?? pool.first else { return }
        remember(quote.work)
        // Free classics come from Standard Ebooks (one tap to download); others get a cover to look at.
        let found = try? await withDeadline(8) { try await FreeBooks.standardEbooks(query: quote.work) }
        if let free = found?.first(where: { Discover.sameTitle($0.title, quote.work) }) {
            book = Spotlight(quote: quote, media: SpotlightMedia(id: 0, title: free.title, cover: free.cover, score: nil,
                                                                 detail: [free.author, "Free from Standard Ebooks"].compactMap { $0 }.joined(separator: " · ")),
                             download: free.download)
            return
        }
        let cover = await BookCovers.candidates(title: quote.work, author: nil, isbn: nil).first
        book = Spotlight(quote: quote, media: cover.map { SpotlightMedia(id: 0, title: quote.work, cover: $0, score: nil, detail: "Book") })
    }
}

/// The launch card: a line from a top-rated series, its cover and score, and a button to start reading it.
/// Sized to the screen: compact on phones (and the Duo's front screen), roomier on iPad.
struct SpotlightCard: View {
    let spotlight: Spotlight
    var isBook = false
    let width: CGFloat
    var owned = false
    var busy = false
    let read: () -> Void
    let next: () -> Void
    let close: () -> Void

    private var compact: Bool { width < 520 }
    private var actionTitle: String {
        if owned { return "Open \(spotlight.work)" }
        if isBook { return spotlight.download != nil ? "Get it free" : "Find \(spotlight.work)" }
        return "Read \(spotlight.work)"
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
                Text("“\(quote.text)”")
                    .font(.system(compact ? .subheadline : .title3, design: .serif).italic().weight(.semibold))
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
                            else { Image(systemName: isBook && spotlight.download != nil && !owned ? "arrow.down" : "book.fill") }
                            Text(actionTitle).lineLimit(1)
                        }
                        .font(.caption.weight(.bold)).padding(.horizontal, 12).frame(height: 30)
                        .background(Eclipse.highlight, in: Capsule()).foregroundStyle(.black)
                    }
                    .buttonStyle(PressableStyle()).disabled(busy)
                    .accessibilityIdentifier(isBook ? "bookSpotlightRead" : "quoteRead")
                    Button(action: next) {
                        Image(systemName: "shuffle").font(.caption.weight(.bold))
                            .frame(width: 30, height: 30).background(Color.white.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel(isBook ? "Another book" : "Another series")
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
            Button(action: next) { Label(isBook ? "Another book" : "Another series", systemImage: "shuffle") }
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

/// First launch: choose what the library home shows. Everything here can be changed later in
/// Settings › Library.
struct HomeSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("libraryShowQuote") private var showQuote = true
    @AppStorage("libraryShowContinue") private var showContinue = true
    @AppStorage("libraryShowDiscover") private var showDiscover = false
    @AppStorage("libraryShowBecause") private var showBecause = false
    @AppStorage("homeSetupDone") private var done = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        EclipseWordmark(size: 24)
                        Text("Choose what your library home shows. You can change it any time in Settings › Library.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                }
                Section {
                    option($showQuote, "Quote of the launch", "A line from a top-rated manga, with a button to start reading it. A new one every launch.", "quote.opening")
                    option($showContinue, "Continue reading", "Pick up where you left off in one tap.", "play.circle")
                    option($showDiscover, "Popular on MangaDex", "A row of what everyone's reading right now.", "flame")
                    option($showBecause, "Because you read…", "Series like the one you read last.", "sparkles")
                }
            }
            .scrollContentBackground(.hidden).background(Eclipse.surface)
            .navigationTitle("Make it yours").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { done = true; dismiss() }.fontWeight(.semibold) }
            .interactiveDismissDisabled(false)
            .onDisappear { done = true }
        }
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
