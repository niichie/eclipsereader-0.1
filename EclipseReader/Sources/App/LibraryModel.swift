import SwiftUI

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
        Task { downloaded = await OfflineStore.shared.downloadedIDs() }
    }
    var preferences: ReaderPreferences {
        get { state.preferences }
        set { state.preferences = newValue; save() }
    }
    var lastChapter: Chapter? { (state.chapters + allSeries.flatMap(\.chapters)).first { $0.id == state.lastChapterID } }
    /// Everything the user added from links or Files, newest first.
    var allSeries: [MangaSeries] { state.series ?? [] }

    // MARK: Library presentation

    static let berserkID = "berserk"
    /// The built-in ReadBerserk source, shown in the library like any other series.
    var berserk: MangaSeries {
        MangaSeries(id: Self.berserkID, url: ReadBerserkParser.home, title: "Berserk",
                    cover: state.covers?[Self.berserkID], kind: .web, chapters: state.chapters, added: .distantPast)
    }
    /// Berserk first, then everything the user added.
    var librarySeries: [MangaSeries] { [berserk] + allSeries }
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
    func ensureCovers() async {
        #if DEBUG
        if ReaderTestFixture.demo { return }
        #endif
        for series in librarySeries where !coverAttempts.contains(series.id) {
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
        if let offline = await OfflineStore.shared.pages(for: chapter) { return offline }
        return try await networkPages(for: chapter)
    }
    private func networkPages(for chapter: Chapter) async throws -> [MangaPage] {
        #if DEBUG
        if ReaderTestFixture.demo || chapter.url.host == "example.invalid" { return try await source.pages(for: chapter) }
        #endif
        if chapter.url.scheme == "eclipselib" { return try await LocalBooks.shared.pages(chapter) }
        if series(containing: chapter) != nil
            || ReadBerserkParser.normalize(chapter.url.absoluteString, relativeTo: ReadBerserkParser.home) == nil && chapter.url.host != "example.invalid" {
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
        do { return try await LinkedSource().inspect(url) }
        catch let e as SourceError where e == .unsupportedStructure || e == .restricted {
            let html = try await PageRenderer.html(for: url)
            return try LinkedSource.analyze(html: html, url: url)
        }
    }
    enum AddLinkError: LocalizedError {
        case invalid
        var errorDescription: String? { "Enter a full link (https://…) to a manga series page, a chapter, or an image." }
    }
    enum LinkResult { case open(Chapter), series(MangaSeries, open: Chapter?) }
    /// Adds a whole series from a pasted link. A series page adds every chapter; a chapter
    /// page adds the series its chapter picker lists (when it has one) and opens that chapter.
    /// `html` is the page as the in-app browser shows it right now: it has already passed any
    /// browser check and run its scripts, so it is read first (covers and chapter lists included).
    func addLink(_ text: String, html: String? = nil) async throws -> LinkResult {
        guard let url = WebLink.parse(text) else { throw AddLinkError.invalid }
        if let known = ReadBerserkParser.normalize(url.absoluteString, relativeTo: ReadBerserkParser.home) {
            if let chapter = state.chapters.first(where: { $0.url == known }) { return .open(chapter) }
            if url.path.count > 1 { return .open(Chapter(url: known, title: "Berserk", number: "")) }
        }
        if let existing = allSeries.first(where: { $0.url == url }) { return .series(existing, open: nil) }
        if let existing = allSeries.first(where: { $0.chapters.contains { $0.url == url } }) {
            return .series(existing, open: existing.chapters.first { $0.url == url })
        }
        var live: LinkInspection?
        if let html, !Webtoons.handles(url), let seen = try? LinkedSource.analyze(html: html, url: url),
           seen.chapters.count >= 2 || !seen.pages.isEmpty {
            live = seen
        }
        let found: LinkInspection
        if let live { found = live } else { found = try await inspectAny(url) }
        // No cover art on the page: leave it empty so the library looks for the site's art later,
        // then falls back to a cropped first page.
        let series = MangaSeries(id: "web-" + url.absoluteString, url: url, title: found.title, cover: found.cover,
                                 kind: .web, chapters: found.chapters)
        state.series = [series] + allSeries
        if let style = found.style { var map = state.detectedStyles ?? [:]; map[series.id] = style; state.detectedStyles = map }
        save()
        // Open straight away only when the link itself was a chapter; a series page shows its chapter list.
        let here = LinkedSource.key(url)
        let opened = found.pages.isEmpty ? nil : series.chapters.first { LinkedSource.key($0.url) == here }
        return .series(series, open: opened)
    }
    /// Re-reads a web series' chapter list and adds new chapters, keeping progress.
    func update(_ series: MangaSeries) async throws {
        if series.id == Self.berserkID { await refresh(); if let message = self.error { throw BookError.invalid(message) }; return }
        guard series.kind == .web else { return }
        let found = try await inspectAny(series.url)
        guard var list = state.series, let i = list.firstIndex(where: { $0.id == series.id }) else { return }
        let known = Set(list[i].chapters.map { LinkedSource.key($0.url) })
        let fresh = found.chapters.filter { !known.contains(LinkedSource.key($0.url)) }
        if !fresh.isEmpty { list[i].chapters = ChapterOrder.sorted(list[i].chapters + fresh) }
        if list[i].cover == nil { list[i].cover = found.cover }
        state.series = list
        if let style = found.style, state.detectedStyles?[series.id] == nil {
            var map = state.detectedStyles ?? [:]; map[series.id] = style; state.detectedStyles = map
        }
        markNew(fresh, in: series.id)
        save()
    }
    func importFiles(_ urls: [URL], copy: Bool) async throws -> MangaSeries {
        let series = try await LocalBooks.shared.importSeries(urls, copy: copy)
        state.series = [series] + allSeries
        save()
        return series
    }
    func remove(_ series: MangaSeries) {
        guard series.id != Self.berserkID else { return }
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
    private func markNew(_ fresh: [Chapter], in seriesID: String) {
        guard !fresh.isEmpty else { return }
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
        await refresh()
        for series in allSeries where series.kind == .web {
            try? await update(series)
            try? await Task.sleep(for: .milliseconds(400))
        }
        state.lastUpdateCheck = Date()
        save()
    }

    // MARK: Offline downloads

    func isDownloaded(_ chapter: Chapter) -> Bool { downloaded.contains(chapter.id) }
    func canDownload(_ chapter: Chapter) -> Bool { chapter.url.scheme == "https" }
    func download(_ chapters: [Chapter]) {
        for chapter in chapters where canDownload(chapter) && !downloaded.contains(chapter.id) && downloads[chapter.id] == nil {
            downloadQueue.append(chapter)
            downloads[chapter.id] = .queued
        }
        guard downloadTask == nil, !downloadQueue.isEmpty else { return }
        downloadTask = Task { [weak self] in
            while let self, !self.downloadQueue.isEmpty {
                let next = self.downloadQueue.removeFirst()
                await self.runDownload(next)
            }
            self?.downloadTask = nil
        }
    }
    func cancelDownload(_ chapter: Chapter) {
        downloadQueue.removeAll { $0.id == chapter.id }
        downloads[chapter.id] = nil
    }
    func removeDownload(_ chapter: Chapter) {
        cancelDownload(chapter)
        downloaded.remove(chapter.id)
        Task { await OfflineStore.shared.remove(chapter.id) }
    }
    func removeAllDownloads() {
        downloadQueue.removeAll()
        downloads = [:]
        downloaded = []
        Task { await OfflineStore.shared.removeAll() }
    }
    private func runDownload(_ chapter: Chapter) async {
        guard downloads[chapter.id] != nil else { return }   // cancelled while queued
        downloads[chapter.id] = .running(0)
        do {
            let pages = try await networkPages(for: chapter)
            guard !pages.isEmpty else { throw SourceError.unsupportedStructure }
            try await OfflineStore.shared.begin(chapter.id)
            var files: [String] = []
            for (i, page) in pages.enumerated() {
                guard downloads[chapter.id] != nil else { throw CancellationError() }
                let data = try await pipeline.data(for: page, chapter: chapter)
                let name = try await OfflineStore.shared.write(chapter.id, index: i, data: data)
                files.append(name)
                downloads[chapter.id] = .running(Double(i + 1) / Double(pages.count))
            }
            try await OfflineStore.shared.finish(chapter.id, title: chapter.title, files: files)
            downloaded.insert(chapter.id)
            downloads[chapter.id] = nil
        } catch {
            await OfflineStore.shared.remove(chapter.id)
            if downloads[chapter.id] != nil {
                downloads[chapter.id] = .failed(error is CancellationError ? "Cancelled" : error.localizedDescription)
            }
        }
    }
    func downloadedCount(_ series: MangaSeries) -> Int { series.chapters.filter { downloaded.contains($0.id) }.count }

    /// Every chapter in the library with its series, for the Updates and History tabs.
    var chapterIndex: [String: (MangaSeries, Chapter)] {
        var map: [String: (MangaSeries, Chapter)] = [:]
        for series in librarySeries { for chapter in series.chapters { map[chapter.id] = (series, chapter) } }
        return map
    }
    /// Forgets where you stopped in every chapter; finished chapters stay marked as read.
    func clearHistory() {
        state.progress = state.progress.filter { $0.value.completed }
        state.lastChapterID = nil
        save()
    }
    func removeHistory(_ chapter: Chapter) {
        state.progress[chapter.id] = nil
        if state.lastChapterID == chapter.id { state.lastChapterID = nil }
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
        guard !sites.contains(where: { $0.url.host == url.host }) else { return }
        let title = name.trimmingCharacters(in: .whitespaces)
        sites.append(SavedSite(name: title.isEmpty ? (url.host ?? "Site") : String(title.prefix(60)), url: url))
        state.sites = sites
        save()
    }
    func removeSite(_ site: SavedSite) {
        state.sites = (state.sites ?? []).filter { $0.id != site.id }
        save()
    }

    // MARK: Covers chosen by the user

    func setCustomCover(_ url: URL?, for seriesID: String) {
        var map = state.customCovers ?? [:]
        map[seriesID] = url
        state.customCovers = map
        save()
    }
    /// Uses a page as the cover. Pages that live in removable downloads are copied, so the cover survives.
    func chooseCoverPage(_ page: MangaPage, seriesID: String) async throws {
        if page.url.scheme == "eclipselib", page.url.host == "offline" {
            let chapter = series(id: seriesID)?.chapters.first ?? Chapter(url: page.url, title: "", number: "")
            let data = try await pipeline.data(for: page, chapter: chapter)
            try await setCoverPhoto(data, for: seriesID)
        } else {
            setCustomCover(page.url, for: seriesID)
        }
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
        copy.series = copy.series?.filter { $0.kind == .web }
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
            guard series.kind == .web, safe(series.url) else { return nil }
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
        state.record(chapter, page: page, count: count, completed: completed); save()
    }
    func save() {
        do { try repository.save(state); persistenceError = nil }
        catch { persistenceError = "Progress could not be saved: \(error.localizedDescription)" }
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
