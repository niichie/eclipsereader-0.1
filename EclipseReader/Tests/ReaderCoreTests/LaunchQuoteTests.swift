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
        XCTAssertGreaterThanOrEqual(Set(CuratedQuotes.books.map(\.work)).count, 25)
    }
}
