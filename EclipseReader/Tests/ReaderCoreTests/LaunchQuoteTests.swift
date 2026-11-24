import XCTest
@testable import ReaderCore

final class LaunchQuoteTests: XCTestCase {
    func testParsesBothQuoteDatabases() throws {
        let yurippe = #"[{"character":"Levi Ackerman","show":"Shingeki no Kyojin","quote":"Give up on your dreams and die."},{"character":"Patricia","show":"Soul Eater","quote":"Giraffe!"}]"#
        let quotes = try QuoteFeed.parseYurippe(Data(yurippe.utf8))
        XCTAssertEqual(quotes.count, 2)
        XCTAssertEqual(quotes[0].work, "Shingeki no Kyojin")
        let chan = #"{"status":"success","data":{"content":"If you’re serious, you can accomplish anything.","anime":{"id":995,"name":"Dr. Stone","altName":"Dr. Stone"},"character":{"id":2574,"name":"Byakuya Ishigami"}}}"#
        let one = try QuoteFeed.parseAnimeChan(Data(chan.utf8))
        XCTAssertEqual(one.work, "Dr. Stone")
        XCTAssertEqual(one.who, "Byakuya Ishigami")
    }

    func testOnlyGoodLinesOnePerSeries() {
        let list = [
            LaunchQuote(text: "Giraffe! Giraffe!", who: "Patty", work: "Soul Eater"),
            LaunchQuote(text: "I WILL DESTROY EVERY LAST ONE OF THEM", who: "Eren", work: "Shingeki no Kyojin"),
            LaunchQuote(text: "Give up on your dreams and die.", who: "Levi", work: "Shingeki no Kyojin Season 3"),
            LaunchQuote(text: "The difference is experience, and nothing more than that.", who: "Levi", work: "Shingeki no Kyojin"),
            LaunchQuote(text: "Admiration is the emotion furthest from understanding.", who: "Aizen", work: "Bleach"),
            LaunchQuote(text: "Hard work never betrays you, not ever.", who: "Kamogawa", work: "Hajime no Ippo"),
        ]
        let picked = QuoteFeed.candidates(list, skipping: [QuoteFeed.workKey("Hajime no Ippo")], limit: 10)
        XCTAssertEqual(picked.map(\.work), ["Shingeki no Kyojin Season 3", "Bleach"])
        XCTAssertEqual(QuoteFeed.cleanWork("Shingeki no Kyojin Season 3 Part 2"), "Shingeki no Kyojin")
        XCTAssertEqual(QuoteFeed.cleanWork("Fullmetal Alchemist (2003)"), "Fullmetal Alchemist")
        XCTAssertEqual(QuoteFeed.cleanWork("Gintama 2nd Season"), "Gintama")
    }

