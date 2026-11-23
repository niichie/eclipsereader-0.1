import Foundation

/// Something worth reading, found live: top-ranked manga from MyAnimeList (through the Jikan API)
/// and the best-rated books on Open Library.
public struct Recommendation: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let cover: URL?
    /// "MAL 9.09" or "★ 4.3".
    public let score: String
    public let detail: String?
    public let synopsis: String?
    public let link: URL?
    public let isBook: Bool
}

public enum Recommendations {
    /// MyAnimeList's top manga (manga, manhwa and manhua), a random page of the top 100.
    public static func topManga(http: any HTTPTransport = WebsiteHTTPClient()) async throws -> [Recommendation] {
        let page = Int.random(in: 1...4)
        guard let url = URL(string: "https://api.jikan.moe/v4/top/manga?page=\(page)") else { return [] }
        return try parseJikan(try await http.fetch(url, referer: nil, image: false))
    }
    static func parseJikan(_ data: Data) throws -> [Recommendation] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { throw SourceError.unsupportedStructure }
        return list.compactMap { entry -> Recommendation? in
            guard let id = entry["mal_id"] as? Int, let score = entry["score"] as? Double, score >= 8.0 else { return nil }
            let title = (entry["title_english"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? entry["title"] as? String ?? "Untitled"
            let images = (entry["images"] as? [String: Any])?["jpg"] as? [String: Any]
            let cover = ((images?["large_image_url"] ?? images?["image_url"]) as? String).flatMap(URL.init(string:))
            let kind = entry["type"] as? String
            let year = ((entry["published"] as? [String: Any])?["prop"] as? [String: Any]).flatMap { ($0["from"] as? [String: Any])?["year"] as? Int }
            let synopsis = (entry["synopsis"] as? String)?
                .replacingOccurrences(of: #"\s*\[Written by MAL Rewrite\]\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Recommendation(id: "mal-\(id)", title: title, cover: cover, score: String(format: "MAL %.2f", score),
                                  detail: [kind, year.map(String.init)].compactMap { $0 }.joined(separator: " · "),
                                  synopsis: synopsis, link: (entry["url"] as? String).flatMap(URL.init(string:)), isBook: false)
        }
    }

    /// Highly rated books (4★ and up, with plenty of ratings) from a rotating genre on Open Library.
    public static func topBooks(http: any HTTPTransport = WebsiteHTTPClient()) async throws -> [Recommendation] {
        let subjects = ["fantasy", "science_fiction", "classics", "mystery", "thriller", "historical_fiction", "horror", "adventure"]
        var parts = URLComponents(string: "https://openlibrary.org/search.json")!
        parts.queryItems = [URLQueryItem(name: "q", value: "subject:\(subjects.randomElement() ?? "fantasy")"),
                            URLQueryItem(name: "sort", value: "rating"),
                            URLQueryItem(name: "fields", value: "key,title,author_name,cover_i,ratings_average,ratings_count,first_publish_year"),
                            URLQueryItem(name: "limit", value: "80")]
        guard let url = parts.url else { return [] }
        return try parseOpenLibrary(try await http.fetch(url, referer: nil, image: false))
    }
    static func parseOpenLibrary(_ data: Data, minimumRatings: Int = 40) throws -> [Recommendation] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let docs = object["docs"] as? [[String: Any]] else { throw SourceError.unsupportedStructure }
        return docs.compactMap { doc -> Recommendation? in
            guard let key = doc["key"] as? String, let title = doc["title"] as? String,
                  let rating = doc["ratings_average"] as? Double, rating >= 4.0,
                  (doc["ratings_count"] as? Int ?? 0) >= minimumRatings, let coverID = doc["cover_i"] as? Int else { return nil }
            let author = (doc["author_name"] as? [String])?.first
            let year = doc["first_publish_year"] as? Int
            return Recommendation(id: "ol-\(key)", title: title,
                                  cover: URL(string: "https://covers.openlibrary.org/b/id/\(coverID)-L.jpg"),
                                  score: String(format: "★ %.1f", rating),
                                  detail: [author, year.map(String.init)].compactMap { $0 }.joined(separator: " · "),
                                  synopsis: nil, link: URL(string: "https://openlibrary.org\(key)"), isBook: true)
        }
    }
}
