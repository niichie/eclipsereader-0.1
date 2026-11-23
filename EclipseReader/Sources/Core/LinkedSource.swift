import Foundation

/// Validation for links the user pastes. Only public HTTPS hosts with real domain
/// names are allowed: no IP literals, local-network names, ports or credentials.
public enum WebLink {
    public static func parse(_ text: String) -> URL? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.lowercased().hasPrefix("http://") { raw = "https://" + raw.dropFirst(7) }
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw), publicHTTPS(url) else { return nil }
        return url
    }
    public static func publicHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased(),
              host.utf8.count <= 253 else { return false }
        let parts = host.components(separatedBy: ".")
        guard parts.count >= 2, let suffix = parts.last, suffix.count >= 2,
              suffix.utf8.allSatisfy({ (97...122).contains($0) }),
              !["local", "localhost", "lan", "internal", "home", "test", "invalid", "onion", "arpa", "corp"].contains(suffix)
        else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 63 && !part.hasPrefix("-") && !part.hasSuffix("-") &&
            part.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
    public static func isDirectImage(_ url: URL) -> Bool {
        ["jpg", "jpeg", "png", "webp", "heic", "heif", "avif"].contains(url.pathExtension.lowercased())
    }
}

public struct LinkedChapter: Sendable {
    public let title: String
    public let pages: [MangaPage]
}

/// What a pasted link turned out to be.
public struct LinkInspection: Sendable {
    public let title: String
    public let cover: URL?
    /// Page images, when the link itself is a readable chapter.
    public let pages: [MangaPage]
    /// Every chapter found (series page list, Madara AJAX list, or a chapter page's chapter picker), reading order.
    public let chapters: [Chapter]
    /// Manga / manhwa / comic hint from the page's own tags, when it states one.
    public var style: ReadingStyle? = nil
}

/// Reads manga from ordinary web pages the user linked.
/// Pages: images marked with known manga-reader classes, else the largest run of large
/// images in one folder. Chapters: chapter-like links or chapter pickers on the page.
/// Ads, logos and icons are excluded. Nothing is bypassed; unreadable sites fall back
/// to the in-app browser.
public struct LinkedSource: Sendable {
    private let http: any HTTPTransport
    public init(http: any HTTPTransport = WebsiteHTTPClient()) { self.http = http }

    public func chapter(_ url: URL) async throws -> LinkedChapter {
        guard WebLink.publicHTTPS(url) else { throw SourceError.insecureURL }
        if WebLink.isDirectImage(url) {
            return LinkedChapter(title: url.deletingPathExtension().lastPathComponent,
                                 pages: [MangaPage(url: url, label: "Page 1")])
        }
        let html = try await page(url)
        return LinkedChapter(title: Self.title(in: html) ?? url.host ?? "Manga", pages: try Self.detect(in: html, base: url))
    }
    public func pages(_ url: URL) async throws -> [MangaPage] { try await chapter(url).pages }

    /// Looks at a link and returns whatever it can read: pages, a chapter list, or both.
    public func inspect(_ url: URL) async throws -> LinkInspection {
        guard WebLink.publicHTTPS(url) else { throw SourceError.insecureURL }
        if WebLink.isDirectImage(url) {
            let title = url.deletingPathExtension().lastPathComponent
            return LinkInspection(title: title, cover: url, pages: [MangaPage(url: url, label: "Page 1")],
                                  chapters: [Chapter(url: url, title: title, number: "1")])
        }
        let html = try await page(url)
        // A Webtoons episode: pages from the episode, the full episode list from the series page.
        if Webtoons.handles(url), url.path.hasSuffix("/viewer"), let list = Webtoons.listURL(for: url),
           let listHTML = try? await page(list), let series = try? Self.analyze(html: listHTML, url: list) {
            let episode = try Self.analyze(html: html, url: url)
            return LinkInspection(title: series.title, cover: series.cover, pages: episode.pages,
                                  chapters: series.chapters.count >= episode.chapters.count ? series.chapters : episode.chapters, style: .manhwa)
        }
        var extra: [Chapter] = []
        if Self.chapterLinks(in: html, base: url).count < 2, html.contains("wp-manga") || html.contains("manga-chapters-holder") {
            // Madara themes (common for manhwa) load the chapter list separately.
            extra = await madaraChapters(series: url, html: html)
        }
        return try Self.analyze(html: html, url: url, extraChapters: extra)
    }

