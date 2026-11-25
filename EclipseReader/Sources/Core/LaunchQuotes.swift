import Foundation

/// A line someone said, and the series (or book) it's from.
public struct LaunchQuote: Hashable, Sendable, Codable {
    public let text: String
    public let who: String
    public let work: String
    public init(text: String, who: String, work: String) { self.text = text; self.who = who; self.work = work }
}

/// The series behind a quote, checked on AniList: cover, score and what it is.
public struct SpotlightMedia: Codable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let cover: URL?
    public let score: Int?
    public let detail: String
    /// Manga, manhwa, manhua or a light novel (from AniList's format and country of origin).
    public var category: SourceCategory
    /// AniList's country code ("JP", "KR", "CN", "TW").
    public var country: String?
    /// The title in its own language (what Japanese novel sites search by).
    public var native: String?
    public init(id: Int, title: String, cover: URL?, score: Int?, detail: String, category: SourceCategory = .manga, country: String? = nil) {
        self.id = id; self.title = title; self.cover = cover; self.score = score; self.detail = detail
        self.category = category; self.country = country
    }
}

/// What the launch card may suggest: the kinds and countries chosen in the setup.
public struct SpotlightPreference: Sendable, Equatable {
    public var categories: Set<SourceCategory>
    public var origins: Set<String>
    public init(categories: Set<SourceCategory>, origins: Set<String>) { self.categories = categories; self.origins = origins }
    public static let everything = SpotlightPreference(categories: Set(SourceCategory.allCases), origins: ["JP", "KR", "CN", "TW"])
    /// Where AniList's data puts a series.
    public static func category(format: String?, country: String?) -> SourceCategory {
        if format == "NOVEL" { return .novels }
        switch country {
        case "KR": return .manhwa
        case "CN", "TW": return .manhua
        default: return .manga
        }
    }
    /// Korean and Chinese series are mostly webtoons, so choosing webtoons lets those through too.
    public func allows(_ media: SpotlightMedia) -> Bool {
        let kind = categories.contains(media.category)
            || ((media.category == .manhwa || media.category == .manhua) && categories.contains(.webtoons))
        let origin = media.country.map { origins.isEmpty || origins.contains($0) } ?? true
        return kind && origin
    }
    /// Pictures before novels when both are allowed (eclipsereader is a comics reader first).
    func rank(_ media: SpotlightMedia) -> Int { media.category == .novels ? 1 : 0 }
}

