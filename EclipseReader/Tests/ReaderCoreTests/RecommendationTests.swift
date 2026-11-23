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
