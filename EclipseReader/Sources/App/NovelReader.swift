import SwiftUI
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

// MARK: - Novels in the library model

/// Novels are an option; a novel link while they're off says how to turn them on.
struct NovelsOff: LocalizedError {
    var errorDescription: String? { "That’s a novel. Turn on Light novels in Settings › Library (or the setup) to read novels here." }
}

/// Chapter texts read this session (the reader goes back and forth; the next chapter is read ahead).
actor NovelTextCache {
    static let shared = NovelTextCache()
    private var texts: [String: NovelChapterText] = [:]
    private var order: [String] = []
    func get(_ id: String) -> NovelChapterText? { texts[id] }
    func put(_ id: String, _ text: NovelChapterText) {
        if texts[id] == nil { order.append(id) }
        texts[id] = text
        if order.count > 16 { texts[order.removeFirst()] = nil }
    }
}

extension LibraryModel {
    /// Whether a link is to a novel: a novel site, a source set to novels, or an address that says so.
    /// Only with novels turned on (except the novel-only sites, which say so when novels are off).
    func isNovel(_ url: URL) -> Bool {
        if NovelSource.isNovelSite(url) { return true }
        guard Features.novelsOn else { return false }
        if let category = source(for: url)?.category { return category == .novels }
        let path = url.path.lowercased()
        return path.contains("/novel/") || path.contains("/novels/") || path.contains("light-novel") || path.contains("lightnovel")
            || path.contains("/fiction/") || path.contains("webnovel")
    }
    func isNovelChapter(_ chapter: Chapter) -> Bool { series(containing: chapter)?.kind == .novel }

    /// Reads a novel's page: the page as the browser shows it when given, the browser session for sites you signed in to,
    /// the site directly otherwise (rendered like Safari when it only answers browsers).
    func novelInfo(_ url: URL, html: String? = nil) async throws -> NovelInfo {
        if let html, let found = try? await NovelSource.info(html: html, url: url), !found.chapters.isEmpty { return found }
        if usesBrowserSession(url) && !NovelSource.isDedicated(url) {
            return try await NovelSource.info(html: PageRenderer.html(for: url), url: url)
        }
        do { return try await NovelSource().info(url) }
        catch let e as SourceError where e == .restricted || e == .unsupportedStructure {
            return try await NovelSource.info(html: PageRenderer.html(for: url), url: url)
        }
    }
    /// Adds a novel from a link (a novel's page or one of its chapters).
    func addNovel(_ url: URL, html: String? = nil, title: String? = nil, addToShelf: Bool = true) async throws -> MangaSeries {
        guard Features.novelsOn else { throw NovelsOff() }
        if let existing = allSeries.first(where: { $0.url == url || ($0.kind == .novel && $0.chapters.contains { $0.url == url }) }) {
            return addToShelf ? addToLibrary(existing) : existing
        }
        var info = try await novelInfo(url, html: html)
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { info.title = title }
        return commitNovel(info.home ?? url, info, addToShelf: addToShelf)
    }
    @discardableResult
    func commitNovel(_ url: URL, _ info: NovelInfo, addToShelf: Bool = true) -> MangaSeries {
        if let existing = allSeries.first(where: { $0.url == url }) { return addToShelf ? addToLibrary(existing) : existing }
        var series = MangaSeries(id: "novel-" + url.absoluteString, url: url, title: info.title, cover: info.cover, kind: .novel,
                                 chapters: info.chapters, summary: info.summary, author: info.author, language: info.language)
        series.inLibrary = addToShelf
        state.series = [series] + allSeries
        save()
        if info.cover == nil {
            // Most web novels have no cover art: set one in type, like a cloth binding.
            Task {
                if let data = GeneratedCover.make(title: series.title, author: series.author) {
                    try? await self.setCoverPhoto(data, for: series.id)
                }
            }
        }
        return series
    }
    /// New chapters for a novel. Sites with their own data give the whole list in order; elsewhere new links are added.
    func updateNovel(_ series: MangaSeries) async throws -> [Chapter] {
        let found = try await novelInfo(series.url)
        guard var list = state.series, let i = list.firstIndex(where: { $0.id == series.id }) else { return [] }
        let known = Set(list[i].chapters.map { LinkedSource.key($0.url) })
        let fresh = found.chapters.filter { !known.contains(LinkedSource.key($0.url)) }
        if NovelSource.isDedicated(series.url), found.chapters.count >= list[i].chapters.count {
            list[i].chapters = found.chapters
        } else if !fresh.isEmpty {
            list[i].chapters = ChapterOrder.sorted(list[i].chapters + fresh)
        }
        if list[i].summary == nil { list[i].summary = found.summary }
        if list[i].language == nil { list[i].language = found.language }
        state.series = list
        return fresh
    }

