import Foundation

/// Native connections for sites with a reliable public interface. Everything else goes
/// through the generic page reader in `LinkedSource`.
enum SiteAdapters {
    /// Series or chapter info from a dedicated adapter, or nil when no adapter handles the link.
    static func inspect(_ url: URL, http: any HTTPTransport) async throws -> LinkInspection? {
        if MangaDex.handles(url) { return try await MangaDex(http: http).inspect(url) }
        if WeebCentral.handles(url) { return try await WeebCentral(http: http).inspect(url) }
        return nil
    }
    static func pages(_ url: URL, http: any HTTPTransport) async throws -> [MangaPage]? {
        if MangaDex.chapterID(url) != nil { return try await MangaDex(http: http).pages(url) }
        if WeebCentral.chapterID(url) != nil { return try await WeebCentral(http: http).pages(url) }
        return nil
    }
}

// MARK: - MangaDex (official public API, api.mangadex.org)

struct MangaDex {
    let http: any HTTPTransport
    static let uuid = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#

    static func handles(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), host == "mangadex.org" || host.hasSuffix(".mangadex.org") else { return false }
        return titleID(url) != nil || chapterID(url) != nil
    }
    static func titleID(_ url: URL) -> String? { component(after: "title", in: url) }
    static func chapterID(_ url: URL) -> String? {
        guard let host = url.host?.lowercased(), host.hasSuffix("mangadex.org") else { return nil }
        return component(after: "chapter", in: url)
    }
    private static func component(after key: String, in url: URL) -> String? {
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: key), i + 1 < parts.count,
              parts[i + 1].range(of: "^" + uuid + "$", options: .regularExpression) != nil else { return nil }
        return parts[i + 1].lowercased()
    }

    private func json(_ url: URL) async throws -> [String: Any] {
        let data = try await http.fetch(url, referer: nil, image: false)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SourceError.unsupportedStructure }
        if (object["result"] as? String) == "error" { throw SourceError.missingChapter }
        return object
    }

    func inspect(_ url: URL) async throws -> LinkInspection {
        var mangaID = Self.titleID(url)
        if mangaID == nil, let chapter = Self.chapterID(url) {
            // A chapter link: find its series, then list everything.
            let info = try await json(URL(string: "https://api.mangadex.org/chapter/\(chapter)?includes[]=manga")!)
            let relations = ((info["data"] as? [String: Any])?["relationships"] as? [[String: Any]]) ?? []
            mangaID = relations.first { $0["type"] as? String == "manga" }?["id"] as? String
        }
        guard let mangaID else { throw SourceError.unsupportedStructure }
        let info = try await json(URL(string: "https://api.mangadex.org/manga/\(mangaID)?includes[]=cover_art")!)
        let data = info["data"] as? [String: Any] ?? [:]
        let attributes = data["attributes"] as? [String: Any] ?? [:]
        let title = Self.displayTitle(attributes) ?? "MangaDex"
        let relations = data["relationships"] as? [[String: Any]] ?? []
        let coverFile = (relations.first { $0["type"] as? String == "cover_art" }?["attributes"] as? [String: Any])?["fileName"] as? String
        let cover = coverFile.flatMap { URL(string: "https://uploads.mangadex.org/covers/\(mangaID)/\($0).512.jpg") }
        let original = (attributes["originalLanguage"] as? String ?? "").lowercased()
        let style = Self.style(language: original, tags: attributes["tags"])

        // Every translation of every chapter first; then one per chapter number, preferring the
        // group that translated the most, so a series reads in one consistent translation.
        struct Entry { let key: String; let group: String; let chapter: Chapter }
        var entries: [Entry] = []
        var offset = 0
        let ratings = ["safe", "suggestive", "erotica", "pornographic"].map { "contentRating[]=\($0)" }.joined(separator: "&")
        while offset < 5000 {
            let feed = try await json(URL(string: "https://api.mangadex.org/manga/\(mangaID)/feed?translatedLanguage[]=en&order[chapter]=asc&order[volume]=asc&limit=500&offset=\(offset)&includeExternalUrl=0&\(ratings)")!)
            let items = feed["data"] as? [[String: Any]] ?? []
            for item in items {
                guard let id = item["id"] as? String, let a = item["attributes"] as? [String: Any] else { continue }
                if (a["pages"] as? Int ?? 1) == 0 { continue }
                let number = a["chapter"] as? String ?? ""
                let key = number.isEmpty ? id : number
                let group = ((item["relationships"] as? [[String: Any]]) ?? []).first { $0["type"] as? String == "scanlation_group" }?["id"] as? String ?? ""
                let name = (a["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let label = number.isEmpty ? (name ?? "Oneshot") : "Chapter \(number)" + (name.map { " · \($0)" } ?? "")
                let published = (a["publishAt"] as? String).flatMap(Self.day)
                entries.append(Entry(key: key, group: group,
                                     chapter: Chapter(url: URL(string: "https://mangadex.org/chapter/\(id)")!, title: label, number: number, published: published)))
            }
            let total = feed["total"] as? Int ?? 0
            offset += 500
            if items.isEmpty || offset >= total { break }
        }
        let chapters = Self.oneTranslation(entries.map { (key: $0.key, group: $0.group, chapter: $0.chapter) })
        var pages: [MangaPage] = []
        if Self.chapterID(url) != nil { pages = (try? await self.pages(url)) ?? [] }
        let about = Self.localized(attributes["description"]).map {
            // MangaDex descriptions are Markdown; keep the first paragraph-ish part, without links.
            $0.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
              .components(separatedBy: "\n---").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? $0
        }
        return LinkInspection(title: title, cover: cover, pages: pages, chapters: chapters, style: style, summary: about)
    }

    func pages(_ url: URL) async throws -> [MangaPage] {
        guard let id = Self.chapterID(url) else { throw SourceError.unsupportedStructure }
        let server = try await json(URL(string: "https://api.mangadex.org/at-home/server/\(id)")!)
        guard let base = server["baseUrl"] as? String, let chapter = server["chapter"] as? [String: Any],
              let hash = chapter["hash"] as? String, let files = chapter["data"] as? [String], !files.isEmpty
        else { throw SourceError.missingChapter }
        return files.enumerated().compactMap { i, file in
            URL(string: "\(base)/data/\(hash)/\(file)").map { MangaPage(url: $0, label: "Page \(i + 1)") }
        }
    }

    /// One chapter per number. When several groups translated a chapter, the group with the most
    /// chapters overall wins, then the earliest listed.
    static func oneTranslation(_ entries: [(key: String, group: String, chapter: Chapter)]) -> [Chapter] {
        var counts: [String: Int] = [:]
        for entry in entries { counts[entry.group, default: 0] += 1 }
        var best: [String: (rank: Int, chapter: Chapter)] = [:]
        var order: [String] = []
        for entry in entries {
            let rank = counts[entry.group] ?? 0
            if let current = best[entry.key] {
                if rank > current.rank { best[entry.key] = (rank, entry.chapter) }
            } else {
                order.append(entry.key)
                best[entry.key] = (rank, entry.chapter)
            }
        }
        return ChapterOrder.sorted(order.compactMap { best[$0]?.chapter })
    }
    /// Korean → manhwa, Chinese → manhua, Japanese → manga; other long-strip titles are webtoons.
    static func style(language: String, tags: Any?) -> ReadingStyle {
        let names = ((tags as? [[String: Any]]) ?? []).compactMap { (($0["attributes"] as? [String: Any])?["name"] as? [String: String])?["en"] }
        let strip = names.contains("Long Strip") || names.contains("Web Comic")
        if language.hasPrefix("ko") { return .manhwa }
        if language.hasPrefix("zh") { return .manhua }
        if language == "ja" { return strip ? .webtoon : .manga }
        return strip ? .webtoon : .comic
    }
    static func localized(_ value: Any?) -> String? {
        guard let map = value as? [String: String], !map.isEmpty else { return nil }
        return map["en"] ?? map["ja-ro"] ?? map["ko-ro"] ?? map.values.first
    }
    static func altTitle(_ value: Any?) -> String? {
        (value as? [[String: String]])?.compactMap { $0["en"] }.first
    }
    /// The series' name, shortened when MangaDex lists a short English form of a long romanised title
    /// ("Jujutsu Kaisen 0: Toukyou Toritsu Jujutsu Koutou Senmon Gakkou" → "Jujutsu Kaisen 0").
    static func displayTitle(_ attributes: [String: Any]) -> String? {
        guard let main = localized(attributes["title"]) else { return altTitle(attributes["altTitles"]) }
        let english = (attributes["altTitles"] as? [[String: String]])?.compactMap { $0["en"] } ?? []
        let lower = main.lowercased()
        if main.count > 24, let short = english.filter({ $0.count >= 4 && $0.count < main.count && lower.hasPrefix($0.lowercased()) })
            .max(by: { $0.count < $1.count }) {
            return short
        }
        return main
    }
    /// Whether MangaDex hosts any English chapter of a title (nil when it couldn't be checked).
    static func hasReadableChapters(_ id: String, http: any HTTPTransport) async -> Bool? {
        let ratings = ["safe", "suggestive", "erotica", "pornographic"].map { "contentRating[]=\($0)" }.joined(separator: "&")
        guard let url = URL(string: "https://api.mangadex.org/manga/\(id)/feed?translatedLanguage[]=en&includeExternalUrl=0&limit=1&\(ratings)"),
              let data = try? await http.fetch(url, referer: nil, image: false),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let total = object["total"] as? Int else { return nil }
        return total > 0
    }
    static func day(_ iso: String) -> String? {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) else { return nil }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.dateFormat = "MMM d, yyyy"
        return out.string(from: date)
    }
}