    /// Reads a page's HTML (fetched directly, or rendered by the in-app browser for script-built sites)
    /// into pages, a chapter list, a title, a cover and a style hint.
    public static func analyze(html: String, url: URL, extraChapters: [Chapter] = []) throws -> LinkInspection {
        let pages = (try? detect(in: html, base: url)) ?? []
        var chapters = Webtoons.handles(url) ? Webtoons.episodes(in: html, base: url) : chapterLinks(in: html, base: url)
        if chapters.count < 2 && extraChapters.count >= chapters.count { chapters = extraChapters }
        if pages.isEmpty && chapters.count < 1 { throw SourceError.unsupportedStructure }
        let title = seriesTitle(in: html) ?? url.host ?? "Manga"
        let here = key(url)
        if !pages.isEmpty, chapters.count <= 3, !chapters.contains(where: { key($0.url) == here }) {
            // A chapter page whose list only shows neighbours (Previous/Next): keep the pasted chapter too.
            let name = Self.title(in: html) ?? title
            let n = ChapterOrder.number(name) ?? ChapterOrder.number(url.path)
            chapters = ChapterOrder.sorted(chapters + [Chapter(url: url, title: name, number: n.map { format($0) } ?? "")])
        }
        return LinkInspection(title: title, cover: cover(in: html, base: url), pages: pages, chapters: chapters,
                              style: styleHint(in: html, url: url))
    }

    /// Finds just the cover of a series page (used to fill in missing covers later).
    public func cover(of url: URL) async -> URL? {
        guard WebLink.publicHTTPS(url), let html = try? await page(url) else { return nil }
        return Self.cover(in: html, base: url)
    }