    /// A chapter's text: read ahead or downloaded copies first, then the site.
    func novelText(_ chapter: Chapter) async throws -> NovelChapterText {
        if let cached = await NovelTextCache.shared.get(chapter.id) { return cached }
        if let data = await OfflineStore.shared.textData(chapter.id), let saved = try? JSONDecoder().decode(NovelChapterText.self, from: data) {
            return saved
        }
        let text = try await fetchNovelText(chapter.url)
        await NovelTextCache.shared.put(chapter.id, text)
        return text
    }
    func fetchNovelText(_ url: URL) async throws -> NovelChapterText {
        if usesBrowserSession(url) {
            let html = try await PageRenderer.html(for: url)
            if let text = NovelText.extract(html: html, url: url) { return text }
        }
        do { return try await NovelSource().chapter(url) }
        catch let e as SourceError where e == .restricted || e == .unsupportedStructure {
            let html = try await PageRenderer.html(for: url)
            guard let text = NovelText.extract(html: html, url: url) else { throw SourceError.unsupportedStructure }
            return text
        }
    }
    /// Saves a chapter's text for offline reading.
    func downloadNovelChapter(_ chapter: Chapter) async throws {
        let text = try await fetchNovelText(chapter.url)
        try await OfflineStore.shared.begin(chapter.id)
        let name = try await OfflineStore.shared.write(chapter.id, index: 0, data: JSONEncoder().encode(text))
        try await OfflineStore.shared.finish(chapter.id, title: chapter.title, files: [name])
    }

    func novelPosition(_ seriesID: String) -> NovelPosition? { state.novelPositions?[seriesID] }
    func setNovelPosition(_ position: NovelPosition, for seriesID: String) {
        guard state.incognito != true else { return }
        var map = state.novelPositions ?? [:]
        map[seriesID] = position
        state.novelPositions = map
        // Saved with the next progress record (every page turn), so no save here.
    }
}

extension OfflineStore {
    /// The saved text of a downloaded novel chapter (stored as its one "page").
    func textData(_ chapterID: String) -> Data? {
        // A chapter's id is its address, so a stand-in with that address finds the download.
        guard let url = URL(string: chapterID), let page = pages(for: Chapter(url: url, title: "", number: ""))?.first else { return nil }
        return try? data(page.url)
    }
}

// MARK: - Translation of novel text

/// Translates a chapter paragraph by paragraph on the device (Apple Translation), and keeps the result.
@MainActor
final class NovelTranslator: ObservableObject {
    @Published var active = false
    @Published var busy = false
    @Published var status: String?
    /// Changes whenever paragraphs are waiting for the translation session.
    @Published var requestID = 0
    /// Bumped when a chapter's translation arrives.
    @Published var version = 0
    var source: String?
    let target = Locale.current.language.languageCode?.identifier ?? "en"
    private var pendingChapter: String?
    private var pendingItems: [(String, String)] = []
    private var done: [String: [String: String]] = [:]

