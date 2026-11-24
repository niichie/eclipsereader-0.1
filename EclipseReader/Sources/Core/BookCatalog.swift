import Foundation

/// The ordinary-book registry drives both Browse and every book search.
public enum BookCatalog: String, CaseIterable, Sendable {
    case standard = "Standard Ebooks", gutenberg = "Project Gutenberg", wolne = "Wolne Lektury"

    public var home: URL {
        let address: String = switch self {
        case .standard: "https://standardebooks.org/ebooks"
        case .gutenberg: "https://www.gutenberg.org/"
        case .wolne: "https://wolnelektury.pl/"
        }
        return URL(string: address)!
    }

    public func searchURL(_ query: String) -> URL {
        guard !query.isEmpty else { return home }
        var parts = URLComponents(url: home, resolvingAgainstBaseURL: false)!
        let endpoint: (String, String) = switch self {
        case .standard: ("/ebooks", "query")
        case .gutenberg: ("/ebooks/search/", "query")
        case .wolne: ("/szukaj/", "q")
        }
        parts.path = endpoint.0
        parts.queryItems = [URLQueryItem(name: endpoint.1, value: query)]
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
        }
    }

    private func matches(_ query: String, _ title: String, _ author: String?) -> Bool {
        let text = title + " " + (author ?? "")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedCaseInsensitiveContains(String($0)) }
    }
}
