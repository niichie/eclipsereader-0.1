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
        let title = Self.localized(attributes["title"]) ?? Self.altTitle(attributes["altTitles"]) ?? "MangaDex"
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
        return try parse(try await http.fetch(url, referer: nil, image: false)).map(\.item)
    }

    /// "Because you read …": finds the series on MangaDex, then the best-rated titles sharing its genres.
    public static func similar(to title: String, excluding: Set<String> = [], limit: Int = 16,
                               http: any HTTPTransport = WebsiteHTTPClient()) async throws -> [DiscoverItem] {
        var lookup = URLComponents(string: "https://api.mangadex.org/manga")!
        lookup.queryItems = base(limit: 5, ratings: ["safe", "suggestive", "erotica"]) + [
            URLQueryItem(name: "title", value: title), URLQueryItem(name: "order[relevance]", value: "desc")]
        guard let lookupURL = lookup.url else { return [] }
        let found = try parse(try await http.fetch(lookupURL, referer: nil, image: false))
        guard let source = found.first(where: { Self.sameTitle($0.item.title, title) }) ?? found.first else { return [] }
        let tags = pickTags(source.tags)
        guard !tags.isEmpty else { return [] }
        var parts = URLComponents(string: "https://api.mangadex.org/manga")!
        parts.queryItems = base(limit: limit + 8)
            + tags.map { URLQueryItem(name: "includedTags[]", value: $0) }
            + [URLQueryItem(name: "includedTagsMode", value: "AND"),
               URLQueryItem(name: "order[rating]", value: "desc")]
        guard let url = parts.url else { return [] }
        let list = try parse(try await http.fetch(url, referer: nil, image: false)).map(\.item)
        let skip = excluding.map { $0.lowercased() }
        return Array(list.filter { item in
            item.id != source.item.id && !skip.contains { Self.sameTitle($0, item.title) }
        }.prefix(limit))
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

    static func parse(_ data: Data) throws -> [(item: DiscoverItem, tags: Any?)] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { throw SourceError.unsupportedStructure }
        return list.compactMap { entry -> (item: DiscoverItem, tags: Any?)? in
            guard let id = entry["id"] as? String, let a = entry["attributes"] as? [String: Any],
                  let page = URL(string: "https://mangadex.org/title/\(id)") else { return nil }
            let title = MangaDex.localized(a["title"]) ?? MangaDex.altTitle(a["altTitles"]) ?? "Untitled"
            let relations = entry["relationships"] as? [[String: Any]] ?? []
            let file = (relations.first { $0["type"] as? String == "cover_art" }?["attributes"] as? [String: Any])?["fileName"] as? String
            let cover = file.flatMap { URL(string: "https://uploads.mangadex.org/covers/\(id)/\($0).256.jpg") }
            let language = (a["originalLanguage"] as? String ?? "").lowercased()
            let kind = MangaDex.style(language: language, tags: a["tags"]).title
            let year = (a["year"] as? Int).map { " · \($0)" } ?? ""
            return (DiscoverItem(id: id, title: title, url: page, cover: cover, detail: kind + year), a["tags"])
        }
    }
}
