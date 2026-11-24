import Foundation

public struct Chapter: Codable, Hashable, Identifiable, Sendable {
    public let url: URL
    public let title: String
    public let number: String
    public let published: String?
    public var id: String { url.absoluteString }
    public init(url: URL, title: String, number: String, published: String? = nil) {
        self.url = url; self.title = title; self.number = number; self.published = published
    }
}

public struct MangaPage: Codable, Hashable, Identifiable, Sendable {
    public let url: URL
    public let label: String
    public let width: Double?
    public let height: Double?
    public var id: String { url.absoluteString }
    public init(url: URL, label: String, width: Double? = nil, height: Double? = nil) {
        self.url = url; self.label = label; self.width = width; self.height = height
    }
}

extension MangaPage {
    /// One half of a double-page spread, shown on its own when spreads are split in portrait.
    public enum Half: String, Sendable { case left, right }
    private static let halfMarker = "eclipse-half="
    public var half: Half? {
        guard let fragment = url.fragment, fragment.hasPrefix(Self.halfMarker) else { return nil }
        return Half(rawValue: String(fragment.dropFirst(Self.halfMarker.count)))
    }
    /// The full image this page shows (itself, unless it is a half).
    public var whole: MangaPage {
        guard half != nil, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return self }
        parts.fragment = nil
        return MangaPage(url: parts.url ?? url, label: label, width: width.map { $0 * 2 }, height: height)
    }
    public func halved(_ side: Half) -> MangaPage {
        guard var parts = URLComponents(url: whole.url, resolvingAgainstBaseURL: false) else { return self }
        parts.fragment = Self.halfMarker + side.rawValue
        return MangaPage(url: parts.url ?? url, label: "\(label) (\(side.rawValue) half)", width: width.map { $0 / 2 }, height: height)
    }
}

public enum ReadingDirection: String, Codable, CaseIterable, Sendable {
    case rightToLeft, leftToRight
    public var title: String { self == .rightToLeft ? "Right to left" : "Left to right" }
}
public enum ReadingMode: String, Codable, CaseIterable, Sendable {
    case paged, vertical
    public var title: String { self == .paged ? "Pages" : "Continuous vertical" }
}
public enum PageFit: String, Codable, CaseIterable, Sendable {
    case screen, width
    public var title: String { self == .screen ? "Fit entire page" : "Fit width" }
}
public enum PageTransition: String, Codable, CaseIterable, Sendable {
    case curl, slide
    public var title: String { self == .curl ? "Paper curl" : "Slide" }
}
/// Page decoding quality. Automatic sizes pages to this device's screen and memory.
public enum ImageQuality: String, Codable, CaseIterable, Sendable {
    case automatic, dataSaver, maximum
    public var title: String {
        switch self {
        case .automatic: "Automatic (best for this device)"
        case .dataSaver: "Battery & memory saver"
        case .maximum: "Maximum detail"
        }
    }
}

/// What a source offers, which decides where it appears and how what you add from it reads.
public enum SourceCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case manga, manhwa, manhua, webtoons, comics, novels
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .manga: "Manga"
        case .manhwa: "Manhwa"
        case .manhua: "Manhua"
        case .webtoons: "Webtoons"
        case .comics: "Comics"
        case .novels: "Light novels & web novels"
        }
    }
    public var short: String { self == .novels ? "Novels" : title }
    public var symbol: String {
        switch self {
        case .manga: "book.pages"
        case .manhwa: "rectangle.portrait"
        case .manhua: "scroll"
        case .webtoons: "iphone.gen3"
        case .comics: "bubble.left.and.bubble.right"
        case .novels: "text.book.closed"
        }
    }
    /// The reading style series from this kind of source start with (novels read as text).
    public var style: ReadingStyle? {
        switch self {
        case .manga: .manga
        case .manhwa: .manhwa
        case .manhua: .manhua
        case .webtoons: .webtoon
        case .comics: .comic
        case .novels: nil
        }
    }
}

