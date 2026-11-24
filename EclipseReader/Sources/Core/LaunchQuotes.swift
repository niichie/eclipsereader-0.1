import Foundation

/// A line someone said, and the series (or book) it's from.
public struct LaunchQuote: Hashable, Sendable, Codable {
    public let text: String
    public let who: String
    public let work: String
    public init(text: String, who: String, work: String) { self.text = text; self.who = who; self.work = work }
}

/// The series behind a quote, checked on AniList: cover, score and what it is.
public struct SpotlightMedia: Hashable, Sendable {
    public let id: Int
    public let title: String
    public let cover: URL?
    public let score: Int?
    public let detail: String
    public init(id: Int, title: String, cover: URL?, score: Int?, detail: String) {
        self.id = id; self.title = title; self.cover = cover; self.score = score; self.detail = detail
    }
}

/// The launch card: a quote, and (when it could be checked) the top-rated series it comes from.
public struct Spotlight: Hashable, Sendable, Identifiable {
    public let quote: LaunchQuote
    public let media: SpotlightMedia?
    /// A book's free download (Standard Ebooks), when there is one.
    public let download: URL?
    public var id: String { quote.text + "|" + quote.work }
    /// The name to search and show: AniList's English title when it has one.
    public var work: String { media?.title ?? quote.work }
    public init(quote: LaunchQuote, media: SpotlightMedia?, download: URL? = nil) {
        self.quote = quote; self.media = media; self.download = download
    }
}

/// Live quotes from two anime-quote databases, each checked against AniList so the card only
/// recommends series that exist as manga and that readers rate highly.
///
/// - Yurippe (yurippe.vercel.app): a random batch in one request, no key, no tight limit.
/// - AnimeChan (api.animechan.io): 10,000+ quotes, but 5 requests an hour without a key, so the app
///   asks it at most once a launch and four times an hour.
public enum QuoteFeed {
    public static let minimumScore = 77

    // MARK: Sources

