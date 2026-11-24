import Foundation

// MARK: - Light novels and web novels
//
// A novel is a series whose chapters are text. Chapters come from a site's own data where it has some
// (Syosetu's API, Kakuyomu's and Wuxiaworld's page data) and otherwise from reading the chapter page
// the way Safari's Reader does: the block of the page with the most running text.

/// What a novel's series page says about it.
public struct NovelInfo: Sendable {
    public var title: String
    public var author: String?
    public var cover: URL?
    public var summary: String?
    /// The language it's written in ("ja", "zh", "ko", "en"), when the site says.
    public var language: String?
    public var chapters: [Chapter]
    /// The novel's own page, when the address given was one of its chapters.
    public var home: URL?
    public init(title: String, author: String? = nil, cover: URL? = nil, summary: String? = nil, language: String? = nil,
                chapters: [Chapter], home: URL? = nil) {
        self.title = title; self.author = author; self.cover = cover; self.summary = summary; self.language = language
        self.chapters = chapters; self.home = home
    }
}

/// One chapter's text, kept as clean HTML (paragraphs, emphasis, rules, pictures) so it can be saved
/// for offline reading and set by the book typesetter.
public struct NovelChapterText: Codable, Sendable, Equatable {
    public var title: String?
    public var html: String
    /// The site shows only the start of this chapter (a paid chapter).
    public var locked: Bool
    public init(title: String?, html: String, locked: Bool = false) { self.title = title; self.html = html; self.locked = locked }
    /// Paragraphs ready for the typesetter, with navigation leftovers ("Next chapter", "Table of contents") removed.
    public func blocks(base: URL) -> [BookBlock] {
        MarkupReader.blocks(html, base: base.absoluteString).filter { block in
            switch block {
            case .paragraph(let runs), .centered(let runs):
                return !NovelText.isNavigation(runs.map(\.text).joined())
            default: return true
            }
        }
    }
}

// MARK: Reader-mode extraction

public enum NovelText {
    /// Containers known to hold chapter text, most specific first (Syosetu, Kakuyomu, Wuxiaworld, Royal Road,
    /// then the names WordPress novel themes use).
    static let containers = ["widget-episodeBody", "chapter-content", "chapter-inner", "chapter_content", "chapter-c", "chr-c",
                             "reading-content", "text-left", "novel-content", "chapter-text", "read-content", "entry-content", "txt"]

    /// The chapter's text from its page, or nil when the page has no running text (a list, a locked page, a picture page).
    public static func extract(html: String, url: URL) -> NovelChapterText? {
        let cleaned = strip(html)
        var body: String?
        // Syosetu splits a chapter into foreword, text and afterword.
        let parts = elements(withClass: "js-novel-text", in: cleaned).filter { textLength($0) > 0 }
        if !parts.isEmpty { body = parts.joined(separator: "<hr/>") }
        if body == nil {
            for name in containers {
                let found = elements(withClass: name, in: cleaned)
                if let best = found.max(by: { textLength($0) < textLength($1) }), textLength(best) >= 200 { body = best; break }
            }
        }
        if body == nil { body = densest(cleaned) }
        guard let body, textLength(body) >= 40 else { return nil }
        return NovelChapterText(title: title(in: html), html: body, locked: Wuxiaworld.isLocked(html: html, url: url))
    }

    /// Text that is only chapter navigation, left behind inside the text block on many sites.
    static func isNavigation(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.isEmpty { return false }
        return t.range(of: #"^(?:[«‹←<]\s*)?(?:previous|prev|next|back)(?:\s+chapter)?(?:\s*[»›→>])?$|^(?:table of contents|index|chapter list|toc)$"#,
                       options: .regularExpression) != nil
    }

    /// The chapter's own heading, when the page marks it.
    static func title(in html: String) -> String? {
        let patterns = [
            #"(?is)<h1[^>]+class=["'][^"']*p-novel__title[^"']*["'][^>]*>(.*?)</h1>"#,
            #"(?is)<p[^>]+class=["'][^"']*widget-episodeTitle[^"']*["'][^>]*>(.*?)</p>"#,
            #"(?is)<[a-z0-9]+[^>]+data-testid=["']title["'][^>]*>(.*?)</[a-z0-9]+>"#,
            #"(?is)<h1[^>]*>(.*?)</h1>"#,
        ]
        for pattern in patterns {
            if let raw = LinkedSource.firstMatch(pattern, html) {
                let text = LinkedSource.plain(raw)
                if !text.isEmpty && text.count < 140 { return text }
            }
        }
        return nil
    }