    func testAniListBatchMatchesTheRightSeries() {
        let json = #"""
        {"data":{
          "m0":{"media":[{"id":53390,"title":{"english":"Attack on Titan","romaji":"Shingeki no Kyojin"},"synonyms":["AoT"],"coverImage":{"large":"https://s4.anilist.co/aot.jpg"},"averageScore":84,"format":"MANGA","countryOfOrigin":"JP","startDate":{"year":2009}}]},
          "m1":{"media":[{"id":1,"title":{"english":"Some Other Thing","romaji":"Betsu"},"synonyms":[],"averageScore":90,"countryOfOrigin":"JP"}]},
          "m2":{"media":[{"id":30013,"title":{"english":"HUNTER×HUNTER","romaji":"HUNTER×HUNTER"},"synonyms":[],"averageScore":88,"countryOfOrigin":"JP","startDate":{"year":1998}}]}
        }}
        """#
        let hits = QuoteFeed.parseBatch(Data(json.utf8), count: 3)
        XCTAssertEqual(QuoteFeed.best(hits[0], for: "Shingeki no Kyojin")?.title, "Attack on Titan")
        XCTAssertEqual(QuoteFeed.best(hits[0], for: "Shingeki no Kyojin")?.detail, "Manga · 2009")
        XCTAssertNil(QuoteFeed.best(hits[1], for: "Samurai Champloo"), "an unrelated search result must not count")
        XCTAssertEqual(QuoteFeed.best(hits[2], for: "Hunter X Hunter")?.id, 30013)
        XCTAssertTrue(QuoteFeed.batchQuery(3).contains("m2: Page"))
    }

    func testBuiltInListIsDiverse() {
        let works = Set(CuratedQuotes.manga.map(\.work))
        XCTAssertGreaterThanOrEqual(works.count, 30)
        let usable = CuratedQuotes.manga.filter(QuoteFeed.usable)
        XCTAssertEqual(usable.count, CuratedQuotes.manga.count, "every built-in line passes the quality check: \(CuratedQuotes.manga.filter { !QuoteFeed.usable($0) }.map(\.text))")
        // One line per series in a shuffle, whatever the series' quote count.
        let round = CuratedQuotes.shuffled(CuratedQuotes.manga)
        XCTAssertEqual(round.count, works.count)
    }
}

final class SpotlightPreferenceTests: XCTestCase {
    func testOnlyChosenKindsAndCountries() {
        let manhwaOnly = SpotlightPreference(categories: [.manhwa], origins: ["KR"])
        let solo = SpotlightMedia(id: 1, title: "Solo Leveling", cover: nil, score: 85, detail: "", category: .manhwa, country: "KR")
        let berserk = SpotlightMedia(id: 2, title: "Berserk", cover: nil, score: 93, detail: "", category: .manga, country: "JP")
        XCTAssertTrue(manhwaOnly.allows(solo))
        XCTAssertFalse(manhwaOnly.allows(berserk))
        XCTAssertTrue(SpotlightPreference(categories: [.webtoons], origins: ["KR", "JP"]).allows(solo), "webtoons let manhwa through")
        XCTAssertFalse(SpotlightPreference(categories: [.manhwa], origins: ["JP"]).allows(solo), "country filter")
        XCTAssertEqual(SpotlightPreference.category(format: "NOVEL", country: "JP"), .novels)
        XCTAssertEqual(SpotlightPreference.category(format: "MANGA", country: "CN"), .manhua)
    }

    func testMangaBeforeItsLightNovelUnlessOnlyNovels() throws {
        let json = #"{"data":{"m0":{"media":[{"id":10,"title":{"english":"Mushoku Tensei","romaji":"Mushoku Tensei","native":"無職転生 ～異世界行ったら本気だす～"},"averageScore":84,"format":"NOVEL","countryOfOrigin":"JP"},{"id":11,"title":{"english":"Mushoku Tensei","romaji":"Mushoku Tensei"},"averageScore":82,"format":"MANGA","countryOfOrigin":"JP"}]}}}"#
        let hits = QuoteFeed.matches(QuoteFeed.parseBatch(Data(json.utf8), count: 1)[0], for: "Mushoku Tensei")
        XCTAssertEqual(QuoteFeed.choose(hits, .everything)?.id, 11, "pictures first")
        let novelsOnly = SpotlightPreference(categories: [.novels], origins: ["JP"])
        let novel = try XCTUnwrap(QuoteFeed.choose(hits, novelsOnly))
        XCTAssertEqual(novel.id, 10)
        XCTAssertEqual(novel.native, "無職転生 ～異世界行ったら本気だす～")
        XCTAssertEqual(QuoteFeed.searchable(native: novel.native!), "無職転生")
        XCTAssertNil(QuoteFeed.choose(hits, SpotlightPreference(categories: [.manhwa], origins: ["KR"])))
    }

    func testPicksAlternateKindsAndUseTheSynopsis() {
        let json = #"{"data":{"manhwa":{"media":[{"id":1,"title":{"english":"Tower of God"},"averageScore":84,"format":"MANGA","countryOfOrigin":"KR","description":"What do you desire? Money and wealth? Honor and pride? Authority and power? Revenge? (Source: WEBTOON)"}]},"novels":{"media":[{"id":2,"title":{"english":"Ascendance of a Bookworm"},"averageScore":86,"format":"NOVEL","countryOfOrigin":"JP","description":"A college girl who loves books is reborn in a world where books are rare.<br><br>She decides to make them herself."}]}}}"#
        let picks = QuoteFeed.parsePicks(Data(json.utf8), preference: SpotlightPreference(categories: [.manhwa, .novels], origins: ["JP", "KR"]))
        XCTAssertEqual(picks.map(\.work), ["Tower of God", "Ascendance of a Bookworm"])
        XCTAssertTrue(picks.allSatisfy(\.pick))
        XCTAssertFalse(picks[0].quote.text.contains("Source"))
        XCTAssertEqual(picks[1].quote.who, "Light novel pick")
        XCTAssertNotNil(QuoteFeed.picksQuery(SpotlightPreference(categories: [.manhwa], origins: ["KR"]), page: 2)?.range(of: #"countryOfOrigin: "KR""#))
        XCTAssertNil(QuoteFeed.picksQuery(SpotlightPreference(categories: [.comics], origins: ["JP"]), page: 1))
    }
}
