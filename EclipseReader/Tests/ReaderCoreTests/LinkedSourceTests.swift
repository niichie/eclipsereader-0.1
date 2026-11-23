import XCTest
@testable import ReaderCore

final class LinkedSourceTests: XCTestCase {
    let base = URL(string: "https://manga.example.com/series/one/chapter-1/")!

    func testMarkedReaderImagesKeepOrderAndLazySources() throws {
        let html = """
        <html><head><title>One &amp; Only – Chapter 1</title></head><body>
        <img class="site-logo" src="/logo.png">
        <img class="wp-manga-chapter-img" data-src=" https://cdn.example.com/c1/01.jpg " src="data:image/gif;base64,AAA">
        <img class="wp-manga-chapter-img" data-src="https://cdn.example.com/c1/02.jpg">
        <img class="wp-manga-chapter-img" src="/c1/03.jpg">
        <script>var x = '<img class="wp-manga-chapter-img" src="/evil.jpg">'</script>
        </body></html>
        """
        let pages = try LinkedSource.detect(in: html, base: base)
        XCTAssertEqual(pages.map(\.url.absoluteString), [
            "https://cdn.example.com/c1/01.jpg", "https://cdn.example.com/c1/02.jpg", "https://manga.example.com/c1/03.jpg"])
        XCTAssertEqual(LinkedSource.title(in: html), "One & Only – Chapter 1")
    }

    func testHeuristicPicksLargestFolderAndSkipsJunk() throws {
        let html = """
        <img src="/img/logo.png"><img src="/ads/banner1.jpg"><img src="/thumbs/a.jpg" width="120">
        <img src="https://img.example.net/ch/5/001.webp"><img src="https://img.example.net/ch/5/002.webp">
        <img src="https://img.example.net/ch/5/003.webp"><img src="https://img.example.net/ch/5/003.webp">
        <img src="/covers/other.jpg">
        """
        let pages = try LinkedSource.detect(in: html, base: base)
        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(pages.last?.url.lastPathComponent, "003.webp")
    }

    func testPageWithoutMangaIsRejected() {
        let html = #"<img src="/logo.png"><img src="/a.jpg"><img src="/b/c.jpg">"#
        XCTAssertThrowsError(try LinkedSource.detect(in: html, base: base))
    }

    func testLinksAreRestrictedToPublicHTTPS() {
        XCTAssertNotNil(WebLink.parse("mangadex.org/chapter/123"))
        XCTAssertEqual(WebLink.parse("http://example.com/a")?.scheme, "https")
        for bad in ["https://192.168.1.1/x", "https://localhost/x", "https://nas.local/x", "file:///etc/passwd",
                    "https://user:pw@example.com/", "https://example.com:8080/"] {
            XCTAssertNil(WebLink.parse(bad), bad)
        }
    }
}