    /// Plain-text length of some HTML (tags removed, runs of spaces counted once).
    static func textLength(_ html: String) -> Int {
        html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).count
    }

    /// Removes everything that is never chapter text: scripts, styles, forms, page chrome, and elements the page
    /// hides with CSS (some sites hide notices between paragraphs that a reader would otherwise show).
    static func strip(_ html: String) -> String {
        var hidden = Set<String>()
        for style in LinkedSource.matches(#"(?is)<style\b[^>]*>(.*?)</style>"#, html) {
            for rule in LinkedSource.matches(#"\.([A-Za-z_][\w-]*)\s*\{[^}]*display\s*:\s*none"#, style[0]) { hidden.insert(rule[0]) }
        }
        var out = html.replacingOccurrences(of: #"(?is)<!--.*?-->"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?is)<(script|style|noscript|template|svg|iframe|form|button|select|textarea|nav|footer|aside)\b[^>]*>.*?</\1\s*>"#,
                                       with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?is)<(p|span|div)\b[^>]*style\s*=\s*["'][^"']*display\s*:\s*none[^"']*["'][^>]*>.*?</\1>"#,
                                       with: "", options: .regularExpression)
        for name in hidden.prefix(40) {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            out = out.replacingOccurrences(of: #"(?is)<(p|span|div)\b[^>]*class\s*=\s*["'](?:[^"']*\s)?"# + escaped + #"(?:\s[^"']*)?["'][^>]*>.*?</\1>"#,
                                           with: "", options: .regularExpression)
        }
        return out
    }

    /// Inner HTML of every element carrying a class (whole class names only), outermost first.
    static func elements(withClass name: String, in html: String) -> [String] {
        let ns = html as NSString
        guard let open = try? NSRegularExpression(pattern: #"<(div|section|article|main|td)\b[^>]*?\bclass\s*=\s*(["'])(.*?)\2[^>]*>"#,
                                                  options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        var results: [String] = []
        var consumed = 0
        for m in open.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard m.range.location >= consumed else { continue }
            let classes = ns.substring(with: m.range(at: 3)).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            guard classes.contains(where: { $0 == name }) else { continue }
            let tag = ns.substring(with: m.range(at: 1)).lowercased()
            let start = m.range.location + m.range.length
            guard let end = closing(tag, in: ns, from: start) else { continue }
            results.append(ns.substring(with: NSRange(location: start, length: end - start)))
            consumed = end
        }
        return results
    }
    /// Where the element opened just before `start` closes (nested elements of the same name counted).
    static func closing(_ tag: String, in ns: NSString, from start: Int) -> Int? {
        guard start <= ns.length, let re = try? NSRegularExpression(pattern: "<(/?)" + tag + #"\b[^>]*?(/?)>"#, options: .caseInsensitive) else { return nil }
        var depth = 1
        for m in re.matches(in: ns as String, range: NSRange(location: start, length: ns.length - start)) {
            if m.range(at: 1).length > 0 {
                depth -= 1
                if depth == 0 { return m.range.location }
            } else if m.range(at: 2).length == 0 {
                depth += 1
            }
        }
        return nil
    }

    /// The block holding the most running text, with link text counted against it (menus and lists of links lose).
    /// Text in leaf blocks (sites that put each paragraph in its own div) counts toward the block around them.
    static func densest(_ html: String) -> String? {
        let ns = html as NSString
        guard let re = try? NSRegularExpression(pattern: #"<(/?)([a-zA-Z][a-zA-Z0-9]*)\b[^>]*?(/?)>|([^<]+)"#) else { return nil }
        struct Box { let tag: String; let start: Int; var text = 0; var links = 0; var leafText = 0; var leafLinks = 0; var hasBlockChild = false }
        let blocks: Set<String> = ["div", "article", "section", "main", "td"]
        var stack: [Box] = []
        var inLink = 0
        var best: (score: Int, range: NSRange)?
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 4).location != NSNotFound {
                guard !stack.isEmpty else { continue }
                let count = ns.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespacesAndNewlines).count
                guard count > 0 else { continue }
                if inLink > 0 { stack[stack.count - 1].links += count } else { stack[stack.count - 1].text += count }
                continue
            }
            let closing = m.range(at: 1).length > 0
            let name = ns.substring(with: m.range(at: 2)).lowercased()
            if name == "a" {
                if m.range(at: 3).length == 0 { inLink = max(0, inLink + (closing ? -1 : 1)) }
                continue
            }
            guard blocks.contains(name), m.range(at: 3).length == 0 else { continue }
            if !closing {
                if !stack.isEmpty { stack[stack.count - 1].hasBlockChild = true }
                stack.append(Box(tag: name, start: m.range.location + m.range.length))
                continue
            }
            guard let i = stack.lastIndex(where: { $0.tag == name }) else { continue }
            let box = stack[i]
            stack.removeSubrange(i...)
            let text = box.text + box.leafText
            let score = text - 3 * (box.links + box.leafLinks)
            if text >= 200, score > (best?.score ?? 0) {
                best = (score, NSRange(location: box.start, length: m.range.location - box.start))
            }
            if !box.hasBlockChild, !stack.isEmpty {
                stack[stack.count - 1].leafText += box.text
                stack[stack.count - 1].leafLinks += box.links
            }
        }
        return best.map { ns.substring(with: $0.range) }
    }

    /// A page is a novel chapter when it carries a lot of running text and few pictures.
    public static func looksLikeChapter(html: String, url: URL) -> Bool {
        guard let text = extract(html: html, url: url) else { return false }
        let pictures = LinkedSource.matches(#"(?i)<img\b"#, text.html).count
        return textLength(text.html) >= 1200 && pictures <= 6
    }
}