/// The launch card: a quote, and (when it could be checked) the top-rated series it comes from.
public struct Spotlight: Codable, Hashable, Sendable, Identifiable {
    public let quote: LaunchQuote
    public let media: SpotlightMedia?
    /// A book's free download (Standard Ebooks), when there is one.
    public let download: URL?
    /// A top-rated pick (its line is from the synopsis), not a quote.
    public let pick: Bool
    public var id: String { quote.text + "|" + quote.work }
    /// The name to search and show: AniList's English title when it has one.
    public var work: String { media?.title ?? quote.work }
    public init(quote: LaunchQuote, media: SpotlightMedia?, download: URL? = nil, pick: Bool = false) {
        self.quote = quote; self.media = media; self.download = download; self.pick = pick
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
        fragment f on Media { id title { english romaji native } synonyms coverImage { extraLarge large } averageScore format countryOfOrigin startDate { year } }
        """
    }

    /// Looks up every quote's series in one request; keeps those scored `minimumScore`+ that are among the kinds you
    /// chose (in order). Curated lines (all manga) are kept when AniList can't be reached and manga is chosen.
    public static func rate(_ quotes: [LaunchQuote], curated: Set<LaunchQuote> = [], preference: SpotlightPreference = .everything) async -> [Spotlight] {
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
            guard preference.categories.contains(.manga) else { return [] }
            return quotes.filter { curated.contains($0) }.map { Spotlight(quote: $0, media: nil) }
        }
        let hits = parseBatch(data, count: quotes.count)
        return quotes.indices.compactMap { i -> Spotlight? in
            let found = matches(hits[safe: i] ?? [], for: works[i])
            if !found.isEmpty {
                // The series exists: it must be one of your kinds, and rated highly.
                guard let media = choose(found, preference, work: works[i]), let score = media.score, score >= minimumScore else { return nil }
                return Spotlight(quote: quotes[i], media: media)
            }
            return curated.contains(quotes[i]) && preference.categories.contains(.manga) ? Spotlight(quote: quotes[i], media: nil) : nil
        }
    }

    // MARK: Picks (when quotes for your kinds are thin)

    /// AniList's top-rated series of each kind you chose (one request), for the card to mix in.
    /// Orders the picks are drawn from, one chosen at random each time, so the card isn't always
    /// the same few all-time top-rated series.
    public static let pickOrders = ["SCORE_DESC", "POPULARITY_DESC", "TRENDING_DESC", "FAVOURITES_DESC"]
    static func picksQuery(_ preference: SpotlightPreference, page: Int, sort: String = "SCORE_DESC") -> String? {
        var parts: [String] = []
        let p = max(1, page)
        let order = pickOrders.contains(sort) ? sort : "SCORE_DESC"
        func add(_ alias: String, _ filter: String) {
            parts.append("\(alias): Page(page: \(p), perPage: 12) { media(type: MANGA, \(filter), sort: \(order), isAdult: false, averageScore_greater: \(minimumScore + 2)) { ...f } }")
        }
        let kinds = preference.categories
        let origins = preference.origins.isEmpty ? ["JP", "KR", "CN", "TW"] : preference.origins
        if kinds.contains(.manga) && origins.contains("JP") { add("manga", "format_in: [MANGA, ONE_SHOT], countryOfOrigin: \"JP\"") }
        if (kinds.contains(.manhwa) || kinds.contains(.webtoons)) && origins.contains("KR") { add("manhwa", "countryOfOrigin: \"KR\"") }
        if (kinds.contains(.manhua) || kinds.contains(.webtoons)) && origins.contains("CN") { add("manhua", "countryOfOrigin: \"CN\"") }
        if kinds.contains(.novels) { add("novels", "format_in: [NOVEL]") }
        guard !parts.isEmpty else { return nil }
        return "query {\n" + parts.joined(separator: "\n") + "\n}\nfragment f on Media { id title { english romaji native } synonyms coverImage { extraLarge large } averageScore format countryOfOrigin startDate { year } description(asHtml: false) }"
    }
    /// Picks from a random order and page; a page past the end of a short list falls back to the first.
    public static func varietyPicks(_ preference: SpotlightPreference) async -> [Spotlight] {
        let order = pickOrders.randomElement() ?? "SCORE_DESC"
        let found = await picks(preference, page: Int.random(in: 1...10), sort: order)
        return found.isEmpty ? await picks(preference, page: 1, sort: order) : found
    }
    /// "Picked for you": AniList readers' recommendations for a series in your library, in your kinds,
    /// each with its synopsis. Nil seed (an empty library) gives none.
    public static func personalPicks(seed: String?, preference: SpotlightPreference) async -> [Spotlight] {
        guard let seed else { return [] }
        let query = """
        query ($search: String) { Media(search: $search, type: MANGA, sort: SEARCH_MATCH) {
          recommendations(sort: RATING_DESC, perPage: 25) { nodes { mediaRecommendation { ...f isAdult } } } } }
        fragment f on Media { id title { english romaji native } synonyms coverImage { extraLarge large } averageScore format countryOfOrigin startDate { year } description(asHtml: false) }
        """
        var request = URLRequest(url: AniListAPI.endpoint, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? AniListAPI.body(query, variables: ["search": seed])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return parsePersonal(data, preference: preference)
    }
    static func parsePersonal(_ data: Data, preference: SpotlightPreference) -> [Spotlight] {
        let media = (((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"] as? [String: Any])?["Media"] as? [String: Any]
        let nodes = ((media?["recommendations"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        return nodes.compactMap { node in
            guard let entry = node["mediaRecommendation"] as? [String: Any], entry["isAdult"] as? Bool != true,
                  let hit = hit(entry), preference.allows(hit.media), let score = hit.media.score, score >= minimumScore,
                  let line = synopsisLine(entry["description"] as? String) else { return nil }
            return Spotlight(quote: LaunchQuote(text: line, who: "Picked for you", work: hit.media.title), media: hit.media, pick: true)
        }.shuffled()
    }
    public static func picks(_ preference: SpotlightPreference, page: Int, sort: String = "SCORE_DESC") async -> [Spotlight] {
        guard let query = picksQuery(preference, page: page, sort: sort) else { return [] }
        var request = URLRequest(url: AniListAPI.endpoint, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? AniListAPI.body(query)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return parsePicks(data, preference: preference)
    }
    static func parsePicks(_ data: Data, preference: SpotlightPreference) -> [Spotlight] {
        let payload = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"] as? [String: Any] ?? [:]
        var lists: [[Spotlight]] = []
        for alias in ["manga", "manhwa", "manhua", "novels"] {
            let entries = (payload[alias] as? [String: Any])?["media"] as? [[String: Any]] ?? []
            lists.append(entries.compactMap { entry in
                guard let hit = hit(entry), preference.allows(hit.media), let score = hit.media.score, score >= minimumScore,
                      let line = synopsisLine(entry["description"] as? String) else { return nil }
                let label = hit.media.category == .novels ? "Light novel pick" : "\(hit.media.category.title) pick"
                return Spotlight(quote: LaunchQuote(text: line, who: label, work: hit.media.title), media: hit.media, pick: true)
            }.shuffled())
        }
        // Alternate between kinds so one doesn't crowd out the rest.
        var mixed: [Spotlight] = []
        var i = 0
        while lists.contains(where: { i < $0.count }) {
            for list in lists where i < list.count { mixed.append(list[i]) }
            i += 1
        }
        return mixed
    }
    /// Longest synopsis line the launch card shows; it always fits the card without being cut off.
    public static let synopsisLimit = 140
    /// The opening of a synopsis: whole sentences only, up to `synopsisLimit` characters, without
    /// credits or markup. Nil when even the first sentence is longer, so that series is skipped
    /// rather than shown with its line cut off mid-sentence.
    static func synopsisLine(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = raw.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\((?:Source|Written by)[^)]*\)|\[(?:Written by|Source)[^\]]*\]"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard text.count >= 20 else { return nil }
        // Sentences end at . ! ? (or …) followed by a space; "Mr." style abbreviations are rare in synopses.
        var sentences: [String] = []
        var current = ""
        let characters = Array(text)
        for (i, c) in characters.enumerated() {
            current.append(c)
            let next = i + 1 < characters.count ? characters[i + 1] : " "
            if ".!?…".contains(c), next == " " || next == "\"" || next == "”" {
                sentences.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { sentences.append(current.trimmingCharacters(in: .whitespaces)) }
        var line = ""
        for sentence in sentences {
            let piece = line.isEmpty ? sentence : line + " " + sentence
            if piece.count > synopsisLimit { break }
            line = piece
            if line.count >= 60 { break }
        }
        guard line.count >= 20, let last = line.last, ".!?…\"”".contains(last) else { return nil }
        return line
    }
    /// Cards saved by an earlier version may hold a longer, cut-off synopsis.
    public static func fitsCard(_ spotlight: Spotlight) -> Bool {
        !spotlight.pick || spotlight.quote.text.count <= synopsisLimit
    }

    struct Hit { let media: SpotlightMedia; let names: [String] }

    static func parseBatch(_ data: Data, count: Int) -> [[Hit]] {
        let payload = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"] as? [String: Any] ?? [:]
        return (0..<count).map { i in
            let list = (payload["m\(i)"] as? [String: Any])?["media"] as? [[String: Any]] ?? []
            return list.compactMap(hit)
        }
    }
    static func hit(_ entry: [String: Any]) -> Hit? {
        guard let id = entry["id"] as? Int else { return nil }
        let titles = entry["title"] as? [String: Any]
        let english = (titles?["english"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let romaji = titles?["romaji"] as? String
        let names = [english, romaji].compactMap { $0 } + (entry["synonyms"] as? [String] ?? [])
        let images = entry["coverImage"] as? [String: Any]
        let cover = ((images?["extraLarge"] ?? images?["large"]) as? String).flatMap(URL.init(string:))
        let country = entry["countryOfOrigin"] as? String
        let category = SpotlightPreference.category(format: entry["format"] as? String, country: country)
        let kind = category == .novels ? "Light novel" : category.title
        let year = ((entry["startDate"] as? [String: Any])?["year"] as? Int).map(String.init)
        var media = SpotlightMedia(id: id, title: english ?? romaji ?? "Untitled", cover: cover,
                                   score: entry["averageScore"] as? Int,
                                   detail: [kind, year].compactMap { $0 }.joined(separator: " · "), category: category, country: country)
        media.native = titles?["native"] as? String
        return Hit(media: media, names: names)
    }

    /// The search results that are really this series: a title that matches, or starts the same way.
    static func matches(_ hits: [Hit], for work: String) -> [Hit] {
        let wanted = key(work)
        guard wanted.count >= 3 else { return [] }
        return hits.filter { hit in
            hit.names.contains { name in
                let have = key(name)
                guard have.count >= 3 else { return false }
                return have == wanted || (wanted.count >= 5 && have.hasPrefix(wanted)) || (have.count >= 5 && wanted.hasPrefix(have))
            }
        }
    }
    /// Of a series' entries (its manga, its light novel…), the one to suggest: among the kinds you chose, pictures first.
    /// A series whose own title is the quote's (not a spin-off that starts the same way) wins within its kind.
    static func choose(_ found: [Hit], _ preference: SpotlightPreference, work: String? = nil) -> SpotlightMedia? {
        let wanted = work.map(key)
        func exact(_ hit: Hit) -> Int { wanted.map { w in hit.names.contains { key($0) == w } ? 0 : 1 } ?? 0 }
        return found.enumerated().filter { preference.allows($0.element.media) }
            .min { (preference.rank($0.element.media), exact($0.element), $0.offset) < (preference.rank($1.element.media), exact($1.element), $1.offset) }?
            .element.media
    }
    static func best(_ hits: [Hit], for work: String) -> SpotlightMedia? { choose(matches(hits, for: work), .everything, work: work) }
    /// A native title cut to what a site search matches ("無職転生 ～異世界行ったら本気だす～" → "無職転生").
    public static func searchable(native: String) -> String {
        let cut = native.components(separatedBy: CharacterSet(charactersIn: "～〜~　 ([（【「『:：-―")).first ?? native
        return cut.count >= 2 ? cut : native
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
