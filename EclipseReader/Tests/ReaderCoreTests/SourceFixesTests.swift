import XCTest
@testable import ReaderCore

/// Fixtures copied from what the live sites send (checked by the "Probe sources" workflow).
final class SourceFixesTests: XCTestCase {
    func testStandardEbooksResults() {
        let html = """
        <ol class="ebooks-list grid">
          <li typeof="schema:Book" about="/ebooks/bram-stoker/dracula">
            <div class="thumbnail-container" aria-hidden="true"><a href="/ebooks/bram-stoker/dracula" tabindex="-1" property="schema:url">
              <picture><img src="/images/covers/bram-stoker_dracula/a02c/cover@2x.jpg" alt="" property="schema:image"/></picture></a></div>
            <p><a href="/ebooks/bram-stoker/dracula" property="schema:url"><span property="schema:name">Dracula</span></a></p>
            <p class="author" typeof="schema:Person" property="schema:author" resource="/ebooks/bram-stoker"><a href="https://standardebooks.org/ebooks/bram-stoker" property="schema:url"><span property="schema:name">Bram Stoker</span></a></p>
          </li>
          <li typeof="schema:Book" about="/ebooks/leo-tolstoy/war-and-peace/louise-maude_aylmer-maude">
            <p><a href="/ebooks/leo-tolstoy/war-and-peace/louise-maude_aylmer-maude"><span property="schema:name">War and Peace</span></a></p>
            <p class="author"><a href="/ebooks/leo-tolstoy"><span property="schema:name">Leo Tolstoy</span></a></p>
          </li>
        </ol>
        """
        let books = FreeBooks.parseStandardEbooks(html)
        XCTAssertEqual(books.map(\.title), ["Dracula", "War and Peace"])
        XCTAssertEqual(books.first?.author, "Bram Stoker")
        XCTAssertEqual(books.first?.cover?.absoluteString, "https://standardebooks.org/images/covers/bram-stoker_dracula/a02c/cover@2x.jpg")
        XCTAssertEqual(books.first?.download?.absoluteString,
                       "https://standardebooks.org/ebooks/bram-stoker/dracula/downloads/bram-stoker_dracula.epub?source=download")
        XCTAssertEqual(books.last?.download?.absoluteString,
                       "https://standardebooks.org/ebooks/leo-tolstoy/war-and-peace/louise-maude_aylmer-maude/downloads/leo-tolstoy_war-and-peace_louise-maude_aylmer-maude.epub?source=download")
    }

    func testGutenbergSearchAndMirror() {
        let html = """
        <ul class="results">
        <li class="booklink"><a class="link" href="/ebooks/84" accesskey="1">
          <span class="cell leftcell with-cover"><img class="cover-thumb" src="/cache/epub/84/pg84.cover.small.jpg" alt=""></span>
          <span class="cell content"><span class="title">Frankenstein; Or, The Modern Prometheus</span>
          <span class="subtitle">Mary Wollstonecraft Shelley</span><span class="extra">96471 downloads</span></span></a></li>
        <li class="booklink"><a class="link" href="/ebooks/42324"><span class="title">Frankenstein</span><span class="subtitle">Mary Shelley</span></a></li>
        </ul>
        """
        let books = FreeBooks.parseGutenbergSearch(html)
        XCTAssertEqual(books.count, 2)
        XCTAssertEqual(books.first?.author, "Mary Wollstonecraft Shelley")
        XCTAssertEqual(books.first?.download?.absoluteString, "https://www.gutenberg.org/ebooks/84.epub3.images")
        XCTAssertEqual(books.first?.detail, "96471 downloads")
        XCTAssertEqual(FreeBooks.mirrors(for: URL(string: "https://www.gutenberg.org/ebooks/84.epub3.images")!).first?.absoluteString,
                       "https://gutenberg.pglaf.org/cache/epub/84/pg84-images-3.epub")
        XCTAssertEqual(FreeBooks.mirrors(for: URL(string: "https://standardebooks.org/x.epub")!), [])
    }