// MARK: - WeebCentral (server-rendered pages; the full chapter list and images load from fragments)

struct WeebCentral {
    let http: any HTTPTransport
    static func handles(_ url: URL) -> Bool { isHost(url) && (seriesID(url) != nil || chapterID(url) != nil) }
    static func isHost(_ url: URL) -> Bool { url.host?.lowercased().hasSuffix("weebcentral.com") ?? false }
    static func seriesID(_ url: URL) -> String? { component(after: "series", in: url) }
    static func chapterID(_ url: URL) -> String? { isHost(url) ? component(after: "chapters", in: url) : nil }
    private static func component(after key: String, in url: URL) -> String? {
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: key), i + 1 < parts.count else { return nil }
        let id = parts[i + 1]
        return id.range(of: #"^[0-9A-Za-z]{10,40}$"#, options: .regularExpression) != nil ? id : nil
    }
    private func text(_ url: URL, referer: URL?) async throws -> String {
        let data = try await http.fetch(url, referer: referer, image: false)
        guard let html = String(data: data, encoding: .utf8) else { throw SourceError.unsupportedStructure }
        return html
    }

    func inspect(_ url: URL) async throws -> LinkInspection {
        if let chapter = Self.chapterID(url), Self.seriesID(url) == nil {
            // A chapter: its page links back to the series.
            let html = try await text(url, referer: nil)
            if let href = LinkedSource.firstMatch(#"href=["']((?:https://weebcentral\.com)?/series/[0-9A-Za-z]+[^"']*)["']"#, html),
               let series = LinkedSource.resolve(href, base: URL(string: "https://weebcentral.com/")!) {
                var found = try await inspect(series)
                found = LinkInspection(title: found.title, cover: found.cover, pages: (try? await pages(url)) ?? [],
                                       chapters: found.chapters, style: found.style, summary: found.summary)
                _ = chapter
                return found
            }
            return LinkInspection(title: LinkedSource.title(in: html) ?? "Chapter", cover: nil, pages: try await pages(url),
                                  chapters: [Chapter(url: url, title: LinkedSource.title(in: html) ?? "Chapter", number: "")])
        }
        guard let id = Self.seriesID(url) else { throw SourceError.unsupportedStructure }
        let html = try await text(url, referer: nil)
        var chapters: [Chapter] = []
        if let full = URL(string: "https://weebcentral.com/series/\(id)/full-chapter-list"),
           let list = try? await text(full, referer: url) {
            chapters = Self.chapters(in: list)
        }
        if chapters.isEmpty { chapters = Self.chapters(in: html) }
        let lower = html.lowercased()
        let style: ReadingStyle? = lower.contains("manhua") ? .manhua : lower.contains("manhwa") ? .manhwa : lower.contains("manga") ? .manga : nil
        return LinkInspection(title: LinkedSource.seriesTitle(in: html) ?? "WeebCentral", cover: LinkedSource.cover(in: html, base: url),
                              pages: [], chapters: chapters, style: style, summary: LinkedSource.synopsis(in: html))
    }

    static func chapters(in html: String) -> [Chapter] {
        var seen = Set<String>()
        var found: [Chapter] = []
        // Links are absolute on older pages and relative ("/chapters/…") on current ones.
        for m in LinkedSource.matches(#"(?is)<a\b[^>]*href=["']((?:https://weebcentral\.com)?/chapters/[0-9A-Za-z]+)["'][^>]*>(.*?)</a>"#, html) {
            guard let url = URL(string: m[0].hasPrefix("/") ? "https://weebcentral.com" + m[0] : m[0]),
                  seen.insert(url.absoluteString).inserted else { continue }
            let text = LinkedSource.plain(m[1])
            let name = LinkedSource.firstMatch(#"((?:Chapter|Episode|Ch\.?)\s*[\d.]+)"#, text) ?? text
            let n = ChapterOrder.number(name) ?? ChapterOrder.number(text)
            found.append(Chapter(url: url, title: name.isEmpty ? "Chapter" : name, number: n.map { LinkedSource.format($0) } ?? ""))
        }
        return ChapterOrder.sorted(found)
    }

    func pages(_ url: URL) async throws -> [MangaPage] {
        guard let id = Self.chapterID(url),
              let images = URL(string: "https://weebcentral.com/chapters/\(id)/images?is_prev=False&current_page=1&reading_style=long_strip")
        else { throw SourceError.unsupportedStructure }
        let html = try await text(images, referer: url)
        return try LinkedSource.detect(in: html, base: url)
    }
}

// MARK: - Discover (native search and popular lists)

public struct DiscoverItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let url: URL
    public let cover: URL?
    public let detail: String?
}

public enum Discover {
    private static func base(limit: Int, ratings: [String] = ["safe", "suggestive"]) -> [URLQueryItem] {
        [URLQueryItem(name: "limit", value: String(limit)),
         URLQueryItem(name: "includes[]", value: "cover_art"),
         URLQueryItem(name: "availableTranslatedLanguage[]", value: "en"),
         URLQueryItem(name: "hasAvailableChapters", value: "true")]
            + ratings.map { URLQueryItem(name: "contentRating[]", value: $0) }
    }
    /// Keeps titles that have at least one English chapter MangaDex itself hosts. Licensed series
    /// (Jujutsu Kaisen, Solo Leveling…) often only link out to the publisher, so nothing can be read here.
    /// Checks a few at a time to stay inside MangaDex's rate limit; a title that can't be checked is kept.
    public static func readable(_ items: [DiscoverItem], http: any HTTPTransport = WebsiteHTTPClient()) async -> [DiscoverItem] {
        guard !items.isEmpty else { return [] }
        var keep = [Bool](repeating: true, count: items.count)
        await withTaskGroup(of: (Int, Bool).self) { group in
            var next = 0
            while next < min(2, items.count) {
                let index = next, id = items[index].id
                group.addTask { (index, await MangaDex.hasReadableChapters(id, http: http) ?? true) }
                next += 1
            }
            // About four requests a second, inside MangaDex's limit of five.
            while let result = await group.next() {
                keep[result.0] = result.1
                if next < items.count {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    let index = next, id = items[index].id
                    group.addTask { (index, await MangaDex.hasReadableChapters(id, http: http) ?? true) }
                    next += 1
                }
            }
        }
        return items.indices.filter { keep[$0] }.map { items[$0] }
    }
    /// MangaDex titles with English chapters: popular ones, or matches for a search.
    public static func mangaDex(query: String? = nil, limit: Int = 24, http: any HTTPTransport = WebsiteHTTPClient()) async throws -> [DiscoverItem] {
        var parts = URLComponents(string: "https://api.mangadex.org/manga")!
        var items = base(limit: limit)
        if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(URLQueryItem(name: "title", value: query))
            items.append(URLQueryItem(name: "order[relevance]", value: "desc"))
        } else {
            items.append(URLQueryItem(name: "order[followedCount]", value: "desc"))
        }
        parts.queryItems = items
        guard let url = parts.url else { return [] }
        return await readable(try parse(try await http.fetch(url, referer: nil, image: false)).map(\.item), http: http)
    }

