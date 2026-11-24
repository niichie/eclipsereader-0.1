import XCTest
@testable import ReaderCore

final class RecommendationTests: XCTestCase {
    func testJikanTopManga() throws {
        let json = #"{"data":[{"mal_id":2,"url":"https://myanimelist.net/manga/2/Berserk","images":{"jpg":{"image_url":"https://cdn.myanimelist.net/images/manga/1/157897.jpg","large_image_url":"https://cdn.myanimelist.net/images/manga/1/157897l.jpg"}},"title":"Berserk","title_english":"Berserk","type":"Manga","score":9.47,"synopsis":"Guts, a former mercenary... [Written by MAL Rewrite]","published":{"prop":{"from":{"year":1989}}}},{"mal_id":9,"title":"Low","score":7.1}]}"#
        let items = try Recommendations.parseJikan(Data(json.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.score, "MAL 9.47")
        XCTAssertEqual(items.first?.detail, "Manga · 1989")
        XCTAssertEqual(items.first?.synopsis, "Guts, a former mercenary...")
        XCTAssertEqual(items.first?.cover?.lastPathComponent, "157897l.jpg")
    }

    func testOpenLibraryBestRated() throws {
        let json = #"{"docs":[{"key":"/works/OL17075811W","title":"Red Rising","author_name":["Pierce Brown"],"cover_i":7362153,"ratings_average":4.3,"ratings_count":120,"first_publish_year":2014},{"key":"/works/OL1W","title":"Meh","cover_i":1,"ratings_average":3.2,"ratings_count":500}]}"#
        let items = try Recommendations.parseOpenLibrary(Data(json.utf8))
        XCTAssertEqual(items.map(\.title), ["Red Rising"])
        XCTAssertEqual(items.first?.score, "★ 4.3")
        XCTAssertEqual(items.first?.cover?.absoluteString, "https://covers.openlibrary.org/b/id/7362153-L.jpg")
    }
}

final class FreeBooksTests: XCTestCase {
    func testGutendexResults() throws {
        let json = #"{"results":[{"id":1342,"title":"Pride and Prejudice","authors":[{"name":"Austen, Jane"}],"formats":{"application/epub+zip":"https://www.gutenberg.org/ebooks/1342.epub3.images","image/jpeg":"https://www.gutenberg.org/cache/epub/1342/pg1342.cover.medium.jpg"},"download_count":51234}]}"#
        let books = try FreeBooks.parseGutendex(Data(json.utf8))
        XCTAssertEqual(books.first?.author, "Jane Austen")
        XCTAssertEqual(books.first?.download?.absoluteString, "https://www.gutenberg.org/ebooks/1342.epub3.images")
        XCTAssertEqual(books.first?.cover?.lastPathComponent, "pg1342.cover.medium.jpg")
    }
}

private actor RoutedTransport: HTTPTransport {
    let routes: [(String, Data)]
    private(set) var asked: [URL] = []
    init(_ routes: [(String, String)]) { self.routes = routes.map { ($0.0, Data($0.1.utf8)) } }
    func fetch(_ url: URL, referer: URL?, image: Bool) async throws -> Data {
        asked.append(url)
        let text = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        guard let hit = routes.first(where: { text.contains($0.0) }) else { throw SourceError.unsupportedStructure }
        return hit.1
    }
}

final class BecauseYouReadTests: XCTestCase {
    private func manga(_ id: String, _ title: String, tags: String = "[]") -> String {
        #"{"id":"\#(id)","attributes":{"title":{"en":"\#(title)"},"originalLanguage":"ja","year":1989,"tags":\#(tags)},"relationships":[]}"#
    }
    func testNovelSeedSelectsNovelsAndKeepsNativeSearchTitle() throws {
        let data = Data(#"{"data":{"Media":{"title":{"english":"Story","native":"物語"},"recommendations":{"nodes":[{"rating":3,"mediaRecommendation":{"id":2,"title":{"english":"Another story","native":"別の物語"},"format":"NOVEL"}},{"rating":4,"mediaRecommendation":{"id":3,"title":{"english":"Comic adaptation"},"format":"MANGA"}}]}}}}"#.utf8)
        let hits = try AniListAPI.novelRecommendations(data, for: "物語")
        XCTAssertEqual(hits.map(\.id), [2])
        XCTAssertEqual(hits.first?.nativeTitle, "別の物語")
        XCTAssertTrue(try AniListAPI.novelRecommendations(data, for: "Unrelated").isEmpty)
    }

    func testPicksDistinctiveGenresAndSkipsTheLibrary() async throws {
        let tags = #"[{"id":"g-action","attributes":{"group":"genre","name":{"en":"Action"}}},{"id":"g-dark","attributes":{"group":"genre","name":{"en":"Tragedy"}}},{"id":"g-fantasy","attributes":{"group":"genre","name":{"en":"Fantasy"}}},{"id":"t-demons","attributes":{"group":"theme","name":{"en":"Demons"}}}]"#
        XCTAssertEqual(Discover.pickTags(try JSONSerialization.jsonObject(with: Data(tags.utf8))), ["g-dark", "g-fantasy"])
        let transport = RoutedTransport([
            ("title=Berserk", #"{"data":[\#(manga("b1", "Berserk", tags: tags))]}"#),
            ("includedTags", #"{"data":[\#(manga("b1", "Berserk")),\#(manga("v1", "Vinland Saga")),\#(manga("c1", "Claymore"))]}"#),
        ])
        let items = try await Discover.similar(to: "Berserk", excluding: ["claymore"], http: transport)
        XCTAssertEqual(items.map(\.title), ["Vinland Saga"])
        let asked = await transport.asked
        // The genre search, then one readability check per result.
        let search = asked.map { $0.absoluteString.removingPercentEncoding ?? $0.absoluteString }.first { $0.contains("includedTags") } ?? ""
        XCTAssertTrue(search.contains("includedTags[]=g-dark"), search)
        XCTAssertTrue(search.contains("originalLanguage[]=ja"), search)
        XCTAssertTrue(asked.contains { $0.path.hasSuffix("/feed") }, "results weren't checked for readable chapters")
    }

    private func series(_ id: String, _ title: String, language: String, tags: String = "[]") -> String {
        #"{"id":"\#(id)","attributes":{"title":{"en":"\#(title)"},"originalLanguage":"\#(language)","year":2018,"tags":\#(tags)},"relationships":[]}"#
    }

    func testManhwaSeedFoundUnderAnotherSpellingGetsManhwaOnly() async throws {
        let tags = #"[{"id":"g-fantasy","attributes":{"group":"genre","name":{"en":"Fantasy"}}}]"#
        let transport = RoutedTransport([
            ("title=Solo Leveling", #"{"data":[\#(series("s1", "Solo Leveling (Official)", language: "ko", tags: tags))]}"#),
            ("includedTags", #"{"data":[\#(series("k1", "Omniscient Reader", language: "ko")),\#(series("j1", "A Manga", language: "ja")),\#(series("c1", "A Manhua", language: "zh"))]}"#),
        ])
        let items = try await Discover.similar(to: "Solo Leveling", style: .manhwa, http: transport)
        XCTAssertEqual(items.map(\.title), ["Omniscient Reader"])
        let asked = await transport.asked.map { $0.absoluteString.removingPercentEncoding ?? $0.absoluteString }
        XCTAssertTrue(asked.contains { $0.contains("includedTags") && $0.contains("originalLanguage[]=ko") }, "\(asked)")
    }

    func testMediumFamiliesAndLooseTitles() {
        XCTAssertTrue(Discover.mediumMatches(.webtoon, .manhwa))
        XCTAssertFalse(Discover.mediumMatches(.manga, .manhwa))
        XCTAssertFalse(Discover.mediumMatches(.comic, .manga))
        XCTAssertTrue(Discover.looselySameTitle("The Beginning After the End", "Beginning After The End"))
        XCTAssertTrue(Discover.looselySameTitle("Solo Leveling (Official)", "Solo Leveling"))
        XCTAssertFalse(Discover.looselySameTitle("Bleach", "Bleach Fan Colored Edition Extra"))
    }
}