    var supported: Bool { if #available(iOS 18.0, *) { return true } else { return false } }
    func translations(_ chapterID: String) -> [String: String]? { done[chapterID] }

    private static let alwaysKey = "translateNovels"
    static func isAlways(_ seriesID: String) -> Bool { (UserDefaults.standard.stringArray(forKey: alwaysKey) ?? []).contains(seriesID) }
    static func setAlways(_ on: Bool, _ seriesID: String) {
        var list = (UserDefaults.standard.stringArray(forKey: alwaysKey) ?? []).filter { $0 != seriesID }
        if on { list.append(seriesID) }
        UserDefaults.standard.set(list, forKey: alwaysKey)
    }

    /// The language a chapter is written in (the site's word for it first, then the text itself).
    static func language(of blocks: [BookBlock], hint: String?) -> String? {
        if let hint { return hint }
        let sample = blocks.prefix(40).compactMap { NovelTranslator.text(of: $0) }.joined(separator: "\n")
        return NLLanguageRecognizer.dominantLanguage(for: sample).map { $0.rawValue.components(separatedBy: "-").first ?? $0.rawValue }
    }
    static func text(of block: BookBlock) -> String? {
        switch block {
        case .paragraph(let runs), .centered(let runs), .quote(let runs), .heading(_, let runs), .listItem(let runs, _):
            let joined = runs.map(\.text).joined()
            return joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : joined
        default: return nil
        }
    }
    /// Blocks with their text swapped for the translation (emphasis inside a paragraph is not kept).
    static func apply(_ map: [String: String], to blocks: [BookBlock]) -> [BookBlock] {
        blocks.enumerated().map { i, block in
            guard let translated = map[String(i)] else { return block }
            let run = [BookRun(text: translated)]
            switch block {
            case .paragraph: return .paragraph(runs: run)
            case .centered: return .centered(runs: run)
            case .quote: return .quote(runs: run)
            case .heading(let level, _): return .heading(level: level, runs: [BookRun(text: translated, bold: true)])
            case .listItem(_, let marker): return .listItem(runs: run, marker: marker)
            default: return block
            }
        }
    }

    private func file(_ chapterID: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NovelTranslations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(OfflineStore.key(chapterID + "|" + target) + ".json")
    }
    /// Asks for a chapter's translation (served from disk when it was translated before).
    func request(chapterID: String, blocks: [BookBlock], language: String?) {
        guard active else { return }
        if done[chapterID] != nil { return }
        if let data = try? Data(contentsOf: file(chapterID)), let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            done[chapterID] = saved
            version += 1
            return
        }
        source = language
        if language == target { status = "This chapter is already in your language."; return }
        pendingChapter = chapterID
        pendingItems = blocks.enumerated().compactMap { i, block in Self.text(of: block).map { (String(i), $0) } }
        guard !pendingItems.isEmpty else { return }
        busy = true
        status = nil
        requestID += 1
    }
    func pending() -> [(String, String)] { pendingItems }
    func apply(_ pairs: [(String, String)]) {
        guard let chapter = pendingChapter else { return }
        var map: [String: String] = [:]
        for (id, text) in pairs { map[id] = text }
        done[chapter] = map
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: file(chapter), options: .atomic) }
        pendingItems = []
        busy = false
        version += 1
    }
    func fail(_ message: String) {
        busy = false
        status = "Couldn’t translate: \(message)"
    }
}

#if canImport(Translation)
@available(iOS 18.0, *)
private struct NovelSessionBox: @unchecked Sendable { let session: TranslationSession }

@available(iOS 18.0, *)
private func translateParagraphs(_ box: NovelSessionBox, items: [(String, String)]) async throws -> [(String, String)] {
    var out: [(String, String)] = []
    // In batches, so a long chapter shows progress and one bad paragraph can't sink the rest.
    for start in stride(from: 0, to: items.count, by: 60) {
        let slice = Array(items[start..<min(items.count, start + 60)])
        let requests = slice.map { TranslationSession.Request(sourceText: $0.1, clientIdentifier: $0.0) }
        let responses = try await box.session.translations(from: requests)
        out += responses.map { ($0.clientIdentifier ?? "", $0.targetText) }
    }
    return out
}

@available(iOS 18.0, *)
private struct NovelTranslationRunner: ViewModifier {
    @ObservedObject var translator: NovelTranslator
    @State private var configuration: TranslationSession.Configuration?
    @State private var languages = ""
    func body(content: Content) -> some View {
        let translator = self.translator
        return content
            .translationTask(configuration) { session in
                let items = translator.pending()
                guard !items.isEmpty else { return }
                let box = NovelSessionBox(session: session)
                do { translator.apply(try await translateParagraphs(box, items: items)) }
                catch { translator.fail(error.localizedDescription) }
            }
            .onChange(of: translator.requestID) { _, _ in
                let wanted = "\(translator.source ?? "auto")>\(translator.target)"
                if configuration != nil && languages == wanted { configuration?.invalidate() }
                else {
                    languages = wanted
                    configuration = TranslationSession.Configuration(source: translator.source.map { Locale.Language(identifier: $0) },
                                                                     target: Locale.Language(identifier: translator.target))
                }
            }
    }
}
#endif

