import XCTest
@testable import ReaderCore

final class SeriesAndArchiveTests: XCTestCase {
    let series = URL(string: "https://manhwa.example.com/series/solo-climb/")!

    func testSeriesPageListsEveryChapterOldestFirst() {
        // Sites usually list newest first; the reader needs reading order.
        let html = """
        <h1>Solo Climb</h1><meta property="og:image" content="https://cdn.example.com/cover.jpg">
        <ul class="main version-chap">
          <li class="wp-manga-chapter"><a href="https://manhwa.example.com/series/solo-climb/chapter-10/">Chapter 10</a></li>
          <li class="wp-manga-chapter"><a href="https://manhwa.example.com/series/solo-climb/chapter-9-5/">Chapter 9.5</a></li>
          <li class="wp-manga-chapter"><a href="/series/solo-climb/chapter-2/"> Chapter 2 </a></li>
          <li class="wp-manga-chapter"><a href="/series/solo-climb/chapter-1/">Chapter 1</a></li>
        </ul>
        <a href="/series/solo-climb/chapter-1/#comments">Chapter 1</a>
        <a href="https://other-site.example.org/chapter-99/">Chapter 99 elsewhere</a>
        <a href="/genre/action/">Action</a>
        """
        let chapters = LinkedSource.chapterLinks(in: html, base: series)
        XCTAssertEqual(chapters.map(\.title), ["Chapter 1", "Chapter 2", "Chapter 9.5", "Chapter 10"])
        XCTAssertEqual(LinkedSource.seriesTitle(in: html), "Solo Climb")
        XCTAssertEqual(LinkedSource.cover(in: html, base: series)?.lastPathComponent, "cover.jpg")
    }

    func testChapterPickerOnAChapterPage() {
        let html = """
        <select class="selectpicker single-chapter-select">
          <option data-redirect="https://manhwa.example.com/series/solo-climb/ep-3/">Episode 3</option>
          <option data-redirect="https://manhwa.example.com/series/solo-climb/ep-2/" selected>Episode 2</option>
          <option data-redirect="https://manhwa.example.com/series/solo-climb/ep-1/">Episode 1</option>
        </select>
        """
        XCTAssertEqual(LinkedSource.chapterLinks(in: html, base: series).map(\.number), ["1", "2", "3"])
    }

    func testChapterNumbers() {
        XCTAssertEqual(ChapterOrder.number("Chapter 12.5 - The Pit"), 12.5)
        XCTAssertEqual(ChapterOrder.number("/manga/x/ch-7/"), 7)
        XCTAssertEqual(ChapterOrder.number("第3話"), 3)
        XCTAssertEqual(ChapterOrder.number("12화"), 12)
        XCTAssertNil(ChapterOrder.number("Prologue"))
        XCTAssertTrue(ChapterOrder.natural("page2.jpg", "page10.jpg"))
    }