/// A website source: one you saved, or one of the app's bundled destinations. Everything but the name and
/// address is optional, so older saved libraries still decode.
public struct SavedSite: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var url: URL
    public var id: String { url.absoluteString }
    /// Where it appears (manga, comics, novels…); nil means work it out from what gets added.
    public var category: SourceCategory?
    /// Reading style for series added from this source (nil: detect it).
    public var style: ReadingStyle?
    /// Read this source's pages through the in-app browser's session (for sites you signed in to there).
    public var browserSession: Bool?
    /// Hidden from Browse (bundled destinations can be hidden rather than removed).
    public var hidden: Bool?
    public var favorite: Bool?
    /// A short description shown under the name.
    public var highlightText: String?
    public var note: String?
    /// The bundled manifest entry this came from.
    public var bundledID: String?
    /// Reads through a dedicated connection (MangaDex, WeebCentral, WEBTOON, Syosetu…).
    public var native: Bool?
    public init(name: String, url: URL, category: SourceCategory? = nil, style: ReadingStyle? = nil, note: String? = nil,
                bundledID: String? = nil, native: Bool? = nil) {
        self.name = name; self.url = url; self.category = category; self.style = style; self.note = note
        self.bundledID = bundledID; self.native = native
    }
    /// The host without "www.".
    public var host: String { url.host?.lowercased().replacingOccurrences(of: "www.", with: "") ?? "" }
    /// Whether an address belongs to this source (same site, any subdomain).
    public func owns(_ address: URL) -> Bool {
        !host.isEmpty && ChapterMerge.site(address.host) == ChapterMerge.site(url.host)
    }
}

/// A place you marked inside a chapter.
public struct Bookmark: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var seriesID: String
    public var chapterID: String
    public var chapterTitle: String
    /// Page number for pictures; for text, the page at the time (the offset is what counts).
    public var page: Int
    public var pageCount: Int
    /// Character offset into the text (books and novels), so it survives font changes.
    public var offset: Int?
    /// For books: the part of the book.
    public var section: Int?
    public var highlightText: String?
    public var note: String?
    public var created: Date
    public init(id: String = UUID().uuidString, seriesID: String, chapterID: String, chapterTitle: String, page: Int, pageCount: Int,
                offset: Int? = nil, section: Int? = nil, note: String? = nil, created: Date = Date()) {
        self.id = id; self.seriesID = seriesID; self.chapterID = chapterID; self.chapterTitle = chapterTitle
        self.page = page; self.pageCount = pageCount; self.offset = offset; self.section = section; self.note = note; self.created = created
    }
}

/// Where you are in a novel: the chapter and a character offset into its text (survives font changes).
public struct NovelPosition: Codable, Hashable, Sendable {
    public var chapterID: String
    public var offset: Int
    public var updated: Date
    public init(chapterID: String, offset: Int, updated: Date = Date()) { self.chapterID = chapterID; self.offset = offset; self.updated = updated }
}


/// What a series is, which decides how it reads. Automatic resolves to a detected style, else manga.
/// Manhwa (Korean), manhua (Chinese) and webtoons (vertical webcomics from anywhere) all scroll;
/// manga turns pages right to left, Western comics left to right.
public enum ReadingStyle: String, Codable, CaseIterable, Sendable {
    case automatic, manga, manhwa, manhua, webtoon, comic
    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .manga: "Manga"
        case .manhwa: "Manhwa"
        case .manhua: "Manhua"
        case .webtoon: "Webtoon"
        case .comic: "Comic"
        }
    }
    /// Short label for cover badges.
    public var tag: String { self == .automatic ? "AUTO" : title.uppercased() }
    public var detail: String {
        switch self {
        case .automatic: "Detected from the site and page shapes"
        case .manga: "Japanese · right to left, page turns"
        case .manhwa: "Korean · vertical scroll"
        case .manhua: "Chinese · vertical scroll"
        case .webtoon: "Webcomic strips · vertical scroll"
        case .comic: "Western · left to right, page turns"
        }
    }
    public var symbol: String {
        switch self {
        case .automatic: "wand.and.stars"
        case .manga: "book"
        case .manhwa: "iphone.gen3"
        case .manhua: "iphone.gen2"
        case .webtoon: "scroll"
        case .comic: "book.pages"
        }
    }
    /// Read as one continuous vertical strip.
    public var scrolls: Bool { self == .manhwa || self == .manhua || self == .webtoon }
}