extension View {
    @ViewBuilder func novelTranslationRunner(_ translator: NovelTranslator) -> some View {
        #if canImport(Translation)
        if #available(iOS 18.0, *) { self.modifier(NovelTranslationRunner(translator: translator)) } else { self }
        #else
        self
        #endif
    }
}

// MARK: - The novel reader

/// Reads a novel chapter like a book (the same typesetting, page curl and settings as books), carrying straight on
/// into the next chapter. Raw chapters can be translated on the device.
struct NovelReaderView: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var chapter: Chapter
    @AppStorage("bookFont") private var fontRaw = BookFont.newYork.rawValue
    @AppStorage("bookSize") private var size = 19.0
    @AppStorage("bookSpacing") private var spacing = 1.4
    @AppStorage("bookMargin") private var margin = 1
    @AppStorage("bookJustify") private var justify = true
    @AppStorage("bookTheme") private var themeRaw = BookTheme.night.rawValue
    @AppStorage("bookCurl") private var curl = true
    @AppStorage("keepScreenOn") private var keepScreenOn = true
    @AppStorage("pageHaptics") private var haptics = true
    @State private var text: NovelChapterText?
    @State private var original: [BookBlock] = []
    @State private var document: BookDocument?
    @State private var images: [String: Data] = [:]
    @State private var typeset: TypesetBook?
    @State private var page = 0
    @State private var chrome = true
    @State private var failure: String?
    @State private var settings = false
    @State private var contents = false
    @State private var pager = BookPagerController()
    @State private var lastActivity = Date()
    /// Where to land once set: a character offset in the chapter, or its last page (coming back from the next chapter).
    @State private var anchorOffset: Int?
    @State private var landAtEnd = false
    @State private var steadySafe: [String: EdgeInsets] = [:]
    @State private var language: String?
    @State private var toast: String?
    @State private var reloads = 0
    /// Bumped whenever the chapter's document is rebuilt (loaded, translated, or shown in the original), to set it again.
    @State private var revision = 0
    @StateObject private var translator = NovelTranslator()

    init(chapter: Chapter) { _chapter = State(initialValue: chapter) }

    private var style: BookStyle {
        BookStyle(font: BookFont(rawValue: fontRaw) ?? .newYork, size: size, spacing: spacing, margin: margin,
                  justify: justify, theme: BookTheme(rawValue: themeRaw) ?? .night)
    }
    private var series: MangaSeries? { library.series(containing: chapter) }
    private var theme: BookTheme { style.theme }
    private var nextChapter: Chapter? { library.next(after: chapter) }
    private var chapterPages: Int { typeset?.pagesIn(section: 0) ?? 0 }

    var body: some View {
        GeometryReader { geometry in
            let full = CGSize(width: geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing,
                              height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom)
            let shape = "\(Int(full.width))x\(Int(full.height))"
            let safe = BookReaderView.merge(steadySafe[shape], geometry.safeAreaInsets)
            let twoUp = curl && full.width > full.height * 1.2 && full.width > 700
            let insets = BookReaderView.insets(for: full, twoUp: twoUp, margin: margin, safe: safe)
            let pageSize = CGSize(width: (twoUp ? full.width / 2 : full.width) - insets.left - insets.right,
                                  height: full.height - insets.top - insets.bottom)
            ZStack {
                Color(theme.background).ignoresSafeArea()
                if let typeset {
                    BookPagerView(book: typeset, style: style, insets: insets, twoUp: twoUp, curl: curl,
                                  title: series?.title ?? "", sectionTitle: { $0 == 0 ? chapter.title : "" },
                                  page: $page, controller: pager, tapped: { tapped(at: $0) })
                        .ignoresSafeArea()
                } else if let failure {
                    VStack(spacing: 14) {
                        Image(systemName: "text.page.slash").font(.largeTitle).foregroundStyle(Color(theme.secondary))
                        Text(failure).multilineTextAlignment(.center).foregroundStyle(Color(theme.text))
                        HStack {
                            Button("Try again") { reloads += 1 }.buttonStyle(.bordered)
                            if let next = nextChapter { Button("Skip to next chapter") { open(next) }.buttonStyle(.bordered) }
                            Button("Close") { dismiss() }.buttonStyle(.borderedProminent).tint(Eclipse.accent)
                        }
                    }.padding(32).frame(maxWidth: 520)
                } else {
                    VStack(spacing: 12) {
                        ProgressView().tint(Color(theme.text))
                        Text(text == nil ? "Opening \(chapter.title)…" : "Setting type…").font(.footnote).foregroundStyle(Color(theme.secondary))
                    }
                }
                if chrome || typeset == nil { controls }
                if let toast {
                    Text(toast).font(.footnote.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 90)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .transition(.opacity)
                }
            }
            .task(id: "\(revision)|\(Int(pageSize.width))x\(Int(pageSize.height))|\(style.key)|\(twoUp)") {
                await layout(pageSize: pageSize)
            }
            .onChange(of: geometry.safeAreaInsets, initial: true) { _, now in
                let merged = BookReaderView.merge(steadySafe[shape], now)
                if steadySafe[shape] != merged { steadySafe[shape] = merged }
            }
        }
        .statusBarHidden(!chrome)
        .persistentSystemOverlays(chrome ? .automatic : .hidden)
        .preferredColorScheme(theme.dark ? .dark : .light)
        .animation(.snappy(duration: 0.2), value: chrome)
        .task(id: "\(chapter.id)|\(reloads)") { await load() }
        .background(KeyTurnCatcher().frame(width: 0, height: 0))
        .onReceive(NotificationCenter.default.publisher(for: PageTurnInput.notification)) { note in
            if let forward = note.userInfo?["forward"] as? Bool { pager.turn(forward: forward) }
            else if let edge = note.userInfo?["edge"] as? Double {
                if edge == 0.5 { chrome.toggle() } else { pager.turn(forward: edge > 0.5) }
            }
        }
        .onChange(of: page) { old, new in pageChanged(from: old, to: new) }
        .onChange(of: phase) { _, now in if now != .active { logTime() } else { lastActivity = Date() } }
        .onAppear {
            lastActivity = Date()
            UIApplication.shared.isIdleTimerDisabled = keepScreenOn
            pager.beyondEnd = { forward in
                if forward, let next = nextChapter { open(next) }
                else if !forward, let previous = library.previous(before: chapter) { open(previous, atEnd: true) }
            }
            if !Syosetu.handles(chapter.url), let id = series?.id, NovelTranslator.isAlways(id) { translator.active = true }
        }
        .onDisappear { logTime(); UIApplication.shared.isIdleTimerDisabled = false; pager.beyondEnd = nil }
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: page) { _, _ in haptics }
        .novelTranslationRunner(translator)
        .onChange(of: translator.status) { _, now in if let now { show(now) } }
        // A translation arrived: set the chapter again in the new language.
        .onChange(of: translator.version) { _, _ in rebuild() }
        .sheet(isPresented: $settings) {
            BookSettingsSheet(fontRaw: $fontRaw, size: $size, spacing: $spacing, margin: $margin, justify: $justify,
                              themeRaw: $themeRaw, curl: $curl)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $contents) {
            NovelContentsSheet(chapters: series?.chapters ?? [chapter], current: chapter.id) { picked in
                contents = false
                open(picked)
            }
            .environmentObject(library)
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: Loading and layout

    private func load() async {
        failure = nil; typeset = nil; document = nil; text = nil
        do {
            let loaded = try await library.novelText(chapter)
            guard !Task.isCancelled else { return }
            let blocks = loaded.blocks(base: chapter.url)
            guard !blocks.isEmpty || loaded.locked else { throw SourceError.unsupportedStructure }
            images = await Self.pictures(in: blocks)
            text = loaded
            original = blocks
            language = NovelTranslator.language(of: blocks, hint: series?.language)
            if anchorOffset == nil, !landAtEnd, let id = series?.id, let saved = library.novelPosition(id), saved.chapterID == chapter.id {
                anchorOffset = saved.offset
            }
            if translator.active { translator.request(chapterID: chapter.id, blocks: blocks, language: language) }
            rebuild()
            // Read the next chapter ahead, so turning into it is instant.
            if let next = nextChapter {
                Task.detached(priority: .utility) { [library] in _ = try? await library.novelText(next) }
            }
        } catch let error as SourceError where error == .unsupportedStructure {
            failure = "Couldn’t find this chapter’s text. The site may have changed, or the chapter needs you to be signed in: open the site in Browse, sign in, then turn on “Read with my browser sign-in” for it in Browse › Manage sources."
        } catch {
            failure = (error as? LocalizedError)?.errorDescription
                ?? "Couldn’t read this chapter. Check your connection and try again."
        }
    }
    /// The chapter as it will be set: its text (translated when asked), then a page leading into the next chapter.
    private func rebuild() {
        guard let text else { return }
        var blocks = original
        if translator.active, let map = translator.translations(chapter.id) { blocks = NovelTranslator.apply(map, to: blocks) }
        let firstText = blocks.lazy.compactMap { NovelTranslator.text(of: $0) }.first ?? ""
        if !firstText.localizedCaseInsensitiveContains(ChapterText.split(chapter.title).name) {
            blocks.insert(.heading(level: 2, runs: [BookRun(text: chapter.title, bold: true)]), at: 0)
        }
        if text.locked {
            blocks += [.rule, .centered(runs: [BookRun(text: "The rest of this chapter is locked on \(chapter.url.host?.replacingOccurrences(of: "www.", with: "") ?? "the site"). Unlock it there, then reopen it here.", italic: true)])]
        }
        let ending: [BookBlock]
        if let next = nextChapter {
            ending = [.centered(runs: [BookRun(text: "End of chapter", small: true)]),
                      .heading(level: 2, runs: [BookRun(text: next.title, bold: true)]),
                      .centered(runs: [BookRun(text: "Turn the page to keep reading", italic: true)])]
        } else {
            ending = [.centered(runs: [BookRun(text: "You’re all caught up", bold: true)]),
                      .centered(runs: [BookRun(text: "New chapters show up in Updates.", italic: true)])]
        }
        document = BookDocument(title: series?.title ?? chapter.title,
                                sections: [BookSection(title: chapter.title, blocks: blocks), BookSection(title: nil, blocks: ending)])
        revision += 1
    }
    private func layout(pageSize: CGSize) async {
        guard let document, pageSize.width > 60, pageSize.height > 80 else { return }
        // Setting it again (new size, font, or a translation with a different length): keep the same place in the chapter.
        var fraction: Double?
        if let typeset, typeset.pages.indices.contains(page), typeset.pages[page].section == 0 {
            fraction = Double(typeset.pages[page].range.location) / Double(max(1, Self.length(typeset)))
        }
        let style = self.style, images = self.images
        let result = await Task.detached(priority: .userInitiated) {
            BookTypesetter.typeset(document, images: images, style: style, pageSize: pageSize)
        }.value
        guard !Task.isCancelled else { return }
        let target: Int
        if landAtEnd { target = max(0, result.pagesIn(section: 0) - 1) }
        else if let fraction { target = result.page(for: 0, offset: Int(fraction * Double(Self.length(result)))) }
        else if let anchorOffset { target = result.page(for: 0, offset: anchorOffset) }
        else { target = 0 }
        landAtEnd = false
        anchorOffset = nil
        let opening = typeset == nil
        typeset = result
        page = target
        if opening, result.pages.indices.contains(target), result.pages[target].section == 0 {
            library.record(chapter, page: target, count: max(1, result.pagesIn(section: 0)))
        }
        if result.pages.indices.contains(target), let series {
            library.setNovelPosition(NovelPosition(chapterID: chapter.id, offset: result.pages[target].range.location), for: series.id)
        }
        if chrome {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { chrome = false }
        }
    }
    /// How much text the chapter itself holds (its pages, not the "next chapter" page).
    private static func length(_ book: TypesetBook) -> Int {
        book.pages.filter { $0.section == 0 }.map { $0.range.location + $0.range.length }.max() ?? 1
    }
    /// Pictures in the chapter (illustrations), fetched once; at most a dozen per chapter.
    private static func pictures(in blocks: [BookBlock]) async -> [String: Data] {
        var found: [String: Data] = [:]
        let http = WebsiteHTTPClient()
        for block in blocks {
            guard case .image(let path) = block, found[path] == nil, found.count < 12, let url = URL(string: path),
                  let data = try? await http.fetch(url, referer: nil, image: true) else { continue }
            found[path] = data
        }
        return found
    }

    // MARK: Reading

    private func open(_ target: Chapter, atEnd: Bool = false) {
        logTime()
        anchorOffset = nil
        landAtEnd = atEnd
        typeset = nil
        page = 0
        if !atEnd, let series {
            library.setNovelPosition(NovelPosition(chapterID: target.id, offset: 0), for: series.id)
        }
        if Syosetu.handles(target.url) { translator.active = false }
        chapter = target
    }
    private func tapped(at x: CGFloat) {
        if x < 0.3 { chrome = false; pager.turn(forward: false) }
        else if x > 0.7 { chrome = false; pager.turn(forward: true) }
        else { chrome.toggle() }
    }
    private func pageChanged(from old: Int, to new: Int) {
        logTime()
        guard let typeset, typeset.pages.indices.contains(new), let series else { return }
        let ref = typeset.pages[new]
        let count = max(1, typeset.pagesIn(section: 0))
        if ref.section == 0 {
            library.setNovelPosition(NovelPosition(chapterID: chapter.id, offset: ref.range.location), for: series.id)
            library.record(chapter, page: new, count: count, completed: new >= count - 1)
            return
        }
        // The page after the chapter: it's finished, and the next one opens.
        library.record(chapter, page: count - 1, count: count, completed: true)
        guard let next = nextChapter else { return }
        let here = chapter.id
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            if chapter.id == here, self.page == new { open(next) }
        }
    }
    private func logTime() {
        let now = Date()
        library.logReading(seconds: min(300, now.timeIntervalSince(lastActivity)))
        lastActivity = now
    }
    private func show(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { if toast == message { toast = nil } }
        }
    }

    // MARK: Bookmarks

    private var currentRef: (page: Int, offset: Int)? {
        guard let typeset, typeset.pages.indices.contains(page), typeset.pages[page].section == 0 else { return nil }
        return (page, typeset.pages[page].range.location)
    }
    private var bookmarkHere: Bookmark? {
        guard let ref = currentRef, let typeset else { return nil }
        let range = typeset.pages[ref.page].range
        return library.bookmarks(chapterID: chapter.id).first { ($0.offset ?? -1) >= range.location && ($0.offset ?? -1) < range.location + max(1, range.length) }
    }
    private func toggleBookmark() {
        if let existing = bookmarkHere { library.removeBookmark(existing); show("Bookmark removed"); return }
        guard let ref = currentRef, let series else { return }
        library.addBookmark(Bookmark(seriesID: series.id, chapterID: chapter.id, chapterTitle: chapter.title,
                                     page: ref.page, pageCount: chapterPages, offset: ref.offset))
        show("Bookmarked")
    }

    // MARK: Controls

    private var translatable: Bool {
        guard translator.supported, let language else { return false }
        return language != translator.target
    }
    @ViewBuilder private var controls: some View {
        let ink = Color(theme.text)
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { dismiss() } label: { Image(systemName: "chevron.down").font(.headline).frame(width: 44, height: 44) }
                    .accessibilityLabel("Close reader")
                VStack(alignment: .leading, spacing: 1) {
                    Text(series?.title ?? "").font(.subheadline.weight(.bold)).lineLimit(1)
                    Text(chapter.title).font(.caption).foregroundStyle(ink.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 4)
                if translatable || translator.active {
                    Button {
                        translator.active.toggle()
                        if translator.active { translator.request(chapterID: chapter.id, blocks: original, language: language) }
                        rebuild()
                    } label: {
                        Group {
                            if translator.busy { ProgressView().controlSize(.small) }
                            else { Image(systemName: translator.active ? "character.bubble.fill" : "character.bubble") }
                        }.frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(translator.active ? "Show the original" : "Translate")
                    .contextMenu {
                        if !Syosetu.handles(chapter.url), let id = series?.id {
                            Button(NovelTranslator.isAlways(id) ? "Stop translating this novel" : "Always translate this novel") {
                                let on = !NovelTranslator.isAlways(id)
                                NovelTranslator.setAlways(on, id)
                                if on && !translator.active {
                                    translator.active = true
                                    translator.request(chapterID: chapter.id, blocks: original, language: language)
                                    rebuild()
                                }
                            }
                        }
                    }
                }
                Button { toggleBookmark() } label: {
                    Image(systemName: bookmarkHere == nil ? "bookmark" : "bookmark.fill").frame(width: 44, height: 44)
                }
                .accessibilityLabel(bookmarkHere == nil ? "Bookmark this page" : "Remove bookmark").disabled(currentRef == nil)
                Button { contents = true } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }
                    .accessibilityLabel("Chapters")
                Button { settings = true } label: { Image(systemName: "textformat.size").frame(width: 44, height: 44) }
                    .accessibilityLabel("Text and page settings")
            }
            .font(.title3)
            .padding(.horizontal, 6)
            .background(.ultraThinMaterial)
            Spacer()
            HStack(spacing: 12) {
                Button { if let previous = library.previous(before: chapter) { open(previous) } } label: {
                    Image(systemName: "backward.end.fill").frame(width: 44, height: 44)
                }
                .disabled(library.previous(before: chapter) == nil).accessibilityLabel("Previous chapter")
                VStack(spacing: 4) {
                    if chapterPages > 0 {
                        ProgressView(value: Double(min(page + 1, chapterPages)), total: Double(chapterPages)).tint(Eclipse.highlight)
                        Text("Page \(min(page + 1, chapterPages)) of \(chapterPages)").font(.caption2.monospacedDigit()).foregroundStyle(ink.opacity(0.7))
                    }
                }
                Button { if let next = nextChapter { open(next) } } label: {
                    Image(systemName: "forward.end.fill").frame(width: 44, height: 44)
                }
                .disabled(nextChapter == nil).accessibilityLabel("Next chapter")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.ultraThinMaterial)
        }
        .foregroundStyle(ink)
    }
}

