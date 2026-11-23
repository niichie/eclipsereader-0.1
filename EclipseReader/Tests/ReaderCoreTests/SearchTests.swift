import XCTest
@testable import ReaderCore

final class SearchTests: XCTestCase {
    func testWordPressSearchCards() {
        let base = URL(string: "https://scans.example.com/?s=solo&post_type=wp-manga")!
        let html = """
        <div class="c-tabs-item__content">
          <a href="https://scans.example.com/manga/solo-hunter/" title="Solo Hunter"><img data-src="https://scans.example.com/wp-content/uploads/solo-193x278.jpg" alt="Solo Hunter"></a>
          <h3><a href="https://scans.example.com/manga/solo-hunter/">Solo Hunter</a></h3>
          <a href="https://scans.example.com/manga/solo-hunter/chapter-12/">Chapter 12</a>
        </div>
        <div class="c-tabs-item__content">
          <a href="/manga/solo-max-level/"><img src="/wp-content/uploads/max.webp" alt="Solo Max-Level Newbie"></a>
        </div>
        <a href="/manga/">All manga</a><a href="/genres/action/">Action</a><a href="https://other.example.org/manga/x/">Elsewhere</a>
        """
        let results = GlobalSearch.results(in: html, base: base)
        XCTAssertEqual(results.map(\.title), ["Solo Hunter", "Solo Max-Level Newbie"])
        XCTAssertEqual(results.first?.cover?.lastPathComponent, "solo-193x278.jpg")
        XCTAssertEqual(results.last?.url.absoluteString, "https://scans.example.com/manga/solo-max-level/")
    }

    func testSearchAddressesForASite() {
        let urls = GlobalSearch.searchURLs(root: URL(string: "https://www.scans.example.com/comics")!, query: "solo leveling")
        XCTAssertEqual(urls.first?.absoluteString, "https://www.scans.example.com/?s=solo%20leveling&post_type=wp-manga")
        XCTAssertEqual(urls.count, 2)
    }

    func testWebtoonsSearchResults() {
        let base = URL(string: "https://www.webtoons.com/en/search?keyword=tower")!
        let html = #"<a href="https://www.webtoons.com/en/fantasy/tower-of-god/list?title_no=95" class="card_item"><img src="https://webtoon-phinf.pstatic.net/a.jpg" alt=""><p class="subj">Tower of God</p></a>"#
        let results = GlobalSearch.webtoonsResults(in: html, base: base)
        XCTAssertEqual(results.first?.title, "Tower of God")
        XCTAssertEqual(results.first?.id, "webtoons-95")
    }

    func testIrrelevantHomePageCardsAreDropped() {
        let items = [DiscoverItem(id: "a", title: "Solo Leveling", url: URL(string: "https://x.example.com/manga/a")!, cover: nil, detail: nil),
                     DiscoverItem(id: "b", title: "Omniscient Reader", url: URL(string: "https://x.example.com/manga/b")!, cover: nil, detail: nil)]
        XCTAssertEqual(GlobalSearch.relevant(items, to: "solo").map(\.id), ["a"])
        XCTAssertEqual(GlobalSearch.relevant(items, to: "  ").count, 2)
    }
}
