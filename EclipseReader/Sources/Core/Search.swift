import Foundation

/// A place global search can look: a built-in connection or any website.
public struct SearchSource: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case mangaDex, weebCentral, webtoons, syosetu, kakuyomu, site(URL) }
    public let name: String
    public let kind: Kind
    /// Results are novels (added as text series).
    public let novels: Bool
    public init(name: String, kind: Kind, novels: Bool = false) {
        self.name = name; self.kind = kind
        self.novels = novels || kind == .syosetu || kind == .kakuyomu
    }
    public var id: String {
        switch kind {
        case .mangaDex: "mangadex"
        case .weebCentral: "weebcentral"
        case .webtoons: "webtoons"
        case .syosetu: "syosetu"
        case .kakuyomu: "kakuyomu"
        case .site(let url): url.host ?? url.absoluteString
        }
    }
    public var host: String {
        switch kind {
        case .mangaDex: "mangadex.org"
        case .weebCentral: "weebcentral.com"
        case .webtoons: "webtoons.com"
        case .syosetu: "syosetu.com"
        case .kakuyomu: "kakuyomu.jp"
        case .site(let url): url.host?.replacingOccurrences(of: "www.", with: "") ?? ""
        }
    }
}

/// Searches one source for a title. Websites are searched the way most manga sites expect
/// (WordPress `?s=`, the engine behind Madara and MangaThemesia), then their result cards are read.
public enum GlobalSearch {
    public static func search(_ source: SearchSource, query: String, http: any HTTPTransport = WebsiteHTTPClient()) async throws -> [DiscoverItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        switch source.kind {
        case .mangaDex:
            return try await Discover.mangaDex(query: q, limit: 20, http: http)
        case .syosetu:
            return try await Syosetu.search(q, http: http)
        case .kakuyomu:
            return try await Kakuyomu.search(q, http: http)
        case .weebCentral:
            var parts = URLComponents(string: "https://weebcentral.com/search/data")!
            parts.queryItems = [URLQueryItem(name: "text", value: q), URLQueryItem(name: "sort", value: "Best Match"),
                                URLQueryItem(name: "order", value: "Descending"), URLQueryItem(name: "official", value: "Any"),
                                URLQueryItem(name: "display_mode", value: "Full Display")]
            guard let url = parts.url else { return [] }
            return relevant(weebCentralResults(in: try await text(url, http: http)), to: q)
        case .webtoons:
            var parts = URLComponents(string: "https://www.webtoons.com/en/search")!
            parts.queryItems = [URLQueryItem(name: "keyword", value: q)]
            guard let url = parts.url else { return [] }
            return strictCanvas(relevant(webtoonsResults(in: try await text(url, http: http), base: url), to: q), query: q)
        case .site(let root) where ReadBerserkParser.normalize(root.absoluteString, relativeTo: ReadBerserkParser.home) != nil:
            let item = DiscoverItem(id: "berserk", title: "Berserk", url: ReadBerserkParser.home, cover: nil, detail: source.name)
            if ["readberserk", "ベルセルク"].contains(q.lowercased()) { return [item] }
            return relevant([item], to: q).filter { _ in q.contains(where: { $0.isLetter }) }
        case .site(let root) where (root.host ?? "").lowercased().hasSuffix("mangadot.net"):
            // MangaDot builds its search page with scripts; its own search API answers directly.
            var parts = URLComponents(string: "https://mangadot.net/api/search")!
            parts.queryItems = [URLQueryItem(name: "search", value: q)]
            guard let url = parts.url else { return [] }
            return relevant(try mangaDotResults(try await http.fetch(url, referer: nil, image: false)), to: q)
        case .site(let root):
            var lastError: Error?
            var recognized = false
            for url in searchURLs(root: root, query: q) {
                try Task.checkCancellation()
                do {
                    let html = try await text(url, http: http)
                    let items = results(in: html, base: url)
                    recognized = recognized || !items.isEmpty || ["no results", "no matches", "nothing found"].contains(where: { html.localizedCaseInsensitiveContains($0) })
                    let found = relevant(items, to: q)
                    if !found.isEmpty { return found }
                } catch { lastError = error }
            }
            if recognized { return [] }
            throw lastError ?? SourceError.unsupportedStructure
        }
    }

    /// Keeps results whose title shares a word with the query. Sites without a real search page
    /// answer `?s=` with their home page; this stops those covers showing up as matches.
    public static func relevant(_ items: [DiscoverItem], to query: String) -> [DiscoverItem] {
        func tokens(_ text: String) -> [String] {
            text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        let words = tokens(query)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let title = tokens(item.title)
            return words.allSatisfy { word in title.contains { $0.hasPrefix(word) } }
        }
    }

