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

/// A website the user saved in the Browse tab.
public struct SavedSite: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var url: URL
    public var id: String { url.absoluteString }
    public init(name: String, url: URL) { self.name = name; self.url = url }
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
    public enum Kind: String, Codable, Sendable { case web, local, book }
    public let id: String
    public var url: URL
    public var title: String
    public var cover: URL?
    public var kind: Kind
    /// Chapters in reading order (first chapter first).
    public var chapters: [Chapter]
    public var added: Date
    /// Synopsis from the site, when it has one.
    public var summary: String?
    /// The writer, for books.
    public var author: String?
    /// A second site that fills in chapters this one is missing (Neko's "merge"), checked on every update.
    public var merged: URL?
    public init(id: String, url: URL, title: String, cover: URL? = nil, kind: Kind, chapters: [Chapter], added: Date = Date(),
                summary: String? = nil, author: String? = nil, merged: URL? = nil) {
        self.id = id; self.url = url; self.title = title; self.cover = cover; self.kind = kind; self.chapters = chapters; self.added = added
        self.summary = summary; self.author = author; self.merged = merged
    }
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
    /// Main chapters, plus filler chapters for numbers the main site lacks, in reading order.
    /// A filler chapter is dropped once the main site has its number, unless `keep` says otherwise (reading progress).
    public static func combine(main: [Chapter], filler: [Chapter], mainHost: String?, keep: (Chapter) -> Bool = { _ in false }) -> [Chapter] {
        let ownHost = mainHost?.lowercased()
        let mainOnly = main.filter { $0.url.host?.lowercased() == ownHost }
        let mainNumbers = Set(mainOnly.compactMap(key))
        let oldFiller = main.filter { $0.url.host?.lowercased() != ownHost }
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
