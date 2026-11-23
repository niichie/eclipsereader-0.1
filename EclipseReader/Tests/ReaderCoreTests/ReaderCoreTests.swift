import XCTest
@testable import ReaderCore

final class ReaderCoreTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }
    func testObservedIndexExcerpt() throws {
        let chapters = try ReadBerserkParser.chapters(in: fixture("index-excerpt"))
        XCTAssertEqual(chapters.map(\.number), ["384", "385", "386"])
        XCTAssertEqual(chapters.first?.published, "Jun 13, 2026")
        XCTAssertEqual(chapters.last?.url.absoluteString, "https://readberserk.com/chapter/berserk-chapter-386/")
    }
    func testCompleteObservedChapterTableAndPageMarkup() throws {
        let chapters = try ReadBerserkParser.chapters(in: fixture("index-observed"))
        XCTAssertEqual(chapters.count, 405)
        XCTAssertEqual(chapters.first?.number, "A0")
        XCTAssertEqual(chapters.last?.number, "386")
        let pages = try ReadBerserkParser.pages(in: fixture("chapter-observed"), chapterURL: ReadBerserkParser.home)
        XCTAssertEqual(pages.count, 25)
        XCTAssertEqual(pages.map { $0.url.lastPathComponent }, (1...25).map { "\($0).jpeg" })
    }
    func testObservedPageExcerptPreservesDOMOrderAndLazyURLs() throws {
        let pages = try ReadBerserkParser.pages(in: fixture("chapter-excerpt"), chapterURL: ReadBerserkParser.home)
        XCTAssertEqual(pages.count, 4)
        XCTAssertEqual(pages.map { $0.url.lastPathComponent }, ["1.jpeg", "2.jpeg", "3.jpeg", "4.jpeg"])
        XCTAssertEqual(pages.first?.label, "Berserk Chapter 384 - Page 1")
    }
    func testSourceOrderIncludesProloguesAndDecimals() throws {
        // Synthetic structural case. The application never constructs chapter URLs this way.
        let labels = ["100", "099.005", "099", "001", "P0", "B0", "A0"]
        let html = "<select>" + labels.map {
            "<option value='/chapter/test-\($0)/'>Berserk Chapter \($0)</option>"
        }.joined() + "</select>"
        XCTAssertEqual(try ReadBerserkParser.chapters(in: html).map(\.number), Array(labels.reversed()))
    }
    func testPredictionsAndExternalLinksAreExcluded() throws {
        let html = "<table><tr><td>Berserk Chapter 387 Predictions</td><td></td><td><a href='/chapter/predictions/'>Read</a></td></tr>" +
            "<tr><td>Berserk Chapter 386</td><td></td><td><a href='https://evil.invalid/chapter/386/'>Read</a></td></tr></table>"
        XCTAssertThrowsError(try ReadBerserkParser.chapters(in: html))
    }
    func testDuplicatePageRemovedAndAdvertisementIgnored() throws {
        let html = "<img src='https://cdn.readberserk.com/ad.jpeg'>" +
            "<img class='pages__img' src='https://cdn.readberserk.com/1.jpeg'>" +
            "<img class='pages__img' src='https://cdn.readberserk.com/1.jpeg'>"
        XCTAssertEqual(try ReadBerserkParser.pages(in: html, chapterURL: ReadBerserkParser.home).count, 1)
    }
    func testUnknownStructureFailsClearly() {
        XCTAssertThrowsError(try ReadBerserkParser.pages(in: "<p>Challenge</p>", chapterURL: ReadBerserkParser.home)) {
            XCTAssertEqual($0 as? SourceError, .unsupportedStructure)
        }
    }
    func testMissingImageURLFailsRatherThanSkippingAPage() {
        XCTAssertThrowsError(try ReadBerserkParser.pages(in: "<img class='pages__img'>", chapterURL: ReadBerserkParser.home)) {
            XCTAssertEqual($0 as? SourceError, .insecureURL)
        }
    }
    func testURLsRejectCredentialsInsecureSchemesAndLookalikeHosts() {
        for url in ["http://readberserk.com/chapter/1/", "https://readberserk.com.evil.invalid/1", "https://user:password@readberserk.com/", "javascript:alert(1)"] {
            XCTAssertNil(ReadBerserkParser.normalize(url, relativeTo: ReadBerserkParser.home))
        }
        XCTAssertNotNil(ReadBerserkParser.normalize("//cdn.readberserk.com/1.jpeg", relativeTo: ReadBerserkParser.home, image: true))
    }
    func testEntitiesAndQuotedGreaterThan() throws {
        let html = #"<img class='pages__img other' src='https://cdn.readberserk.com/page.jpeg?a=1&amp;b=2' alt='A > B &#38; C'>"#
        let page = try XCTUnwrap(ReadBerserkParser.pages(in: html, chapterURL: ReadBerserkParser.home).first)
        XCTAssertEqual(page.label, "A > B & C")
        XCTAssertEqual(page.url.query, "a=1&b=2")
    }
    func testRTLSpreadPlacesEarlierPageOnRight() {
        let groups = ReadingOrder.groups(count: 5, landscape: true, spreads: true, wide: [])
        XCTAssertEqual(groups.map(\.indices), [[0, 1], [2, 3], [4]])
        XCTAssertEqual(groups[0].displayOrder(.rightToLeft), [1, 0])
        XCTAssertEqual(groups[0].displayOrder(.leftToRight), [0, 1])
    }
    func testGenuineWideArtworkIsKeptWhole() {
        XCTAssertEqual(ReadingOrder.groups(count: 5, landscape: true, spreads: true, wide: [1, 4]).map(\.indices), [[0], [1], [2, 3], [4]])
    }
    func testResponsivePageGroupsKeepEveryLogicalPage() {
        for (width, height, paired) in [(390.0, 844.0, false), (951, 669, true), (669, 951, false),
                                         (320, 460, false), (1024, 768, true), (0, 0, false)] {
            let fits = ReadingOrder.canPair(width: width, height: height)
            XCTAssertEqual(fits, paired)
            let groups = ReadingOrder.groups(count: 9, landscape: fits, spreads: true, wide: [0, 4])
            XCTAssertEqual(groups.flatMap(\.indices), Array(0..<9))
            XCTAssertEqual(groups.first { $0.indices.contains(4) }?.indices, [4])
            let containing = groups.filter { $0.indices.contains(6) }
            XCTAssertEqual(containing.count, 1)
            XCTAssertEqual(containing[0].displayOrder(.rightToLeft), Array(containing[0].indices.reversed()))
        }
    }
    func testPortraitAndDisabledSpreadsUseSinglePages() {
        XCTAssertEqual(ReadingOrder.groups(count: 3, landscape: false, spreads: true, wide: []).map(\.indices), [[0], [1], [2]])
        XCTAssertEqual(ReadingOrder.groups(count: 2, landscape: true, spreads: false, wide: []).map(\.indices), [[0], [1]])
    }
    func testRequestedSwipeGesturesAndAlternateConvention() {
        XCTAssertEqual(ReadingOrder.destination(current: 1, count: 4, swipeLeft: true, advanceOnLeft: true), 2)
        XCTAssertEqual(ReadingOrder.destination(current: 1, count: 4, swipeLeft: false, advanceOnLeft: true), 0)
        XCTAssertEqual(ReadingOrder.destination(current: 1, count: 4, swipeLeft: false, advanceOnLeft: false), 2)
        XCTAssertNil(ReadingOrder.destination(current: 0, count: 4, swipeLeft: false, advanceOnLeft: true))
        XCTAssertNil(ReadingOrder.destination(current: 3, count: 4, swipeLeft: true, advanceOnLeft: true))
    }
    func testProgressPersistsAcrossRepositoryInstances() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        let chapter = Chapter(url: ReadBerserkParser.home, title: "Test", number: "1")
        var state = LibraryState(); state.chapters = [chapter]
        state.preferences.direction = .leftToRight; state.preferences.fit = .width
        state.record(chapter, page: 7, count: 20, completed: true)
        try StateRepository(url: url).save(state)
        let loaded = try StateRepository(url: url).load()
        XCTAssertEqual(loaded.lastChapterID, chapter.id)
        XCTAssertEqual(loaded.progress[chapter.id]?.page, 7)
        XCTAssertEqual(loaded.progress[chapter.id]?.completed, true)
        XCTAssertEqual(loaded.preferences, state.preferences)
    }
    func testCorruptedStateThrowsRatherThanSilentlyDiscarding() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("invalid".utf8).write(to: file)
        XCTAssertThrowsError(try StateRepository(url: file).load())
    }
    func testProgressClampsAndKeepsReadStatus() {
        let chapter = Chapter(url: ReadBerserkParser.home, title: "Test", number: "1")
        var state = LibraryState(); state.record(chapter, page: 100, count: 5, completed: true)
        XCTAssertEqual(state.progress[chapter.id]?.page, 4)
        state.record(chapter, page: -5, count: 5)
        XCTAssertEqual(state.progress[chapter.id]?.page, 0)
        XCTAssertEqual(state.progress[chapter.id]?.completed, true)
    }
    func testStatusFailures() {
        for status in [401, 403, 429] { XCTAssertThrowsError(try HTTPPolicy.validate(status: status)) { XCTAssertEqual($0 as? SourceError, .restricted) } }
        XCTAssertThrowsError(try HTTPPolicy.validate(status: 404)) { XCTAssertEqual($0 as? SourceError, .missingChapter) }
        XCTAssertThrowsError(try HTTPPolicy.validate(status: 503)) { XCTAssertEqual($0 as? SourceError, .unavailable(503)) }
        XCTAssertNoThrow(try HTTPPolicy.validate(status: 200))
    }
}

