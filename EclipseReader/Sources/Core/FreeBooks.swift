import Foundation

/// A book from a free library you can download and keep: Standard Ebooks or Project Gutenberg.
public struct FreeBook: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let author: String?
    public let cover: URL?
    /// Direct EPUB download.
    public let download: URL?
    /// The book's own page.
    public let page: URL?
    public let detail: String?
    public let source: String
}

/// Runs work with a deadline (slow mirrors and APIs shouldn't hold the screen hostage).
public func withDeadline<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw SourceError.timeout
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw SourceError.timeout }
        return first
    }
}

public enum FreeBooks {
    // MARK: Standard Ebooks

    /// Standard Ebooks: carefully typeset public-domain classics. No query: their most-read books.
    public static func standardEbooks(query: String? = nil, http: any HTTPTransport = WebsiteHTTPClient()) async throws -> [FreeBook] {
        var parts = URLComponents(string: "https://standardebooks.org/ebooks")!
        let q = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        parts.queryItems = q.isEmpty
            ? [URLQueryItem(name: "sort", value: "popularity"), URLQueryItem(name: "per-page", value: "48")]
            : [URLQueryItem(name: "query", value: q), URLQueryItem(name: "per-page", value: "48")]
        guard let url = parts.url else { return [] }
        let data = try await http.fetch(url, referer: nil, image: false)
        return parseStandardEbooks(String(decoding: data, as: UTF8.self))
    }

