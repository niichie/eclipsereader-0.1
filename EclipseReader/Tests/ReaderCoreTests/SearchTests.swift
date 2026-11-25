import XCTest
@testable import ReaderCore

final class SearchTests: XCTestCase {
    func testBookCatalogSearchURLsIncludeQuery() {
        for catalog in BookCatalog.allCases {
            let url = catalog.searchURL("Mary Shelley")
            XCTAssertEqual(url.host, catalog.home.host)
            XCTAssertTrue(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.value == "Mary Shelley" } == true)
        }
    }

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
        let titles = ["Guidebook", "Cover of Kakegurui", "Xiao Gǔ Niang"]
        let results = titles.map { DiscoverItem(id: $0, title: $0, url: items[0].url, cover: nil, detail: nil) }
        XCTAssertEqual(GlobalSearch.relevant(results, to: "Xiao Gu Niang").map(\.title), ["Xiao Gǔ Niang"])
    }

    func testSameSeriesOnSeveralSitesIsGroupedOnce() {
        func item(_ id: String, _ title: String) -> DiscoverItem {
            DiscoverItem(id: id, title: title, url: URL(string: "https://example.org/\(id)")!, cover: nil, detail: nil)
        }
        let works = GlobalSearch.group([
            (site: "WeebCentral", items: [item("w1", "Jujutsu Kaisen 0"), item("w2", "Jujutsu Kaisen")]),
            (site: "MangaDot", items: [item("d1", "JUJUTSU KAISEN"), item("d2", "Jujutsu Kaisen Modulo")]),
            (site: "MangaDex", items: [item("x1", "Jujutsu Kaisen"), item("x2", "Jujutsu Kaisen 0")]),
        ], query: "jujutsu kaisen")
        XCTAssertEqual(works.map(\.title), ["Jujutsu Kaisen", "Jujutsu Kaisen 0", "Jujutsu Kaisen Modulo"])
        XCTAssertEqual(works[0].sites, ["WeebCentral", "MangaDot", "MangaDex"])
        XCTAssertEqual(works[1].sites, ["WeebCentral", "MangaDex"])
        XCTAssertEqual(works[2].sites, ["MangaDot"])
    }

    func testDependableSitesFirstAndSilentOnesFlagged() {
        var r = SearchReliability()
        for _ in 0..<3 { r.record("finds", .results); r.record("empty", .empty); r.record("silent", .noAnswer) }
        XCTAssertEqual(r.ordered(["silent", "new", "empty", "finds"]), ["finds", "new", "empty", "silent"])
        XCTAssertEqual(r.failing(["silent", "finds"]), [])
        r.record("silent", .noAnswer); r.record("silent", .noAnswer)
        XCTAssertEqual(r.failing(["silent", "finds"]), ["silent"])
        r.record("silent", .empty)
        XCTAssertEqual(r.failing(["silent"]), [], "answering once resets the run")
    }
}