final class CacheAndNetworkTests: XCTestCase, @unchecked Sendable {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    func testCacheIsBoundedAndEvictsLeastRecentlyUsed() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = DiskImageCache(directory: dir, byteLimit: 1800)
        let a = URL(string: "https://cdn.readberserk.com/a.jpeg")!
        let b = URL(string: "https://cdn.readberserk.com/b.jpeg")!
        let c = URL(string: "https://cdn.readberserk.com/c.jpeg")!
        let now = Date()
        try await cache.insert(Data(repeating: 3, count: 600), for: a, now: now)
        try await cache.insert(Data(repeating: 5, count: 600), for: b, now: now.addingTimeInterval(1))
        _ = try await cache.data(for: a, now: now.addingTimeInterval(2))
        try await cache.insert(Data(repeating: 8, count: 600), for: c, now: now.addingTimeInterval(3))
        let size = try await cache.size()
        let old = try await cache.data(for: b, now: now.addingTimeInterval(4))
        let recent = try await cache.data(for: a, now: now.addingTimeInterval(4))
        XCTAssertLessThanOrEqual(size, 1800); XCTAssertNil(old); XCTAssertNotNil(recent)
    }
    func testCacheExpiresAndClears() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = DiskImageCache(directory: dir, lifetime: 10)
        let url = URL(string: "https://cdn.readberserk.com/a.jpeg")!
        let now = Date()
        try await cache.insert(Data([1, 2, 3]), for: url, now: now)
        let expired = try await cache.data(for: url, now: now.addingTimeInterval(11))
        XCTAssertNil(expired)
        try await cache.insert(Data([1]), for: url)
        try await cache.removeAll()
        let size = try await cache.size(); XCTAssertEqual(size, 0)
    }
    func testOversizedEntryIsNotStored() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = DiskImageCache(directory: dir, byteLimit: 32)
        try await cache.insert(Data(repeating: 0, count: 100), for: ReadBerserkParser.home)
        let size = try await cache.size(); XCTAssertEqual(size, 0)
    }
    func testPruningRemovesExpiredCacheWithoutARead() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let cache = DiskImageCache(directory: dir, lifetime: 10)
        try await cache.insert(Data([1, 2]), for: ReadBerserkParser.home, now: now)
        try await cache.prune(now: now.addingTimeInterval(11))
        let size = try await cache.size(); XCTAssertEqual(size, 0)
    }
    func testImagePipelineReusesCacheAndPrefetchIsBounded() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let transport = StubTransport(response: Data([1, 2, 3]))
        let pipeline = ImagePipeline(cache: DiskImageCache(directory: dir), http: transport)
        let chapter = Chapter(url: ReadBerserkParser.home, title: "Test", number: "1")
        let pages = (0..<8).map { MangaPage(url: URL(string: "https://cdn.readberserk.com/test-\($0).jpeg")!, label: "Test") }
        _ = try await pipeline.data(for: pages[0], chapter: chapter)
        _ = try await pipeline.data(for: pages[0], chapter: chapter)
        await pipeline.prefetch(Array(pages.dropFirst()), chapter: chapter)
        let requests = await transport.count
        XCTAssertEqual(requests, 3)
    }
    func testNetworkFailurePropagatesAndDoesNotEnterCache() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = DiskImageCache(directory: dir)
        let pipeline = ImagePipeline(cache: cache, http: StubTransport(failure: .timeout))
        do {
            _ = try await pipeline.data(for: MangaPage(url: ReadBerserkParser.home, label: "Missing"),
                chapter: Chapter(url: ReadBerserkParser.home, title: "Test", number: "1"))
            XCTFail("Expected a timeout")
        } catch { XCTAssertEqual(error as? SourceError, .timeout) }
        let size = try await cache.size(); XCTAssertEqual(size, 0)
    }
    func testCancelledImageRequestDoesNotStartNetworkWork() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let transport = StubTransport(response: Data([1]))
        let pipeline = ImagePipeline(cache: DiskImageCache(directory: dir), http: transport)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await pipeline.data(for: MangaPage(url: ReadBerserkParser.home, label: "Test"),
                    chapter: Chapter(url: ReadBerserkParser.home, title: "Test", number: "1"))
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let cancelled = await task.value
        let count = await transport.count
        XCTAssertTrue(cancelled); XCTAssertEqual(count, 0)
    }
    func testSourceAdapterUsesActualHTMLFixture() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "index-excerpt", withExtension: "html", subdirectory: "Fixtures"))
        let source = ReadBerserkSource(http: StubTransport(response: try Data(contentsOf: url)))
        let chapters = try await source.chapters()
        XCTAssertEqual(chapters.map(\.number), ["384", "385", "386"])
    }
}

private actor StubTransport: HTTPTransport {
    let response: Data
    let failure: SourceError?
    var count = 0
    init(response: Data = Data(), failure: SourceError? = nil) { self.response = response; self.failure = failure }
    func fetch(_ url: URL, referer: URL?, image: Bool) async throws -> Data {
        count += 1
        if let failure { throw failure }
        return response
    }
}