// MARK: - Sites with their own data

/// Syosetu (小説家になろう): the home of most Japanese web novels and light novels. Official API for titles and
/// search; the table of contents and chapters from its pages.
public enum Syosetu {
    public static func ncode(_ url: URL) -> String? {
        guard let host = url.host?.lowercased(), host == "ncode.syosetu.com" else { return nil }
        guard let first = url.pathComponents.first(where: { $0 != "/" }),
              first.range(of: #"^[nN][0-9]{4}[a-zA-Z]{1,3}$"#, options: .regularExpression) != nil else { return nil }
        return first.lowercased()
    }
    public static func handles(_ url: URL) -> Bool { ncode(url) != nil }
    static func workURL(_ ncode: String) -> URL { URL(string: "https://ncode.syosetu.com/\(ncode.lowercased())/")! }

    struct Entry { let ncode: String; let title: String; let writer: String?; let story: String?; let chapters: Int; let short: Bool }
    static func parseAPI(_ data: Data) throws -> [Entry] {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw SourceError.unsupportedStructure }
        return list.compactMap { item in
            guard let code = item["ncode"] as? String, let title = item["title"] as? String else { return nil }
            return Entry(ncode: code.lowercased(), title: title, writer: item["writer"] as? String, story: item["story"] as? String,
                         chapters: item["general_all_no"] as? Int ?? 0, short: (item["noveltype"] as? Int) == 2)
        }
    }
    static func api(_ items: [URLQueryItem]) -> URL {
        var parts = URLComponents(string: "https://api.syosetu.com/novelapi/api/")!
        parts.queryItems = [URLQueryItem(name: "out", value: "json"), URLQueryItem(name: "of", value: "t-n-w-s-ga-nt")] + items
        return parts.url!
    }
    static func items(_ entries: [Entry]) -> [DiscoverItem] {
        entries.map { entry in
            DiscoverItem(id: "syosetu-" + entry.ncode, title: entry.title, url: workURL(entry.ncode), cover: nil,
                         detail: entry.short ? "Japanese · short story" : "Japanese · \(entry.chapters) chapters")
        }
    }
    public static func search(_ query: String, http: any HTTPTransport) async throws -> [DiscoverItem] {
        let data = try await http.fetch(api([URLQueryItem(name: "word", value: query), URLQueryItem(name: "lim", value: "20"),
                                             URLQueryItem(name: "order", value: "hyperpoint")]), referer: nil, image: false)
        return items(try parseAPI(data))
    }
    /// Match published novel editions to ranked web novels, keeping Syosetu's order and reading links.
    static func illustratedPreviews(_ ranked: [DiscoverItem]) async -> [DiscoverItem] {
        var previews: [DiscoverItem] = []
        for start in stride(from: 0, to: ranked.count, by: 6) {
            guard !Task.isCancelled else { return [] }
            let batch = Array(ranked[start..<min(start + 6, ranked.count)])
            var variables: [String: any Sendable] = [:]
            for (index, item) in batch.enumerated() { variables["s\(index)"] = QuoteFeed.searchable(native: item.title) }
            var request = URLRequest(url: AniListAPI.endpoint, timeoutInterval: 10)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? AniListAPI.body(QuoteFeed.batchQuery(batch.count), variables: variables)
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { break }
            previews += matchedPreviews(batch, data: data)
        }
        return previews
    }