    public static func yurippe(count: Int = 25, http: any HTTPTransport = WebsiteHTTPClient()) async throws -> [LaunchQuote] {
        guard let url = URL(string: "https://yurippe.vercel.app/api/quotes?random=\(count)") else { return [] }
        return try parseYurippe(try await http.fetch(url, referer: nil, image: false))
    }
    static func parseYurippe(_ data: Data) throws -> [LaunchQuote] {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw SourceError.unsupportedStructure }
        return list.compactMap { entry -> LaunchQuote? in
            guard let text = entry["quote"] as? String, let show = entry["show"] as? String else { return nil }
            return LaunchQuote(text: tidy(text), who: (entry["character"] as? String).map(tidy) ?? "", work: tidy(show))
        }
    }

    public static func animeChan(http: any HTTPTransport = WebsiteHTTPClient()) async throws -> LaunchQuote {
        guard let url = URL(string: "https://api.animechan.io/v1/quotes/random") else { throw SourceError.unsupportedStructure }
        return try parseAnimeChan(try await http.fetch(url, referer: nil, image: false))
    }
    static func parseAnimeChan(_ data: Data) throws -> LaunchQuote {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["data"] as? [String: Any], let text = payload["content"] as? String,
              let anime = (payload["anime"] as? [String: Any])?["name"] as? String else { throw SourceError.unsupportedStructure }
        let who = (payload["character"] as? [String: Any])?["name"] as? String ?? ""
        return LaunchQuote(text: tidy(text), who: tidy(who), work: tidy(anime))
    }

    static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
    }

    /// A line worth putting on the home screen: a sentence or three, not a one-word gag or a speech.
    public static func usable(_ quote: LaunchQuote) -> Bool {
        let text = quote.text
        guard (18...170).contains(text.count), !quote.work.isEmpty, text.split(separator: " ").count >= 4 else { return false }
        let letters = text.filter(\.isLetter)
        // SHOUTED lines and lines in other scripts don't read well.
        guard !letters.isEmpty, letters.uppercased() != letters,
              Double(letters.unicodeScalars.filter { $0.isASCII }.count) / Double(letters.unicodeScalars.count) > 0.9 else { return false }
        return true
    }

    /// The series name without season and edition tags ("Shingeki no Kyojin Season 3" → "Shingeki no Kyojin").
    public static func cleanWork(_ name: String) -> String {
        var work = name.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        for pattern in [#"(?i)\s+(season|part|cour)\s*\d+.*$"#, #"(?i)\s+\d+(st|nd|rd|th)\s+season.*$"#,
                        #"(?i)\s*[:\-–]\s*(the movie|movie|ova|specials?)\b.*$"#, #"(?i)\s+(the movie|movie)\s*\d*$"#,
                        #"(?i)\s+(II|III|IV|2|3|4)$"#] {
            work = work.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return work.trimmingCharacters(in: .whitespaces)
    }

    /// How a series is recognised across sources ("Shingeki no Kyojin Season 3" and "shingeki no kyojin" match).
    public static func workKey(_ work: String) -> String { key(cleanWork(work)) }
    static func key(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "×", with: "x").filter { $0.isLetter || $0.isNumber }
    }

    /// One quote per series, in the order given, skipping series shown lately or already in the library.
    public static func candidates(_ quotes: [LaunchQuote], skipping: Set<String>, limit: Int) -> [LaunchQuote] {
        var seen = Set<String>()
        var out: [LaunchQuote] = []
        for quote in quotes where usable(quote) {
            let work = key(cleanWork(quote.work))
            guard !work.isEmpty, !skipping.contains(work), seen.insert(work).inserted else { continue }
            out.append(quote)
            if out.count == limit { break }
        }
        return out
    }

    // MARK: Rating check (AniList)

    static func batchQuery(_ count: Int) -> String {
        let variables = (0..<count).map { "$s\($0): String" }.joined(separator: ", ")
        let fields = (0..<count).map {
            "m\($0): Page(perPage: 3) { media(search: $s\($0), type: MANGA, sort: SEARCH_MATCH, isAdult: false) { ...f } }"
        }.joined(separator: "\n")
        return """
        query (\(variables)) {
        \(fields)
        }
        fragment f on Media { id title { english romaji } synonyms coverImage { extraLarge large } averageScore format countryOfOrigin startDate { year } }
        """
    }

    /// Looks up every quote's series in one request; keeps those that are manga scored `minimumScore`+ (in order).
    /// Curated lines are kept even when AniList can't be reached; live lines need the check.
    public static func rate(_ quotes: [LaunchQuote], curated: Set<LaunchQuote> = []) async -> [Spotlight] {
        guard !quotes.isEmpty else { return [] }
        let works = quotes.map { cleanWork($0.work) }
        var variables: [String: any Sendable] = [:]
        for (i, work) in works.enumerated() { variables["s\(i)"] = work }
        var request = URLRequest(url: AniListAPI.endpoint, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? AniListAPI.body(batchQuery(quotes.count), variables: variables)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return quotes.filter { curated.contains($0) }.map { Spotlight(quote: $0, media: nil) }
        }
        let hits = parseBatch(data, count: quotes.count)
        return quotes.indices.compactMap { i -> Spotlight? in
            if let media = best(hits[safe: i] ?? [], for: works[i]) {
                guard let score = media.score, score >= minimumScore else { return nil }
                return Spotlight(quote: quotes[i], media: media)
            }
            return curated.contains(quotes[i]) ? Spotlight(quote: quotes[i], media: nil) : nil
        }
    }

    struct Hit { let media: SpotlightMedia; let names: [String] }

    static func parseBatch(_ data: Data, count: Int) -> [[Hit]] {
        let payload = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"] as? [String: Any] ?? [:]
        return (0..<count).map { i in
            let list = (payload["m\(i)"] as? [String: Any])?["media"] as? [[String: Any]] ?? []
            return list.compactMap { entry -> Hit? in
                guard let id = entry["id"] as? Int else { return nil }
                let titles = entry["title"] as? [String: Any]
                let english = (titles?["english"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let romaji = titles?["romaji"] as? String
                let names = [english, romaji].compactMap { $0 } + (entry["synonyms"] as? [String] ?? [])
                let images = entry["coverImage"] as? [String: Any]
                let cover = ((images?["extraLarge"] ?? images?["large"]) as? String).flatMap(URL.init(string:))
                let kind: String = switch entry["countryOfOrigin"] as? String {
                case "KR": "Manhwa"
                case "CN", "TW": "Manhua"
                default: (entry["format"] as? String) == "NOVEL" ? "Light novel" : "Manga"
                }
                let year = ((entry["startDate"] as? [String: Any])?["year"] as? Int).map(String.init)
                let media = SpotlightMedia(id: id, title: english ?? romaji ?? "Untitled", cover: cover,
                                           score: entry["averageScore"] as? Int,
                                           detail: [kind, year].compactMap { $0 }.joined(separator: " · "))
                return Hit(media: media, names: names)
            }
        }
    }

    /// The search result that is really this series: a title that matches, or starts the same way.
    static func best(_ hits: [Hit], for work: String) -> SpotlightMedia? {
        let wanted = key(work)
        guard wanted.count >= 3 else { return nil }
        return hits.first { hit in
            hit.names.contains { name in
                let have = key(name)
                guard have.count >= 3 else { return false }
                return have == wanted || (wanted.count >= 5 && have.hasPrefix(wanted)) || (have.count >= 5 && wanted.hasPrefix(have))
            }
        }?.media
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
