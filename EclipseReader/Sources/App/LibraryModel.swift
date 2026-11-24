import SwiftUI
import ImageIO

@MainActor
final class LibraryModel: ObservableObject {
    @Published var state: LibraryState
    @Published var loading = false
    @Published var error: String?
    @Published var persistenceError: String?
    /// Chapter ids saved for offline reading.
    @Published var downloaded: Set<String> = []
    /// Chapters queued or downloading, with progress 0...1 (or a failure message).
    @Published var downloads: [String: DownloadState] = [:]
    enum DownloadState: Equatable { case queued, running(Double), failed(String) }
    private var downloadQueue: [Chapter] = []
    private let pendingDownloadsKey = "EclipseReader.pendingChapterDownloads"
    private func pendingDownloads() -> [Chapter] {
        guard let data = UserDefaults.standard.data(forKey: pendingDownloadsKey) else { return [] }
        return (try? JSONDecoder().decode([Chapter].self, from: data)) ?? []
    }
    private func persistPending(_ chapters: [Chapter]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(chapters), forKey: pendingDownloadsKey)
    }
    private func forgetPending(_ id: String) { persistPending(pendingDownloads().filter { $0.id != id }) }
    @Published var bookmarkReturn: Bookmark?
    /// A page sent to the app (eclipsereader://open?url=…) to open in the browser.
    @Published var incoming: BrowseTarget?
    /// A note for the series page that opens next ("added from WeebCentral instead"), keyed by series.
    @Published var notice: (seriesID: String, text: String)?
    /// A chapter to open right away (Siri "Continue reading", Handoff from another device).
    @Published var requestedChapter: Chapter?
    /// A series to show (Spotlight).
    @Published var requestedSeriesID: String?
    /// Website series whose chapter list was refreshed since launch.
    var sessionRefreshed = Set<String>()
    private var downloadTask: Task<Void, Never>?
    let source: any MangaSource
    let pipeline: ImagePipeline
    private let repository: StateRepository
    private var refreshing = false
    init() {
        var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EclipseReader", isDirectory: true)
        #if DEBUG
        let testingReader = ProcessInfo.processInfo.arguments.contains("--reader-regression") || ReaderTestFixture.demo
        if testingReader { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
        #endif
        let repo = StateRepository(url: root.appendingPathComponent("library-v1.json"))
        var restored = LibraryState()
        var recoveryMessage: String?
        do { restored = try repo.load() }
        catch {
            let backup = root.appendingPathComponent("unreadable-\(UUID().uuidString).json")
            do {
                try FileManager.default.copyItem(at: repo.url, to: backup)
                recoveryMessage = "Saved progress could not be read. A backup of the unreadable file was preserved."
            } catch {
                recoveryMessage = "Saved progress could not be read or backed up. Check available device storage."
            }
        }
        if restored.showsBerserk == nil {
            restored.showsBerserk = restored.favorites?.contains(Self.berserkID) == true || restored.categories?.contains(where: { $0.seriesIDs.contains(Self.berserkID) }) == true || restored.chapters.contains { chapter in
                restored.progress[chapter.id] != nil || restored.lastChapterID == chapter.id
                    || restored.bookmarks?.contains(where: { mark in mark.chapterID == chapter.id }) == true
            }
            restored.sites?.removeAll { $0.bundledID == "readberserk" && $0.url == ReadBerserkParser.home && $0.name == "ReadBerserk" }
        }
        // Links added by an earlier build were single chapters; keep them as one-chapter series.
        if let shelf = restored.shelf, !shelf.isEmpty {
            let migrated = shelf.map { MangaSeries(id: "web-" + $0.id, url: $0.url, title: $0.title, kind: .web, chapters: [$0]) }
            restored.series = migrated + (restored.series ?? [])
            restored.shelf = nil
        }
        // One-time switch to the manga-first defaults (page turn, Japanese swipe direction).
        if (restored.defaultsVersion ?? 0) < 2 {
            restored.preferences.advanceOnLeftSwipe = false
            restored.preferences.transition = .curl
            restored.defaultsVersion = 2
        }
        // v3: an over-eager page-shape check could mark manga (including Berserk) as webtoons.
        // Forget those guesses; real webtoons are re-detected from their strips or site tags.
        if (restored.defaultsVersion ?? 0) < 3 {
            restored.detectedStyles = restored.detectedStyles?.filter { $0.key != Self.berserkID && $0.value != .manhwa }
            restored.defaultsVersion = 3
        }
        // v4: earlier builds used a chapter page as the cover when a site hid its cover art.
        // Forget those so the series' real art is looked for again (pages stay as a fallback).
        if (restored.defaultsVersion ?? 0) < 4 {
            restored.series = restored.series?.map { item in
                var item = item
                if let cover = item.cover, Self.looksLikePage(cover) { item.cover = nil }
                return item
            }
            restored.coverChecked = nil
            restored.defaultsVersion = 4
        }
        // v5: share-card banners (…/og/…) were taken as covers; some sit behind a bot check and never load.
        if (restored.defaultsVersion ?? 0) < 5 {
            var reset: [String] = []
            restored.series = restored.series?.map { item in
                var item = item
                if let cover = item.cover, LinkedSource.isSocialCard(cover) { item.cover = nil; reset.append(item.id) }
                return item
            }
            restored.coverChecked = restored.coverChecked?.filter { !reset.contains($0) }
            restored.defaultsVersion = 5
        }
        #if DEBUG
        if ReaderTestFixture.demo { restored = ReaderTestFixture.demoState() }
        #endif
        repository = repo
        _state = Published(initialValue: restored)
        _persistenceError = Published(initialValue: recoveryMessage)
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EclipsePageCache", isDirectory: true)
        #if DEBUG
        if testingReader {
            let fixture = ReaderTestFixture()
            source = fixture
            pipeline = ImagePipeline(cache: DiskImageCache(directory: root.appendingPathComponent("cache")), http: fixture)
            if ProcessInfo.processInfo.arguments.contains("--slide") { state.preferences.transition = .slide }
        } else {
            source = ReadBerserkSource()
            pipeline = ImagePipeline(cache: DiskImageCache(directory: cache), localData: Self.readLocal)
        }
        #else
        source = ReadBerserkSource()
        pipeline = ImagePipeline(cache: DiskImageCache(directory: cache), localData: Self.readLocal)
        #endif
        Task { try? await pipeline.cache.prune() }
        Task {
            downloaded = await OfflineStore.shared.downloadedIDs()
            let pending = pendingDownloads().filter { !downloaded.contains($0.id) }
            persistPending(pending)
            download(pending)
        }
        Self.current = self
        NetworkWatch.shared.onChange = { [weak self] in self?.startDownloads() }
    }
    var preferences: ReaderPreferences {
        get { state.preferences }
        set { state.preferences = newValue; save() }
    }
    var lastChapter: Chapter? { (state.chapters + allSeries.flatMap(\.chapters)).first { $0.id == state.lastChapterID } }
    /// Everything the user added from links or Files, newest first.
    var allSeries: [MangaSeries] { state.series ?? [] }

    var libraryMembers: [MangaSeries] { allSeries.filter(\.isLibraryMember) }

    @discardableResult
    func addToLibrary(_ series: MangaSeries) -> MangaSeries {
        if series.id == Self.berserkID { state.showsBerserk = true; save(); return berserk }
        guard var records = state.series, let i = records.firstIndex(where: { $0.id == series.id }),
              !records[i].isLibraryMember else { return self.series(id: series.id) ?? series }
        records[i].inLibrary = true
        state.series = records
        save()
        return records[i]
    }

    // MARK: Library presentation

    static let berserkID = "berserk"
    /// The built-in ReadBerserk source, shown in the library like any other series.
    var berserk: MangaSeries {
        MangaSeries(id: Self.berserkID, url: ReadBerserkParser.home, title: "Berserk",
                    cover: state.covers?[Self.berserkID], kind: .web, chapters: state.chapters, added: .distantPast)
    }
    /// Berserk first, then everything the user added.
    var librarySeries: [MangaSeries] {
        let all = (state.showsBerserk == true ? [berserk] : []) + libraryMembers
        guard !showHidden, let hidden = state.hiddenSeries, !hidden.isEmpty else { return all }
        return all.filter { !hidden.contains($0.id) }
    }
    func series(id: String) -> MangaSeries? { id == Self.berserkID ? berserk : allSeries.first { $0.id == id } }
    func seriesID(for chapter: Chapter) -> String { series(containing: chapter)?.id ?? Self.berserkID }
    func cover(for series: MangaSeries) -> URL? {
        if let custom = state.customCovers?[series.id] { return custom }
        if brokenCovers.contains(series.id) { return state.covers?[series.id] == series.cover ? nil : state.covers?[series.id] }
        return series.cover ?? state.covers?[series.id]
    }
    /// Covers that failed to load this session; the next best cover is used instead.
    @Published private(set) var brokenCovers: Set<String> = []
    func coverFailed(_ series: MangaSeries) {
        guard !brokenCovers.contains(series.id), state.customCovers?[series.id] == nil else { return }
        brokenCovers.insert(series.id)
        if let auto = state.covers?[series.id], auto != series.cover {
            // The automatic cover failed too: forget it so a fresh one is found.
            state.covers?[series.id] = nil
        }
        coverAttempts.remove(series.id)
        Task { await ensureCovers() }
    }
    func ignoreRecommendationSeed(_ id: String) {
        state.ignoredRecommendationSeries = (state.ignoredRecommendationSeries ?? []).union([id])
        save()
    }
    func hideSuggestion(_ title: String) {
        state.hiddenRecommendationTitles = (state.hiddenRecommendationTitles ?? []).union([QuoteFeed.workKey(title)])
        save()
    }
    func lastRead(_ series: MangaSeries) -> Date? {
        series.chapters.compactMap { state.progress[$0.id]?.updated }.max()
    }
    func readCount(_ series: MangaSeries) -> Int {
        series.chapters.filter { state.progress[$0.id]?.completed == true }.count
    }

    // MARK: Reading style (manga / manhwa / comic)

    func styleOverride(_ seriesID: String) -> ReadingStyle { state.styleOverrides?[seriesID] ?? .automatic }
    func setStyle(_ style: ReadingStyle, for seriesID: String) {
        var map = state.styleOverrides ?? [:]
        map[seriesID] = style == .automatic ? nil : style
        state.styleOverrides = map
        save()
    }
    /// The style actually used: the user's choice, else what was detected, else manga.
    func style(for seriesID: String) -> ReadingStyle {
        if let chosen = state.styleOverrides?[seriesID], chosen != .automatic { return chosen }
        if seriesID == Self.berserkID { return .manga }
        if let found = state.detectedStyles?[seriesID], found != .automatic { return found }
        return .manga
    }
    func rememberDetected(_ style: ReadingStyle, for seriesID: String) {
        guard state.detectedStyles?[seriesID] != style else { return }
        var map = state.detectedStyles ?? [:]
        map[seriesID] = style
        state.detectedStyles = map
        save()
    }

    // MARK: Covers

    private var coverAttempts = Set<String>()
    /// Fills in missing covers from the first page of each series' first chapter, one at a time.
    nonisolated static func looksLikePage(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        if path.range(of: #"(chapter|episode|/ch[-_]?\d|/read/)"#, options: .regularExpression) != nil { return true }
        return url.lastPathComponent.range(of: #"^\d{1,4}[a-z]?\.(jpe?g|png|webp|avif)$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    func ensureCovers() async {
        #if DEBUG
        if ReaderTestFixture.demo { return }
        #endif
        for series in librarySeries where !coverAttempts.contains(series.id) && series.kind != .novel {
            let isWeb = series.kind == .web && series.id != Self.berserkID
            // Website series without the site's own cover art get one look for it (stored, so it
            // happens once), even if a first-page cover is already showing.
            let wantsArt = isWeb && series.cover == nil && state.customCovers?[series.id] == nil
                && !(state.coverChecked ?? []).contains(series.id) && !brokenCovers.contains(series.id)
            guard cover(for: series) == nil || wantsArt else { continue }
            coverAttempts.insert(series.id)
            if wantsArt {
                state.coverChecked = (state.coverChecked ?? []) + [series.id]
                if let art = await siteCover(series.url), var list = state.series,
                   let i = list.firstIndex(where: { $0.id == series.id }) {
                    list[i].cover = art
                    state.series = list
                    save()
                    continue
                }
                save()
                if cover(for: series) != nil { continue }
            }
            guard let first = series.chapters.first else { continue }
            guard let page = try? await pages(for: first).first else { continue }
            var map = state.covers ?? [:]
            map[series.id] = page.url
            state.covers = map
            save()
        }
    }
    /// The series' own cover art: read the page directly, or render it like Safari when the site
    /// only answers browsers (Asura and similar).
    private func siteCover(_ url: URL) async -> URL? {
        if let art = await LinkedSource().cover(of: url) { return art }
        guard let html = try? await PageRenderer.html(for: url, timeout: 18) else { return nil }
        return LinkedSource.cover(in: html, base: url)
    }
    func series(containing chapter: Chapter) -> MangaSeries? {
        allSeries.first { $0.chapters.contains { $0.id == chapter.id } }
    }
    /// Imported books, downloaded chapters and custom covers, all read from this device.
    nonisolated static let readLocal: @Sendable (URL) async throws -> Data = { url in
        if url.host == "offline" || url.host == "cover" { return try await OfflineStore.shared.data(url) }
        return try await LocalBooks.shared.data(url)
    }
    /// One entry point for every source, so the same reader handles all of them.
    /// Downloaded chapters are read from disk first, so they work offline.
    func pages(for chapter: Chapter) async throws -> [MangaPage] {
        if let index = downloadQueue.firstIndex(where: { $0.id == chapter.id }) {
            let next = downloadQueue.remove(at: index)
            downloadQueue.insert(next, at: 0)
        }
        if let offline = await OfflineStore.shared.pages(for: chapter) { return offline }
        return try await networkPages(for: chapter)
    }
    func repairOfflinePage(_ chapter: Chapter, index: Int) async throws {
        guard let offline = await OfflineStore.shared.pages(for: chapter), offline.indices.contains(index) else { throw SourceError.missingChapter }
        let remote = try await networkPages(for: chapter)
        guard remote.count == offline.count else { throw SourceError.unsupportedStructure }
        let page = remote[index]
        await pipeline.cache.remove(page.url)
        let bytes = try await pipeline.data(for: page, chapter: chapter)
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 32] as CFDictionary) != nil else { throw SourceError.invalidImage }
        try await OfflineStore.shared.repair(chapter.id, index: index, page: page, data: bytes)
        await pipeline.cache.remove(offline[index].url)
    }
    private func networkPages(for chapter: Chapter) async throws -> [MangaPage] {
        #if DEBUG
        if ReaderTestFixture.demo || chapter.url.host == "example.invalid" { return try await source.pages(for: chapter) }
        #endif
        if chapter.url.scheme == "eclipselib" { return try await LocalBooks.shared.pages(chapter) }
        if series(containing: chapter) != nil
            || ReadBerserkParser.normalize(chapter.url.absoluteString, relativeTo: ReadBerserkParser.home) == nil && chapter.url.host != "example.invalid" {
            if usesBrowserSession(chapter.url), source(for: chapter.url)?.native != true,
               let html = try? await PageRenderer.html(for: chapter.url), let pages = try? LinkedSource.detect(in: html, base: chapter.url), !pages.isEmpty {
                // Signed in on this site in the browser: what your account can see, through that session.
                return pages
            }
            do { return try await LinkedSource().pages(chapter.url) }
            catch let e as SourceError where e == .unsupportedStructure || e == .restricted {
                // Script-built or browser-only sites: render the page like Safari, then read its images.
                let html = try await PageRenderer.html(for: chapter.url)
                return try LinkedSource.detect(in: html, base: chapter.url)
            }
        }
        return try await source.pages(for: chapter)
    }
    /// Reads a link directly; if the site builds its pages with scripts (or only answers browsers),
    /// renders it in an off-screen web view and reads the result instead.
    private func inspectAny(_ url: URL) async throws -> LinkInspection {
        if usesBrowserSession(url), source(for: url)?.native != true {
            // A site you signed in to in the browser: read the page through that session.
            if let found = try? LinkedSource.analyze(html: await PageRenderer.html(for: url), url: url) { return found }
        }
        do { return try await LinkedSource().inspect(url) }
        catch let e as SourceError where e == .unsupportedStructure || e == .restricted {
            let html = try await PageRenderer.html(for: url)
            return try LinkedSource.analyze(html: html, url: url)
        }
    }
    /// Reads a series page without adding it (migration previews).
    func inspect(_ url: URL) async throws -> LinkInspection { try await inspectAny(url) }
    enum AddLinkError: LocalizedError {
        case invalid
        case noChapters(title: String, host: String)
        var errorDescription: String? {
            switch self {
            case .invalid: "Enter a full link (https://…) to a manga series page, a chapter, or an image."
            case .noChapters(let title, let host):
                "\(host) has no chapters you can read for “\(title)”, and it wasn’t found on the other sites either. Licensed series often only link to the official app."
            }
        }
    }
    enum LinkResult { case open(Chapter), series(MangaSeries, open: Chapter?) }
    /// Adds a whole series from a pasted link. A series page adds every chapter; a chapter
    /// page adds the series its chapter picker lists (when it has one) and opens that chapter.
    enum LinkPreview { case existing(LinkResult), fresh(URL, LinkInspection) }
    /// Reads a link without adding it, so the browser can show what would be added.
    /// `html` is the page as the in-app browser shows it right now: it has already passed any
    /// browser check and run its scripts, so it is read first (covers and chapter lists included).
    func preview(_ text: String, html: String? = nil) async throws -> LinkPreview {
        guard let url = WebLink.parse(text) else { throw AddLinkError.invalid }
        if let known = ReadBerserkParser.normalize(url.absoluteString, relativeTo: ReadBerserkParser.home) {
            if let chapter = state.chapters.first(where: { $0.url == known }) { return .existing(.open(chapter)) }
            if url.path.count > 1 { return .existing(.open(Chapter(url: known, title: "Berserk", number: ""))) }
            return .existing(.series(berserk, open: nil))
        }
        if let existing = allSeries.first(where: { $0.url == url }) { return .existing(.series(existing, open: nil)) }
        if let existing = allSeries.first(where: { $0.chapters.contains { $0.url == url } }) {
            return .existing(.series(existing, open: existing.chapters.first { $0.url == url }))
        }
        var live: LinkInspection?
        if let html, !Webtoons.handles(url), !MangaDex.handles(url) {
            do {
                let seen = try LinkedSource.analyze(html: html, url: url)
                if seen.chapters.count >= 2 || !seen.pages.isEmpty { live = seen }
            } catch SourceError.listing { throw SourceError.listing } catch {}
        }
        let found: LinkInspection
        if let live { found = live } else { found = try await inspectAny(url) }
        // The same series already added from another page of it (a chapter, say).
        let keys = Set(found.chapters.map { LinkedSource.key($0.url) })
        if keys.count >= 2, let existing = allSeries.first(where: { series in
            let overlap = series.chapters.filter { keys.contains(LinkedSource.key($0.url)) }.count
            return overlap * 2 >= min(keys.count, series.chapters.count) && overlap > 0
        }) {
            return .existing(.series(existing, open: nil))
        }
        return .fresh(url, found)
    }
    /// Adds a previewed series to the library.
    func commit(_ url: URL, _ found: LinkInspection, addToShelf: Bool = true) -> LinkResult {
        if let existing = allSeries.first(where: { $0.url == url }) { return .series(addToShelf ? addToLibrary(existing) : existing, open: nil) }
        // No cover art on the page: leave it empty so the library looks for the site's art later,
        // then falls back to a cropped first page.
        var series = MangaSeries(id: "web-" + url.absoluteString, url: url, title: found.title, cover: found.cover,
                                 kind: .web, chapters: found.chapters, summary: found.summary)
        series.inLibrary = addToShelf
        state.series = [series] + allSeries
        // The source's own setting wins, then what the page says, then what kind of source it is.
        let site = source(for: url)
        if let style = site?.style ?? found.style ?? site?.category?.style {
            var map = state.detectedStyles ?? [:]; map[series.id] = style; state.detectedStyles = map
        }
        save()
        // Open straight away only when the link itself was a chapter; a series page shows its chapter list.
        let here = LinkedSource.key(url)
        let opened = found.pages.isEmpty ? nil : series.chapters.first { LinkedSource.key($0.url) == here }
        return .series(series, open: opened)
    }
    /// `title`: the name a search result showed, cleaner than many series pages' headings.
    func addLink(_ text: String, html: String? = nil, title: String? = nil, addToShelf: Bool = true) async throws -> LinkResult {
        if let url = WebLink.parse(text), isNovel(url) {
            let series = try await addNovel(url, html: html, title: title, addToShelf: addToShelf)
            return .series(series, open: series.chapters.first { $0.url == url })
        }
        switch try await preview(text, html: html) {
        case .existing(.series(let series, let chapter)):
            return .series(addToShelf ? addToLibrary(series) : series, open: chapter)
        case .existing(let result): return result
        case .fresh(let url, var found):
            if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title != found.title {
                found = LinkInspection(title: title, cover: found.cover, pages: found.pages, chapters: found.chapters,
                                       style: found.style, summary: found.summary)
            }
            guard found.chapters.isEmpty && found.pages.isEmpty else { return commit(url, found, addToShelf: addToShelf) }
            // Nothing to read here (MangaDex only links licensed series to the publisher's app):
            // add the same series from a site that has its chapters.
            let host = url.host?.replacingOccurrences(of: "www.", with: "") ?? "This site"
            if let (other, otherFound) = await readableElsewhere(found.title, avoiding: url.host) {
                let result = commit(other, otherFound, addToShelf: addToShelf)
                if addToShelf, case .series(let series, _) = result {
                    notice = (series.id, "\(host) has no chapters to read for \(found.title), so it was added from \(other.host?.replacingOccurrences(of: "www.", with: "") ?? "another site") instead.")
                }
                return result
            }
            throw AddLinkError.noChapters(title: found.title, host: host)
        }
    }
    /// The same series on another connected or popular site, with chapters to read.
    func readableElsewhere(_ title: String, avoiding host: String?) async -> (URL, LinkInspection)? {
        let sources = GlobalSearchModel.sources(saved: state.sites ?? [])
            .filter { source in host.map { !$0.lowercased().hasSuffix(source.host) } ?? true }
        for source in sources {
            guard let hits = try? await GlobalSearch.search(source, query: title),
                  let match = hits.first(where: { Discover.sameTitle($0.title, title) }),
                  let found = try? await inspectAny(match.url), !found.chapters.isEmpty else { continue }
            return (match.url, found)
        }
        return nil
    }
    // MARK: Merging (fill missing chapters from another site)

    /// Finds the same series on another site and adds the chapters this one is missing.
    /// Returns how many were added and from where (nil when no site had any).
    func fillMissing(_ series: MangaSeries) async -> (count: Int, host: String)? {
        guard series.kind == .web, series.id != Self.berserkID else { return nil }
        let ownHost = series.url.host?.lowercased()
        let sources = GlobalSearchModel.sources(saved: state.sites ?? [])
            .filter { source in ownHost.map { !$0.hasSuffix(source.host) } ?? true }
        var best: (url: URL, chapters: [Chapter])?
        for source in sources {
            guard let hits = try? await GlobalSearch.search(source, query: series.title),
                  let match = hits.first(where: { Discover.sameTitle($0.title, series.title) }),
                  let found = try? await inspectAny(match.url) else { continue }
            let missing = ChapterMerge.missing(from: series.chapters, in: found.chapters)
            if missing.count > (best.map { ChapterMerge.missing(from: series.chapters, in: $0.chapters).count } ?? 0) {
                best = (match.url, found.chapters)
            }
        }
        guard let best, var list = state.series, let i = list.firstIndex(where: { $0.id == series.id }) else { return nil }
        let before = Set(list[i].chapters.map(\.id))
        list[i].merged = best.url
        list[i].chapters = ChapterMerge.combine(main: list[i].chapters, filler: best.chapters, fillerHost: best.url.host,
                                                keep: { self.state.progress[$0.id] != nil })
        state.series = list
        save()
        return (list[i].chapters.filter { !before.contains($0.id) }.count, best.url.host?.replacingOccurrences(of: "www.", with: "") ?? "another site")
    }
    func stopMerging(_ series: MangaSeries) {
        guard var list = state.series, let i = list.firstIndex(where: { $0.id == series.id }) else { return }
        let filler = list[i].merged?.host
        list[i].merged = nil
        list[i].chapters = list[i].chapters.filter { !ChapterMerge.isFiller($0, from: filler) || state.progress[$0.id] != nil }
        state.series = list
        save()
    }

    // MARK: Migration (a site died or moved)

    /// A chapter's number as a comparable key ("12", "12.5"), from its number or its title.
    nonisolated static func numberKey(_ chapter: Chapter) -> String? {
        if let n = Double(chapter.number) { return LinkedSource.format(n) }
        return ChapterOrder.number(ChapterText.split(chapter.title).name).map(LinkedSource.format)
    }
    /// How many chapters with reading progress have a matching chapter number in `found`.
    func migrationMatches(_ series: MangaSeries, to found: LinkInspection) -> (matched: Int, total: Int) {
        let targets = Set(found.chapters.compactMap(Self.numberKey))
        let tracked = series.chapters.filter { state.progress[$0.id] != nil }
        return (tracked.filter { Self.numberKey($0).map(targets.contains) ?? false }.count, tracked.count)
    }
    /// Moves a series to another site: its chapters become the new site's, reading progress follows
    /// each chapter by number, and the series keeps its place, cover choice and reading style.
    @discardableResult
    func migrate(_ old: MangaSeries, to target: URL, found: LinkInspection) -> Int {
        guard old.kind == .web, old.id != Self.berserkID, var list = state.series,
              let i = list.firstIndex(where: { $0.id == old.id }) else { return 0 }
        var byNumber: [String: Chapter] = [:]
        for chapter in found.chapters { if let key = Self.numberKey(chapter), byNumber[key] == nil { byNumber[key] = chapter } }
        var moved = 0
        for chapter in old.chapters {
            guard let progress = state.progress[chapter.id] else { continue }
            state.progress[chapter.id] = nil
            guard let key = Self.numberKey(chapter), let match = byNumber[key] else { continue }
            if let existing = state.progress[match.id], existing.updated > progress.updated { continue }
            state.progress[match.id] = progress
            if state.lastChapterID == chapter.id { state.lastChapterID = match.id }
            moved += 1
        }
        // Downloads belong to the old site's chapter addresses; free that space.
        for chapter in old.chapters where isDownloaded(chapter) { removeDownload(chapter) }
        let oldIDs = Set(old.chapters.map(\.id))
        state.newChapterIDs?.removeAll { oldIDs.contains($0) }
        list[i].url = target
        list[i].chapters = found.chapters
        list[i].cover = found.cover
        if list[i].summary == nil { list[i].summary = found.summary }
        state.series = list
        state.covers?[old.id] = nil
        state.coverChecked?.removeAll { $0 == old.id }
        coverAttempts.remove(old.id)
        if let style = found.style, state.styleOverrides?[old.id] == nil {
            var map = state.detectedStyles ?? [:]; map[old.id] = style; state.detectedStyles = map
        }
        sessionRefreshed.insert(old.id)
        save()
        return moved
    }
    /// The same site at a new address (asura.example → asura-new.example): every chapter address
    /// moves to the new domain and keeps its progress.
    @discardableResult
    func moveSite(_ old: MangaSeries, to address: String) -> Bool {
        guard old.kind == .web, old.id != Self.berserkID, let target = WebLink.parse(address), let newHost = target.host,
              let oldHost = old.url.host, var list = state.series, let i = list.firstIndex(where: { $0.id == old.id }) else { return false }
        let oldRoot = LinkedSource.root(oldHost)
        func swap(_ url: URL) -> URL {
            guard let host = url.host, LinkedSource.root(host) == oldRoot,
                  var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
            parts.host = newHost
            return parts.url ?? url
        }
        let chapters = old.chapters.map { Chapter(url: swap($0.url), title: $0.title, number: $0.number, published: $0.published) }
        for (before, after) in zip(old.chapters, chapters) where before.id != after.id {
            if let progress = state.progress[before.id] { state.progress[after.id] = progress; state.progress[before.id] = nil }
            if state.lastChapterID == before.id { state.lastChapterID = after.id }
            if let k = state.newChapterIDs?.firstIndex(of: before.id) { state.newChapterIDs?[k] = after.id }
            if isDownloaded(before) { removeDownload(before) }
        }
        list[i].url = swap(old.url)
        list[i].chapters = chapters
        if let cover = list[i].cover { list[i].cover = swap(cover) }
        state.series = list
        state.covers?[old.id] = nil
        coverAttempts.remove(old.id)
        save()
        return true
    }

    /// Re-reads a web series' chapter list and adds new chapters, keeping progress.
    func update(_ series: MangaSeries) async throws {
        if series.id == Self.berserkID { await refresh(); if let message = self.error { throw BookError.invalid(message) }; return }
        if series.kind == .novel {
            let fresh = try await updateNovel(series)
            markNew(fresh, in: series.id)
            save()
            return
        }
        guard series.kind == .web else { return }
        let found = try await inspectAny(series.url)
        guard var list = state.series, let i = list.firstIndex(where: { $0.id == series.id }) else { return }
        let known = Set(list[i].chapters.map { LinkedSource.key($0.url) })
        var fresh = found.chapters.filter { !known.contains(LinkedSource.key($0.url)) }
        if !fresh.isEmpty { list[i].chapters = ChapterOrder.sorted(list[i].chapters + fresh) }
        // A merged second site fills the gaps (and filler chapters give way once the main site has them).
        if let merged = list[i].merged, let other = try? await inspectAny(merged) {
            let before = Set(list[i].chapters.map(\.id))
            list[i].chapters = ChapterMerge.combine(main: list[i].chapters, filler: other.chapters, fillerHost: merged.host,
                                                    keep: { self.state.progress[$0.id] != nil })
            fresh += list[i].chapters.filter { !before.contains($0.id) && !fresh.contains($0) }
        }
        if list[i].cover == nil { list[i].cover = found.cover }
        if list[i].summary == nil { list[i].summary = found.summary }
        state.series = list
        if let style = found.style, state.detectedStyles?[series.id] == nil {
            var map = state.detectedStyles ?? [:]; map[series.id] = style; state.detectedStyles = map
        }
        markNew(fresh, in: series.id)
        save()
    }
    func importFiles(_ urls: [URL], copy: Bool, addToShelf: Bool = true) async throws -> MangaSeries {
        // Books (EPUB, MOBI, TXT…) join "Boring books without pictures"; everything else is read as pages.
        let books = urls.filter { BookFormat.from(fileExtension: $0.pathExtension) != nil }
        var first: MangaSeries?
        for book in books {
            let series = try await importBook(book, addToShelf: addToShelf)
            if first == nil { first = series }
        }
        let rest = urls.filter { BookFormat.from(fileExtension: $0.pathExtension) == nil }
        if rest.isEmpty, let first { return first }
        var series = try await LocalBooks.shared.importSeries(rest, copy: copy)
        series.inLibrary = addToShelf
        state.series = [series] + allSeries
        save()
        return series
    }
    func remove(_ series: MangaSeries) {
        if series.id == Self.berserkID { state.showsBerserk = false; save(); return }
        state.series = allSeries.filter { $0.id != series.id }
        state.styleOverrides?[series.id] = nil
        state.detectedStyles?[series.id] = nil
        state.covers?[series.id] = nil
        state.customCovers?[series.id] = nil
        for chapter in series.chapters where downloaded.contains(chapter.id) || downloads[chapter.id] != nil { removeDownload(chapter) }
        for chapter in series.chapters {
            state.progress[chapter.id] = nil
            if state.lastChapterID == chapter.id { state.lastChapterID = nil }
        }
        save()
        if series.kind == .local {
            let chapters = series.chapters
            Task { for c in chapters { await LocalBooks.shared.delete(c) } }
        }
        if series.kind == .book, let file = BookLink.file(of: series.url) {
            state.bookPositions?[series.id] = nil
            Task { await BookStore.shared.delete(file) }
        }
    }
    func rename(_ series: MangaSeries, to title: String) {
        guard var list = state.series, let i = list.firstIndex(where: { $0.id == series.id }),
              !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        list[i].title = title
        state.series = list
        save()
    }
    /// Chapter to resume in a series: the last one opened, else the first unfinished.
    func resume(_ series: MangaSeries) -> Chapter? {
        let opened = series.chapters.compactMap { c in state.progress[c.id].map { (c, $0.updated) } }.max { $0.1 < $1.1 }?.0
        if let opened, state.progress[opened.id]?.completed != true { return opened }
        if let opened, let i = series.chapters.firstIndex(of: opened), i + 1 < series.chapters.count { return series.chapters[i + 1] }
        return series.chapters.first { state.progress[$0.id]?.completed != true } ?? series.chapters.first
    }
    // MARK: New chapters and automatic checks

    func isNew(_ chapter: Chapter) -> Bool { state.newChapterIDs?.contains(chapter.id) == true }
    func newCount(_ series: MangaSeries) -> Int {
        guard let ids = state.newChapterIDs, !ids.isEmpty else { return 0 }
        let set = Set(ids)
        return series.chapters.filter { set.contains($0.id) }.count
    }
    var totalNew: Int { librarySeries.reduce(0) { $0 + newCount($1) } }
    /// New chapters found during the current update check, per series (for notifications).
    private var foundThisCheck: [String: (count: Int, latest: String?)] = [:]
    func markNew(_ fresh: [Chapter], in seriesID: String) {
        guard !fresh.isEmpty else { return }
        let previous = foundThisCheck[seriesID]?.count ?? 0
        foundThisCheck[seriesID] = (previous + fresh.count, fresh.last?.title)
        state.newChapterIDs = Array(Set((state.newChapterIDs ?? []) + fresh.map(\.id)))
        // Optionally download new chapters of series you have started.
        if state.autoDownloadNew == true, let started = self.series(id: seriesID), lastRead(started) != nil {
            download(fresh)
        }
    }
    func clearNew(_ series: MangaSeries) {
        let ids = Set(series.chapters.map(\.id))
        state.newChapterIDs?.removeAll { ids.contains($0) }
        save()
    }
    @Published var checking = false
    /// Checks Berserk and every website series for new chapters. Runs at most every 6 hours
    /// unless forced (pull to refresh), one series at a time to be gentle with the sites.
    func checkForUpdates(force: Bool = false) async {
        guard !checking else { return }
        #if DEBUG
        if ReaderTestFixture.demo { return }
        #endif
        if !force, let last = state.lastUpdateCheck, Date().timeIntervalSince(last) < 6 * 3600 { return }
        checking = true; defer { checking = false }
        foundThisCheck = [:]
        if state.showsBerserk == true { await refresh() }
        // Series you're reading first, so a short background window covers what matters most.
        let order = libraryMembers.filter { $0.isOnline && ($0.kind != .novel || Features.novelsOn) }
            .sorted { (lastRead($0) ?? .distantPast) > (lastRead($1) ?? .distantPast) }
        for series in order {
            try? await update(series)
            try? await Task.sleep(for: .milliseconds(400))
        }
        state.lastUpdateCheck = Date()
        save()
        if state.notifyNew == true {
            let updates = foundThisCheck.compactMap { id, found -> ChapterAlerts.Update? in
                guard let series = self.series(id: id) else { return nil }
                return ChapterAlerts.Update(seriesID: id, title: series.title, count: found.count, latest: found.latest)
            }
            await ChapterAlerts.post(updates)
        }
        foundThisCheck = [:]
    }

    // MARK: Background checks

    /// The model the app is running with, for background refreshes.
    static weak var current: LibraryModel?
    /// Runs when iOS wakes the app to look for new chapters.
    static func backgroundRefresh() async {
        ChapterAlerts.schedule()
        let model = current ?? LibraryModel()
        guard model.state.notifyNew == true else { return }
        await model.checkForUpdates(force: true)
    }
    /// Turns new-chapter alerts on (asking iOS for permission) or off.
    func setNotifications(_ on: Bool) async -> Bool {
        if on {
            guard await ChapterAlerts.requestPermission() else {
                state.notifyNew = false; save()
                return false
            }
            state.notifyNew = true
            ChapterAlerts.schedule()
        } else {
            state.notifyNew = false
            ChapterAlerts.cancelSchedule()
        }
        lastBadge = -1
        save()
        return true
    }
    private var lastBadge = -1
    private func updateBadge() {
        let count = state.notifyNew == true ? totalNew : 0
        guard count != lastBadge else { return }
        lastBadge = count
        Task { await ChapterAlerts.badge(count) }
    }

    // MARK: Offline downloads

    func isDownloaded(_ chapter: Chapter) -> Bool { downloaded.contains(chapter.id) }
    func canDownload(_ chapter: Chapter) -> Bool { chapter.url.scheme == "https" }
    func download(_ chapters: [Chapter]) {
        var pending = pendingDownloads()
        for chapter in chapters where canDownload(chapter) && !downloaded.contains(chapter.id) {
            if let status = downloads[chapter.id] {
                guard case .failed = status else { continue }
            }
            if !pending.contains(where: { $0.id == chapter.id }) { pending.append(chapter) }
            downloadQueue.append(chapter)
            downloads[chapter.id] = .queued
        }
        persistPending(pending)
        startDownloads()
    }
    /// Set while downloads wait for Wi-Fi (Settings › Downloads › Wi-Fi only).
    @Published var waitingForWiFi = false
    func startDownloads() {
        guard downloadTask == nil, !downloadQueue.isEmpty else { return }
        downloadTask = Task { [weak self] in
            while let self, !self.downloadQueue.isEmpty {
                if self.state.downloadWiFiOnly == true && NetworkWatch.shared.expensive {
                    self.waitingForWiFi = true
                    break
                }
                self.waitingForWiFi = false
                let next = self.downloadQueue.removeFirst()
                await self.runDownload(next)
            }
            self?.downloadTask = nil
        }
    }
    func cancelDownload(_ chapter: Chapter) {
        forgetPending(chapter.id)
        if case .failed = downloads[chapter.id] { Task { await OfflineStore.shared.remove(chapter.id) } }
        downloadQueue.removeAll { $0.id == chapter.id }
        downloads[chapter.id] = nil
    }
    func removeDownload(_ chapter: Chapter) {
        cancelDownload(chapter)
        downloaded.remove(chapter.id)
        Task { await OfflineStore.shared.remove(chapter.id) }
    }
    func removeAllDownloads() {
        persistPending([])
        downloadQueue.removeAll()
        downloads = [:]
        downloaded = []
        Task { await OfflineStore.shared.removeAll() }
    }
    private func runDownload(_ chapter: Chapter) async {
        guard downloads[chapter.id] != nil else { return }   // cancelled while queued
        downloads[chapter.id] = .running(0)
        do {
            if series(containing: chapter)?.kind == .novel {
                // A novel chapter is its text: one small file.
                try await downloadNovelChapter(chapter)
                forgetPending(chapter.id)
                downloaded.insert(chapter.id)
                downloads[chapter.id] = nil
                return
            }
            let pages = try await networkPages(for: chapter)
            guard !pages.isEmpty else { throw SourceError.unsupportedStructure }
            var files = try await OfflineStore.shared.resume(chapter.id, pages: pages)
            for (i, page) in pages.enumerated().dropFirst(files.count) {
                guard downloads[chapter.id] != nil else { throw CancellationError() }
                let data = try await pipeline.data(for: page, chapter: chapter)
                guard downloads[chapter.id] != nil else { throw CancellationError() }
                let name = try await OfflineStore.shared.write(chapter.id, index: i, data: data)
                files.append(name)
                downloads[chapter.id] = .running(Double(i + 1) / Double(pages.count))
            }
            try await OfflineStore.shared.finish(chapter.id, title: chapter.title, files: files, pages: pages)
            forgetPending(chapter.id)
            downloaded.insert(chapter.id)
            downloads[chapter.id] = nil
        } catch {
            if error is CancellationError { await OfflineStore.shared.remove(chapter.id) }
            if downloads[chapter.id] != nil {
                downloads[chapter.id] = .failed(error is CancellationError ? "Cancelled" : error.localizedDescription)
            }
        }
    }
    func downloadedCount(_ series: MangaSeries) -> Int { series.chapters.filter { downloaded.contains($0.id) }.count }

    /// Every chapter in the library with its series, for the Updates and History tabs.
    var chapterIndex: [String: (MangaSeries, Chapter)] {
        var map: [String: (MangaSeries, Chapter)] = [:]
        for series in librarySeries + allSeries.filter({ !$0.isLibraryMember }) { for chapter in series.chapters { map[chapter.id] = (series, chapter) } }
        return map
    }
    /// Forgets where you stopped in every chapter; finished chapters stay marked as read.
    func clearHistory() {
        state.progress = state.progress.filter { $0.value.completed }
        state.lastChapterID = nil
        state.historyCleared = Date()
        save()
    }
    func removeHistory(_ chapter: Chapter) {
        state.hiddenHistoryDates = (state.hiddenHistoryDates ?? [:]).merging([chapter.id: Date()]) { _, new in new }
        save()
    }
    /// Starts downloading the next two chapters after the one being read (Settings › Download ahead).
    func downloadAhead(after chapter: Chapter) {
        guard state.downloadAhead == true, state.incognito != true else { return }
        var upcoming: [Chapter] = []
        var cursor = chapter
        while upcoming.count < 2, let next = next(after: cursor) { upcoming.append(next); cursor = next }
        download(upcoming)
    }

    // MARK: Saved sites (Browse tab)

    func saveSite(name: String, url: URL) {
        guard WebLink.publicHTTPS(url) else { return }
        var sites = state.sites ?? []
        if let i = sites.firstIndex(where: { $0.owns(url) }) {
            // Already a source (maybe a hidden built-in one): show it again.
            if sites[i].hidden == true { sites[i].hidden = false; state.sites = sites; save() }
            return
        }
        let title = name.trimmingCharacters(in: .whitespaces)
        sites.append(SavedSite(name: title.isEmpty ? (url.host ?? "Site") : String(title.prefix(60)), url: url))
        state.sites = sites
        save()
    }
    func removeSite(_ site: SavedSite) { removeSource(site) }

    // MARK: Favourites and bookmarks

    func isFavorite(_ series: MangaSeries) -> Bool { state.favorites?.contains(series.id) == true }
    func toggleFavorite(_ series: MangaSeries) {
        var list = state.favorites ?? []
        if let i = list.firstIndex(of: series.id) { list.remove(at: i) } else { list.append(series.id) }
        state.favorites = list
        save()
    }
    func bookmarks(chapterID: String) -> [Bookmark] { (state.bookmarks ?? []).filter { $0.chapterID == chapterID } }
    func addBookmark(_ bookmark: Bookmark) {
        state.bookmarks = [bookmark] + (state.bookmarks ?? [])
        save()
    }
    func removeBookmark(_ bookmark: Bookmark) {
        state.bookmarks = (state.bookmarks ?? []).filter { $0.id != bookmark.id }
        save()
    }
    /// Sets things up so opening the bookmark's chapter lands on its spot, and returns the chapter to open.
    func prepareToOpen(_ bookmark: Bookmark, remember: Bool = true) -> Chapter? {
        guard let series = series(id: bookmark.seriesID), let chapter = series.chapters.first(where: { $0.id == bookmark.chapterID }) else { return nil }
        if remember {
            bookmarkReturn = nil
            if let last = lastChapter, let previous = self.series(id: seriesID(for: last)), let progress = state.progress[last.id] {
                let book = previous.isPlainBook ? state.bookPositions?[previous.id] : nil
                let novel = previous.isNovel ? state.novelPositions?[previous.id] : nil
                bookmarkReturn = Bookmark(seriesID: previous.id, chapterID: last.id, chapterTitle: last.title,
                                          page: progress.page, pageCount: progress.pageCount,
                                          offset: book?.offset ?? novel?.offset, section: book?.section)
            }
        }
        switch series.kind {
        case .novel:
            var map = state.novelPositions ?? [:]
            map[series.id] = NovelPosition(chapterID: chapter.id, offset: bookmark.offset ?? 0)
            state.novelPositions = map
        case .book:
            var map = state.bookPositions ?? [:]
            map[series.id] = BookPosition(section: bookmark.section ?? BookLink.section(of: chapter), offset: bookmark.offset ?? 0)
            state.bookPositions = map
        default:
            let completed = state.progress[chapter.id]?.completed == true
            state.progress[chapter.id] = ChapterProgress(page: bookmark.page, pageCount: max(bookmark.pageCount, bookmark.page + 1), completed: completed)
        }
        save()
        return chapter
    }
    /// A book file shelved with light novels (or back with books).
    func setLightNovel(_ on: Bool, _ series: MangaSeries) {
        guard var list = state.series, let i = list.firstIndex(where: { $0.id == series.id }) else { return }
        list[i].lightNovel = on
        state.series = list
        save()
    }

    // MARK: Covers chosen by the user

    func setCustomCover(_ url: URL?, for seriesID: String) {
        var map = state.customCovers ?? [:]
        map[seriesID] = url
        state.customCovers = map
        save()
    }
    /// Uses a page as the cover. The picture is saved on the device (cropped to a cover's shape
    /// when it's a tall webtoon strip), so it shows instantly and survives the site or a download going away.
    func chooseCoverPage(_ page: MangaPage, seriesID: String, chapter: Chapter? = nil) async throws {
        let source = chapter ?? series(id: seriesID)?.chapters.first ?? Chapter(url: page.url, title: "", number: "")
        let data = try await pipeline.data(for: page, chapter: source)
        let shaped = await Task.detached(priority: .userInitiated) { Self.coverShaped(data) }.value
        try await setCoverPhoto(shaped, for: seriesID)
    }
    /// Keeps the top of very tall images in cover proportions; other images are returned as they are.
    nonisolated static func coverShaped(_ data: Data) -> Data {
        guard let image = UIImage(data: data), let cg = image.cgImage, cg.height > Int(Double(cg.width) * 1.6),
              let top = cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width, height: Int(Double(cg.width) / 0.7))),
              let jpeg = UIImage(cgImage: top).jpegData(compressionQuality: 0.9) else { return data }
        return jpeg
    }
    func setCoverPhoto(_ data: Data, for seriesID: String) async throws {
        let url = try await OfflineStore.shared.saveCover(data, seriesID: seriesID)
        setCustomCover(url, for: seriesID)
    }
    /// The first pages of a series' first chapter, offered as cover choices.
    func coverChoices(_ series: MangaSeries) async -> [MangaPage] {
        guard let first = series.chapters.first, let pages = try? await pages(for: first) else { return [] }
        return Array(pages.prefix(12))
    }

    // MARK: Backup and restore (move your library between devices through Files / iCloud Drive)

    struct Backup: Codable {
        var version = 1
        var created = Date()
        var state: LibraryState
    }
    func backupFile() throws -> URL {
        var copy = state
        // Imported files live on this device only; their entries would not open elsewhere.
        copy.series = copy.series?.filter { $0.isOnline }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Backup(state: copy))
        let name = "eclipsereader-backup-\(Date().formatted(.iso8601.year().month().day())).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }
    /// Merges a backup: newer progress wins, missing series are added, nothing is deleted.
    func restore(from url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // A backup file is untrusted input: bounded size, and every address in it is re-validated.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= 20 * 1024 * 1024 else { throw BookError.invalid("That isn’t an eclipsereader backup (wrong size).") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(Backup.self, from: Data(contentsOf: url))
        var incoming = backup.state
        func safe(_ url: URL) -> Bool { WebLink.publicHTTPS(url) }
        incoming.series = incoming.series?.compactMap { series in
            guard series.isOnline, safe(series.url) else { return nil }
            var clean = series
            clean.chapters = series.chapters.filter { safe($0.url) }
            if let cover = clean.cover, !safe(cover) { clean.cover = nil }
            return clean
        }
        incoming.chapters = incoming.chapters.filter {
            ReadBerserkParser.normalize($0.url.absoluteString, relativeTo: ReadBerserkParser.home) != nil
        }
        incoming.covers = incoming.covers?.filter { safe($0.value) }
        var progressCount = 0
        for (id, p) in incoming.progress where (state.progress[id]?.updated ?? .distantPast) < p.updated {
            state.progress[id] = p; progressCount += 1
        }
        var added = 0
        for series in incoming.series ?? [] where !allSeries.contains(where: { $0.id == series.id }) {
            state.series = allSeries + [series]; added += 1
        }
        if state.chapters.isEmpty { state.chapters = incoming.chapters }
        state.preferences = incoming.preferences
        state.styleOverrides = (state.styleOverrides ?? [:]).merging(incoming.styleOverrides ?? [:]) { _, new in new }
        state.detectedStyles = (state.detectedStyles ?? [:]).merging(incoming.detectedStyles ?? [:]) { old, _ in old }
        state.covers = (state.covers ?? [:]).merging(incoming.covers ?? [:]) { old, _ in old }
        if let last = incoming.lastChapterID, (incoming.progress[last]?.updated ?? .distantPast) >= (state.progress[state.lastChapterID ?? ""]?.updated ?? .distantPast) {
            state.lastChapterID = last
        }
        save()
        return "Restored \(progressCount) reading position\(progressCount == 1 ? "" : "s") and \(added) series."
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true; loading = true; error = nil
        defer { refreshing = false; loading = false }
        do {
            let chapters = try await source.chapters()
            try Task.checkCancellation()
            let known = Set(state.chapters.map(\.id))
            let fresh = known.isEmpty ? [] : chapters.filter { !known.contains($0.id) }
            state.chapters = chapters; state.catalogUpdated = Date()
            markNew(fresh, in: Self.berserkID)
            save()
        } catch is CancellationError { }
        catch let e as URLError where e.code == .cancelled { }
        catch { self.error = error.localizedDescription }
    }
    func record(_ chapter: Chapter, page: Int, count: Int, completed: Bool = false) {
        if state.newChapterIDs?.contains(chapter.id) == true { state.newChapterIDs?.removeAll { $0 == chapter.id } }
        if state.incognito == true && !completed { return }
        if state.lastChapterID == chapter.id, let old = state.progress[chapter.id],
           old.page == page && old.pageCount == count && (!completed || old.completed) { return }
        let newlyFinished = completed && state.progress[chapter.id]?.completed != true
        state.record(chapter, page: page, count: count, completed: completed)
        if newlyFinished {
            var log = state.finishedLog ?? [:]
            log[Self.day(Date()), default: 0] += 1
            state.finishedLog = log
            if state.deleteAfterReading == true && isDownloaded(chapter) { removeDownload(chapter) }
            finishedChapter(chapter)
        }
        save()
    }
    /// Hook for tracking services when a chapter is finished.
    private func finishedChapter(_ chapter: Chapter) {
        Task { await AniList.chapterFinished(chapter, model: self) }
    }

    // MARK: Reading stats

    nonisolated static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    /// Adds reading time to today (the reader logs it between page turns, idle gaps capped).
    func logReading(seconds: Double) {
        guard seconds > 0.5, state.incognito != true else { return }
        var log = state.readingLog ?? [:]
        log[Self.day(Date()), default: 0] += seconds
        // Keep a year of days.
        if log.count > 400, let oldest = log.keys.sorted().first { log[oldest] = nil }
        state.readingLog = log
    }

    /// Marks every chapter of these series read, in one save, keeping "Continue reading" where it was.
    func markAllRead(_ list: [MangaSeries]) {
        let last = state.lastChapterID
        for series in list {
            for chapter in series.chapters where state.progress[chapter.id]?.completed != true {
                state.record(chapter, page: 0, count: 1, completed: true)
            }
            let ids = Set(series.chapters.map(\.id))
            state.newChapterIDs?.removeAll { ids.contains($0) }
        }
        state.lastChapterID = last
        save()
    }

    // MARK: Hidden series and categories

    /// Hidden series show only after Face ID / passcode in this session.
    @Published var showHidden = false
    func isHidden(_ series: MangaSeries) -> Bool { state.hiddenSeries?.contains(series.id) == true }
    func setHidden(_ hidden: Bool, _ series: MangaSeries) {
        var list = state.hiddenSeries ?? []
        list.removeAll { $0 == series.id }
        if hidden { list.append(series.id) }
        state.hiddenSeries = list
        save()
    }
    var categories: [LibraryCategory] { state.categories ?? [] }
    func addCategory(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !categories.contains(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) else { return }
        state.categories = categories + [LibraryCategory(name: clean)]
        save()
    }
    func removeCategory(_ category: LibraryCategory) {
        state.categories = categories.filter { $0.id != category.id }
        save()
    }
    func renameCategory(_ category: LibraryCategory, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, var list = state.categories, let i = list.firstIndex(where: { $0.id == category.id }) else { return }
        list[i].name = clean
        state.categories = list
        save()
    }
    func moveCategories(from: IndexSet, to: Int) {
        var list = categories
        list.move(fromOffsets: from, toOffset: to)
        state.categories = list
        save()
    }
    func isIn(_ category: LibraryCategory, _ series: MangaSeries) -> Bool {
        categories.first { $0.id == category.id }?.seriesIDs.contains(series.id) == true
    }
    func set(_ series: [MangaSeries], in category: LibraryCategory, _ member: Bool) {
        guard var list = state.categories, let i = list.firstIndex(where: { $0.id == category.id }) else { return }
        var ids = list[i].seriesIDs
        for item in series {
            ids.removeAll { $0 == item.id }
            if member { ids.append(item.id) }
        }
        list[i].seriesIDs = ids
        state.categories = list
        save()
    }
    func save() {
        do { try repository.save(state); persistenceError = nil }
        catch { persistenceError = "Progress could not be saved: \(error.localizedDescription)" }
        updateBadge()
    }
    func previous(before chapter: Chapter) -> Chapter? {
        if let series = self.series(containing: chapter) {
            guard let i = series.chapters.firstIndex(where: { $0.id == chapter.id }), i > 0 else { return nil }
            return series.chapters[i - 1]
        }
        guard let index = state.chapters.firstIndex(where: { $0.id == chapter.id }), index > 0 else { return nil }
        return state.chapters[index - 1]
    }
    func next(after chapter: Chapter) -> Chapter? {
        if let series = self.series(containing: chapter) {
            guard let i = series.chapters.firstIndex(where: { $0.id == chapter.id }), i + 1 < series.chapters.count else { return nil }
            return series.chapters[i + 1]
        }
        guard let index = state.chapters.firstIndex(where: { $0.id == chapter.id }), index + 1 < state.chapters.count else { return nil }
        return state.chapters[index + 1]
    }
}