    private func page(_ url: URL) async throws -> String {
        let bytes = try await http.fetch(url, referer: nil, image: false)
        guard let html = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1)
        else { throw SourceError.unsupportedStructure }
        return html
    }
    private func madaraChapters(series: URL, html: String) async -> [Chapter] {
        guard let client = http as? WebsiteHTTPClient else { return [] }
        var base = series.absoluteString
        if !base.hasSuffix("/") { base += "/" }
        if let url = URL(string: base + "ajax/chapters/"), let data = try? await client.post(url, referer: series, body: nil),
           let text = String(data: data, encoding: .utf8) {
            let found = Self.chapterLinks(in: text, base: series)
            if !found.isEmpty { return found }
        }
        // Older Madara: admin-ajax with the numeric manga id.
        if let id = ReadBerserkParser.matches(#"(?:data-id|manga_id|"manga_id")\s*[=:]\s*["']?([0-9]+)"#, html).first?.first,
           let host = series.host, let url = URL(string: "https://\(host)/wp-admin/admin-ajax.php"),
           let data = try? await client.post(url, referer: series, body: "action=manga_get_chapters&manga=\(id)"),
           let text = String(data: data, encoding: .utf8) {
            return Self.chapterLinks(in: text, base: series)
        }
        return []
    }

    /// Reads genre/type tags the page states about itself. Site names often contain "manga",
    /// so only explicit manhwa/webtoon/manhua/comic signals count; anything else is left to page-shape detection.
    public static func styleHint(in html: String, url: URL) -> ReadingStyle? {
        let text = (url.absoluteString + " " + plain(String(html.prefix(400_000)))).lowercased()
        func count(_ word: String) -> Int { text.components(separatedBy: word).count - 1 }
        let host = url.host?.lowercased() ?? ""
        let hostVertical = ["webtoon", "manhwa", "manhua", "asura", "toon"].contains(where: host.contains) ? 3 : 0
        let vertical = count("manhwa") + count("manhua") + count("webtoon") + count("korean") + count("long strip") + hostVertical
        let japanese = count("japanese manga") + count("type: manga") + count("right to left")
        let western = count("western comic") + count("type: comic") + count("american comic")
        if vertical >= 2 && vertical > japanese { return .manhwa }
        if western >= 1 && western > vertical { return .comic }
        if japanese >= 1 { return .manga }
        return nil
    }
    /// Looks for the series cover the way sites declare it, most reliable first:
    /// Open Graph / Twitter cards, image_src links, structured data, then cover-like images on the page.
    public static func cover(in html: String, base: URL) -> URL? {
        let patterns = [
            #"(?is)<meta[^>]+(?:property|name)=["']og:image(?::secure_url)?["'][^>]*content=["']([^"']+)"#,
            #"(?is)<meta[^>]+content=["']([^"']+)["'][^>]*(?:property|name)=["']og:image["']"#,
            #"(?is)<meta[^>]+name=["']twitter:image(?::src)?["'][^>]*content=["']([^"']+)"#,
            #"(?is)<link[^>]+rel=["']image_src["'][^>]*href=["']([^"']+)"#,
            #"(?is)"(?:image|thumbnailUrl)"\s*:\s*"(https?:[^"]+?\.(?:jpe?g|png|webp|avif)[^"]*)""#,
        ]
        for pattern in patterns {
            if let raw = firstMatch(pattern, html), let url = resolve(raw, base: base), !looksLikeLogo(url) { return url }
        }
        // Cover-like <img>: class, alt or file name mentions a cover, poster or thumbnail.
        let inert = html.replacingOccurrences(of: #"(?is)<(script|style|template|noscript)\b[^>]*>.*?</\1\s*>"#,
                                              with: "", options: .regularExpression)
        for tag in ReadBerserkParser.tags("img", inert) {
            let fields = ReadBerserkParser.attributes(tag)
            let hint = [fields["class"], fields["alt"], fields["id"], fields["src"], fields["data-src"]]
                .compactMap { $0?.lowercased() }.joined(separator: " ")
            guard ["cover", "poster", "thumbnail", "summary_image", "wp-post-image", "series-image"].contains(where: hint.contains)
            else { continue }
            let raw = ["data-src", "data-lazy-src", "data-original", "src"].lazy.compactMap { fields[$0] }
                .first { !$0.hasPrefix("data:") && !$0.isEmpty }
            if let raw, let url = resolve(raw, base: base), !looksLikeLogo(url) { return url }
        }
        return nil
    }
    static func resolve(_ raw: String, base: URL) -> URL? {
        let clean = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\/", with: "/")
        guard let url = URL(string: clean, relativeTo: base)?.absoluteURL, WebLink.publicHTTPS(url) else { return nil }
        return url
    }
    static func looksLikeLogo(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return ["logo", "favicon", "icon", "default", "placeholder", "banner"].contains(where: path.contains) || url.pathExtension.lowercased() == "svg"
    }
    static func seriesTitle(in html: String) -> String? {
        if let h1 = firstMatch(#"(?is)<h1[^>]*>(.*?)</h1>"#, html) {
            let text = plain(h1)
            if !text.isEmpty && text.count < 140 { return text }
        }
        return title(in: html)
    }
    static func firstMatch(_ pattern: String, _ text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
    static func plain(_ html: String) -> String {
        decodeEntities(html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression))
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static let chapterWords = #"(?i)(chapter|chap[\-_.]|/ch[\-_.]?[0-9]|episode|/ep[\-_.]?[0-9]|第[0-9]+[話话章]|[0-9]+화|/c[0-9]+)"#
    /// Chapter links on a series page, plus <option> chapter pickers found on chapter pages.
    public static func chapterLinks(in html: String, base: URL) -> [Chapter] {
        let inert = html.replacingOccurrences(of: #"(?is)<!--.*?-->|<(script|style|template)\b[^>]*>.*?</\1\s*>"#,
                                              with: "", options: .regularExpression)
        guard let words = try? NSRegularExpression(pattern: chapterWords) else { return [] }
        func chapterLike(_ s: String) -> Bool { words.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        let baseRoot = base.host.map { Self.root($0) } ?? ""
        var seen = Set<String>()
        var found: [Chapter] = []
        func consider(href: String, text: String) {
            let cleanHref = decodeEntities(href).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanHref.isEmpty, !cleanHref.hasPrefix("#"), !cleanHref.lowercased().hasPrefix("javascript"),
                  var url = URL(string: cleanHref, relativeTo: base)?.absoluteURL, WebLink.publicHTTPS(url),
                  let host = url.host, Self.root(host) == baseRoot else { return }
            if var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) { parts.fragment = nil; url = parts.url ?? url }
            let label = plain(text)
            let path = url.path
            guard path.count > 1, chapterLike(path) || chapterLike(label),
                  !path.lowercased().contains("/comment"), !path.lowercased().hasSuffix("/feed")
            else { return }
            let key = url.absoluteString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard seen.insert(key).inserted else { return }
            let n = ChapterOrder.number(label) ?? ChapterOrder.number(path)
            let title = label.isEmpty || label.count > 90 ? (n.map { "Chapter \(Self.format($0))" } ?? url.lastPathComponent) : label
            found.append(Chapter(url: url, title: title, number: n.map { Self.format($0) } ?? ""))
        }
        for m in matches(#"(?is)<a\b([^>]*)>(.*?)</a>"#, inert) {
            if let href = ReadBerserkParser.attributes("<a " + m[0] + ">")["href"] { consider(href: href, text: m[1]) }
        }
        for m in matches(#"(?is)<option\b([^>]*)>(.*?)</option>"#, inert) {
            let fields = ReadBerserkParser.attributes("<option " + m[0] + ">")
            if let href = fields["data-redirect"] ?? fields["value"], href.contains("/") { consider(href: href, text: m[1]) }
        }
        // Chapters of one series share an address folder. A home page that links chapters of many
        // series is not a chapter list: keep the dominant series only when it clearly dominates.
        let folders = Dictionary(grouping: found) { $0.url.deletingLastPathComponent().path.lowercased() }
        if folders.count > 1, let biggest = folders.values.max(by: { $0.count < $1.count }) {
            guard Double(biggest.count) >= Double(found.count) * 0.6 else { return [] }
            let keep = Set(biggest.map(\.url))
            found = found.filter { keep.contains($0.url) }
        }
        // A real chapter list has several entries; single stray links (e.g. "latest chapter") are ignored.
        guard found.count >= 2 else { return [] }
        return ChapterOrder.sorted(found)
    }
    static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { i in m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)) }
        }
    }
    /// Comparison key that ignores case, fragments and trailing slashes.
    public static func key(_ url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        return (parts?.url ?? url).absoluteString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    static func root(_ host: String) -> String { host.lowercased().split(separator: ".").suffix(2).joined(separator: ".") }
    static func format(_ n: Double) -> String { n == n.rounded() ? String(Int(n)) : String(n) }

    static let readerClasses: Set<String> = [
        "wp-manga-chapter-img", "manga-page", "pages__img", "chapter-img", "page-img", "reader-img",
        "comic-page", "manga-img", "img-chapter", "page-image", "chapter-image", "reading-content-img",
        "_images", "viewer-img", "reader-page", "page-break"
    ]
    static let junk = ["logo", "icon", "avatar", "banner", "sprite", "emoji", "button", "badge", "thumb",
                       "gravatar", "pixel", "tracking", "/ads/", "advert", "promo", "spinner", "loading", "placeholder"]

    public static func title(in html: String) -> String? {
        let patterns = [#"(?is)<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)"#, #"(?is)<title[^>]*>(.*?)</title>"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            let text = decodeEntities(String(html[range])).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return String(text.prefix(120)) }
        }
        return nil
    }
    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#8211;", with: "–").replacingOccurrences(of: "&#8217;", with: "’")
    }

    public static func detect(in html: String, base: URL) throws -> [MangaPage] {
        let inert = html.replacingOccurrences(of: #"(?is)<!--.*?-->|<(script|style|template|noscript)\b[^>]*>.*?</\1\s*>"#,
                                              with: "", options: .regularExpression)
        struct Candidate { let url: URL; let alt: String?; let width: Double?; let height: Double?; let marked: Bool }
        var candidates: [Candidate] = []
        var seen = Set<URL>()
        for tag in ReadBerserkParser.tags("img", inert) {
            let fields = ReadBerserkParser.attributes(tag)
            let sourceKeys = ["data-src", "data-lazy-src", "data-original", "data-url", "data-cfsrc", "src"]
            guard let raw = sourceKeys.lazy.compactMap({ fields[$0] }).first(where: { !$0.hasPrefix("data:") && !$0.isEmpty }),
                  let url = URL(string: decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base)?.absoluteURL,
                  WebLink.publicHTTPS(url), seen.insert(url).inserted else { continue }
            let classes = Set((fields["class"] ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
            let id = (fields["id"] ?? "").lowercased()
            let marked = !classes.isDisjoint(with: readerClasses) || id.hasPrefix("image-") || id.hasPrefix("page")
            candidates.append(Candidate(url: url, alt: fields["alt"], width: fields["width"].flatMap(Double.init),
                                        height: fields["height"].flatMap(Double.init), marked: marked))
        }
        func page(_ c: Candidate, _ i: Int) -> MangaPage {
            MangaPage(url: c.url, label: "Page \(i + 1)", width: c.width, height: c.height)
        }
        let marked = candidates.filter(\.marked)
        if marked.count >= 2 { return marked.enumerated().map { page($1, $0) } }

        // Heuristic fallback: large, non-decorative images grouped by folder.
        let usable = candidates.filter { c in
            let path = c.url.absoluteString.lowercased()
            if ["svg", "gif", "ico"].contains(c.url.pathExtension.lowercased()) { return false }
            if junk.contains(where: path.contains) { return false }
            if let w = c.width, w < 300 { return false }
            if let h = c.height, h < 300 { return false }
            return true
        }
        var folders: [String: [Candidate]] = [:]
        var order: [String] = []
        for c in usable {
            let key = (c.url.host ?? "") + c.url.deletingLastPathComponent().path
            if folders[key] == nil { order.append(key) }
            folders[key, default: []].append(c)
        }
        if let best = order.max(by: { (folders[$0]?.count ?? 0) < (folders[$1]?.count ?? 0) }),
           let run = folders[best], run.count >= 3 {
            return run.enumerated().map { page($1, $0) }
        }
        // CDNs that give every image its own folder (Webtoons, many manhwa hosts): group by host.
        // Only on pages that are plainly a chapter, so a catalogue of covers is never read as pages.
        let chapterLike = base.absoluteString.range(of: #"(?i)(chapter|episode|viewer|/ch[-_.]?\d|/read/)"#, options: .regularExpression) != nil
        guard chapterLike else { throw SourceError.unsupportedStructure }
        var hosts: [String: [Candidate]] = [:]
        var hostOrder: [String] = []
        for c in usable {
            let key = c.url.host ?? ""
            if hosts[key] == nil { hostOrder.append(key) }
            hosts[key, default: []].append(c)
        }
        if let best = hostOrder.max(by: { (hosts[$0]?.count ?? 0) < (hosts[$1]?.count ?? 0) }),
           let run = hosts[best], run.count >= 4 {
            return run.enumerated().map { page($1, $0) }
        }
        // Script-built readers: image addresses listed in the page's data.
        let listed = scriptImages(in: html)
        if listed.count >= 3 { return listed.enumerated().map { MangaPage(url: $1, label: "Page \($0 + 1)") } }
        throw SourceError.unsupportedStructure
    }

    /// Image addresses written into a page's scripts (JSON chapter data), in order, grouped
    /// by folder or host so the largest consistent set wins.
    static func scriptImages(in html: String) -> [URL] {
        let text = html.replacingOccurrences(of: "\\/", with: "/")
        var seen = Set<URL>()
        var urls: [URL] = []
        for m in matches(#"(https://[^\s"'<>\\]+?\.(?:jpe?g|png|webp|avif)(?:\?[^\s"'<>\\]*)?)["'\\]"#, text) {
            guard let url = URL(string: m[0]), WebLink.publicHTTPS(url) else { continue }
            let lower = url.absoluteString.lowercased()
            if junk.contains(where: lower.contains) || lower.contains("cover") { continue }
            if seen.insert(url).inserted { urls.append(url) }
        }
        func group(_ key: (URL) -> String) -> [URL] {
            var g: [String: [URL]] = [:]
            var order: [String] = []
            for u in urls { let k = key(u); if g[k] == nil { order.append(k) }; g[k, default: []].append(u) }
            return order.map { g[$0]! }.max(by: { $0.count < $1.count }) ?? []
        }
        let byFolder = group { ($0.host ?? "") + $0.deletingLastPathComponent().path }
        return byFolder.count >= 3 ? byFolder : group { $0.host ?? "" }
    }
}

/// Webtoons lists only 10 episodes per series page. Every episode has a numbered viewer address,
/// so the full list is built from the newest episode number on the first page (one request).
public enum Webtoons {
    public static func handles(_ url: URL) -> Bool {
        (url.host?.lowercased().hasSuffix("webtoons.com") ?? false) && titleNumber(url) != nil
    }
    static func titleNumber(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "title_no" }?.value
    }
    static func episodeNumber(_ url: URL) -> Int? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "episode_no" }?.value.flatMap(Int.init)
    }
    static func cleanTitle(_ text: String) -> String {
        var t = LinkedSource.plain(text)
        if let r = t.range(of: " BGM") { t = String(t[..<r.lowerBound]) }
        t = t.replacingOccurrences(of: #"\s+(UP\s+)?[A-Z][a-z]{2} \d{1,2}, \d{4}.*$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+like\s+[\d,]+.*$"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }
    /// The series list page for an episode viewer address.
    public static func listURL(for viewer: URL) -> URL? {
        guard let title = titleNumber(viewer), var parts = URLComponents(url: viewer, resolvingAgainstBaseURL: false) else { return nil }
        let path = parts.path.split(separator: "/").dropLast(2)
        parts.path = "/" + path.joined(separator: "/") + "/list"
        parts.queryItems = [URLQueryItem(name: "title_no", value: title)]
        return parts.url
    }
    public static func episodes(in html: String, base: URL) -> [Chapter] {
        guard let title = titleNumber(base) else { return [] }
        var known: [Int: (URL, String)] = [:]
        for m in LinkedSource.matches(#"(?is)<a\b([^>]*)>(.*?)</a>"#, html) {
            guard let href = ReadBerserkParser.attributes("<a " + m[0] + ">")["href"],
                  let url = LinkedSource.resolve(href, base: base), url.path.hasSuffix("/viewer"),
                  titleNumber(url) == title, let n = episodeNumber(url) else { continue }
            let name = cleanTitle(m[1])
            if known[n] == nil || (known[n]?.1.isEmpty ?? true) { known[n] = (url, name) }
        }
        guard let newest = known.keys.max(), let template = known[newest]?.0,
              var parts = URLComponents(url: template, resolvingAgainstBaseURL: false) else { return [] }
        return (1...newest).compactMap { n -> Chapter? in
            if let entry = known[n] { return Chapter(url: entry.0, title: entry.1.isEmpty ? "Episode \(n)" : entry.1, number: String(n)) }
            parts.queryItems = (parts.queryItems ?? []).map { $0.name == "episode_no" ? URLQueryItem(name: "episode_no", value: String(n)) : $0 }
            guard let url = parts.url else { return nil }
            return Chapter(url: url, title: "Episode \(n)", number: String(n))
        }
    }
}