public struct ReaderPreferences: Codable, Equatable, Sendable {
    public var direction: ReadingDirection = .rightToLeft
    public var mode: ReadingMode = .paged
    public var fit: PageFit = .screen
    // Manga-first defaults: page-turn animation, Japanese order (drag the page to the right to go forward).
    public var transition: PageTransition = .curl
    public var landscapeSpreads = true
    public var detectWidePages = true
    // Explicitly follows the supplied brief. Spread order is independent of swipe gesture.
    public var advanceOnLeftSwipe = false
    public var doubleTapZoom: Double = 2.5
    // Optional so libraries saved by earlier builds still decode. nil means on.
    public var trimMargins: Bool?
    /// Switch to vertical scrolling automatically for tall webtoon/manhwa strips. nil means on.
    public var autoWebtoon: Bool?
    /// BCP-47 language code for translations, e.g. "en". nil means English.
    public var translateTarget: String?
    /// How sharply pages are decoded for this device. nil means automatic.
    public var quality: ImageQuality?
    /// A thin gap between pages in vertical scrolling. nil means off (seamless strips).
    public var verticalGap: Bool?
    /// Tap the left/right edge of a page to turn it. nil means on.
    public var tapZones: Bool?
    /// Sharpen and upscale low-resolution scans while decoding. nil means off.
    public var enhance: Bool?
    /// Show two-page scans as two single pages in portrait. nil means on.
    public var splitSpreads: Bool?
    /// Guided view: step through a page panel by panel. nil means off.
    public var guided: Bool?
    public init() {}
    /// Global settings are the manga defaults; other styles adjust only what they must.
    public func applying(_ style: ReadingStyle) -> ReaderPreferences {
        var p = self
        switch style {
        case .automatic, .manga: break
        case .manhwa, .manhua, .webtoon:
            p.mode = .vertical; p.direction = .leftToRight; p.trimMargins = false
        case .comic:
            p.direction = .leftToRight; p.advanceOnLeftSwipe = true
        }
        return p
    }
}