    /// "Because you read …": finds the series on MangaDex, then the best-rated titles sharing its genres.
    /// `style` is the medium you read it as (manga, manhwa, manhua, webtoon, comic). Results stay in that
    /// medium even when MangaDex files the seed differently, and a seed MangaDex spells differently is
    /// still found (alternative and partial titles), so non-Japanese series get recommendations too.
    /// `verify: false` skips the per-title chapter check (about 5 s at MangaDex's rate limit), so the
    /// shelf can show at once and drop unreadable titles afterwards with `readable(_:)`.
    public static func similar(to title: String, excluding: Set<String> = [], limit: Int = 16, style: ReadingStyle? = nil,
                               verify: Bool = true,
                               http: any HTTPTransport = WebsiteHTTPClient()) async throws -> [DiscoverItem] {
        let wanted = style.flatMap { $0 == .automatic ? nil : $0 }
        // Library titles are often worded differently from MangaDex ("Gurren Lagann Tengen Toppa
        // Gurren Lagann" vs "Tengen Toppa Gurren Lagann"): try the title, then shorter forms of it.
        var source: (item: DiscoverItem, tags: Any?, language: String, style: ReadingStyle)?
        var lastError: (any Error)?
        for query in lookupQueries(title) {
            var lookup = URLComponents(string: "https://api.mangadex.org/manga")!
            lookup.queryItems = base(limit: 10, ratings: ["safe", "suggestive", "erotica"]) + [
                URLQueryItem(name: "title", value: query), URLQueryItem(name: "order[relevance]", value: "desc")]
            guard let lookupURL = lookup.url else { continue }
            let found: [(item: DiscoverItem, tags: Any?, language: String, style: ReadingStyle)]
            do { found = try parse(try await http.fetch(lookupURL, referer: nil, image: false)) } catch { lastError = error; continue }
            source = found.first { Self.sameTitle($0.item.title, title) }
                ?? found.first { entry in Self.titleMatches(entry.item.title, title) && (wanted.map { mediumMatches(entry.style, $0) } ?? true) }
            if source != nil { break }
        }
        guard let source else {
            if let lastError { throw lastError }
            return []
        }
        let medium = wanted ?? source.style
        let tags = pickTags(source.tags)
        var parts = URLComponents(string: "https://api.mangadex.org/manga")!
        var query = base(limit: limit + 12)
        // The language that defines the medium; webtoons can be Korean, Chinese or English, so keep the seed's.
        let language = Self.language(for: medium) ?? source.language
        if !language.isEmpty { query.append(URLQueryItem(name: "originalLanguage[]", value: language)) }
        query += tags.map { URLQueryItem(name: "includedTags[]", value: $0) }
        if !tags.isEmpty { query.append(URLQueryItem(name: "includedTagsMode", value: "AND")) }
        query.append(URLQueryItem(name: "order[rating]", value: "desc"))
        parts.queryItems = query
        guard let url = parts.url else { return [] }
        let list = try parse(try await http.fetch(url, referer: nil, image: false))
            .filter { mediumMatches($0.style, medium) }.map(\.item)
        let skip = Array(excluding)
        let seedKey = franchiseKey(title), sourceKey = franchiseKey(source.item.title)
        var fresh = list.filter { item in
            item.id != source.item.id && !skip.contains { Self.titleMatches($0, item.title) }
                // Not the series itself again under another name, nor its own spin-offs.
                && (seedKey.isEmpty || franchiseKey(item.title) != seedKey)
                && (sourceKey.isEmpty || franchiseKey(item.title) != sourceKey)
        }
        fresh = onePerFranchise(fresh)
        guard verify else { return Array(fresh.prefix(limit + 4)) }
        return Array(await readable(Array(fresh.prefix(limit + 4)), http: http).prefix(limit))
    }