    func testScriptListedRelativePagesInNumberOrder() throws {
        // MangaDot: a React data stream lists pages newest-first, as site-relative paths.
        let names = (1...12).reversed().map { String(format: "%03d", $0) }
        let stream = names.map { #"\"/chapters/manga_118/chapter_0_g0/\#($0).webp\",\"\#($0).webp\""# }.joined(separator: ",")
        let html = #"<link rel="preload" as="image" href="/chapters/manga_118/chapter_0_g0/001.webp"/><script>window.__data=JSON.parse("[\#(stream)]");</script>"#
        let pages = try LinkedSource.detect(in: html, base: URL(string: "https://mangadot.net/chapter/32749?source=user")!)
        XCTAssertEqual(pages.count, 12)
        XCTAssertEqual(pages.first?.url.absoluteString, "https://mangadot.net/chapters/manga_118/chapter_0_g0/001.webp")
        XCTAssertEqual(pages.last?.url.lastPathComponent, "012.webp")
    }

    func testAsuraSearchesItsBrowsePage() {
        let urls = GlobalSearch.searchURLs(root: URL(string: "https://asurascans.com/comics")!, query: "murim login")
        XCTAssertEqual(urls.map(\.absoluteString), ["https://asurascans.com/browse?search=murim%20login"])
    }

    func testWebtoonOriginalsBeforeCanvas() {
        func item(_ title: String, _ path: String) -> DiscoverItem {
            DiscoverItem(id: path, title: title, url: URL(string: "https://www.webtoons.com/en/\(path)/list?title_no=1")!, cover: nil, detail: nil)
        }
        let found = [item("Filipino Kaisen", "canvas/filipino"), item("Jujutsu Kaisen fan comic", "canvas/jjk"), item("Jujutsu Kaisen", "action/jjk")]
        let strict = GlobalSearch.strictCanvas(found, query: "Jujutsu Kaisen")
        XCTAssertEqual(strict.map(\.title), ["Jujutsu Kaisen"])
        let onlyCanvas = GlobalSearch.strictCanvas(Array(found.prefix(2)), query: "Jujutsu Kaisen")
        XCTAssertEqual(onlyCanvas.map(\.title), ["Jujutsu Kaisen fan comic"])
    }

    func testAniListTopManga() throws {
        let json = #"{"data":{"Page":{"media":[{"id":30002,"title":{"english":null,"romaji":"Berserk"},"coverImage":{"extraLarge":"https://s4.anilist.co/b.jpg"},"averageScore":93,"format":"MANGA","countryOfOrigin":"JP","startDate":{"year":1989},"description":"Guts, a former mercenary...<br><br>(Source: Dark Horse)","siteUrl":"https://anilist.co/manga/30002"},{"id":1,"title":{"english":"Okay"},"averageScore":70,"countryOfOrigin":"KR"}]}}}"#
        let picks = try Recommendations.parseAniList(Data(json.utf8))
        XCTAssertEqual(picks.map(\.title), ["Berserk"])
        XCTAssertEqual(picks.first?.score, "AniList 93%")
        XCTAssertEqual(picks.first?.detail, "Manga · 1989")
        XCTAssertEqual(picks.first?.synopsis, "Guts, a former mercenary...")
    }
}

final class BookLinksTests: XCTestCase {
    func testGutenbergBookPagePicksEPUB3() {
        let html = """
        <a href="/ebooks/84.html.images">Read online</a><a href="/ebooks/84.epub3.images">EPUB3 (E-readers incl. Send-to-Kindle)</a>
        <a href="/ebooks/84.epub.noimages">EPUB (older E-readers)</a><a href="/ebooks/84.kf8.images">Kindle</a><a href="/ebooks/1342">Also read</a>
        """
        let link = BookLinks.best(in: html, base: URL(string: "https://www.gutenberg.org/ebooks/84")!)
        XCTAssertEqual(link?.url.absoluteString, "https://www.gutenberg.org/ebooks/84.epub3.images")
        XCTAssertEqual(link?.format, "EPUB")
    }
    func testStandardEbooksAddsSourceDownload() {
        let html = """
        <a href="/ebooks/bram-stoker/dracula/downloads/bram-stoker_dracula.epub" property="schema:contentUrl">Compatible epub</a>
        <a href="/ebooks/bram-stoker/dracula/downloads/bram-stoker_dracula_advanced.epub">Advanced epub</a>
        <a href="/ebooks/bram-stoker/dracula/downloads/bram-stoker_dracula.kepub.epub">Kobo</a>
        <a href="/ebooks/bram-stoker/dracula/downloads/bram-stoker_dracula.azw3">Kindle</a>
        """
        let link = BookLinks.best(in: html, base: URL(string: "https://standardebooks.org/ebooks/bram-stoker/dracula")!)
        XCTAssertEqual(link?.url.absoluteString, "https://standardebooks.org/ebooks/bram-stoker/dracula/downloads/bram-stoker_dracula.epub?source=download")
    }
    func testWikisourceGrabADownload() {
        let html = """
        <a rel="nofollow" class="external text" href="https://ws-export.wmcloud.org/?format=epub&amp;lang=en&amp;page=A_History_of_Japanese_Literature">EPUB</a>
        <a href="https://ws-export.wmcloud.org/?format=rtf&amp;lang=en&amp;page=A_History_of_Japanese_Literature">RTF</a>
        <a href="https://ws-export.wmcloud.org/?format=mobi&amp;lang=en&amp;page=A_History_of_Japanese_Literature">MOBI</a>
        """
        let link = BookLinks.best(in: html, base: URL(string: "https://en.wikisource.org/wiki/Main_Page")!)
        XCTAssertEqual(link?.format, "EPUB")
        XCTAssertTrue(link?.url.absoluteString.contains("format=epub") ?? false)
    }
    func testListsOfBooksAskYouToPickOne() {
        let html = #"<a href="/ebooks/84.epub3.images">A</a><a href="/ebooks/345.epub3.images">B</a>"#
        XCTAssertNil(BookLinks.best(in: html, base: URL(string: "https://www.gutenberg.org/ebooks/search/?query=x")!))
        XCTAssertNil(BookLinks.best(in: #"<a href="/ebooks/84">Frankenstein</a>"#, base: URL(string: "https://www.gutenberg.org/")!))
    }
}

final class CoverAndTextTests: XCTestCase {
    func testEscapedHTMLDescriptionsReadAsText() {
        let raw = #"<p><i>Pride and Prejudice</i> may today be one of <a href="https://standardebooks.org/ebooks/jane-austen">Jane Austen’s</a> most famous novels.</p><p>Second.</p>"#
        XCTAssertEqual(BookText.richText(raw), "Pride and Prejudice may today be one of Jane Austen’s most famous novels. Second.")
        XCTAssertEqual(BookText.richText("Plain words & more"), "Plain words & more")
    }
    func testSocialCardsComeLastAsCovers() {
        let html = """
        <meta property="og:image" content="https://asurascans.com/og/comics/murim-login.jpg">
        <h1>Murim Login</h1><img alt="Murim Login" src="https://cdn.asurascans.com/asura-images/covers/murim-login.407650-400.webp">
        """
        XCTAssertEqual(LinkedSource.cover(in: html, base: URL(string: "https://asurascans.com/comics/murim-login-7de80a82")!)?.host,
                       "cdn.asurascans.com")
        let only = #"<meta property="og:image" content="https://mangadot.net/og/manga/118">"#
        XCTAssertEqual(LinkedSource.cover(in: only, base: URL(string: "https://mangadot.net/manga/118")!)?.path, "/og/manga/118")
        XCTAssertFalse(LinkedSource.isSocialCard(URL(string: "https://example.com/wp-content/uploads/cover-logo.jpg")!))
    }
}

final class MangaDexTitleTests: XCTestCase {
    func testLongRomanisedTitlesUseTheShortEnglishForm() {
        let long: [String: Any] = ["title": ["en": "Jujutsu Kaisen 0: Toukyou Toritsu Jujutsu Koutou Senmon Gakkou"],
                                   "altTitles": [["ja": "呪術廻戦 0"], ["en": "Jujutsu Kaisen 0"], ["en": "JJK0"]]]
        XCTAssertEqual(MangaDex.displayTitle(long), "Jujutsu Kaisen 0")
        let plain: [String: Any] = ["title": ["en": "Jujutsu Kaisen"], "altTitles": [["en": "Sorcery Fight"], ["en": "JJK"]]]
        XCTAssertEqual(MangaDex.displayTitle(plain), "Jujutsu Kaisen")
        let romaji: [String: Any] = ["title": ["en": "Kage no Jitsuryokusha ni Naritakute!"], "altTitles": [["en": "The Eminence in Shadow"]]]
        XCTAssertEqual(MangaDex.displayTitle(romaji), "Kage no Jitsuryokusha ni Naritakute!")
    }
}

final class MangaDotSearchTests: XCTestCase {
    func testSearchAPIResults() throws {
        let json = #"{"manga_list":[{"id":118,"title":"Solo Leveling","title_romanized":"Na Honjaman Level Up","photo":"/uploads/cover_9494d20d2f1e108e.webp","country_of_origin":"KR","chapter_count":201},{"id":5,"title":"Solo Leveling: Ragnarok","photo":"/uploads/x.webp","country_of_origin":"KR","chapter_count":40}],"pagination":{"total_results":2}}"#
        let items = try GlobalSearch.mangaDotResults(Data(json.utf8))
        XCTAssertEqual(items.first?.url.absoluteString, "https://mangadot.net/manga/118")
        XCTAssertEqual(items.first?.cover?.absoluteString, "https://mangadot.net/uploads/cover_9494d20d2f1e108e.webp")
        XCTAssertEqual(items.first?.detail, "Manhwa · 201 ch")
    }
}
