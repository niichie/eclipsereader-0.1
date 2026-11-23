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
        let sites = [("Asura Scans", "https://asurascans.com/comics"), ("MangaDot", "https://mangadot.net/"),
                     ("MangaBall", "https://mangaball.com/"), ("Comix", "https://comix.to/")]
        for (name, address) in sites {
            await raw(name + " home", address)
            await series(name, source: SearchSource(name: name, kind: .site(URL(string: address)!)), query: "Solo Leveling")
        }
        let official = [("MANGA Plus", "https://mangaplus.shueisha.co.jp/updates"), ("Tapas", "https://tapas.io/"),
                        ("Tappytoon", "https://www.tappytoon.com/en"), ("Manta", "https://manta.net/en"),
                        ("GlobalComix", "https://globalcomix.com/"), ("Comikey", "https://comikey.com/"),
                        ("WEBTOON Canvas", "https://www.webtoons.com/en/canvas")]
        for (name, address) in official { await raw(name + " home", address) }
    }

    func testBooks() async {
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
        _ = await timed("Open Library search", { try await FreeBooks.openLibrary(query: "red rising", http: http) }) {
            ($0.count > 0, "\($0.count): " + $0.prefix(3).map { "\($0.title) [\($0.detail ?? "")]" }.joined(separator: " | "))
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
}
