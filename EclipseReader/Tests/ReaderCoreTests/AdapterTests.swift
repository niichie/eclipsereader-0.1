import XCTest
@testable import ReaderCore

final class AdapterTests: XCTestCase {
    func testWebtoonsViewerImagesUseDataURL() throws {
        let base = URL(string: "https://www.webtoons.com/en/fantasy/tower/episode-1/viewer?title_no=95&episode_no=1")!
        let html = (1...5).map {
            #"<img src="https://webtoons-static.pstatic.net/image/bg_transparency.png" data-url="https://webtoon-phinf.pstatic.net/2023010\#($0)_1/abc\#($0)/img.jpg?type=q90" class="_images" width="800" height="1200">"#
        }.joined()
        let pages = try LinkedSource.detect(in: html, base: base)
        XCTAssertEqual(pages.count, 5)
        XCTAssertTrue(pages[0].url.absoluteString.contains("webtoon-phinf"))
    }

    func testImagesInSeparateFoldersGroupByHost() throws {
        let base = URL(string: "https://toons.example.com/series/x/chapter-3")!
        let html = (1...6).map { #"<img src="https://cdn.example.net/\#($0)a9/page.jpg">"# }.joined() + #"<img src="/logo.png">"#
        let pages = try LinkedSource.detect(in: html, base: base)
        XCTAssertEqual(pages.count, 6)
    }

    func testCatalogueOfCoversIsNotReadAsPages() {
        let base = URL(string: "https://toons.example.com/latest")!
        let html = (1...8).map { #"<a href="/s/\#($0)"><img src="https://cdn.example.net/\#($0)/cover.jpg"></a>"# }.joined()
        XCTAssertThrowsError(try LinkedSource.detect(in: html, base: base))
    }

    func testScriptListedImages() throws {
        let base = URL(string: "https://reader.example.com/read/abc/chapter-9")!
        let html = #"<div id="app"></div><script>window.__DATA__={"images":["https:\/\/img.example.org\/ch9\/01.webp","https:\/\/img.example.org\/ch9\/02.webp","https:\/\/img.example.org\/ch9\/03.webp"]}</script>"#
        let pages = try LinkedSource.detect(in: html, base: base)
        XCTAssertEqual(pages.map(\.url.lastPathComponent), ["01.webp", "02.webp", "03.webp"])
    }

    func testCoverPrefersImageNamedAfterTheSeries() {
        let base = URL(string: "https://scans.example.com/comics/solo-hunter-1a2b")!
        let html = """
        <h1>Solo Hunter</h1>
        <img src="https://cdn.example.com/covers/other-series.webp" alt="Other Series">
        <img src="https://cdn.example.com/covers/solo-hunter.webp" alt="Solo Hunter">
        """
        XCTAssertEqual(LinkedSource.cover(in: html, base: base)?.lastPathComponent, "solo-hunter.webp")
    }

    func testOptimizedImageAddressesAreUnwrapped() {
        let base = URL(string: "https://scans.example.com/comics/x")!
        let url = LinkedSource.resolve("/_next/image?url=https%3A%2F%2Fcdn.example.com%2Fcovers%2Fx.webp&w=640&q=75", base: base)
        XCTAssertEqual(url?.absoluteString, "https://cdn.example.com/covers/x.webp")
    }

    func testMangaDexLinks() {
        let title = URL(string: "https://mangadex.org/title/a1c7c817-4e59-43b7-9365-09675a149a6f/one-piece")!
        let chapter = URL(string: "https://mangadex.org/chapter/0f5a2a1e-1111-4b2b-9c9c-123456789abc")!
        XCTAssertTrue(MangaDex.handles(title))
        XCTAssertEqual(MangaDex.titleID(title), "a1c7c817-4e59-43b7-9365-09675a149a6f")
        XCTAssertEqual(MangaDex.chapterID(chapter), "0f5a2a1e-1111-4b2b-9c9c-123456789abc")
        XCTAssertFalse(MangaDex.handles(URL(string: "https://mangadex.org/titles/latest")!))
    }

    func testWeebCentralChapterList() {
        let html = """
        <a href="https://weebcentral.com/chapters/01J76XYAAA1111111111111111"><span>Chapter 2</span><time>2024</time></a>
        <a href="https://weebcentral.com/chapters/01J76XYAAA0000000000000000"><span>Chapter 1</span></a>
        """
        let chapters = WeebCentral.chapters(in: html)
        XCTAssertEqual(chapters.map(\.number), ["1", "2"])
        XCTAssertTrue(WeebCentral.handles(URL(string: "https://weebcentral.com/series/01J76XY7E9FNDZ1DBBM6PBJPFK/Solo")!))
    }

    func testHomeAndLatestPagesAreListings() {
        let home = URL(string: "https://scans.example.com/comics")!
        XCTAssertThrowsError(try LinkedSource.analyze(html: "<a href='/comics/a/chapter-1'>Chapter 1</a><a href='/comics/a/chapter-2'>Chapter 2</a>", url: home)) {
            XCTAssertEqual($0 as? SourceError, .listing)
        }
        // A "latest" page whose chapter links share one folder but belong to many series.
        let latest = URL(string: "https://reader.example.com/updates/today")!
        let html = [5, 12, 5, 40, 12, 7, 5, 3].enumerated().map { i, n in
            "<a href='/chapter/\(1000 + i)'>Chapter \(n)</a>"
        }.joined()
        XCTAssertEqual(LinkedSource.summarize(html: html, url: latest), .listing)
    }

    func testSeriesPageIsNotAListing() throws {
        let series = URL(string: "https://scans.example.com/comics/solo-hunter-1a2b")!
        let related = (1...12).map { "<a href='/comics/other-\($0)'>Other \($0)</a>" }.joined()
        let chapters = (1...30).map { "<a href='/comics/solo-hunter-1a2b/chapter/\($0)'>Chapter \($0)</a>" }.joined()
        let found = try LinkedSource.analyze(html: "<h1>Solo Hunter</h1>" + chapters + related, url: series)
        XCTAssertEqual(found.chapters.count, 30)
    }
}
