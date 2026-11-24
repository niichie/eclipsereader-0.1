import Foundation

/// A manga on AniList, for linking a library series to your AniList list.
public struct AniListMedia: Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let cover: URL?
    public let chapters: Int?
    public let format: String?
    public let year: Int?
    /// AniList readers' average score (0–100).
    public var score: Int? = nil
    /// Manga, Manhwa or Manhua.
    public var kind: String? = nil
    public init(id: Int, title: String, cover: URL?, chapters: Int?, format: String?, year: Int?, score: Int? = nil, kind: String? = nil) {
        self.id = id; self.title = title; self.cover = cover; self.chapters = chapters; self.format = format; self.year = year
        self.score = score; self.kind = kind
    }
}

/// Your list entry for one manga.
public struct AniListEntry: Equatable, Sendable {
    public let progress: Int
    public let status: String?
}

/// AniList's GraphQL API: requests and response parsing. The app sends them (with your sign-in).
public enum AniListAPI {
    public static let endpoint = URL(string: "https://graphql.anilist.co")!
    public static let callbackScheme = "eclipsereader"
    public static let redirect = "eclipsereader://anilist"

    /// Implicit-grant sign-in: AniList sends the token back in the redirect's fragment.
    public static func authorizeURL(clientID: String) -> URL? {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        var parts = URLComponents(string: "https://anilist.co/api/v2/oauth/authorize")!
        parts.queryItems = [URLQueryItem(name: "client_id", value: id), URLQueryItem(name: "response_type", value: "token")]
        return parts.url
    }

    /// eclipsereader://anilist#access_token=…&token_type=Bearer&expires_in=31536000
    public static func token(fromCallback url: URL) -> (token: String, expires: Date?)? {
        guard let fragment = url.fragment ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?.query else { return nil }
        var values: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { values[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
        }
        guard let token = values["access_token"], !token.isEmpty else { return nil }
        let expires = values["expires_in"].flatMap(Double.init).map { Date().addingTimeInterval($0) }
        return (token, expires)
    }

    public static let viewerQuery = "query { Viewer { id name } }"
    public static let searchQuery = """
    query ($search: String) { Page(perPage: 12) { media(search: $search, type: MANGA, sort: SEARCH_MATCH) {
      id title { english romaji } coverImage { medium } chapters format startDate { year } } } }
    """
    public static let entryQuery = "query ($id: Int) { Media(id: $id) { chapters mediaListEntry { progress status } } }"
    public static let saveMutation = """
    mutation ($id: Int, $progress: Int, $status: MediaListStatus) {
      SaveMediaListEntry(mediaId: $id, progress: $progress, status: $status) { id progress status } }
    """

    /// Readers' recommendations for a series ("if you liked this…"), best rated first.
    public static let similarQuery = """
    query ($search: String) { Media(search: $search, type: MANGA, sort: SEARCH_MATCH) { id title { english romaji }
      recommendations(sort: RATING_DESC, perPage: 18) { nodes { rating mediaRecommendation {
        id title { english romaji } coverImage { large } averageScore format countryOfOrigin isAdult startDate { year } } } } } }
    """
    /// The recommended series (adult titles left out), and the title AniList matched.
    public static func parseSimilar(_ data: Data) throws -> (matched: String?, items: [AniListMedia]) {
        let media = try dataObject(data)["Media"] as? [String: Any]
        let names = media?["title"] as? [String: Any]
        let matched = (names?["english"] as? String) ?? (names?["romaji"] as? String)
        let nodes = ((media?["recommendations"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        var seen = Set<Int>()
        let items = nodes.compactMap { node -> AniListMedia? in
            guard (node["rating"] as? Int ?? 0) > 0, let item = node["mediaRecommendation"] as? [String: Any],
                  let id = item["id"] as? Int, item["isAdult"] as? Bool != true, seen.insert(id).inserted else { return nil }
            let titles = item["title"] as? [String: Any]
            let title = (titles?["english"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (titles?["romaji"] as? String) ?? "Untitled"
            let cover = ((item["coverImage"] as? [String: Any])?["large"] as? String).flatMap(URL.init(string:))
            let kind: String = switch item["countryOfOrigin"] as? String {
            case "KR": "Manhwa"
            case "CN", "TW": "Manhua"
            default: "Manga"
            }
            return AniListMedia(id: id, title: title, cover: cover, chapters: nil, format: item["format"] as? String,
                                year: (item["startDate"] as? [String: Any])?["year"] as? Int, score: item["averageScore"] as? Int, kind: kind)
        }
        return (matched, items)
    }

    public static func body(_ query: String, variables: [String: any Sendable] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
    }

    /// AniList's error message, if the response carries one.
    public static func error(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = object["errors"] as? [[String: Any]], let first = errors.first else { return nil }
        return first["message"] as? String ?? "AniList refused the request."
    }

    private static func dataObject(_ data: Data) throws -> [String: Any] {
        if let message = error(in: data) { throw AniListError.service(message) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["data"] as? [String: Any] else { throw AniListError.unreadable }
        return payload
    }

    public static func parseViewer(_ data: Data) throws -> String {
        guard let viewer = try dataObject(data)["Viewer"] as? [String: Any], let name = viewer["name"] as? String else {
            throw AniListError.unreadable
        }
        return name
    }

    public static func parseSearch(_ data: Data) throws -> [AniListMedia] {
        let page = try dataObject(data)["Page"] as? [String: Any]
        let list = page?["media"] as? [[String: Any]] ?? []
        return list.compactMap { item -> AniListMedia? in
            guard let id = item["id"] as? Int else { return nil }
            let titles = item["title"] as? [String: Any]
            let title = (titles?["english"] as? String) ?? (titles?["romaji"] as? String) ?? "Untitled"
            let cover = ((item["coverImage"] as? [String: Any])?["medium"] as? String).flatMap(URL.init(string:))
            let year = (item["startDate"] as? [String: Any])?["year"] as? Int
            return AniListMedia(id: id, title: title, cover: cover, chapters: item["chapters"] as? Int,
                                format: item["format"] as? String, year: year)
        }
    }

    /// Your entry (nil if it isn't on your list yet) and the manga's chapter count.
    public static func parseEntry(_ data: Data) throws -> (entry: AniListEntry?, chapters: Int?) {
        let media = try dataObject(data)["Media"] as? [String: Any]
        let chapters = media?["chapters"] as? Int
        guard let entry = media?["mediaListEntry"] as? [String: Any] else { return (nil, chapters) }
        return (AniListEntry(progress: entry["progress"] as? Int ?? 0, status: entry["status"] as? String), chapters)
    }

    /// Whole chapters read: "Chapter 12.5" counts as 12.
    public static func progress(for number: String) -> Int? {
        guard let value = Double(number.trimmingCharacters(in: .whitespaces)), value >= 1 else { return nil }
        return Int(value.rounded(.down))
    }

    /// What to send after finishing a chapter, or nil when AniList already has as much (or more).
    public static func update(after progress: Int, current: AniListEntry?, total: Int?) -> (progress: Int, status: String)? {
        if let current, current.progress >= progress { return nil }
        if let total, total > 0, progress >= total { return (total, "COMPLETED") }
        // Re-reading keeps its status; everything else becomes "Reading".
        let status = current?.status == "REPEATING" ? "REPEATING" : "CURRENT"
        return (progress, status)
    }
}

public enum AniListError: LocalizedError, Equatable {
    case notSignedIn, unreadable, service(String)
    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to AniList in Settings › Tracking first."
        case .unreadable: "AniList sent a reply eclipsereader couldn't read."
        case .service(let message): message
        }
    }
}