    func testZipIndexReadsStoredAndDeflatedEntriesInNaturalOrder() throws {
        let zipTool = URL(fileURLWithPath: "/usr/bin/zip")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: zipTool.path), "zip tool unavailable")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("vol"), withIntermediateDirectories: true)
        let big = Data(repeating: 0x41, count: 200_000)       // compresses well -> deflate
        let small = Data((0..<255).map { UInt8($0) })          // stored when -0
        try big.write(to: dir.appendingPathComponent("vol/page10.jpg"))
        try small.write(to: dir.appendingPathComponent("vol/page2.jpg"))
        let archive = dir.appendingPathComponent("book.cbz")
        let process = Process()
        process.executableURL = zipTool
        process.currentDirectoryURL = dir
        process.arguments = ["-q", "-r", archive.path, "vol"]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let entries = try ZipIndex.read(archive, maxEntry: 64 << 20).filter { !$0.path.hasSuffix("/") }
            .sorted { ChapterOrder.natural($0.path, $1.path) }
        XCTAssertEqual(entries.map(\.path), ["vol/page2.jpg", "vol/page10.jpg"])
        #if canImport(Compression)
        XCTAssertEqual(try ZipIndex.extract(entries[0], from: archive), small)
        XCTAssertEqual(try ZipIndex.extract(entries[1], from: archive), big)
        #endif
    }

    func testDamagedArchiveIsRejected() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cbz")
        try Data("not a zip at all, just text that is long enough".utf8).write(to: file)
        XCTAssertThrowsError(try ZipIndex.read(file, maxEntry: 1 << 20))
    }

    func testMangaFirstDefaultsAndStyles() {
        let defaults = ReaderPreferences()
        XCTAssertEqual(defaults.direction, .rightToLeft)
        XCTAssertEqual(defaults.mode, .paged)
        XCTAssertEqual(defaults.transition, .curl)
        XCTAssertFalse(defaults.advanceOnLeftSwipe, "Manga turns by dragging the page to the right")
        let manhwa = defaults.applying(.manhwa)
        XCTAssertEqual(manhwa.mode, .vertical)
        XCTAssertEqual(manhwa.trimMargins, false)
        let comic = defaults.applying(.comic)
        XCTAssertEqual(comic.direction, .leftToRight)
        XCTAssertTrue(comic.advanceOnLeftSwipe)
        XCTAssertEqual(defaults.applying(.manga), defaults)
    }

    func testStyleHintsFromSiteTags() {
        let manhwa = #"<div class="genres"><a>Manhwa</a> <a>Action</a></div><span>Type: Manhwa</span><a href="/genre/webtoon">Webtoon</a>"#
        XCTAssertEqual(LinkedSource.styleHint(in: manhwa, url: series), .manhwa)
        // "manga" in a site's name alone says nothing.
        let neutral = #"<title>Read at MangaSite</title><div class="wp-manga">Chapter 1</div>"#
        XCTAssertNil(LinkedSource.styleHint(in: neutral, url: URL(string: "https://mangasite.example.com/x/")!))
    }

    func testWebtoonsBuildsEveryEpisodeFromTheFirstListPage() {
        let base = URL(string: "https://www.webtoons.com/en/drama/lookism/list?title_no=1049")!
        let html = """
        <a href="https://www.webtoons.com/en/drama/lookism/ep-623-gapryong-kim-14/viewer?title_no=1049&amp;episode_no=623">Ep. 623: Gapryong Kim (14) BGM Nov 21, 2026 like 2,217 #623</a>
        <a href="https://www.webtoons.com/en/drama/lookism/ep-622-gapryong-kim-13/viewer?title_no=1049&amp;episode_no=622">Ep. 622: Gapryong Kim (13) Nov 14, 2026 like 3,224 #622</a>
        <a href="https://www.webtoons.com/en/drama/other/ep-1/viewer?title_no=9999&amp;episode_no=1">Another series</a>
        """
        let episodes = Webtoons.episodes(in: html, base: base)
        XCTAssertEqual(episodes.count, 623)
        XCTAssertEqual(episodes.first?.number, "1")
        XCTAssertEqual(episodes.last?.title, "Ep. 623: Gapryong Kim (14)")
        XCTAssertEqual(Webtoons.episodeNumber(episodes[9].url), 10)
        XCTAssertEqual(Webtoons.listURL(for: episodes.last!.url)?.absoluteString,
                       "https://www.webtoons.com/en/drama/lookism/list?title_no=1049")
        XCTAssertEqual(LinkedSource.styleHint(in: "", url: base), .manhwa)
    }

    func testCoverFoundInEveryCommonPlace() {
        let base = URL(string: "https://reader.example.com/series/solo/")!
        XCTAssertEqual(LinkedSource.cover(in: #"<meta content="https://cdn.example.com/c/solo.jpg" property="og:image">"#, base: base)?.lastPathComponent, "solo.jpg")
        XCTAssertEqual(LinkedSource.cover(in: #"<meta name="twitter:image" content="/covers/solo.webp">"#, base: base)?.absoluteString,
                       "https://reader.example.com/covers/solo.webp")
        XCTAssertEqual(LinkedSource.cover(in: #"<script type="application/ld+json">{"image":"https:\/\/cdn.example.com\/solo-400.webp"}</script>"#, base: base)?.absoluteString,
                       "https://cdn.example.com/solo-400.webp")
        let page = #"<img src="/img/logo.png" class="logo"><div class="summary_image"><img class="img-responsive" data-src="https://cdn.example.com/covers/solo.jpg" alt="Solo cover"></div>"#
        XCTAssertEqual(LinkedSource.cover(in: page, base: base)?.absoluteString, "https://cdn.example.com/covers/solo.jpg")
        XCTAssertNil(LinkedSource.cover(in: #"<meta property="og:image" content="https://reader.example.com/logo.png">"#, base: base))
    }

    func testHomePageWithManySeriesIsNotOneChapterList() {
        let home = URL(string: "https://manhwa.example.com/")!
        let html = """
        <a href="/series/alpha/chapter-12/">Chapter 12</a><a href="/series/beta/chapter-40/">Chapter 40</a>
        <a href="/series/gamma/chapter-7/">Chapter 7</a><a href="/series/delta/chapter-3/">Chapter 3</a>
        """
        XCTAssertTrue(LinkedSource.chapterLinks(in: html, base: home).isEmpty)
    }
}