    static func matchedPreviews(_ items: [DiscoverItem], data: Data) -> [DiscoverItem] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let groups = json?["data"] as? [String: Any]
        return items.enumerated().compactMap { index, item in
            let group = groups?["m\(index)"] as? [String: Any]
            let matches = (group?["media"] as? [[String: Any]] ?? []).filter { entry in
                guard entry["format"] as? String == "NOVEL", let titles = entry["title"] as? [String: Any],
                      let native = titles["native"] as? String else { return false }
                return QuoteFeed.key(native) == QuoteFeed.key(item.title)
            }
            guard matches.count == 1, let match = matches.first,
                  let titles = match["title"] as? [String: Any], let english = titles["english"] as? String,
                  !english.isEmpty, let cover = QuoteFeed.hit(match)?.media.cover else { return nil }
            return DiscoverItem(id: item.id, title: english, url: item.url, cover: cover, detail: item.detail)
        }
    }

    /// The most-loved works of all time (Syosetu's own points ranking).
    public static func popular(http: any HTTPTransport) async throws -> [DiscoverItem] {
        let data = try await http.fetch(api([URLQueryItem(name: "lim", value: "24"), URLQueryItem(name: "order", value: "hyperpoint")]),
                                        referer: nil, image: false)
        return items(try parseAPI(data))
    }

    static func info(_ url: URL, http: any HTTPTransport) async throws -> NovelInfo {
        guard let code = ncode(url) else { throw SourceError.unsupportedStructure }
        let entry = try? await parseAPI(http.fetch(api([URLQueryItem(name: "ncode", value: code)]), referer: nil, image: false)).first
        if entry?.short == true {
            return NovelInfo(title: entry?.title ?? code, author: entry?.writer, summary: entry?.story, language: "ja",
                             chapters: [Chapter(url: workURL(code), title: entry?.title ?? "Story", number: "1")])
        }
        var chapters: [Chapter] = []
        var title = entry?.title
        for page in 1...80 {
            let address = page == 1 ? workURL(code) : URL(string: "https://ncode.syosetu.com/\(code)/?p=\(page)")!
            let data = try await http.fetch(address, referer: nil, image: false)
            guard let html = String(data: data, encoding: .utf8) else { break }
            if title == nil { title = LinkedSource.firstMatch(#"(?is)<h1[^>]+class=["'][^"']*p-novel__title[^"']*["'][^>]*>(.*?)</h1>"#, html).map(LinkedSource.plain) }
            let found = episodes(in: html, ncode: code)
            if page == 1 && found.isEmpty && html.contains("js-novel-text") {
                // A short story: the work page is the text.
                return NovelInfo(title: title ?? code, author: entry?.writer, summary: entry?.story, language: "ja",
                                 chapters: [Chapter(url: workURL(code), title: title ?? "Story", number: "1")])
            }
            chapters += found
            if !hasNextPage(html) { break }
        }
        guard !chapters.isEmpty else { throw SourceError.unsupportedStructure }
        return NovelInfo(title: title ?? code, author: entry?.writer, summary: entry?.story, language: "ja", chapters: chapters)
    }
    /// The chapter links on one page of the table of contents.
    static func episodes(in html: String, ncode: String) -> [Chapter] {
        var seen = Set<Int>()
        var found: [Chapter] = []
        for m in LinkedSource.matches(#"(?is)<a\b([^>]*)>(.*?)</a>"#, html) {
            let fields = ReadBerserkParser.attributes("<a " + m[0] + ">")
            guard (fields["class"] ?? "").contains("p-eplist__subtitle"), let href = fields["href"],
                  let n = LinkedSource.firstMatch(#"^/"# + ncode + #"/([0-9]+)/?$"#, href.lowercased()).flatMap(Int.init),
                  seen.insert(n).inserted else { continue }
            let name = LinkedSource.plain(m[1])
            found.append(Chapter(url: URL(string: "https://ncode.syosetu.com/\(ncode)/\(n)/")!, title: name.isEmpty ? "第\(n)話" : name, number: String(n)))
        }
        return found
    }
    static func hasNextPage(_ html: String) -> Bool {
        html.range(of: #"<a\b[^>]*class=["'][^"']*c-pager__item--next"#, options: .regularExpression) != nil
    }
}

/// Kakuyomu (カクヨム): Kadokawa's web novel site. Its pages carry their data as JSON (Next.js + Apollo).
public enum Kakuyomu {
    public static func workID(_ url: URL) -> String? {
        guard let host = url.host?.lowercased(), host == "kakuyomu.jp" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0] == "works", parts[1].allSatisfy(\.isNumber) else { return nil }
        return parts[1]
    }
    public static func handles(_ url: URL) -> Bool { workID(url) != nil }

    /// The Apollo cache embedded in a Kakuyomu page.
    static func apollo(_ html: String) -> [String: Any]? {
        guard let json = LinkedSource.firstMatch(#"(?is)<script[^>]+id=["']__NEXT_DATA__["'][^>]*>(.*?)</script>"#, html),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let props = object["props"] as? [String: Any], let page = props["pageProps"] as? [String: Any] else { return nil }
        return page["__APOLLO_STATE__"] as? [String: Any]
    }
    static func ref(_ value: Any?) -> String? { (value as? [String: Any])?["__ref"] as? String }

    public static func info(html: String, url: URL) throws -> NovelInfo {
        guard let id = workID(url), let state = apollo(html) else { throw SourceError.unsupportedStructure }
        let work = state["Work:\(id)"] as? [String: Any] ?? [:]
        let title = work["title"] as? String ?? LinkedSource.title(in: html) ?? "Kakuyomu"
        let author = ref(work["author"]).flatMap { (state[$0] as? [String: Any])?["activityName"] as? String }
        let summary = (work["introduction"] as? String) ?? (work["catchphrase"] as? String)
        // Table of contents in order: the work's own list when it has one, else every chapter group by date.
        var groups: [[String: Any]] = []
        for key in ["tableOfContentsV2", "tableOfContents"] {
            if let list = work[key] as? [Any] {
                groups = list.compactMap { ref($0).flatMap { state[$0] as? [String: Any] } }
                if !groups.isEmpty { break }
            }
        }
        func episode(_ id: String) -> [String: Any]? { state["Episode:\(id)"] as? [String: Any] ?? state[id] as? [String: Any] }
        var order: [String] = []
        if groups.isEmpty {
            let all = state.filter { $0.key.hasPrefix("TableOfContentsChapter:") }.compactMap { $0.value as? [String: Any] }
            func firstDate(_ group: [String: Any]) -> String {
                ((group["episodeUnions"] as? [Any]) ?? []).compactMap { ref($0).flatMap { state[$0] as? [String: Any] }?["publishedAt"] as? String }.min() ?? ""
            }
            groups = all.sorted { firstDate($0) < firstDate($1) }
        }
        for group in groups {
            for item in (group["episodeUnions"] as? [Any]) ?? (group["episodes"] as? [Any]) ?? [] {
                if let key = ref(item), key.hasPrefix("Episode:") { order.append(String(key.dropFirst("Episode:".count))) }
            }
        }
        if order.isEmpty {
            // No table of contents in the data: every episode, oldest first.
            order = state.compactMap { key, value -> (String, String)? in
                guard key.hasPrefix("Episode:"), let item = value as? [String: Any] else { return nil }
                return (String(key.dropFirst("Episode:".count)), item["publishedAt"] as? String ?? "")
            }.sorted { $0.1 < $1.1 }.map(\.0)
        }
        var seen = Set<String>()
        let chapters = order.filter { seen.insert($0).inserted }.enumerated().map { i, episodeID in
            Chapter(url: URL(string: "https://kakuyomu.jp/works/\(id)/episodes/\(episodeID)")!,
                    title: (state["Episode:\(episodeID)"] as? [String: Any])?["title"] as? String ?? "第\(i + 1)話",
                    number: String(i + 1),
                    published: ((state["Episode:\(episodeID)"] as? [String: Any])?["publishedAt"] as? String).flatMap(MangaDex.day))
        }
        guard !chapters.isEmpty else { throw SourceError.unsupportedStructure }
        return NovelInfo(title: title, author: author, summary: summary, language: "ja", chapters: chapters)
    }
    public static func search(_ query: String, http: any HTTPTransport) async throws -> [DiscoverItem] {
        var parts = URLComponents(string: "https://kakuyomu.jp/search")!
        parts.queryItems = [URLQueryItem(name: "q", value: query)]
        let data = try await http.fetch(parts.url!, referer: nil, image: false)
        guard let html = String(data: data, encoding: .utf8) else { throw SourceError.unsupportedStructure }
        return results(in: html)
    }
    static func results(in html: String) -> [DiscoverItem] {
        let state = apollo(html) ?? [:]
        var seen = Set<String>()
        var items: [DiscoverItem] = []
        for m in LinkedSource.matches(#"href=["']/works/([0-9]+)["']"#, html) where seen.insert(m[0]).inserted {
            let work = state["Work:\(m[0])"] as? [String: Any]
            guard let title = work?["title"] as? String else { continue }
            let count = work?["publishedEpisodeCount"] as? Int
            items.append(DiscoverItem(id: "kakuyomu-" + m[0], title: title, url: URL(string: "https://kakuyomu.jp/works/\(m[0])")!, cover: nil,
                                      detail: "Japanese" + (count.map { " · \($0) chapters" } ?? "")))
            if items.count >= 20 { break }
        }
        return items
    }
}

/// Wuxiaworld: the official publisher of translated Chinese and Korean web novels. Its pages carry their data
/// as JSON; free chapters read in full, paid ones show what the site shows (the start).
public enum Wuxiaworld {
    public static func novelSlug(_ url: URL) -> String? {
        guard let host = url.host?.lowercased(), host == "wuxiaworld.com" || host == "www.wuxiaworld.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0] == "novel" else { return nil }
        return parts[1]
    }
    public static func handles(_ url: URL) -> Bool { novelSlug(url) != nil }

    static func state(_ html: String) -> [[String: Any]] {
        guard let json = LinkedSource.firstMatch(#"(?s)window\.__REACT_QUERY_STATE__\s*=\s*(\{.*?\});\s*(?:window\.|</script>)"#, html),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return [] }
        return object["queries"] as? [[String: Any]] ?? []
    }
    static func query(_ queries: [[String: Any]], _ name: String) -> [String: Any]? {
        for query in queries where ((query["queryKey"] as? [Any])?.first as? String) == name {
            return ((query["state"] as? [String: Any])?["data"] as? [String: Any])?["item"] as? [String: Any]
        }
        return nil
    }
    static func number(_ value: Any?) -> Int? { ((value as? [String: Any])?["units"] as? Int) ?? (value as? Int) }

    public static func info(html: String, url: URL) throws -> NovelInfo {
        guard let slug = novelSlug(url), let item = query(state(html), "novel") else { throw SourceError.unsupportedStructure }
        let title = item["name"] as? String ?? slug
        let cover = ((item["coverUrl"] as? [String: Any])?["value"] as? String).flatMap(URL.init(string:))
        let synopsis = ((item["synopsis"] as? [String: Any])?["value"] as? String).map(LinkedSource.plain)
        let language: String? = switch ((item["language"] as? [String: Any])?["value"] as? String)?.lowercased() {
        case "chinese": "zh"
        case "korean": "ko"
        case "japanese": "ja"
        default: nil
        }
        let info = item["chapterInfo"] as? [String: Any] ?? [:]
        let first = info["firstChapter"] as? [String: Any]
        let latest = info["latestChapter"] as? [String: Any]
        var chapters: [Chapter] = []
        // Chapter addresses follow the first chapter's ("mw-chapter-0" … "mw-chapter-2256").
        if let firstSlug = first?["slug"] as? String, let low = number(first?["number"]), let high = number(latest?["number"]), high >= low, high - low < 20_000,
           let prefix = LinkedSource.firstMatch(#"^(.*?)[0-9]+$"#, firstSlug), !prefix.isEmpty {
            for n in low...high {
                let name: String? = n == low ? first?["name"] as? String : n == high ? latest?["name"] as? String : nil
                chapters.append(Chapter(url: URL(string: "https://www.wuxiaworld.com/novel/\(slug)/\(prefix)\(n)")!,
                                        title: name ?? "Chapter \(n)", number: String(n)))
            }
        }
        if chapters.isEmpty {
            chapters = LinkedSource.chapterLinks(in: html, base: url).filter { $0.url.path.hasPrefix("/novel/\(slug)/") }
        }
        guard !chapters.isEmpty else { throw SourceError.unsupportedStructure }
        return NovelInfo(title: title, author: nil, cover: cover, summary: synopsis, language: language, chapters: chapters)
    }
    /// Whether this chapter page is a paid chapter (the site shows only its start).
    static func isLocked(html: String, url: URL) -> Bool {
        guard handles(url), let item = query(state(html), "chapter") else { return false }
        return ((item["pricingInfo"] as? [String: Any])?["isFree"] as? Bool) == false
    }
}

// MARK: - Any novel

/// Reads novels from any site: dedicated data where a site has it, reader-mode extraction everywhere else.
public struct NovelSource: Sendable {
    private let http: any HTTPTransport
    public init(http: any HTTPTransport = WebsiteHTTPClient()) { self.http = http }

    /// Sites whose novels come from their own data rather than page reading.
    public static func isDedicated(_ url: URL) -> Bool { Syosetu.handles(url) || Kakuyomu.handles(url) || Wuxiaworld.handles(url) }
    /// Sites that only host novels (anything added from them is a novel).
    public static func isNovelSite(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return ["syosetu.com", "kakuyomu.jp", "wuxiaworld.com", "j-novel.club"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    public func info(_ url: URL) async throws -> NovelInfo {
        guard WebLink.publicHTTPS(url) else { throw SourceError.insecureURL }
        if Syosetu.handles(url) { return try await Syosetu.info(url, http: http) }
        if let id = Kakuyomu.workID(url) {
            return try Kakuyomu.info(html: try await page(URL(string: "https://kakuyomu.jp/works/\(id)")!), url: url)
        }
        if let slug = Wuxiaworld.novelSlug(url) {
            let home = URL(string: "https://www.wuxiaworld.com/novel/\(slug)")!
            return try Wuxiaworld.info(html: try await page(home), url: home)
        }
        return try await Self.info(html: page(url), url: url, http: http)
    }
    /// A series page already loaded (by the in-app browser, say): its chapters, title and cover.
    public static func info(html: String, url: URL, http: any HTTPTransport = WebsiteHTTPClient(), followIndex: Bool = true) async throws -> NovelInfo {
        if let id = Kakuyomu.workID(url) {
            // An episode page carries only part of the table of contents: read the work page.
            if url.pathComponents.contains("episodes") {
                let home = URL(string: "https://kakuyomu.jp/works/\(id)")!
                let data = try await http.fetch(home, referer: nil, image: false)
                var found = try Kakuyomu.info(html: String(decoding: data, as: UTF8.self), url: home)
                found.home = home
                return found
            }
            return try Kakuyomu.info(html: html, url: url)
        }
        if let slug = Wuxiaworld.novelSlug(url) {
            if let found = try? Wuxiaworld.info(html: html, url: url) { return found }
            let home = URL(string: "https://www.wuxiaworld.com/novel/\(slug)")!
            let data = try await http.fetch(home, referer: nil, image: false)
            var found = try Wuxiaworld.info(html: String(decoding: data, as: UTF8.self), url: home)
            found.home = home
            return found
        }
        if let code = Syosetu.ncode(url) {
            var found = try await Syosetu.info(url, http: http)
            if url.pathComponents.count > 2 { found.home = Syosetu.workURL(code) }
            return found
        }
        var chapters = Webtoons.handles(url) ? [] : LinkedSource.chapterLinks(in: html, base: url)
        let title = LinkedSource.seriesTitle(in: html) ?? url.host ?? "Novel"
        let text = NovelText.extract(html: html, url: url)
        let isChapter = text.map { NovelText.textLength($0.html) >= 1000 } ?? false
        if isChapter && chapters.count < 4 {
            // A chapter page that only links its neighbours: the novel's own page has the full list.
            if followIndex, let index = indexLink(in: html, base: url), index != url,
               let data = try? await http.fetch(index, referer: url, image: false),
               let page = String(data: data, encoding: .utf8),
               var found = try? await info(html: page, url: index, http: http, followIndex: false), found.chapters.count > chapters.count {
                found.home = index
                return found
            }
            if !chapters.contains(where: { LinkedSource.key($0.url) == LinkedSource.key(url) }) {
                let n = ChapterOrder.number(text?.title ?? "") ?? ChapterOrder.number(url.path)
                chapters = ChapterOrder.sorted(chapters + [Chapter(url: url, title: text?.title ?? title, number: n.map { LinkedSource.format($0) } ?? "")])
            }
        }
        if chapters.isEmpty, let text, NovelText.textLength(text.html) >= 400 {
            // A one-page story with no list of others.
            chapters = [Chapter(url: url, title: text.title ?? title, number: "1")]
        }
        guard !chapters.isEmpty else { throw SourceError.unsupportedStructure }
        return NovelInfo(title: title, cover: LinkedSource.cover(in: html, base: url), summary: LinkedSource.synopsis(in: html), chapters: chapters)
    }
    /// The link from a chapter back to its novel: "Index", "Table of contents", or the address the chapter sits under.
    static func indexLink(in html: String, base: URL) -> URL? {
        let root = LinkedSource.root(base.host ?? "")
        var parent: URL?
        for m in LinkedSource.matches(#"(?is)<a\b([^>]*)>(.*?)</a>"#, html) {
            guard let href = ReadBerserkParser.attributes("<a " + m[0] + ">")["href"], let url = LinkedSource.resolve(href, base: base),
                  LinkedSource.root(url.host ?? "") == root, url.path.count > 1 else { continue }
            let label = LinkedSource.plain(m[1]).lowercased()
            if label.range(of: #"^(?:index|table of contents|toc|chapter list|all chapters|novel info|目次)$"#, options: .regularExpression) != nil { return url }
            // The page the chapter's address sits under (/novel/name for /novel/name/chapter-3).
            let path = url.path.hasSuffix("/") ? url.path : url.path + "/"
            if parent == nil, base.path.hasPrefix(path), base.path.count > path.count + 1,
               url.path.range(of: LinkedSource.seriesPath, options: .regularExpression) != nil { parent = url }
        }
        return parent
    }
    /// One chapter's text.
    public func chapter(_ url: URL) async throws -> NovelChapterText {
        guard WebLink.publicHTTPS(url) else { throw SourceError.insecureURL }
        let html = try await page(url)
        guard let text = NovelText.extract(html: html, url: url) else {
            // A paid chapter whose page carries no text at all: say it's locked rather than failing.
            if Wuxiaworld.isLocked(html: html, url: url) { return NovelChapterText(title: NovelText.title(in: html), html: "", locked: true) }
            throw SourceError.unsupportedStructure
        }
        return text
    }
    private func page(_ url: URL) async throws -> String {
        let data = try await http.fetch(url, referer: nil, image: false)
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw SourceError.unsupportedStructure }
        return html
    }
}
