import Foundation

/// The ordinary-book registry drives both Browse and every book search.
public enum BookCatalog: String, CaseIterable, Sendable {
    case libgen = "Library Genesis", anna = "Anna’s Archive", standard = "Standard Ebooks"
    case gutenberg = "Project Gutenberg", wikisource = "Wikisource", zlibrary = "Z-Library"
    case mobilism = "Mobilism", unglue = "Unglue.it", wolne = "Wolne Lektury"

    public var home: URL {
        let address: String = switch self {
        case .libgen: "https://libgen.li/"
        case .anna: "https://annas-archive.gl/"
        case .standard: "https://standardebooks.org/ebooks"
        case .gutenberg: "https://www.gutenberg.org/"
        case .wikisource: "https://en.wikisource.org/"
        case .zlibrary: "https://z-library.gy/"
        case .mobilism: "https://forum.mobilism.org/viewforum.php?f=120"
        case .unglue: "https://unglue.it/"
        case .wolne: "https://wolnelektury.pl/"
        }
        return URL(string: address)!
    }

    public func searchURL(_ query: String) -> URL {
        guard !query.isEmpty else { return home }
        var parts = URLComponents(url: home, resolvingAgainstBaseURL: false)!
        let endpoint: (String, String) = switch self {
        case .libgen: ("/index.php", "req")
        case .anna: ("/search", "q")
        case .standard: ("/ebooks", "query")
        case .gutenberg: ("/ebooks/search/", "query")
        case .wikisource: ("/w/index.php", "search")
        case .mobilism: ("/search.php", "keywords")
        case .unglue: ("/search/", "q")
        case .wolne: ("/szukaj/", "q")
        case .zlibrary: ("/s/", "")
        }
        if self == .zlibrary {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            parts.percentEncodedPath = "/s/" + (query.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        } else {
            parts.path = endpoint.0
            parts.queryItems = [URLQueryItem(name: endpoint.1, value: query)]
            if self == .libgen { parts.queryItems?.append(URLQueryItem(name: "filesuns", value: "epub")) }
        }
        return parts.url ?? home
    }

    public func search(_ query: String, http: any HTTPTransport = WebsiteHTTPClient()) async throws -> [FreeBook] {
        switch self {
        case .standard: return try await FreeBooks.standardEbooks(query: query, http: http).filter { matches(query, $0.title, $0.author) }
        case .gutenberg: return try await FreeBooks.gutenberg(query: query, http: http)
        case .wolne:
            let data = try await http.fetch(URL(string: "https://wolnelektury.pl/api/books/?format=json")!, referer: nil, image: false)
            struct Entry: Decodable { let title, author, slug: String; let url: URL; let simple_thumb: URL? }
            return try JSONDecoder().decode([Entry].self, from: data).lazy.filter { matches(query, $0.title, $0.author) }.prefix(24).map {
                FreeBook(id: $0.url.absoluteString, title: $0.title, author: $0.author, cover: $0.simple_thumb,
                         download: home.appendingPathComponent("media/book/epub").appendingPathComponent($0.slug + ".epub"),
                         page: $0.url, detail: "EPUB", source: rawValue)
            }
        default:
            let page = searchURL(query)
            let data = try await http.fetch(page, referer: home, image: false)
            return try results(String(decoding: data, as: UTF8.self), page: page, query: query)
        }
    }

    private func matches(_ query: String, _ title: String, _ author: String?) -> Bool {
        let text = title + " " + (author ?? "")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedCaseInsensitiveContains(String($0)) }
    }

    func results(_ html: String, page: URL, query: String) throws -> [FreeBook] {
        let pattern: String
        switch self {
        case .libgen: pattern = #"(?is)href=["'](edition\.php\?id=\d+)["'][^>]*>(.*?)</a>"#
        case .anna: pattern = #"(?is)<a\b[^>]*href=["'](/md5/[a-f0-9]{32})["'][^>]*>(.*?)</a>"#
        case .unglue: pattern = #"(?is)<a\b[^>]*href=["'](/work/\d+/)["'][^>]*>(.*?)</a>"#
        case .zlibrary: pattern = #"(?is)<a\b[^>]*href=["'](/book/[^"']+)["'][^>]*>(.*?)</a>"#
        case .mobilism: pattern = #"(?is)<a\b[^>]*href=["']([^"']*viewtopic\.php\?[^"']+)["'][^>]*>(.*?)</a>"#
        case .wikisource: pattern = #"(?is)<div class="mw-search-result-heading">\s*<a href="([^"]+)"[^>]*>(.*?)</a>"#
        default: return []
        }
        var seen = Set<URL>()
        var books = [FreeBook]()
        let blocks = self == .libgen ? LinkedSource.matches(#"(?is)<tr\b[^>]*>(.*?)</tr>"#, html).map { $0[0] } : [html]
        for block in blocks {
            let cols = self == .libgen ? LinkedSource.matches(#"(?is)<td\b[^>]*>(.*?)</td>"#, block) : []
            let author = cols.count > 1 ? LinkedSource.plain(cols[1][0]) : nil
            let links = LinkedSource.matches(pattern, cols.first?.first ?? block)
            for link in self == .libgen ? Array(links.suffix(1)) : links {
                let title = LinkedSource.plain(link[1])
                guard !title.isEmpty, title != "More Info", title != "Read it Now",
                      let url = LinkedSource.resolve(link[0], base: page), url.host == page.host,
                      seen.insert(url).inserted else { continue }
                books.append(FreeBook(id: url.absoluteString, title: title, author: author, cover: nil,
                                      download: nil, page: url, detail: nil, source: rawValue))
                if books.count == 24 { return books }
            }
        }
        if books.isEmpty && !["no results", "no matches", "nothing found", "no books found", "did not match", "no pages matching"].contains(where: { html.localizedCaseInsensitiveContains($0) }) {
            throw SourceError.unsupportedStructure
        }
        return books
    }
}