    static func parseStandardEbooks(_ html: String) -> [FreeBook] {
        let site = "https://standardebooks.org"
        return LinkedSource.matches(#"(?is)<li\b[^>]*typeof=["']schema:Book["'][^>]*about=["'](/ebooks/[^"']+)["'][^>]*>(.*?)</li>"#, html)
            .compactMap { m -> FreeBook? in
                let path = m[0], block = m[1]
                let names = LinkedSource.matches(#"(?is)<span\b[^>]*property=["']schema:name["'][^>]*>(.*?)</span>"#, block).map { LinkedSource.plain($0[0]) }
                guard let title = names.first, !title.isEmpty else { return nil }
                let cover = LinkedSource.firstMatch(#"<img\b[^>]*src=["']([^"']+)["']"#, block).flatMap { URL(string: $0.hasPrefix("/") ? site + $0 : $0) }
                // /ebooks/bram-stoker/dracula → …/downloads/bram-stoker_dracula.epub
                let file = path.dropFirst("/ebooks/".count).replacingOccurrences(of: "/", with: "_")
                return FreeBook(id: "se-\(path)", title: title, author: names.count > 1 ? names[1] : nil, cover: cover,
                                download: URL(string: "\(site)\(path)/downloads/\(file).epub?source=download"),
                                page: URL(string: site + path), detail: "Standard Ebooks", source: "Standard Ebooks")
            }
    }

    // MARK: Project Gutenberg

    /// Project Gutenberg's 70,000+ public-domain books, from its own search (Gutendex when that's down).
    /// No query: the most downloaded books.
    public static func gutenberg(query: String? = nil, http: any HTTPTransport = WebsiteHTTPClient()) async throws -> [FreeBook] {
        let q = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var parts = URLComponents(string: "https://www.gutenberg.org/ebooks/search/")!
        parts.queryItems = q.isEmpty ? [URLQueryItem(name: "sort_order", value: "downloads")] : [URLQueryItem(name: "query", value: q)]
        var siteError: Error?
        if let url = parts.url {
            do {
                let found = parseGutenbergSearch(String(decoding: try await http.fetch(url, referer: nil, image: false), as: UTF8.self))
                if !found.isEmpty || !q.isEmpty { return found }
            } catch { siteError = error }
        }
        do {
            return try await withDeadline(12) { try await gutendex(query: q.isEmpty ? nil : q, http: http) }
        } catch {
            throw siteError ?? error
        }
    }

    /// gutenberg.org's search results: <li class="booklink"> with title, author and downloads.
    static func parseGutenbergSearch(_ html: String) -> [FreeBook] {
        var seen = Set<Int>()
        return LinkedSource.matches(#"(?is)<li\b[^>]*class=["'][^"']*booklink[^"']*["'][^>]*>(.*?)</li>"#, html).compactMap { m -> FreeBook? in
            let block = m[0]
            guard let raw = LinkedSource.firstMatch(#"href=["']/ebooks/(\d+)["']"#, block), let id = Int(raw), seen.insert(id).inserted,
                  let title = LinkedSource.firstMatch(#"(?is)<span\b[^>]*class=["']title["'][^>]*>(.*?)</span>"#, block).map(LinkedSource.plain),
                  !title.isEmpty else { return nil }
            let author = LinkedSource.firstMatch(#"(?is)<span\b[^>]*class=["']subtitle["'][^>]*>(.*?)</span>"#, block).map(LinkedSource.plain)
            let extra = LinkedSource.firstMatch(#"(?is)<span\b[^>]*class=["']extra["'][^>]*>(.*?)</span>"#, block).map(LinkedSource.plain)
            return book(id: id, title: title, author: author, detail: extra)
        }
    }

    static func book(id: Int, title: String, author: String?, detail: String?) -> FreeBook {
        FreeBook(id: "pg-\(id)", title: title, author: author,
                 cover: URL(string: "https://www.gutenberg.org/cache/epub/\(id)/pg\(id).cover.medium.jpg"),
                 download: URL(string: "https://www.gutenberg.org/ebooks/\(id).epub3.images"),
                 page: URL(string: "https://www.gutenberg.org/ebooks/\(id)"), detail: detail, source: "Project Gutenberg")
    }

    /// Gutendex, a community index of Project Gutenberg.
    static func gutendex(query: String?, http: any HTTPTransport) async throws -> [FreeBook] {
        var parts = URLComponents(string: "https://gutendex.com/books/")!
        var items = [URLQueryItem(name: "mime_type", value: "application/epub+zip")]
        if let query { items.append(URLQueryItem(name: "search", value: query)) }
        parts.queryItems = items
        guard let url = parts.url else { return [] }
        return try parseGutendex(try await http.fetch(url, referer: nil, image: false))
    }
    static func parseGutendex(_ data: Data) throws -> [FreeBook] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { throw SourceError.unsupportedStructure }
        return results.compactMap { entry -> FreeBook? in
            guard let id = entry["id"] as? Int, let title = entry["title"] as? String else { return nil }
            let author = ((entry["authors"] as? [[String: Any]])?.first?["name"] as? String).map(flipName)
            let downloads = entry["download_count"] as? Int
            return book(id: id, title: title, author: author, detail: downloads.map { "\($0.formatted()) downloads" })
        }
    }
    /// "Austen, Jane" → "Jane Austen".
    static func flipName(_ name: String) -> String {
        let parts = name.components(separatedBy: ", ")
        guard parts.count == 2 else { return name }
        return parts[1] + " " + parts[0]
    }

    /// Other places the same file lives: Project Gutenberg's own mirror keeps serving when gutenberg.org is down.
    public static func mirrors(for url: URL) -> [URL] {
        let text = url.absoluteString
        guard url.host?.hasSuffix("gutenberg.org") == true,
              let raw = LinkedSource.firstMatch(#"/ebooks/(\d+)\.epub"#, text) ?? LinkedSource.firstMatch(#"/cache/epub/(\d+)/"#, text),
              let id = Int(raw) else { return [] }
        return ["https://gutenberg.pglaf.org/cache/epub/\(id)/pg\(id)-images-3.epub",
                "https://aleph.pglaf.org/cache/epub/\(id)/pg\(id)-images-3.epub"].compactMap(URL.init(string:))
    }
}

/// Finds cover art for a book: Open Library by ISBN, then by title and author, then Google Books.
public enum BookCovers {
    public static func candidates(title: String, author: String?, isbn: String?, http: any HTTPTransport = WebsiteHTTPClient()) async -> [URL] {
        var found: [URL] = []
        if let isbn, let url = URL(string: "https://covers.openlibrary.org/b/isbn/\(isbn)-L.jpg?default=false") { found.append(url) }
        var parts = URLComponents(string: "https://openlibrary.org/search.json")!
        var items = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "fields", value: "cover_i"), URLQueryItem(name: "limit", value: "5")]
        if let author, !author.isEmpty { items.append(URLQueryItem(name: "author", value: author)) }
        parts.queryItems = items
        if let url = parts.url, let data = try? await http.fetch(url, referer: nil, image: false),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let docs = object["docs"] as? [[String: Any]] {
            for id in docs.compactMap({ $0["cover_i"] as? Int }).prefix(2) {
                if let cover = URL(string: "https://covers.openlibrary.org/b/id/\(id)-L.jpg") { found.append(cover) }
            }
        }
        var google = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        google.queryItems = [URLQueryItem(name: "q", value: "intitle:\(title)" + (author.map { " inauthor:\($0)" } ?? "")),
                             URLQueryItem(name: "maxResults", value: "3")]
        if let url = google.url, let data = try? await http.fetch(url, referer: nil, image: false),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let items = object["items"] as? [[String: Any]] {
            for item in items {
                let links = (item["volumeInfo"] as? [String: Any])?["imageLinks"] as? [String: String]
                if var raw = links?["thumbnail"] ?? links?["smallThumbnail"] {
                    raw = raw.replacingOccurrences(of: "http://", with: "https://").replacingOccurrences(of: "&edge=curl", with: "")
                    if let url = URL(string: raw) { found.append(url) }
                }
            }
        }
        return found
    }
}

extension WebsiteHTTPClient {
    /// Downloads a file (a book) to a temporary location, keeping the server's file name.
    public func downloadFile(_ url: URL, maxBytes: Int = 300 * 1024 * 1024) async throws -> URL {
        guard WebLink.publicHTTPS(url) else { throw SourceError.insecureURL }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        let (file, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw SourceError.unavailable(0) }
        try HTTPPolicy.validate(status: http.statusCode)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= maxBytes else { throw BookReaderError.unreadable("That download was empty or too large.") }
        // A web page instead of the file (a "thank you" or bot-check page): not a book.
        if (http.mimeType ?? "").lowercased().hasPrefix("text/html"), !["html", "htm", "xhtml"].contains(url.pathExtension.lowercased()) {
            try? FileManager.default.removeItem(at: file)
            throw BookReaderError.unreadable("The site showed a web page instead of the book. Open it in the browser and download it there.")
        }
        var name = http.suggestedFilename ?? url.lastPathComponent
        if (name as NSString).pathExtension.isEmpty {
            let mime = http.mimeType ?? ""
            name += mime.contains("epub") ? ".epub" : mime.contains("pdf") ? ".pdf" : mime.contains("mobi") ? ".mobi" : ""
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("book-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }
}

/// A book file linked from the page that's open in the browser.
public struct BookDownloadLink: Equatable, Sendable {
    public let url: URL
    /// "EPUB", "AZW3", "MOBI" or "FB2".
    public let format: String
}

/// Finds the best download on a single book's page (Project Gutenberg, Standard Ebooks, Wikisource's
/// "Grab a download", or any page linking .epub/.mobi/.azw3/.fb2 files). Pages linking several
/// different books (search results, lists) return nil, so the browser asks you to open one.
public enum BookLinks {
    public static let libraryHosts = ["gutenberg.org", "standardebooks.org", "wikisource.org"]

    public static func best(in html: String, base: URL) -> BookDownloadLink? {
        var found: [(link: BookDownloadLink, book: String, score: Int)] = []
        for m in LinkedSource.matches(#"(?is)<a\b[^>]*href=["']([^"'#]+)["']"#, html) {
            let href = m[0].replacingOccurrences(of: "&amp;", with: "&")
            guard let url = LinkedSource.resolve(href, base: base), WebLink.publicHTTPS(url),
                  let match = kind(of: url) else { continue }
            found.append((BookDownloadLink(url: polished(url), format: match.0), bookKey(url), match.1))
        }
        guard !found.isEmpty, Set(found.map(\.book)).count == 1 else { return nil }
        return found.max { $0.score < $1.score }?.link
    }

    /// Format and preference (higher is better) for a download address, or nil when it isn't a book file.
    static func kind(of url: URL) -> (String, Int)? {
        let path = url.path.lowercased()
        let format = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "format" }?.value?.lowercased()
        if url.host?.lowercased().hasPrefix("ws-export.") == true {
            switch format { case "epub", "epub-3": return ("EPUB", 90); case "mobi": return ("MOBI", 50); default: return nil }
        }
        if path.hasSuffix(".kepub.epub") { return ("EPUB", 60) }
        if path.hasSuffix("_advanced.epub") { return ("EPUB", 70) }
        if path.hasSuffix(".epub3.images") { return ("EPUB", 95) }
        if path.hasSuffix(".epub.images") { return ("EPUB", 85) }
        if path.hasSuffix(".epub.noimages") { return ("EPUB", 75) }
        if path.hasSuffix(".epub") { return ("EPUB", 90) }
        if path.hasSuffix(".azw3") { return ("AZW3", 55) }
        if path.hasSuffix(".kf8.images") { return ("AZW3", 54) }
        if path.hasSuffix(".mobi") || path.hasSuffix(".kindle.images") { return ("MOBI", 50) }
        if path.hasSuffix(".fb2") || path.hasSuffix(".fb2.zip") { return ("FB2", 40) }
        return nil
    }

    /// Which book a download belongs to: its formats share one key.
    static func bookKey(_ url: URL) -> String {
        if let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value {
            return "page:" + page
        }
        if let id = LinkedSource.firstMatch(#"/ebooks/(\d+)\."#, url.path) { return "pg:" + id }
        if let range = url.path.range(of: "/downloads/") { return "folder:" + url.path[..<range.lowerBound] }
        var name = url.lastPathComponent.lowercased()
        for suffix in ["_advanced.epub", ".kepub.epub", ".epub", ".azw3", ".mobi", ".fb2.zip", ".fb2"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count)); break
        }
        return (url.host ?? "") + url.deletingLastPathComponent().path + "/" + name
    }

    /// Standard Ebooks shows a thank-you page unless the link says it's a download.
    static func polished(_ url: URL) -> URL {
        guard url.host?.lowercased().hasSuffix("standardebooks.org") == true, url.path.contains("/downloads/"),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        if parts.queryItems?.contains(where: { $0.name == "source" }) != true {
            parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "source", value: "download")]
        }
        return parts.url ?? url
    }
}