public struct ChapterProgress: Codable, Equatable, Sendable {
    public var page: Int
    public var pageCount: Int
    public var completed: Bool
    public var updated: Date
    public var fraction: Double { pageCount > 0 ? Double(page + 1) / Double(pageCount) : 0 }
    public init(page: Int, pageCount: Int, completed: Bool = false, updated: Date = Date()) {
        self.pageCount = max(0, pageCount)
        self.page = min(max(0, page), max(0, pageCount - 1))
        self.completed = completed; self.updated = updated
    }
}
public struct LibraryState: Codable, Sendable {
    public var preferences = ReaderPreferences()
    public var chapters: [Chapter] = []
    public var progress: [String: ChapterProgress] = [:]
    public var lastChapterID: String?
    public var showsBerserk: Bool?
    public var catalogUpdated: Date?
    // Manga added from web links. Optional so older saved libraries still decode.
    public var shelf: [Chapter]?
    /// Series added from links or Files, each with its full chapter list in reading order.
    public var series: [MangaSeries]?
    /// Bumped when built-in defaults change, so saved settings migrate once.
    public var defaultsVersion: Int?
    /// Per-series reading style chosen by the user, keyed by series id ("berserk" for the built-in source).
    public var styleOverrides: [String: ReadingStyle]?
    /// Per-series style detected from the site or the page shapes.
    public var detectedStyles: [String: ReadingStyle]?
    /// Cover images found automatically (first page of the first chapter) for series without one.
    public var covers: [String: URL]?
    /// Series whose site cover art has been looked for (so it happens once).
    public var coverChecked: [String]?
    /// Notify about new chapters (background checks, notifications, icon badge). nil means off.
    public var notifyNew: Bool?
    /// Seconds spent reading per day ("2026-11-23" → seconds).
    public var readingLog: [String: Double]?
    /// Chapters finished per day.
    public var finishedLog: [String: Int]?
    /// Series hidden from the library until unlocked.
    public var hiddenSeries: [String]?
    /// Your own shelves: category name → series ids, in display order.
    public var categories: [LibraryCategory]?
    /// Downloads: only on Wi-Fi; remove a chapter's download once it's read.
    public var downloadWiFiOnly: Bool?
    public var deleteAfterReading: Bool?
    /// Where you are in each book: section and character offset (survives font changes).
    public var bookPositions: [String: BookPosition]?
    /// AniList: linked media per series, and the signed-in token.
    public var aniListLinks: [String: Int]?
    public var aniListToken: String?
    public var aniListUser: String?
    /// History shows only reading after this moment (set by "Clear history").
    public var historyCleared: Date?
    public var hiddenHistoryDates: [String: Date]?
    public var ignoredRecommendationSeries: Set<String>?
    public var hiddenRecommendationTitles: Set<String>?
    /// Legacy per-series cleanup strengths from an earlier filter experiment. No longer read:
    /// values left over from that build forced enhancement off for some series.
    public var seriesCleanup: [String: Double]?
    /// Per-series "Enhance scans" choice (true on, false off). Missing means the global setting.
    public var seriesEnhance: [String: Bool]?
    /// Covers the user picked (a page or a photo); these win over automatic ones.
    public var customCovers: [String: URL]?
    /// Chapters that appeared since the last check and have not been opened yet.
    public var newChapterIDs: [String]?
    public var lastUpdateCheck: Date?
    /// Download new chapters automatically for series you have started.
    public var autoDownloadNew: Bool?
    /// Incognito: read without saving progress or history.
    public var incognito: Bool?
    /// While reading, download the next two chapters in the background.
    public var downloadAhead: Bool?
    /// Sites saved in the Browse tab.
    public var sites: [SavedSite]?
    /// Bundled destinations you removed (so updates don't add them back).
    public var removedBundled: [String]?
    /// Bundled source categories already added (onboarding and updates add each category's sources once).
    public var bundledCategories: [String]?
    /// Favourite series (a library tab).
    public var favorites: [String]?
    /// Places you marked inside chapters.
    public var bookmarks: [Bookmark]?
    /// Where you are in each novel, by series id.
    public var novelPositions: [String: NovelPosition]?
    public init() {}
    public mutating func record(_ chapter: Chapter, page: Int, count: Int, completed: Bool = false) {
        lastChapterID = chapter.id
        progress[chapter.id] = ChapterProgress(page: page, pageCount: count,
            completed: completed || progress[chapter.id]?.completed == true)
    }
}

public struct PageGroup: Equatable, Identifiable, Sendable {
    public let indices: [Int]
    public var id: Int { indices[0] }
    public func displayOrder(_ direction: ReadingDirection) -> [Int] {
        direction == .rightToLeft ? Array(indices.reversed()) : indices
    }
}
public enum ReadingOrder {
    // A spread must have enough space for two readable portrait pages.
    // Measure the live reader viewport in points, including resized windows.
    public static func canPair(width: Double, height: Double) -> Bool {
        width > 0 && height > 0 && width >= 600 && width >= height * 1.12
    }
    // Source DOM order is the story order. Never reverse individual artwork.
    public static func groups(count: Int, landscape: Bool, spreads: Bool, wide: Set<Int>) -> [PageGroup] {
        var result: [PageGroup] = []
        var i = 0
        while i < count {
            if landscape && spreads && !wide.contains(i) && i + 1 < count && !wide.contains(i + 1) {
                result.append(PageGroup(indices: [i, i + 1])); i += 2
            } else { result.append(PageGroup(indices: [i])); i += 1 }
        }
        return result
    }
    public static func destination(current: Int, count: Int, swipeLeft: Bool, advanceOnLeft: Bool) -> Int? {
        let next = current + (swipeLeft == advanceOnLeft ? 1 : -1)
        return (0..<count).contains(next) ? next : nil
    }
}

