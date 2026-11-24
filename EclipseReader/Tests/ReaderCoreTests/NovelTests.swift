import XCTest
@testable import ReaderCore

final class NovelTests: XCTestCase {
    func testSyosetuChapterKeepsForewordTextAndAfterword() throws {
        let html = """
        <html><body><h1 class="p-novel__title p-novel__title--rensai">プロローグ</h1>
        <div class="p-novel__body">
        <div class="js-novel-text p-novel__text p-novel__text--preface"><p id="Lp1">前書きです。</p></div>
        <div class="js-novel-text p-novel__text"><p id="L1">　俺は34歳住所不定無職。</p><p id="L2"><br /></p><p id="L3">　人生を後悔している真っ最中の小太りブサメンのナイスガイだ。</p></div>
        <div class="js-novel-text p-novel__text p-novel__text--afterword"><p id="La1">後書きです。</p></div>
        </div><a href="/n9669bk/2/">次へ</a></body></html>
        """
        let text = try XCTUnwrap(NovelText.extract(html: html, url: URL(string: "https://ncode.syosetu.com/n9669bk/1/")!))
        XCTAssertEqual(text.title, "プロローグ")
        let plain = text.blocks(base: URL(string: "https://ncode.syosetu.com/n9669bk/1/")!).compactMap { block -> String? in
            if case .paragraph(let runs) = block { return runs.map(\.text).joined() } else { return nil }
        }
        XCTAssertEqual(plain.first, "前書きです。")
        XCTAssertTrue(plain.contains { $0.contains("住所不定無職") })
        XCTAssertEqual(plain.last, "後書きです。")
    }

    func testHiddenNoticesAndNavigationAreDropped() throws {
        let paragraph = String(repeating: "Zorian woke to the sound of his little sister jumping on his bed. ", count: 6)
        let html = """
        <html><head><style>.cjE1Mz { display: none; speak: never; }</style></head><body>
        <nav><a href="/">Home</a><a href="/fictions">Fictions</a></nav>
        <div class="chapter-inner chapter-content"><p>\(paragraph)</p><p class="cjE1Mz">This story was taken without permission.</p>
        <p>\(paragraph)</p><p><a href="/next">Next Chapter</a></p></div>
        <footer>© 2026</footer></body></html>
        """
        let text = try XCTUnwrap(NovelText.extract(html: html, url: URL(string: "https://example.com/fiction/1/chapter/2")!))
        XCTAssertFalse(text.html.contains("without permission"))
        let blocks = text.blocks(base: URL(string: "https://example.com/")!)
        XCTAssertEqual(blocks.count, 2)
    }

    func testDensestBlockWinsOverMenus() throws {
        let words = String(repeating: "The cultivator stepped forward and the mountain trembled beneath him. ", count: 8)
        let links = (1...40).map { "<a href=\"/novel/\($0)\">Some other novel title number \($0)</a>" }.joined()
        let html = "<html><body><div class=\"sidebar\">\(links)</div><div id=\"x\"><div>\(words)</div><div>\(words)</div><div>\(words)</div></div></body></html>"
        let text = try XCTUnwrap(NovelText.extract(html: html, url: URL(string: "https://novels.example/novel/a/chapter-1")!))
        XCTAssertTrue(text.html.contains("cultivator"))
        XCTAssertFalse(text.html.contains("Some other novel"))
        XCTAssertGreaterThan(NovelText.textLength(text.html), 1500)
    }

    func testListsAreNotChapters() {
        let links = (1...60).map { "<li><a href=\"/novel/x/chapter-\($0)\">Chapter \($0): A title</a></li>" }.joined()
        let html = "<html><body><ul>\(links)</ul></body></html>"
        XCTAssertFalse(NovelText.looksLikeChapter(html: html, url: URL(string: "https://novels.example/novel/x")!))
    }