    /// Sites whose search lives somewhere other than WordPress's `?s=` (checked against the live sites).
    static let searchPaths: [String: (path: String, parameter: String)] = [
        "asurascans.com": ("/browse", "search"),
        "royalroad.com": ("/fictions/search", "title"),
        "tapas.io": ("/search", "q"),
        "wuxiaworld.com": ("/novels", "search"),
        "j-novel.club": ("/series", "search"),
    ]
    /// The search addresses to try for a website, most specific first.
    public static func searchURLs(root: URL, query: String) -> [URL] {
        var base = URLComponents()
        base.scheme = "https"; base.host = root.host; base.path = "/"
        let host = (root.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        if let known = searchPaths[host] {
            var own = base
            own.path = known.path
            own.queryItems = [URLQueryItem(name: known.parameter, value: query)]
            return [own.url].compactMap { $0 }
        }
        var madara = base
        madara.queryItems = [URLQueryItem(name: "s", value: query), URLQueryItem(name: "post_type", value: "wp-manga")]
        var plain = base
        plain.queryItems = [URLQueryItem(name: "s", value: query)]
        return [madara.url, plain.url].compactMap { $0 }
    }

    private static func text(_ url: URL, http: any HTTPTransport) async throws -> String {
        let data = try await http.fetch(url, referer: nil, image: false)
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw SourceError.unsupportedStructure
        }
        return html
    }