    /// Same medium for recommendations. Manhwa and webtoons are both vertical Korean-style strips, so
    /// they count as one family; manga, manhua and comics stay separate.
    public static func mediumMatches(_ found: ReadingStyle, _ wanted: ReadingStyle) -> Bool {
        if found == wanted { return true }
        let vertical: Set<ReadingStyle> = [.manhwa, .webtoon]
        return vertical.contains(found) && vertical.contains(wanted)
    }
    static func language(for style: ReadingStyle) -> String? {
        switch style {
        case .manga: "ja"
        case .manhwa: "ko"
        case .manhua: "zh"
        case .comic: "en"
        case .webtoon, .automatic: nil
        }
    }
    /// Words of a title for comparing, without punctuation or filler words.
    static func titleWords(_ title: String) -> Set<String> {
        let filler: Set<String> = ["the", "a", "an", "of", "no", "wa", "to", "ga", "wo", "and"]
        return Set(title.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { !filler.contains($0) })
    }
    /// The same work under another wording: identical, a near-identical prefix, or every word of the
    /// shorter title (at least two) appearing in the longer one, in any order.
    public static func titleMatches(_ a: String, _ b: String) -> Bool {
        if sameTitle(a, b) || looselySameTitle(a, b) { return true }
        let x = titleWords(a), y = titleWords(b)
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        return short.count >= 2 && short.isSubset(of: long) && Double(short.count) >= Double(long.count) * 0.5
    }
    /// The title, then shorter forms: before a subtitle or bracket, and its first two words.
    static func lookupQueries(_ title: String) -> [String] {
        var queries = [title]
        if let cut = title.range(of: #"\s*[:~(\[–—]|\s+-\s+"#, options: .regularExpression) {
            // A title with a subtitle: the part before it is the series name.
            let head = String(title[..<cut.lowerBound]).trimmingCharacters(in: .whitespaces)
            if head.count >= 3 { queries.append(head) }
        } else {
            // A long run-on title ("Gurren Lagann Tengen Toppa Gurren Lagann"): its first two words.
            let words = title.split(separator: " ")
            if words.count >= 4 { queries.append(words.prefix(2).joined(separator: " ")) }
        }
        var seen = Set<String>()
        return queries.filter { seen.insert($0.lowercased()).inserted }
    }
    /// The series a title belongs to: without its part, subtitle or edition ("JoJo no Kimyou na Bouken:
    /// Part 7" and "Part 8" share one; "Chainsaw Man (Official Colored)" shares "Chainsaw Man").
    public static func franchiseKey(_ title: String) -> String {
        var t = title.lowercased()
        if let cut = t.range(of: #"\s*[:~(\[–—]|\s+-\s+|\s+part\s+\d|\s+season\s+\d"#, options: .regularExpression) {
            t = String(t[..<cut.lowerBound])
        }
        for word in ["official colored", "colored", "coloured", "digital colored comics", "full color", "remastered"] {
            t = t.replacingOccurrences(of: word, with: "")
        }
        return t.filter { $0.isLetter || $0.isNumber }
    }
    /// One entry per series, preferring the plain edition over colored or remastered ones.
    static func onePerFranchise(_ items: [DiscoverItem]) -> [DiscoverItem] {
        func isVariant(_ title: String) -> Bool {
            let t = title.lowercased()
            return t.contains("colored") || t.contains("coloured") || t.contains("full color") || t.contains("remastered")
        }
        var chosen: [String: Int] = [:]
        var result: [DiscoverItem] = []
        for item in items {
            let key = franchiseKey(item.title)
            if key.isEmpty { result.append(item); continue }
            if let index = chosen[key] {
                if isVariant(result[index].title) && !isVariant(item.title) { result[index] = item }
            } else {
                chosen[key] = result.count
                result.append(item)
            }
        }
        return result
    }