    func testSyosetuTableOfContents() {
        let html = """
        <div class="p-eplist"><div class="p-eplist__chapter-title">第１章　幼年期</div>
        <div class="p-eplist__sublist"><a href="/n9669bk/1/" class="p-eplist__subtitle"> プロローグ </a></div>
        <div class="p-eplist__sublist"><a href="/n9669bk/2/" class="p-eplist__subtitle"> 第一話「もしかして：異世界」 </a></div></div>
        <div class="c-pager"><a href="/n9669bk/?p=2" class="c-pager__item c-pager__item--next">次へ</a></div>
        """
        let chapters = Syosetu.episodes(in: html, ncode: "n9669bk")
        XCTAssertEqual(chapters.map(\.number), ["1", "2"])
        XCTAssertEqual(chapters.first?.title, "プロローグ")
        XCTAssertEqual(chapters.last?.url.absoluteString, "https://ncode.syosetu.com/n9669bk/2/")
        XCTAssertTrue(Syosetu.hasNextPage(html))
        XCTAssertFalse(Syosetu.hasNextPage(#"<span class="c-pager__item c-pager__item--next">次へ</span>"#))
        XCTAssertEqual(Syosetu.ncode(URL(string: "https://ncode.syosetu.com/N9669BK/12/")!), "n9669bk")
        XCTAssertNil(Syosetu.ncode(URL(string: "https://syosetu.com/")!))
    }

    func testSyosetuPreviewKeepsOriginalLinkAndRequiresMatchingNovelEdition() throws {
        let url = try XCTUnwrap(URL(string: "https://ncode.syosetu.com/n1234ab/"))
        let item = DiscoverItem(id: "work", title: "物語", url: url, cover: nil, detail: "Japanese")
        let data = Data(#"{"data":{"m0":{"media":[{"id":1,"format":"MANGA","title":{"native":"物語","english":"Comic"}},{"id":2,"format":"NOVEL","title":{"native":"物語","english":"The Story"},"coverImage":{"large":"https://example.org/cover.jpg"}}]}}}"#.utf8)
        let preview = try XCTUnwrap(Syosetu.matchedPreviews([item], data: data).first)
        XCTAssertEqual(preview.title, "The Story")
        XCTAssertEqual(preview.cover?.lastPathComponent, "cover.jpg")
        XCTAssertEqual(preview.url, url)
        let other = DiscoverItem(id: "other", title: "別の物語", url: url, cover: nil, detail: nil)
        XCTAssertTrue(Syosetu.matchedPreviews([other], data: data).isEmpty)
    }

    func testSyosetuAPI() throws {
        let json = #"[{"allcount":41},{"title":"無職転生","ncode":"N9669BK","writer":"理不尽な孫の手","story":"34歳…","noveltype":1,"end":0,"general_all_no":286},{"title":"短編","ncode":"N1111AA","noveltype":2,"general_all_no":1}]"#
        let entries = try Syosetu.parseAPI(Data(json.utf8))
        XCTAssertEqual(entries.map(\.ncode), ["n9669bk", "n1111aa"])
        XCTAssertEqual(entries.first?.chapters, 286)
        XCTAssertTrue(entries.last?.short ?? false)
        XCTAssertEqual(Syosetu.items(entries).first?.url.absoluteString, "https://ncode.syosetu.com/n9669bk/")
    }

    func testKakuyomuWork() throws {
        let state: [String: Any] = [
            "Work:100": ["title": "異世界転生した俺", "author": ["__ref": "UserAccount:9"], "introduction": "現代日本で…",
                         "tableOfContents": [["__ref": "TableOfContentsChapter:2"], ["__ref": "TableOfContentsChapter:1"]]],
            "UserAccount:9": ["activityName": "きえないで黄昏"],
            "TableOfContentsChapter:1": ["episodeUnions": [["__ref": "Episode:13"]]],
            "TableOfContentsChapter:2": ["episodeUnions": [["__ref": "Episode:11"], ["__ref": "Episode:12"]]],
            "Episode:11": ["title": "第1話", "publishedAt": "2026-07-08T21:00:31Z"],
            "Episode:12": ["title": "第2話", "publishedAt": "2026-07-09T21:00:31Z"],
            "Episode:13": ["title": "第3話", "publishedAt": "2026-07-10T21:00:31Z"],
        ]
        let next: [String: Any] = ["props": ["pageProps": ["__APOLLO_STATE__": state]]]
        let json = String(data: try JSONSerialization.data(withJSONObject: next), encoding: .utf8)!
        let html = "<html><script id=\"__NEXT_DATA__\" type=\"application/json\">\(json)</script></html>"
        let info = try Kakuyomu.info(html: html, url: URL(string: "https://kakuyomu.jp/works/100")!)
        XCTAssertEqual(info.title, "異世界転生した俺")
        XCTAssertEqual(info.author, "きえないで黄昏")
        XCTAssertEqual(info.chapters.map(\.title), ["第1話", "第2話", "第3話"])
        XCTAssertEqual(info.chapters.first?.url.absoluteString, "https://kakuyomu.jp/works/100/episodes/11")
        XCTAssertEqual(info.language, "ja")
    }

    func testWuxiaworldChapterNumbering() throws {
        let item: [String: Any] = [
            "name": "Martial World", "slug": "martial-world", "coverUrl": ["value": "https://cdn.wuxiaworld.com/images/covers/mw.webp"],
            "synopsis": ["value": "<p>In the Divine Realm…</p>"], "language": ["value": "Chinese"],
            "chapterInfo": ["firstChapter": ["name": "Chapter 0 - Magic Cube", "slug": "mw-chapter-0", "number": ["units": 0, "nanos": 0]],
                            "latestChapter": ["name": "Afterword", "slug": "mw-chapter-5", "number": ["units": 5, "nanos": 0]]],
        ]
        let state: [String: Any] = ["queries": [["state": ["data": ["item": item]], "queryKey": ["novel", "martial-world", NSNull()]]]]
        let json = String(data: try JSONSerialization.data(withJSONObject: state), encoding: .utf8)!
        let html = "<script> window.__REACT_QUERY_STATE__ = \(json); window.__APP_CONTEXT__ = {}; </script>"
        let info = try Wuxiaworld.info(html: html, url: URL(string: "https://www.wuxiaworld.com/novel/martial-world")!)
        XCTAssertEqual(info.title, "Martial World")
        XCTAssertEqual(info.language, "zh")
        XCTAssertEqual(info.chapters.count, 6)
        XCTAssertEqual(info.chapters.first?.title, "Chapter 0 - Magic Cube")
        XCTAssertEqual(info.chapters[3].url.absoluteString, "https://www.wuxiaworld.com/novel/martial-world/mw-chapter-3")
        XCTAssertEqual(info.chapters.last?.title, "Afterword")
        XCTAssertEqual(info.summary, "In the Divine Realm…")
    }

    func testSourcesDecodeFromOlderLibraries() throws {
        let old = #"{"name":"Asura","url":"https://asurascans.com/"}"#
        let site = try JSONDecoder().decode(SavedSite.self, from: Data(old.utf8))
        XCTAssertNil(site.category)
        XCTAssertTrue(site.owns(URL(string: "https://www.asurascans.com/comics/x")!))
        let series = #"{"id":"a","url":"https://a.com/","title":"A","kind":"web","chapters":[],"added":0}"#
        XCTAssertEqual(try JSONDecoder().decode(MangaSeries.self, from: Data(series.utf8)).isOnline, true)
    }
}