public enum SourceError: Error, LocalizedError, Equatable, Sendable {
    case unavailable(Int), restricted, missingChapter, unsupportedStructure, timeout, invalidImage, insecureURL, listing
    public var errorDescription: String? {
        switch self {
        case .unavailable(let status): "The site isn’t responding right now (error \(status)). Try again later."
        case .restricted: "This site only opens in a browser. Open it in the browser once (it may ask you to confirm you’re human), then try again."
        case .missingChapter: "This chapter is no longer available on the website."
        case .listing: "This page lists lots of different series. Open the one you want, then add it."
        case .unsupportedStructure: "eclipsereader couldn’t find this chapter’s pages. Open it in the browser, or try again."
        case .timeout: "The request timed out. Check your connection and try again."
        case .invalidImage: "This page didn’t load as an image. Try again, or open it in the browser."
        case .insecureURL: "The site sent the reader to an unsafe address, so it was blocked."
        }
    }
}

public struct BookPosition: Codable, Hashable, Sendable {
    public var section: Int
    public var offset: Int
    public var updated: Date
    public init(section: Int, offset: Int, updated: Date = Date()) { self.section = section; self.offset = offset; self.updated = updated }
}

/// A shelf of the user's own making ("Plan to read", "Favourites"…).
public struct LibraryCategory: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var seriesIDs: [String]
    public init(id: String = UUID().uuidString, name: String, seriesIDs: [String] = []) {
        self.id = id; self.name = name; self.seriesIDs = seriesIDs
    }
}

/// A whole manga/manhwa added by the user, from a website or from Files.
public struct MangaSeries: Codable, Hashable, Identifiable, Sendable {
    /// web: pictures from a website · local: pictures from Files · book: a book file · novel: text chapters from a website.
    public enum Kind: String, Codable, Sendable { case web, local, book, novel }
    public let id: String
    public var url: URL
    public var title: String
    public var cover: URL?
    public var kind: Kind
    /// Chapters in reading order (first chapter first).
    public var chapters: [Chapter]
    public var added: Date
    /// Older records predate explicit membership and belong to the library.
    public var inLibrary: Bool?
    /// Direct source of a downloaded catalog book, for reopening the saved copy.
    public var bookDownloadURL: URL?
    public var isCatalogBookPreview: Bool { kind == .book && bookDownloadURL != nil && url.scheme == "https" }
    public var isLibraryMember: Bool { inLibrary ?? true }
    /// Synopsis from the site, when it has one.
    public var summary: String?
    /// The writer, for books.
    public var author: String?
    /// A second site that fills in chapters this one is missing (Neko's "merge"), checked on every update.
    public var merged: URL?
    /// A book file that is a light novel volume: it shelves with novels, not with books.
    public var lightNovel: Bool?
    /// The language the text is written in ("ja", "zh", "ko", "en"), when known (novels).
    public var language: String?
    public init(id: String, url: URL, title: String, cover: URL? = nil, kind: Kind, chapters: [Chapter], added: Date = Date(),
                summary: String? = nil, author: String? = nil, merged: URL? = nil, lightNovel: Bool? = nil, language: String? = nil) {
        self.id = id; self.url = url; self.title = title; self.cover = cover; self.kind = kind; self.chapters = chapters; self.added = added
        self.summary = summary; self.author = author; self.merged = merged; self.lightNovel = lightNovel; self.language = language
    }
    /// Light novels and web novels: web text chapters, or a book file marked as a light novel.
    public var isNovel: Bool { kind == .novel || (kind == .book && lightNovel == true) }
    /// A normal book (shown only when books are turned on).
    public var isPlainBook: Bool { kind == .book && lightNovel != true }
    /// Read as text rather than pictures.
    public var readsAsText: Bool { kind == .book || kind == .novel }
    /// Comes from a website and can be checked for new chapters.
    public var isOnline: Bool { kind == .web || kind == .novel }
}

