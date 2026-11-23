import Foundation

/// A book from a free library: Project Gutenberg (through Gutendex) or Open Library.
public struct FreeBook: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let author: String?
    public let cover: URL?
    /// Direct EPUB download, when the book is free to keep.
    public let download: URL?
    /// The book's own page (to borrow or read online).
    public let page: URL?
    public let detail: String?
    public let source: String
}

public enum FreeBooks {
    /// Project Gutenberg's 70,000+ public-domain books. No query: the most downloaded right now.
    public static func gutenberg(query: String? = nil, http: any HTTPTransport = WebsiteHTTPClient()) async throws -> [FreeBook] {
        var parts = URLComponents(string: "https://gutendex.com/books/")!
        var items = [URLQueryItem(name: "mime_type", value: "application/epub+zip")]
        if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty { items.append(URLQueryItem(name: "search", value: query)) }
        parts.queryItems = items
        guard let url = parts.url else { return [] }
        return try parseGutendex(try await http.fetch(url, referer: nil, image: false))
    }
    static func parseGutendex(_ data: Data) throws -> [FreeBook] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { throw SourceError.unsupportedStructure }
        return results.compactMap { entry in
            guard let id = entry["id"] as? Int, let title = entry["title"] as? String else { return nil }
            let formats = entry["formats"] as? [String: String] ?? [:]
            let epub = formats.first { $0.key.hasPrefix("application/epub+zip") }?.value.flatMap(URL.init(string:))
            let cover = formats["image/jpeg"].flatMap(URL.init(string:))
            let author = ((entry["authors"] as? [[String: Any]])?.first?["name"] as? String).map(flipName)
            let downloads = entry["download_count"] as? Int
            return FreeBook(id: "pg-\(id)", title: title, author: author, cover: cover, download: epub,
                            page: URL(string: "https://www.gutenberg.org/ebooks/\(id)"),
                            detail: downloads.map { "\($0.formatted()) downloads" }, source: "Project Gutenberg")
        }
    }
    /// "Austen, Jane" → "Jane Austen".
    static func flipName(_ name: String) -> String {
        let parts = name.components(separatedBy: ", ")
        guard parts.count == 2 else { return name }
        return parts[1] + " " + parts[0]
    }

    /// Open Library: every edition it knows, free to borrow or read when available.
    public static func openLibrary(query: String, http: any HTTPTransport = WebsiteHTTPClient()) async throws -> [FreeBook] {
        var parts = URLComponents(string: "https://openlibrary.org/search.json")!
        parts.queryItems = [URLQueryItem(name: "q", value: query),
                            URLQueryItem(name: "fields", value: "key,title,author_name,cover_i,ebook_access,first_publish_year,ratings_average"),
                            URLQueryItem(name: "limit", value: "20")]
        guard let url = parts.url else { return [] }
        let data = try await http.fetch(url, referer: nil, image: false)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let docs = object["docs"] as? [[String: Any]] else { throw SourceError.unsupportedStructure }
        return docs.compactMap { doc in
            guard let key = doc["key"] as? String, let title = doc["title"] as? String else { return nil }
            let access = doc["ebook_access"] as? String ?? "no_ebook"
            let rating = (doc["ratings_average"] as? Double).map { String(format: "★ %.1f", $0) }
            let availability = access == "public" ? "Free to read" : access == "borrowable" ? "Borrow free" : nil
            return FreeBook(id: "ol-\(key)", title: title, author: (doc["author_name"] as? [String])?.first,
                            cover: (doc["cover_i"] as? Int).flatMap { URL(string: "https://covers.openlibrary.org/b/id/\($0)-L.jpg") },
                            download: nil, page: URL(string: "https://openlibrary.org\(key)"),
                            detail: [availability, rating, (doc["first_publish_year"] as? Int).map(String.init)].compactMap { $0 }.joined(separator: " · "),
                            source: "Open Library")
        }
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
