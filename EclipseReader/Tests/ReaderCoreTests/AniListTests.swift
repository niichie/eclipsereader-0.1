import XCTest
@testable import ReaderCore

final class AniListTests: XCTestCase {
    func testSignInLinkAndCallback() throws {
        XCTAssertNil(AniListAPI.authorizeURL(clientID: "abc"))
        let url = try XCTUnwrap(AniListAPI.authorizeURL(clientID: " 12345 "))
        XCTAssertTrue(url.absoluteString.contains("client_id=12345"))
        XCTAssertTrue(url.absoluteString.contains("response_type=token"))
        let back = URL(string: "eclipsereader://anilist#access_token=eyJ0eXAi.abc&token_type=Bearer&expires_in=31536000")!
        let token = try XCTUnwrap(AniListAPI.token(fromCallback: back))
        XCTAssertEqual(token.token, "eyJ0eXAi.abc")
        XCTAssertNotNil(token.expires)
        XCTAssertNil(AniListAPI.token(fromCallback: URL(string: "eclipsereader://anilist#error=access_denied")!))
    }

    func testParsesSearchAndEntries() throws {
        let search = #"{"data":{"Page":{"media":[{"id":30002,"title":{"english":null,"romaji":"Berserk"},"coverImage":{"medium":"https://s4.anilist.co/b.jpg"},"chapters":null,"format":"MANGA","startDate":{"year":1989}}]}}}"#
        let media = try AniListAPI.parseSearch(Data(search.utf8))
        XCTAssertEqual(media.first?.id, 30002)
        XCTAssertEqual(media.first?.title, "Berserk")
        XCTAssertEqual(media.first?.year, 1989)
        let entry = #"{"data":{"Media":{"chapters":null,"mediaListEntry":{"progress":372,"status":"CURRENT"}}}}"#
        let parsed = try AniListAPI.parseEntry(Data(entry.utf8))
        XCTAssertEqual(parsed.entry, AniListEntry(progress: 372, status: "CURRENT"))
        let denied = #"{"errors":[{"message":"Invalid token","status":400}],"data":null}"#
        XCTAssertThrowsError(try AniListAPI.parseViewer(Data(denied.utf8))) { error in
            XCTAssertEqual(error as? AniListError, .service("Invalid token"))
        }
    }

    func testOnlyMovesProgressForward() {
        XCTAssertEqual(AniListAPI.progress(for: "12.5"), 12)
        XCTAssertNil(AniListAPI.progress(for: "Extra"))
        XCTAssertNil(AniListAPI.update(after: 10, current: AniListEntry(progress: 12, status: "CURRENT"), total: nil))
        XCTAssertEqual(AniListAPI.update(after: 13, current: AniListEntry(progress: 12, status: "PLANNING"), total: nil)?.status, "CURRENT")
        XCTAssertEqual(AniListAPI.update(after: 40, current: nil, total: 40)?.status, "COMPLETED")
        XCTAssertEqual(AniListAPI.update(after: 5, current: AniListEntry(progress: 2, status: "REPEATING"), total: 40)?.status, "REPEATING")
    }
}

final class SimilarAndMergeTests: XCTestCase {
    func testSimilarSeriesFromAniList() throws {
        let json = #"{"data":{"Media":{"id":30002,"title":{"english":null,"romaji":"Berserk"},"recommendations":{"nodes":[{"rating":412,"mediaRecommendation":{"id":30656,"title":{"english":"Vagabond","romaji":"Vagabond"},"coverImage":{"large":"https://s4.anilist.co/v.jpg"},"averageScore":91,"format":"MANGA","countryOfOrigin":"JP","isAdult":false,"startDate":{"year":1998}}},{"rating":3,"mediaRecommendation":{"id":9,"title":{"romaji":"Adult thing"},"isAdult":true}},{"rating":0,"mediaRecommendation":{"id":10,"title":{"romaji":"Unrated"}}}]}}}}"#
        let result = try AniListAPI.parseSimilar(Data(json.utf8))
        XCTAssertEqual(result.matched, "Berserk")
        XCTAssertEqual(result.items.map(\.title), ["Vagabond"])
        XCTAssertEqual(result.items.first?.score, 91)
        XCTAssertEqual(result.items.first?.kind, "Manga")
    }

    func testMergeFillsOnlyTheGaps() {
        func ch(_ host: String, _ n: String) -> Chapter { Chapter(url: URL(string: "https://\(host)/c/\(n)")!, title: "Chapter \(n)", number: n) }
        let main = [ch("mangadex.org", "1"), ch("mangadex.org", "2"), ch("mangadex.org", "5")]
        let other = [ch("weebcentral.com", "1"), ch("weebcentral.com", "2"), ch("weebcentral.com", "3"), ch("weebcentral.com", "4"), ch("weebcentral.com", "5"), ch("weebcentral.com", "5.5")]
        XCTAssertEqual(ChapterMerge.missing(from: main, in: other).map(\.number), ["3", "4", "5.5"])
        let merged = ChapterMerge.combine(main: main, filler: other, fillerHost: "weebcentral.com")
        XCTAssertEqual(merged.map(\.number), ["1", "2", "3", "4", "5", "5.5"])
        XCTAssertEqual(merged.filter { $0.url.host == "weebcentral.com" }.count, 3)
        // MangaDex later posts chapter 3: the filler copy gives way, unless it's being read.
        let later = merged + [ch("mangadex.org", "3")]
        XCTAssertEqual(ChapterMerge.combine(main: later, filler: other, fillerHost: "weebcentral.com")
            .filter { $0.number == "3" }.map { $0.url.host }, ["mangadex.org"])
        XCTAssertEqual(ChapterMerge.combine(main: later, filler: other, fillerHost: "weebcentral.com", keep: { $0.url.host == "weebcentral.com" })
            .filter { $0.number == "3" }.count, 2)
        // A main site serving chapters from its own subdomain never has them treated as filler.
        let sub = [ch("read.example.com", "1"), ch("read.example.com", "2")]
        XCTAssertEqual(ChapterMerge.combine(main: sub, filler: [ch("weebcentral.com", "2"), ch("weebcentral.com", "3")], fillerHost: "weebcentral.com")
            .map { $0.url.host ?? "" }, ["read.example.com", "read.example.com", "weebcentral.com"])
        XCTAssertFalse(ChapterMerge.isFiller(ch("www.weebcentral.com", "1"), from: nil))
        XCTAssertTrue(ChapterMerge.isFiller(ch("www.weebcentral.com", "1"), from: "weebcentral.com"))
    }
}