    /// Result cards on a search or listing page: links to series pages, with the cover image and
    /// title found inside or next to the link. Chapter links and navigation are ignored.
    public static func results(in html: String, base: URL, limit: Int = 24) -> [DiscoverItem] {
        let inert = html.replacingOccurrences(of: #"(?is)<!--.*?-->|<(script|style|template|noscript)\b[^>]*>.*?</\1\s*>"#,
                                              with: "", options: .regularExpression)
        let site = base.host.map(LinkedSource.root) ?? ""
        var order: [String] = []
        var found: [String: (url: URL, title: String?, cover: URL?)] = [:]
        for m in LinkedSource.matches(#"(?is)<a\b([^>]*)>(.*?)</a>"#, inert) {
            let fields = ReadBerserkParser.attributes("<a " + m[0] + ">")
            guard let href = fields["href"], let url = LinkedSource.resolve(href, base: base),
                  let host = url.host, LinkedSource.root(host) == site else { continue }
            let path = url.path
            guard path.range(of: LinkedSource.seriesPath, options: .regularExpression) != nil,
                  path.range(of: #"(?i)chapter|episode|/ch[-_]?\d|/page/\d|/genres?/|/tag/|/author/"#, options: .regularExpression) == nil,
                  !LinkedSource.listingWords.contains(url.lastPathComponent.lowercased()) else { continue }
            var cover: URL?
            var alt: String?
            if let tag = ReadBerserkParser.tags("img", m[1]).first {
                let img = ReadBerserkParser.attributes(tag)
                let raw = ["data-src", "data-lazy-src", "data-original", "src"].lazy.compactMap { img[$0] }
                    .first { !$0.hasPrefix("data:") && !$0.isEmpty }
                    ?? (img["srcset"] ?? img["data-srcset"])?.split(separator: ",").first.map { String($0.split(separator: " ").first ?? "") }
                cover = raw.flatMap { LinkedSource.resolve($0, base: base) }
                alt = img["alt"].map(LinkedSource.plain)
            }
            let text = LinkedSource.plain(m[1])
            let candidates = [fields["title"].map(LinkedSource.plain), alt, text.count <= 120 ? text : nil]
            let title = candidates.compactMap { $0 }.first { $0.count >= 2 && $0.rangeOfCharacter(from: .letters) != nil }
            let key = url.absoluteString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if var entry = found[key] {
                if entry.cover == nil { entry.cover = cover }
                if entry.title == nil { entry.title = title }
                found[key] = entry
            } else {
                order.append(key)
                found[key] = (url, title, cover)
            }
        }
        return order.compactMap { key -> DiscoverItem? in
            guard let entry = found[key], let title = entry.title else { return nil }
            return DiscoverItem(id: key, title: title, url: entry.url, cover: entry.cover, detail: nil)
        }.prefix(limit).map { $0 }
    }

    /// MangaDot's search API: {"manga_list":[{"id":118,"title":"Solo Leveling","photo":"/uploads/….webp",…}]}.
    static func mangaDotResults(_ data: Data) throws -> [DiscoverItem] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["manga_list"] as? [[String: Any]] else { throw SourceError.unsupportedStructure }
        return list.compactMap { entry -> DiscoverItem? in
            guard let id = entry["id"] as? Int, let title = entry["title"] as? String,
                  let url = URL(string: "https://mangadot.net/manga/\(id)") else { return nil }
            let cover = (entry["photo"] as? String).flatMap { URL(string: $0.hasPrefix("/") ? "https://mangadot.net" + $0 : $0) }
            let kind: String? = switch entry["country_of_origin"] as? String {
            case "KR": "Manhwa"
            case "CN", "TW": "Manhua"
            case "JP": "Manga"
            default: nil
            }
            let count = (entry["chapter_count"] as? Int).map { "\($0) ch" }
            return DiscoverItem(id: "mangadot-\(id)", title: title, url: url, cover: cover,
                                detail: [kind, count].compactMap { $0 }.joined(separator: " · "))
        }
    }
    static func weebCentralResults(in html: String) -> [DiscoverItem] {
        var seen = Set<String>()
        var items: [DiscoverItem] = []
        for block in LinkedSource.matches(#"(?is)<article\b[^>]*>(.*?)</article>"#, html) {
            guard let href = LinkedSource.firstMatch(#"href=["'](https://weebcentral\.com/series/[0-9A-Za-z]+[^"']*)["']"#, block[0]),
                  let url = URL(string: href), let id = WeebCentral.seriesID(url), seen.insert(id).inserted else { continue }
            let img = ReadBerserkParser.tags("img", block[0]).first.map(ReadBerserkParser.attributes)
            let cover = (img?["src"] ?? img?["data-src"]).flatMap { LinkedSource.resolve($0, base: url) }
            let title = img?["alt"].map { LinkedSource.plain($0).replacingOccurrences(of: " cover", with: "") }
                ?? LinkedSource.firstMatch(#"(?is)<a[^>]*>([^<]{2,120})</a>"#, block[0]).map(LinkedSource.plain)
            items.append(DiscoverItem(id: id, title: title ?? "Untitled", url: url, cover: cover, detail: nil))
        }
        if items.isEmpty {
            // Layout without <article>: fall back to plain result links.
            return results(in: html, base: URL(string: "https://weebcentral.com/")!).filter { WeebCentral.seriesID($0.url) != nil }
        }
        return items
    }

    static func webtoonsResults(in html: String, base: URL) -> [DiscoverItem] {
        var seen = Set<String>()
        var items: [DiscoverItem] = []
        for m in LinkedSource.matches(#"(?is)<a\b([^>]*)>(.*?)</a>"#, html) {
            guard let href = ReadBerserkParser.attributes("<a " + m[0] + ">")["href"],
                  let url = LinkedSource.resolve(href, base: base), Webtoons.handles(url), url.path.hasSuffix("/list"),
                  let number = Webtoons.titleNumber(url), seen.insert(number).inserted else { continue }
            let img = ReadBerserkParser.tags("img", m[1]).first.map(ReadBerserkParser.attributes)
            let cover = (img?["src"] ?? img?["data-src"]).flatMap { LinkedSource.resolve($0, base: base) }
            let title = LinkedSource.firstMatch(#"(?is)class=["'][^"']*(?:subj|title)[^"']*["'][^>]*>(.*?)<"#, m[1]).map(LinkedSource.plain)
                ?? img?["alt"].map(LinkedSource.plain)
            let canvas = url.path.lowercased().contains("/canvas/")
            items.append(DiscoverItem(id: "webtoons-" + number, title: title ?? "Untitled", url: url, cover: cover,
                                      detail: canvas ? "Canvas · fan & indie" : "WEBTOON Original"))
        }
        // Official series first; Canvas (anyone can post there) only when its title has every word searched for.
        return items.filter { !$0.url.path.lowercased().contains("/canvas/") }
            + items.filter { $0.url.path.lowercased().contains("/canvas/") }
    }
    /// Canvas results need the whole query in the title; a search for "Jujutsu Kaisen" shouldn't fill up with fan comics.
    static func strictCanvas(_ items: [DiscoverItem], query: String) -> [DiscoverItem] {
        let words = query.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 }
        let originals = items.filter { !$0.url.path.lowercased().contains("/canvas/") }
        return items.filter { item in
            guard item.url.path.lowercased().contains("/canvas/") else { return true }
            // Fan works named after an official series are noise when the official one is right there.
            if !originals.isEmpty && originals.contains(where: { $0.title.lowercased().contains(words.joined(separator: " ")) }) { return false }
            return words.allSatisfy { item.title.lowercased().contains($0) }
        }
    }
}


/// One series found by a global search, with every site that has it.
public struct SearchWork: Identifiable, Sendable {
    public struct Entry: Sendable {
        public let site: String
        public let item: DiscoverItem
    }
    public let id: String
    public var entries: [Entry]
    public var title: String { entries[0].item.title }
    public var cover: URL? { entries.lazy.compactMap(\.item.cover).first }
    public var sites: [String] { entries.map(\.site) }
}

extension GlobalSearch {
    /// The same series on several sites, shown once. Titles count as the same work only when they
    /// match ignoring case, punctuation and a leading "the" (so "Jujutsu Kaisen 0" stays separate).
    /// Order: titles matching the query exactly, then works on more sites, then the order sites answered.
    public static func group(_ results: [(site: String, items: [DiscoverItem])], query: String) -> [SearchWork] {
        func key(_ title: String) -> String {
            var t = title.lowercased()
            if t.hasPrefix("the ") { t.removeFirst(4) }
            return t.filter { $0.isLetter || $0.isNumber }
        }
        var works: [SearchWork] = []
        var index: [String: Int] = [:]
        for (site, items) in results {
            for item in items {
                let k = key(item.title)
                guard !k.isEmpty else { continue }
                if let i = index[k] {
                    if !works[i].entries.contains(where: { $0.site == site }) { works[i].entries.append(.init(site: site, item: item)) }
                } else {
                    index[k] = works.count
                    works.append(SearchWork(id: k, entries: [.init(site: site, item: item)]))
                }
            }
        }
        let wanted = key(query)
        return works.enumerated().sorted { a, b in
            let ea = a.element.id == wanted, eb = b.element.id == wanted
            if ea != eb { return ea }
            if a.element.entries.count != b.element.entries.count { return a.element.entries.count > b.element.entries.count }
            return a.offset < b.offset
        }.map(\.element)
    }
}


/// How each site has done in your searches: used to search the dependable ones first and to suggest
/// switching off sites that keep not answering.
public struct SearchReliability: Codable, Sendable, Equatable {
    public enum Outcome: Sendable { case results, empty, noAnswer }
    public struct Record: Codable, Sendable, Equatable {
        public var searches = 0
        public var withResults = 0
        public var answered = 0
        /// Searches in a row the site didn't answer.
        public var missedInARow = 0
    }
    public var sites: [String: Record] = [:]
    public init() {}

    public mutating func record(_ site: String, _ outcome: Outcome) {
        var r = sites[site] ?? Record()
        r.searches += 1
        switch outcome {
        case .results: r.withResults += 1; r.answered += 1; r.missedInARow = 0
        case .empty: r.answered += 1; r.missedInARow = 0
        case .noAnswer: r.missedInARow += 1
        }
        sites[site] = r
    }
    /// 0...1: sites that find things score highest, ones that answer with nothing next, ones that
    /// don't answer lowest. A site not searched yet sits in the middle.
    public func score(_ site: String) -> Double {
        guard let r = sites[site], r.searches > 0 else { return 0.5 }
        return Double(2 * r.withResults + (r.answered - r.withResults) + 1) / Double(2 * r.searches + 2)
    }
    /// The sites in the order to search them: most dependable first, ties kept in their own order.
    public func ordered(_ ids: [String]) -> [String] {
        ids.enumerated().sorted { a, b in
            let sa = score(a.element), sb = score(b.element)
            return sa != sb ? sa > sb : a.offset < b.offset
        }.map(\.element)
    }
    /// Sites that haven't answered the last `threshold` searches.
    public func failing(_ ids: [String], threshold: Int = 5) -> [String] {
        ids.filter { (sites[$0]?.missedInARow ?? 0) >= threshold }
    }
}

/// The last few searches, newest first, without repeats (letter case ignored).
public enum RecentSearches {
    public static let limit = 8
    public static func adding(_ query: String, to list: [String], limit: Int = RecentSearches.limit) -> [String] {
        let cleaned = query.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return list }
        let rest = list.filter { $0.caseInsensitiveCompare(cleaned) != .orderedSame }
        return Array(([cleaned] + rest).prefix(max(0, limit)))
    }
    public static func decode(_ raw: String) -> [String] { raw.split(separator: "\n").map(String.init) }
    public static func encode(_ list: [String]) -> String { list.joined(separator: "\n") }
}