/// Fills the gaps in one site's chapter list with another's (Neko-style merging).
public enum ChapterMerge {
    /// A chapter's number as a comparable key ("12", "12.5").
    public static func key(_ chapter: Chapter) -> String? {
        let value = Double(chapter.number) ?? ChapterOrder.number(chapter.title) ?? ChapterOrder.number(chapter.url.path)
        return value.map { $0 == $0.rounded() ? String(Int($0)) : String($0) }
    }
    /// The other site's chapters whose numbers the main list doesn't have.
    public static func missing(from main: [Chapter], in other: [Chapter]) -> [Chapter] {
        let have = Set(main.compactMap(key))
        var seen = Set<String>()
        return other.filter { chapter in
            guard let k = key(chapter), !have.contains(k) else { return false }
            return seen.insert(k).inserted
        }
    }
    /// The site a host belongs to ("www.webtoons.com" and "m.webtoons.com" → "webtoons.com").
    public static func site(_ host: String?) -> String {
        (host ?? "").lowercased().split(separator: ".").suffix(2).joined(separator: ".")
    }
    /// Whether a chapter came from the filling site (by site, so a main site's own subdomains never count).
    public static func isFiller(_ chapter: Chapter, from fillerHost: String?) -> Bool {
        guard fillerHost != nil else { return false }
        return site(chapter.url.host) == site(fillerHost)
    }
    /// Main chapters, plus filler chapters for numbers the main site lacks, in reading order.
    /// A filler chapter is dropped once the main site has its number, unless `keep` says otherwise (reading progress).
    public static func combine(main: [Chapter], filler: [Chapter], fillerHost: String?, keep: (Chapter) -> Bool = { _ in false }) -> [Chapter] {
        let mainOnly = main.filter { !isFiller($0, from: fillerHost) }
        let mainNumbers = Set(mainOnly.compactMap(key))
        let oldFiller = main.filter { isFiller($0, from: fillerHost) }
        let keptFiller = oldFiller.filter { chapter in key(chapter).map { !mainNumbers.contains($0) } ?? true || keep(chapter) }
        let newFiller = missing(from: mainOnly + keptFiller, in: filler)
        return ChapterOrder.sorted(mainOnly + keptFiller + newFiller)
    }
}

/// Sorting helpers shared by link and file imports.
public enum ChapterOrder {
    /// The chapter number in a title or URL ("Chapter 12.5", "ch-12", "Episode 3", "第3話", "3화"), if any.
    public static func number(_ text: String) -> Double? {
        let patterns = [#"(?i)(?:chapter|chap|ch|episode|ep|vol(?:ume)?)[\s._\-]*([0-9]+(?:[.\-][0-9]+)?)"#,
                        #"第\s*([0-9]+)\s*[話话章]"#, #"([0-9]+)\s*화"#]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range(at: 1), in: text) else { continue }
            if let n = Double(text[r].replacingOccurrences(of: "-", with: ".")) { return n }
        }
        return nil
    }
    /// Puts chapters into reading order. Uses chapter numbers when most chapters have one,
    /// otherwise assumes the page listed newest-first if it ends with the oldest number.
    public static func sorted(_ chapters: [Chapter]) -> [Chapter] {
        let numbers = chapters.map { number($0.title) ?? number($0.url.path) }
        let known = numbers.compactMap { $0 }
        if known.count >= max(2, chapters.count * 4 / 5) {
            return zip(chapters, numbers).enumerated().sorted { a, b in
                let x = a.element.1 ?? .infinity, y = b.element.1 ?? .infinity
                return x == y ? a.offset < b.offset : x < y
            }.map { $0.element.0 }
        }
        if let first = known.first, let last = known.last, first > last { return chapters.reversed() }
        return chapters
    }
    public static func natural(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.numeric, .caseInsensitive]) == .orderedAscending
    }
}