/// Every chapter of the novel, the current one in view.
struct NovelContentsSheet: View {
    @EnvironmentObject private var library: LibraryModel
    let chapters: [Chapter]
    let current: String
    let pick: (Chapter) -> Void
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(chapters) { chapter in
                    Button { pick(chapter) } label: {
                        HStack {
                            Text(chapter.title).lineLimit(2)
                                .foregroundStyle(library.state.progress[chapter.id]?.completed == true ? .secondary : .primary)
                            Spacer()
                            if chapter.id == current { Image(systemName: "book.fill").foregroundStyle(Eclipse.highlight) }
                            else if library.isDownloaded(chapter) { Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary) }
                        }
                    }
                    .id(chapter.id)
                }
                .onAppear { proxy.scrollTo(current, anchor: .center) }
            }
            .navigationTitle("Chapters").navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Browse: novels

/// Popular Japanese web novels from Syosetu, when you read raws (translated on the device).
struct NovelBrowseSection: View {
    @EnvironmentObject private var model: LibraryModel
    @Binding var opened: MangaSeries?
    @State private var popular: [DiscoverItem] = []
    @State private var adding: String?
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !popular.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Popular on Syosetu").font(.title3.weight(.bold))
                    Text("English edition titles · chapters in Japanese").font(.footnote).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(popular) { item in
                            Button { add(item) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    CoverView(url: item.cover, referer: nil)
                                        .frame(width: 112, height: 160)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay { if adding == item.id { ProgressView() } }
                                    Text(item.title).font(.caption.weight(.semibold)).lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    if let detail = item.detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                .frame(width: 112)
                            }
                            .buttonStyle(PressableStyle()).disabled(adding != nil)
                        }
                    }.padding(.vertical, 2)
                }
                if let failure { Text(failure).font(.footnote).foregroundStyle(.orange) }
            }
        }
        .task {
            guard popular.isEmpty, let ranked = try? await Syosetu.popular(http: WebsiteHTTPClient()), !Task.isCancelled else { return }
            popular = await Syosetu.illustratedPreviews(ranked)
        }
    }
    private func add(_ item: DiscoverItem) {
        if let owned = model.allSeries.first(where: { $0.url == item.url }) { opened = owned; return }
        adding = item.id
        failure = nil
        Task {
            defer { adding = nil }
            do { opened = try await model.addNovel(item.url, title: item.title, addToShelf: false) }
            catch { failure = "Couldn’t open \(item.title): \(error.localizedDescription)" }
        }
    }
}
