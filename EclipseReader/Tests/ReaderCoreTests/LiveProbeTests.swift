import XCTest
@testable import ReaderCore

/// Checks every source against the live sites with the app's own code. Runs only when LIVE_PROBE=1
/// (the "Probe sources" workflow); prints one PROBE line per check and never fails the build.
final class LiveProbeTests: XCTestCase {
    private let http = WebsiteHTTPClient()

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_PROBE"] == "1", "live probe only")
    }

    private func report(_ name: String, _ ok: Bool, _ detail: String) {
        print("PROBE|\(ok ? "OK" : "FAIL")|\(name)|\(detail.replacingOccurrences(of: "\n", with: " ").prefix(300))")
    }

    /// Status, type, size and the start of the body, fetched like an iPhone browser would.
    private func raw(_ name: String, _ address: String, desktop: Bool = false) async {
        guard let url = URL(string: address) else { return }
        var request = URLRequest(url: url, timeoutInterval: 40)
        request.setValue(desktop
            ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
            : "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent")
        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let text = String(data: data.prefix(400), encoding: .utf8) ?? "<binary>"
            let headers = ["Content-Type", "Content-Disposition", "Server", "cf-mitigated"].compactMap { key in
                http?.value(forHTTPHeaderField: key).map { "\(key)=\($0)" }
            }.joined(separator: " ")
            report("raw " + name, (200..<300).contains(http?.statusCode ?? 0),
                   "\(http?.statusCode ?? 0) \(data.count)B \(String(format: "%.1fs", Date().timeIntervalSince(start))) final=\(http?.url?.absoluteString ?? "") \(headers) :: \(text.prefix(200))")
        } catch {
            report("raw " + name, false, "\(String(format: "%.1fs", Date().timeIntervalSince(start))) \(error)")
        }
    }

    private func timed<T>(_ name: String, _ body: () async throws -> T, describe: (T) -> (Bool, String)) async -> T? {
        let start = Date()
        do {
            let value = try await body()
            let (ok, detail) = describe(value)
            report(name, ok, String(format: "%.1fs ", Date().timeIntervalSince(start)) + detail)
            return value
        } catch {
            report(name, false, String(format: "%.1fs ", Date().timeIntervalSince(start)) + "\(error)")
            return nil
        }
    }

    /// Search → open the first result → read its chapters → read the first chapter's pages.
    private func series(_ name: String, source: SearchSource, query: String) async {
        let found = await timed("\(name) search \"\(query)\"", { try await GlobalSearch.search(source, query: query, http: http) }) {
            ($0.isEmpty == false, "\($0.count) results: " + $0.prefix(5).map { "\($0.title) <\($0.url.absoluteString)>" }.joined(separator: " | "))
        }
        guard let first = found?.first else { return }
        await chapters(name, url: first.url)
    }

    private func chapters(_ name: String, url: URL) async {
        let source = LinkedSource(http: http)
        let inspected = await timed("\(name) series <\(url.absoluteString)>", { try await source.inspect(url) }) {
            ($0.chapters.count > 0, "title=\($0.title) cover=\($0.cover?.absoluteString ?? "-") chapters=\($0.chapters.count) first=\($0.chapters.first?.url.absoluteString ?? "-")")
        }
        guard let chapter = inspected?.chapters.first else { return }
        _ = await timed("\(name) pages <\(chapter.url.absoluteString)>", { try await source.pages(chapter.url) }) {
            ($0.count > 1, "\($0.count) pages, first=\($0.first?.url.absoluteString ?? "-")")
        }
    }

    func testManga() async {
        _ = await timed("MangaDex popular", { try await Discover.mangaDex(limit: 10, http: http) }) { ($0.count > 0, "\($0.count): " + $0.prefix(3).map(\.title).joined(separator: ", ")) }
        await series("MangaDex", source: SearchSource(name: "MangaDex", kind: .mangaDex), query: "Chainsaw Man")
        _ = await timed("MangaDex because-you-read Berserk", { try await Discover.similar(to: "Berserk", http: http) }) { ($0.count > 0, "\($0.count): " + $0.prefix(4).map(\.title).joined(separator: ", ")) }

        await raw("WeebCentral home", "https://weebcentral.com/")
        await series("WeebCentral", source: SearchSource(name: "WeebCentral", kind: .weebCentral), query: "Jujutsu Kaisen")
        await series("WEBTOON", source: SearchSource(name: "WEBTOON", kind: .webtoons), query: "Tower of God")
    }

    func testSites() async {
        let sites = [("Asura Scans", "https://asurascans.com/comics", "murim login"), ("MangaDot", "https://mangadot.net/", "Solo Leveling"),
                     ("MangaBall", "https://mangaball.com/", "Solo Leveling"), ("Comix", "https://comix.to/", "Solo Leveling")]
        for (name, address, query) in sites {
            await raw(name + " home", address)
            await series(name, source: SearchSource(name: name, kind: .site(URL(string: address)!)), query: query)
        }
        await chapters("Comix title", url: URL(string: "https://comix.to/title/l9vj2-the-demon-king-overrun-by-heroes")!)
        let (_, _, dot2) = await body("https://mangadot.net/manga/118?page=2")
        dump("mangadot page 2", "chapter links: \(Set(LinkedSource.matches(#"/chapter/(\d+)"#, dot2).map { $0[0] }).count) || \(around(dot2, #"(?i)next|page=2|pagination"#, before: 300, after: 300))")
        let official = [("MANGA Plus", "https://mangaplus.shueisha.co.jp/updates"), ("Tapas", "https://tapas.io/"),
                        ("Tappytoon", "https://www.tappytoon.com/en"), ("Manta", "https://manta.net/en"),
                        ("GlobalComix", "https://globalcomix.com/"), ("Comikey", "https://comikey.com/"),
                        ("WEBTOON Canvas", "https://www.webtoons.com/en/canvas")]
        for (name, address) in official { await raw(name + " home", address) }
    }

    func testBooks() async {
        _ = await timed("Standard Ebooks search", { try await FreeBooks.standardEbooks(query: "dracula", http: http) }) {
            ($0.count > 0, "\($0.count): " + $0.prefix(3).map { "\($0.title) by \($0.author ?? "-") \($0.download?.absoluteString ?? "-") cover=\($0.cover?.absoluteString ?? "-")" }.joined(separator: " | "))
        }
        _ = await timed("Standard Ebooks popular", { try await FreeBooks.standardEbooks(http: http) }) { ($0.count > 0, "\($0.count): " + $0.prefix(5).map(\.title).joined(separator: ", ")) }
        if let book = try? await FreeBooks.standardEbooks(query: "frankenstein", http: http).first, let link = book.download {
            _ = await timed("Standard Ebooks download \(book.title)", { try await http.downloadFile(link) }) { file in
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return (size > 10_000, "\(file.lastPathComponent) \(size)B")
            }
        }
        _ = await timed("Gutenberg search (site, then Gutendex)", { try await FreeBooks.gutenberg(query: "frankenstein", http: http) }) {
            ($0.count > 0, "\($0.count): " + $0.prefix(3).map { "\($0.title) by \($0.author ?? "-")" }.joined(separator: " | "))
        }
        for mirror in FreeBooks.mirrors(for: URL(string: "https://www.gutenberg.org/ebooks/84.epub3.images")!) {
            _ = await timed("Gutenberg mirror \(mirror.host ?? "")", { try await http.downloadFile(mirror) }) { file in
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return (size > 10_000, "\(file.lastPathComponent) \(size)B")
            }
        }
        await raw("Gutenberg mirror cover", "https://gutenberg.pglaf.org/cache/epub/84/pg84.cover.medium.jpg")
        _ = await timed("Gutenberg (gutendex) search", { try await FreeBooks.gutenberg(query: "pride and prejudice", http: http) }) {
            ($0.count > 0, "\($0.count): " + $0.prefix(3).map { "\($0.title) \($0.download?.absoluteString ?? "-")" }.joined(separator: " | "))
        }
        _ = await timed("Gutenberg (gutendex) popular", { try await FreeBooks.gutenberg(http: http) }) { ($0.count > 0, "\($0.count)") }
        await raw("gutendex", "https://gutendex.com/books/?search=dracula")
        await raw("gutenberg.org opds search", "https://www.gutenberg.org/ebooks/search.opds/?query=dracula")
        await raw("gutenberg.org html search", "https://www.gutenberg.org/ebooks/search/?query=dracula")
        await raw("gutenberg.org top", "https://www.gutenberg.org/ebooks/search/?sort_order=downloads")
        _ = await timed("Gutenberg EPUB download", { try await http.downloadFile(URL(string: "https://www.gutenberg.org/ebooks/345.epub3.images")!) }) { file in
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return (size > 10_000, "\(file.lastPathComponent) \(size)B")
        }
        await raw("openlibrary search.json", "https://openlibrary.org/search.json?q=red+rising&fields=key,title,ebook_access&limit=3")
        _ = await timed("Book covers Red Rising", { await BookCovers.candidates(title: "Red Rising", author: "Pierce Brown", isbn: nil, http: http) }) {
            ($0.count > 0, $0.prefix(3).map(\.absoluteString).joined(separator: " "))
        }
        await raw("Standard Ebooks search", "https://standardebooks.org/ebooks?query=dracula")
        await raw("Standard Ebooks book", "https://standardebooks.org/ebooks/bram-stoker/dracula")
        await raw("Standard Ebooks download", "https://standardebooks.org/ebooks/bram-stoker/dracula/downloads/bram-stoker_dracula.epub?source=download")
        await raw("Standard Ebooks download plain", "https://standardebooks.org/ebooks/bram-stoker/dracula/downloads/bram-stoker_dracula.epub")
        await raw("Standard Ebooks opds", "https://standardebooks.org/feeds/opds/all")
        await raw("Wikisource ws-export", "https://ws-export.wmcloud.org/?format=epub&lang=en&page=Dracula")
        await raw("Wikisource search api", "https://en.wikisource.org/w/api.php?action=query&list=search&srsearch=dracula&srlimit=3&format=json")
        await raw("Internet Archive advancedsearch", "https://archive.org/advancedsearch.php?q=title%3A%28red+rising%29+AND+mediatype%3Atexts&fl%5B%5D=identifier&fl%5B%5D=title&rows=3&output=json")
    }

    func testRecommendations() async {
        _ = await timed("Jikan top manga", { try await Recommendations.topManga(http: http) }) { ($0.count > 0, "\($0.count): " + $0.prefix(3).map(\.title).joined(separator: ", ")) }
        _ = await timed("Open Library top books", { try await Recommendations.topBooks(http: http) }) { ($0.count > 0, "\($0.count): " + $0.prefix(3).map(\.title).joined(separator: ", ")) }
        _ = await timed("AniList search", { () async throws -> Data in
            var request = URLRequest(url: AniListAPI.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try AniListAPI.body(AniListAPI.searchQuery, variables: ["search": "Berserk"])
            return try await URLSession.shared.data(for: request).0
        }) { data in
            let media = (try? AniListAPI.parseSearch(data)) ?? []
            return (!media.isEmpty, "\(media.count): \(media.first?.title ?? String(data: data.prefix(200), encoding: .utf8) ?? "")")
        }
    }

    // MARK: Diagnostics: what the broken sources actually send back

    private func body(_ address: String, ua: String? = "iphone", accept: String? = nil, headers: [String: String] = [:]) async -> (Int, String, String) {
        guard let url = URL(string: address) else { return (0, "", "") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        switch ua {
        case "iphone": request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        case "desktop": request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        case .some(let custom): request.setValue(custom, forHTTPHeaderField: "User-Agent")
        case .none: break
        }
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            return (http?.statusCode ?? 0, http?.value(forHTTPHeaderField: "Content-Type") ?? "", String(data: data, encoding: .utf8) ?? "<binary \(data.count)B>")
        } catch { return (-1, "", "\(error)") }
    }
    /// Text around the first match of a pattern, flattened to one line.
    private func around(_ text: String, _ pattern: String, before: Int = 200, after: Int = 1200) -> String {
        guard let r = text.range(of: pattern, options: .regularExpression) else { return "<no \(pattern)>" }
        let start = text.index(r.lowerBound, offsetBy: -min(before, text.distance(from: text.startIndex, to: r.lowerBound)))
        let end = text.index(r.lowerBound, offsetBy: min(after, text.distance(from: r.lowerBound, to: text.endIndex)))
        return String(text[start..<end]).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
    }
    private func dump(_ name: String, _ text: String) { print("DUMP|\(name)|\(text.prefix(2400))") }
    private func links(_ html: String, _ pattern: String, limit: Int = 25) -> String {
        var seen = Set<String>()
        var out: [String] = []
        for m in LinkedSource.matches(#"href=["']([^"'#]+)["']"#, html) where m[0].range(of: pattern, options: .regularExpression) != nil {
            if seen.insert(m[0]).inserted { out.append(m[0]) }
            if out.count >= limit { break }
        }
        return out.joined(separator: " ")
    }

    func testDiagnostics() async {
        for (label, ua) in [("iphone", "iphone"), ("app", "EclipseReader/1.0 (iOS; +https://github.com/niichie/eclipsereader-0.1)"), ("none", nil)] as [(String, String?)] {
            let (status, type, text) = await body("https://api.mangadex.org/manga?limit=1&title=chainsaw", ua: ua, accept: "application/json")
            dump("mangadex ua=\(label)", "\(status) \(type) :: \(text.prefix(500))")
        }
        let wc = "https://weebcentral.com/series/01J76XYCERXE60T7FKXVCCAQ0H"
        let (s1, t1, list) = await body(wc + "/full-chapter-list", headers: ["Referer": wc + "/Jujutsu-Kaisen"])
        dump("weebcentral list", "\(s1) \(t1) \(list.count)B links: \(links(list, "chapters/", limit: 5)) :: \(around(list, "chapter", before: 300, after: 1500))")
        let (s1b, _, listHX) = await body(wc + "/full-chapter-list", headers: ["Referer": wc + "/Jujutsu-Kaisen", "HX-Request": "true", "HX-Current-URL": wc + "/Jujutsu-Kaisen", "HX-Target": "chapter-list"])
        dump("weebcentral list hx", "\(s1b) \(listHX.count)B links: \(links(listHX, "chapters/", limit: 5)) :: \(listHX.prefix(800))")
        let (s2, _, page) = await body(wc + "/Jujutsu-Kaisen")
        dump("weebcentral series", "\(s2) \(page.count)B chapterlinks: \(links(page, "chapters/", limit: 5)) hx: \(around(page, "full-chapter-list", before: 600, after: 600))")

        let (s3, _, chapter) = await body("https://mangadot.net/chapter/32749?source=user")
        dump("mangadot chapter", "\(s3) \(chapter.count)B img: \(around(chapter, #"\.(webp|jpg|jpeg|png)"#, before: 600, after: 600)) || api: \(around(chapter, "/api/", before: 200, after: 400))")
        let (_, _, dotSeries) = await body("https://mangadot.net/manga/118")
        dump("mangadot series", "\(dotSeries.count)B chapterlinks=\(LinkedSource.matches(#"/chapter/\d+"#, dotSeries).count) api: \(around(dotSeries, "/api/", before: 200, after: 400)) || more: \(around(dotSeries, #"(?i)load more|show all|page=2"#, before: 300, after: 300))")

        let (_, _, asura) = await body("https://asurascans.com/comics")
        dump("asura links", links(asura, "asurascans\\.com/|^/", limit: 40))
        for q in ["https://asurascans.com/comics?name=solo", "https://asurascans.com/series?name=solo", "https://asurascans.com/comics?search=solo", "https://asurascans.com/search?q=solo"] {
            let (st, _, html) = await body(q)
            dump("asura search \(q)", "\(st) \(html.count)B solo-links: \(links(html, "(?i)solo", limit: 8))")
        }
        let (_, _, comix) = await body("https://comix.to/")
        dump("comix links", links(comix, "^/|comix\\.to/", limit: 40) + " || search: " + around(comix, #"(?i)search"#, before: 200, after: 500))
        for q in ["https://comix.to/browser?keyword=solo", "https://comix.to/search?keyword=solo", "https://comix.to/api/v2/manga?keyword=solo&limit=5"] {
            let (st, type, html) = await body(q)
            dump("comix search \(q)", "\(st) \(type) \(html.count)B solo-links: \(links(html, "(?i)solo", limit: 8)) :: \(html.prefix(300))")
        }

        let (_, _, se) = await body("https://standardebooks.org/ebooks?query=dracula")
        dump("standardebooks search", around(se, "schema:Book", before: 300, after: 2000))
        let (sp, _, popular) = await body("https://standardebooks.org/ebooks?sort=popularity&per-page=48")
        dump("standardebooks popular", "\(sp) books: \(links(popular, #"^/ebooks/[^/]+/[^/?]+$"#, limit: 12))")

        for mirror in ["https://gutenberg.pglaf.org/cache/epub/345/pg345-images-3.epub", "https://aleph.pglaf.org/cache/epub/345/pg345-images-3.epub",
                       "https://www.gutenberg.org/cache/epub/345/pg345-images-3.epub", "https://gutenberg.pglaf.org/3/4/345/"] {
            let (st, type, text) = await body(mirror)
            dump("gutenberg mirror \(mirror)", "\(st) \(type) \(text.count) :: \(text.prefix(200))")
        }
        let (gs, gt, opds) = await body("https://www.gutenberg.org/ebooks/search.opds/?query=dracula")
        dump("gutenberg opds", "\(gs) \(gt) :: \(around(opds, "<entry", before: 0, after: 1800))")

        let started = Date()
        let (js, _, jikan) = await body("https://api.jikan.moe/v4/top/manga?page=1", ua: nil, accept: "application/json")
        dump("jikan", "\(js) \(String(format: "%.1fs", Date().timeIntervalSince(started))) \(jikan.prefix(200))")

        for (name, home) in [("Tapas", "https://tapas.io/"), ("Tappytoon", "https://www.tappytoon.com/en"), ("Manta", "https://manta.net/en"),
                             ("GlobalComix", "https://globalcomix.com/"), ("Comikey", "https://comikey.com/")] {
            let (_, _, html) = await body(home)
            let first = GlobalSearch.results(in: html, base: URL(string: home)!).first
            dump("official \(name)", "first series: \(first?.url.absoluteString ?? "-") links: \(links(html, "(?i)series|comic|title|manga|episode", limit: 8))")
            if let url = first?.url { await chapters("official \(name)", url: url) }
        }
    }

    func testDiagnostics2() async {
        let (_, _, comics) = await body("https://asurascans.com/comics")
        let slugs = Set(LinkedSource.matches(#"href=["'](/comics/[a-z0-9-]+)["']"#, comics).map { $0[0] })
        dump("asura /comics", "\(comics.count)B \(slugs.count) series links; overgeared: \(around(comics, "(?i)overgeared", before: 400, after: 600))")
        let (_, _, browse) = await body("https://asurascans.com/browse")
        let browseSlugs = Set(LinkedSource.matches(#"href=["'](/comics/[a-z0-9-]+)["']"#, browse).map { $0[0] })
        dump("asura /browse", "\(browse.count)B \(browseSlugs.count) series links; api: \(around(browse, #"(?i)api[./]"#, before: 200, after: 500)) || search: \(around(browse, #"(?i)search"#, before: 300, after: 600))")
        for q in ["https://asurascans.com/browse?search=murim", "https://asurascans.com/browse?q=murim", "https://asurascans.com/browse/comics?search=murim", "https://asurascans.com/comics?page=2"] {
            let (st, _, html) = await body(q)
            let found = Set(LinkedSource.matches(#"href=["'](/comics/[a-z0-9-]+)["']"#, html).map { $0[0] })
            dump("asura try \(q)", "\(st) \(html.count)B \(found.count) links: \(found.filter { $0.contains("murim") }.joined(separator: " "))")
        }
        await chapters("Asura", url: URL(string: "https://asurascans.com/comics/overgeared-7de80a82")!)

        let (_, _, chapter) = await body("https://mangadot.net/chapter/32749?source=user")
        let webps = LinkedSource.matches(#"([A-Za-z0-9_/.-]*\d{3}\.webp)"#, chapter).map { $0[0] }
        dump("mangadot chapter", "\(webps.count) webp refs: \(Array(Set(webps)).sorted().prefix(6)) || 002: \(around(chapter, "002", before: 600, after: 600)) || pages: \(around(chapter, #"(?i)\"pages\"|pageCount|page_count|totalPages"#, before: 300, after: 600))")
        dump("mangadot chapter tail", String(chapter.suffix(2400)))
        let (_, _, series) = await body("https://mangadot.net/manga/118")
        let chapterLinks = LinkedSource.matches(#"/chapter/(\d+)"#, series).map { $0[0] }
        dump("mangadot series", "links \(chapterLinks.count) unique \(Set(chapterLinks).count) || chapters json: \(around(series, #"(?i)\"chapters\"|chapterCount|totalChapters"#, before: 200, after: 900))")

        let (_, _, comix) = await body("https://comix.to/")
        dump("comix structure", "data-page: \(around(comix, "data-page", before: 50, after: 400)) || slug: \(around(comix, #"\"slug\""#, before: 300, after: 300)) || title-path: \(around(comix, #"/title/"#, before: 300, after: 300)) || hash: \(around(comix, #"hash_id|hid"#, before: 200, after: 300))")
    }

    func testDiagnostics3() async {
        let (_, _, series) = await body("https://mangadot.net/manga/118")
        let plain = series.replacingOccurrences(of: "\\\"", with: "\"")
        let numbers = LinkedSource.matches(#""chapter_number",([\d.]+)"#, plain).map { $0[0] }
        dump("mangadot numbers", "\(numbers.count) chapter_number values, first: \(numbers.prefix(8)) last: \(numbers.suffix(5))")
        dump("mangadot chapter keys", around(plain, #""chapter_number""#, before: 900, after: 600))
        dump("mangadot totals", around(plain, #"(?i)"(total|count|chapter_count|chapters_count|total_chapters|hasMore|has_more|next_cursor|cursor)""#, before: 300, after: 400))
        let scripts = LinkedSource.matches(#"<script[^>]+src=["']([^"']+)["']"#, series).map { $0[0] }
        dump("mangadot scripts", scripts.joined(separator: " "))
        for guess in ["https://mangadot.net/api/manga/118/chapters", "https://mangadot.net/api/manga/118/chapters?page=2",
                      "https://mangadot.net/manga/118/chapters", "https://mangadot.net/manga/118?tab=chapters", "https://mangadot.net/manga/118?chapters=all"] {
            let (st, type, text) = await body(guess)
            let count = Set(LinkedSource.matches(#"/chapter/(\d+)"#, text).map { $0[0] }).count
            dump("mangadot try \(guess)", "\(st) \(type) \(text.count)B chapter links \(count) :: \(text.prefix(300))")
        }
    }

    func testDiagnostics4() async {
        let (_, _, series) = await body("https://mangadot.net/manga/118")
        // React Router streams its data as a JSON array inside enqueue("…") calls.
        let calls = LinkedSource.matches(#"(?s)\.enqueue\((".*?")\);"#, series).map { $0[0] }
        dump("mangadot stream", "\(calls.count) enqueue calls, sizes \(calls.map(\.count))")
        for call in calls {
            guard let decoded = try? JSONSerialization.jsonObject(with: Data(call.utf8), options: .fragmentsAllowed) as? String,
                  let array = try? JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [Any] else { dump("mangadot decode", "failed \(call.prefix(200))"); continue }
            let keyIndex = array.firstIndex { ($0 as? String) == "chapter_number" }
            let idIndex = array.firstIndex { ($0 as? String) == "id" }
            var objects = 0, numbers: [String] = []
            for case let object as [String: Any] in array {
                if let keyIndex, let ref = object["_\(keyIndex)"] as? Int {
                    objects += 1
                    if ref >= 0, ref < array.count { numbers.append("\(array[ref])") }
                }
            }
            dump("mangadot decoded", "array \(array.count) items; chapter_number key at \(keyIndex ?? -1), id key at \(idIndex ?? -1); objects using it: \(objects); numbers: \(numbers.prefix(6))…\(numbers.suffix(4))")
        }
    }

    // MARK: Pictures, fetched exactly the way the app does (ImagePipeline, same referer)

    private lazy var pipeline = ImagePipeline(cache: DiskImageCache(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("probe-\(UUID().uuidString)")), http: http)

    private func image(_ name: String, _ url: URL?, referer: URL? = nil) async {
        guard let url else { report("image " + name, false, "no address"); return }
        let chapter = Chapter(url: referer ?? url, title: "", number: "")
        let start = Date()
        do {
            let data = try await pipeline.data(for: MangaPage(url: url, label: "probe"), chapter: chapter)
            report("image " + name, ImageSniffer.isImage(data.prefix(12)), String(format: "%.1fs ", Date().timeIntervalSince(start)) + "\(data.count)B <\(url.absoluteString)>")
        } catch {
            report("image " + name, false, "\(error) <\(url.absoluteString)>")
            await raw("image \(name) as browser", url.absoluteString)
        }
    }

    func testImages() async {
        // Covers shown on the library home (Discover, Because you read) and in search.
        let popular = (try? await Discover.mangaDex(limit: 3, http: http)) ?? []
        for item in popular { await image("MangaDex discover cover \(item.title)", item.cover) }
        let similar = (try? await Discover.similar(to: "Vinland Saga", http: http)) ?? []
        for item in similar.prefix(2) { await image("MangaDex because cover \(item.title)", item.cover) }
        let sources: [(String, SearchSource, String)] = [
            ("MangaDex", SearchSource(name: "MangaDex", kind: .mangaDex), "Chainsaw Man"),
            ("WeebCentral", SearchSource(name: "WeebCentral", kind: .weebCentral), "Jujutsu Kaisen"),
            ("WEBTOON", SearchSource(name: "WEBTOON", kind: .webtoons), "Tower of God"),
            ("Asura", SearchSource(name: "Asura", kind: .site(URL(string: "https://asurascans.com/comics")!)), "murim login"),
            ("MangaDot", SearchSource(name: "MangaDot", kind: .site(URL(string: "https://mangadot.net/")!)), "Solo Leveling"),
        ]
        let linked = LinkedSource(http: http)
        for (name, source, query) in sources {
            guard let first = try? await GlobalSearch.search(source, query: query, http: http).first else {
                report("image \(name)", false, "search failed"); continue
            }
            await image("\(name) search cover", first.cover)
            guard let series = try? await linked.inspect(first.url) else { report("image \(name)", false, "inspect failed"); continue }
            await image("\(name) series cover", series.cover, referer: first.url)
            guard let chapter = series.chapters.first, let pages = try? await linked.pages(chapter.url) else { continue }
            for page in pages.prefix(2) { await image("\(name) page \(page.label)", page.url, referer: chapter.url) }
        }
        if let tapas = URL(string: "https://tapas.io/series/205543"), let series = try? await linked.inspect(tapas) {
            await image("Tapas cover", series.cover, referer: tapas)
            if let chapter = series.chapters.first, let pages = try? await linked.pages(chapter.url) {
                for page in pages.prefix(2) { await image("Tapas page \(page.label)", page.url, referer: chapter.url) }
            }
        }
        // Books and picks.
        for book in ((try? await FreeBooks.standardEbooks(http: http)) ?? []).prefix(2) { await image("Standard Ebooks cover \(book.title)", book.cover) }
        for pick in ((try? await Recommendations.topManga(http: http)) ?? []).prefix(2) { await image("pick cover \(pick.title)", pick.cover) }
        for cover in (await BookCovers.candidates(title: "Red Rising", author: "Pierce Brown", isbn: nil, http: http)).prefix(1) {
            await image("Open Library cover", cover)
        }
    }

    func testDiagnostics5() async {
        let (_, _, home) = await body("https://mangadot.net/")
        dump("mangadot home search", around(home, #"(?i)search"#, before: 300, after: 700))
        dump("mangadot home forms", LinkedSource.matches(#"(?is)<form\b[^>]*>"#, home).map { $0.joined() }.joined(separator: " ") + " || " + links(home, "(?i)search|browse|catalog|library|directory", limit: 20))
        for q in ["https://mangadot.net/search?q=solo%20leveling", "https://mangadot.net/search?query=solo%20leveling", "https://mangadot.net/browse?q=solo%20leveling",
                  "https://mangadot.net/browse?search=solo%20leveling", "https://mangadot.net/manga?q=solo%20leveling", "https://mangadot.net/search/solo%20leveling",
                  "https://mangadot.net/api/search?q=solo%20leveling", "https://mangadot.net/api/manga/search?q=solo%20leveling"] {
            let (st, type, html) = await body(q)
            let found = Set(LinkedSource.matches(#"/manga/(\d+)"#, html).map { $0[0] })
            dump("mangadot try \(q)", "\(st) \(type) \(html.count)B manga links \(found.count) solo? \(html.lowercased().contains("solo leveling")) :: \(html.prefix(160))")
        }
    }
}
