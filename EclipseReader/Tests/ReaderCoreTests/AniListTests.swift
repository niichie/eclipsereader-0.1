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
