import Foundation

/// Something worth reading, found live: AniList's top-rated manga (MyAnimeList through Jikan as a backup)
/// and Standard Ebooks' most-read classics, which download in one tap.
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
    /// The top-rated manga, manhwa and manhua: a random page of AniList's top 150 (scored 80%+ by its readers).
    /// MyAnimeList's top list is the backup when AniList doesn't answer.
    public static func topManga(http: any HTTPTransport = WebsiteHTTPClient()) async throws -> [Recommendation] {
        let page = Int.random(in: 1...3)
        do {
            let found = try await withDeadline(10) { try parseAniList(try await aniListTop(page: page)) }
            if !found.isEmpty { return found }
        } catch {}
        guard let url = URL(string: "https://api.jikan.moe/v4/top/manga?page=\(page)") else { return [] }
        return try await withDeadline(12) { try parseJikan(try await http.fetch(url, referer: nil, image: false)) }
    }
    static let aniListTopQuery = """
    query ($page: Int) { Page(page: $page, perPage: 50) { media(type: MANGA, sort: SCORE_DESC, isAdult: false) {
      id title { english romaji } coverImage { extraLarge large } averageScore format countryOfOrigin
      startDate { year } description(asHtml: false) siteUrl } } }
    """
    private static func aniListTop(page: Int) async throws -> Data {
        var request = URLRequest(url: AniListAPI.endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try AniListAPI.body(aniListTopQuery, variables: ["page": page])
        let (data, response) = try await URLSession.shared.data(for: request)
        try HTTPPolicy.validate(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        return data
    }
    static func parseAniList(_ data: Data, minimumScore: Int = 80) throws -> [Recommendation] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = ((object["data"] as? [String: Any])?["Page"] as? [String: Any])?["media"] as? [[String: Any]] else {
            throw SourceError.unsupportedStructure
        }
        return list.compactMap { entry -> Recommendation? in
            guard let id = entry["id"] as? Int, let score = entry["averageScore"] as? Int, score >= minimumScore else { return nil }
            let titles = entry["title"] as? [String: Any]
            let title = (titles?["english"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? titles?["romaji"] as? String ?? "Untitled"
            let images = entry["coverImage"] as? [String: Any]
            let cover = ((images?["extraLarge"] ?? images?["large"]) as? String).flatMap(URL.init(string:))
            let kind: String? = switch entry["countryOfOrigin"] as? String {
            case "KR": "Manhwa"
            case "CN", "TW": "Manhua"
            default: (entry["format"] as? String) == "ONE_SHOT" ? "One-shot" : "Manga"
            }
            let year = (entry["startDate"] as? [String: Any])?["year"] as? Int
            let synopsis = (entry["description"] as? String).map {
                LinkedSource.plain($0.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: " ", options: .regularExpression))
                    .replacingOccurrences(of: #"\s*\(Source:[^)]*\)\s*$"#, with: "", options: .regularExpression)
            }
            return Recommendation(id: "al-\(id)", title: title, cover: cover, score: "AniList \(score)%",
                                  detail: [kind, year.map(String.init)].compactMap { $0 }.joined(separator: " · "),
                                  synopsis: synopsis, link: (entry["siteUrl"] as? String).flatMap(URL.init(string:)), isBook: false)
        }
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

    /// One of Standard Ebooks' most-read classics: every one downloads in a tap.
    public static func topBooks(http: any HTTPTransport = WebsiteHTTPClient()) async throws -> [Recommendation] {
        try await FreeBooks.standardEbooks(http: http).map { book in
            Recommendation(id: book.id, title: book.title, cover: book.cover, score: "Most read",
                           detail: [book.author, "Standard Ebooks"].compactMap { $0 }.joined(separator: " · "),
                           synopsis: nil, link: book.download, isBook: true)
        }
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