    /// "Solo Leveling" vs "Solo Leveling (Official)", "The Beginning After the End" vs "Beginning After the End".
    static func looselySameTitle(_ a: String, _ b: String) -> Bool {
        func clean(_ s: String) -> String {
            var t = s.lowercased()
            if let paren = t.firstIndex(where: { $0 == "(" || $0 == "[" }) { t = String(t[..<paren]) }
            for article in ["the ", "a "] where t.hasPrefix(article) { t.removeFirst(article.count) }
            return t.filter { $0.isLetter || $0.isNumber }
        }
        let x = clean(a), y = clean(b)
        guard min(x.count, y.count) >= 5 else { return x == y && !x.isEmpty }
        // A prefix only counts when it is most of the title, so "Bleach" doesn't match a long spin-off.
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        return x == y || (long.hasPrefix(short) && Double(short.count) >= Double(long.count) * 0.7)
    }

    /// Up to two genre tags (themes fill in when a series has fewer), most specific first.
    static func pickTags(_ value: Any?) -> [String] {
        guard let tags = value as? [[String: Any]] else { return [] }
        // Broad genres match almost everything; prefer the distinctive ones.
        let broad: Set<String> = ["action", "adventure", "drama", "comedy", "romance", "slice of life"]
        func entries(_ group: String) -> [(id: String, name: String)] {
            tags.compactMap { tag -> (id: String, name: String)? in
                guard let id = tag["id"] as? String, let a = tag["attributes"] as? [String: Any],
                      a["group"] as? String == group else { return nil }
                let name = ((a["name"] as? [String: Any])?["en"] as? String ?? "").lowercased()
                return (id, name)
            }
        }
        let genres = entries("genre").sorted { !broad.contains($0.name) && broad.contains($1.name) }
        let themes = entries("theme")
        return Array((genres + themes).prefix(2).map(\.id))
    }

    static func sameTitle(_ a: String, _ b: String) -> Bool {
        func clean(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        return clean(a) == clean(b)
    }

    static func parse(_ data: Data) throws -> [(item: DiscoverItem, tags: Any?, language: String, style: ReadingStyle)] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { throw SourceError.unsupportedStructure }
        return list.compactMap { entry in
            guard let id = entry["id"] as? String, let a = entry["attributes"] as? [String: Any],
                  let page = URL(string: "https://mangadex.org/title/\(id)") else { return nil }
            let title = MangaDex.displayTitle(a) ?? "Untitled"
            let relations = entry["relationships"] as? [[String: Any]] ?? []
            let file = (relations.first { $0["type"] as? String == "cover_art" }?["attributes"] as? [String: Any])?["fileName"] as? String
            let cover = file.flatMap { URL(string: "https://uploads.mangadex.org/covers/\(id)/\($0).256.jpg") }
            let language = (a["originalLanguage"] as? String ?? "").lowercased()
            let style = MangaDex.style(language: language, tags: a["tags"])
            let year = (a["year"] as? Int).map { " · \($0)" } ?? ""
            return (DiscoverItem(id: id, title: title, url: page, cover: cover, detail: style.title + year), a["tags"], language, style)
        }
    }
}
