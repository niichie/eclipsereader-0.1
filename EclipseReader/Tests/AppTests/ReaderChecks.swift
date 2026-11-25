import XCTest
import CoreImage
import SwiftUI
@testable import EclipseReader

/// Runs inside the real app on a simulator: downloads real books and chapters, opens them in the
/// actual reader screens, and waits for pages to appear. Run by the "Device checks" workflow.
@MainActor
final class ReaderChecks: XCTestCase {
    static let books: [(String, String)] = [
        ("Frankenstein (Standard Ebooks)", "https://standardebooks.org/ebooks/mary-shelley/frankenstein/downloads/mary-shelley_frankenstein.epub?source=download"),
        ("Pride and Prejudice (Standard Ebooks)", "https://standardebooks.org/ebooks/jane-austen/pride-and-prejudice/downloads/jane-austen_pride-and-prejudice.epub?source=download"),
        ("Alice (Project Gutenberg mirror, pictures)", "https://gutenberg.pglaf.org/cache/epub/11/pg11-images-3.epub"),
    ]
    func testQuoteArtworkIsVisibleAtCompactAndOpenWidths() async throws {
        let art = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 85)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 85))
        }
        let page = ReaderTestFixture.chapter
        let work = "One-Punch Man"
        let item = Spotlight(quote: LaunchQuote(text: "A quote", who: "Saitama", work: work), media: nil)
        let info = LinkInspection(title: work, cover: nil, pages: [], chapters: [page])
        let card = VerifiedQuote(item: item, destination: .manga(page.url, info), thumbnail: try XCTUnwrap(art.pngData()))
        for width: CGFloat in [300, 650] {
            let view = SpotlightCard(card: card, width: width, read: {}, next: {}, close: {}).frame(width: width)
            let fitting = UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 360))
            XCTAssertLessThan(fitting.height, width < 520 ? 120 : 145, "Short quotes should fit the artwork and controls")
            let window = show(view, size: CGSize(width: width, height: 360))
            let visible = await wait(5) {
                let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                guard let image = shot.cgImage,
                      let bitmap = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 256,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                      let data = bitmap.data else { return false }
                bitmap.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 48))
                let rgb = data.assumingMemoryBound(to: UInt8.self)
                return stride(from: 0, to: 64 * 48 * 4, by: 4).filter {
                    rgb[$0] > 220 && rgb[$0 + 1] < 30 && rgb[$0 + 2] < 30
                }.count > 12
            }
            XCTAssertTrue(visible, "Missing page artwork at width \(width)")
            window.isHidden = true
        }
    }

    func testPreparedQuoteKeepsOneThumbnailThroughCacheRestore() async throws {
        let chapter = ReaderTestFixture.chapter
        let title = "Tsubasa Reservoir Chronicle"
        let item = Spotlight(quote: LaunchQuote(text: "Fixture", who: "Sakura", work: title), media: nil)
        let artURL = URL(string: "eclipselib://fixture/cover")!
        let info = LinkInspection(title: title, cover: artURL, pages: [], chapters: [chapter])
        let source = ReaderTestFixture.render(chapter.url)
        let art = ReaderTestFixture.render(URL(string: "https://example.invalid/cover/tsubasa")!)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pipeline = ImagePipeline(cache: DiskImageCache(directory: directory), localData: { _ in art })
        let fallback = try XCTUnwrap(VerifiedQuote.thumbnailData(source))
        let card = VerifiedQuote(item: item, destination: .manga(chapter.url, info), thumbnail: fallback)
        let prepared = await card.preparedCover(using: pipeline)
        let selected = try XCTUnwrap(prepared.thumbnail)
        XCTAssertNotEqual(selected, fallback)
        let restored = try JSONDecoder().decode(VerifiedQuote.self, from: JSONEncoder().encode(prepared))
        XCTAssertEqual(restored.thumbnail, selected)
        let failed = ImagePipeline(cache: DiskImageCache(directory: directory), localData: { _ in Data() })
        let offline = await card.preparedCover(using: failed)
        XCTAssertEqual(offline.thumbnail, fallback)
    }

    func testQuoteCoversSurviveMissingMetadataAndCacheRoundTrip() throws {
        let series = URL(string: "https://example.org/series")!
        let cover = series.appendingPathComponent("cover.jpg")
        let alternate = series.appendingPathComponent("alternate.jpg")
        for work in ["One-Punch Man", "Your Lie in April"] {
            let quote = LaunchQuote(text: "Fixture", who: "Speaker", work: work)
            let item = Spotlight(quote: quote, media: nil)
            let info = LinkInspection(title: work, cover: cover, pages: [], chapters: [ReaderTestFixture.chapter])
            let card = VerifiedQuote(item: item, destination: .manga(series, info), searchCover: alternate)
            let cached = try JSONDecoder().decode(VerifiedQuote.self, from: JSONEncoder().encode(card))
            XCTAssertEqual(cached.coverURLs, [cover, alternate])
            let oldCard = VerifiedQuote(item: item, destination: .manga(series, info))
            XCTAssertEqual(oldCard.coverURLs, [cover])
        }
    }

    func testVerifiedQuoteCacheLoadsAndShufflesWithoutWaitingForSources() async throws {
        let model = model()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = QuoteCache(url: url)
        let settings = SpotlightStore.settings(for: model)
        let cards = (0..<5).map { index in
            let title = "Fixture work \(index)"
            let quote = LaunchQuote(text: "Fixture line \(index)", who: "Speaker", work: title)
            let info = NovelInfo(title: title, chapters: [ReaderTestFixture.chapter])
            return VerifiedQuote(item: Spotlight(quote: quote, media: nil), destination: .novel(url, info))
        }
        await cache.write(cards, settings: settings)
        let store = SpotlightStore(cache: cache)
        defer { store.reset() }
        await store.loadManga(owned: [], model: model)
        let first = try XCTUnwrap(store.manga)
        XCTAssertFalse(store.loadingManga)
        await store.nextManga(owned: [], model: model)
        let second = try XCTUnwrap(store.manga)
        XCTAssertNotEqual(first.work, second.work)
        XCTAssertNotNil(store.openVerified)
        XCTAssertFalse(store.loadingManga)
        let wrongSettings = await cache.read(settings: settings + "-changed")
        XCTAssertTrue(wrongSettings.isEmpty)
    }

    func testFullResolutionMangaKeepsEnhancedImageAtZoomAndRotation() async throws {
        let window = show(Color.black, size: CGSize(width: 390, height: 844))
        let canvas = ZoomPageView(frame: window.bounds)
        window.addSubview(canvas)
        let chapter = ReaderTestFixture.chapter
        let image = MangaPage(url: chapter.url.appendingPathComponent("0"), label: "Page 1")
        let cache = DiskImageCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let pipeline = ImagePipeline(cache: cache, http: ReaderTestFixture())
        var prefs = ReaderPreferences()
        prefs.enhance = true
        var ready = false
        canvas.configure(page: image, index: 0, chapter: chapter, pipeline: pipeline, preferences: prefs) { _, _ in ready = true }
        let loaded = await wait(12) { ready }
        XCTAssertTrue(loaded)
        canvas.layoutIfNeeded()
        let pageView = try XCTUnwrap(canvas.viewForZooming(in: canvas.scroll) as? UIImageView)
        let enhancedImage = try XCTUnwrap(pageView.image)
        let overlay = try XCTUnwrap(pageView.subviews.compactMap { $0 as? UIImageView }.first)
        canvas.scroll.setZoomScale(canvas.scroll.minimumZoomScale * 2, animated: false)
        canvas.scheduleDetail()
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertTrue(pageView.image === enhancedImage)
        XCTAssertNil(overlay.image, "The zoom tile must leave the full-resolution enhanced page visible")
        canvas.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        canvas.layoutIfNeeded()
        XCTAssertEqual(canvas.scroll.zoomScale / canvas.scroll.minimumZoomScale, 2, accuracy: 0.1)
        canvas.cancel()
        XCTAssertNil(canvas.decodedSize)
    }

    func testResumePartialOfflineChapterAndInvalidateChangedPages() async throws {
        let store = OfflineStore()
        let id = UUID().uuidString
        let pages = (1...3).map { MangaPage(url: URL(string: "https://example.invalid/\($0)")!, label: "page") }
        let first = try await store.resume(id, pages: pages)
        XCTAssertTrue(first.isEmpty)
        _ = try await store.write(id, index: 0, data: Data([1, 2]))
        let reopened = OfflineStore()
        let restored = try await reopened.resume(id, pages: pages)
        XCTAssertEqual(restored, ["0000.page"])
        let ids = await reopened.downloadedIDs()
        XCTAssertFalse(ids.contains(id))
        let changed = try await reopened.resume(id, pages: Array(pages.reversed()))
        XCTAssertTrue(changed.isEmpty)
        await reopened.remove(id)
    }

    func testPassageOffsetsSurvivePagination() throws {
        let text = "Snow. 🐈 Small ink strokes. Evening."
        let range = NSRange(location: 0, length: (text as NSString).length)
        let book = TypesetBook(sections: [NSAttributedString(string: text)],
                               pages: [BookPageRef(section: 0, range: range)], sectionStarts: [0], pageSize: .zero)
        let found = PassageTools.find("ink", in: [text], page: book.pages[0])
        let hit = try XCTUnwrap(found.first)
        book.applyHighlight(section: hit.section, offset: hit.offset, quote: hit.text)
        XCTAssertNotNil(book.text(of: 0).attribute(.backgroundColor, at: hit.offset, effectiveRange: nil))
    }

    /// A low-resolution black-and-white scan: grey paper, washed-out ink, JPEG.
    private func scanFixture(width: Int = 300, height: Int = 450, quality: CGFloat = 0.5) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let page = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor(white: 0.86, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let ink = UIColor(white: 0.2, alpha: 1)
            ink.setStroke()
            let bubble = UIBezierPath(ovalIn: CGRect(x: 20, y: 30, width: 260, height: 150)); bubble.lineWidth = 3; bubble.stroke()
            let text = NSAttributedString(string: "THE TIDE\nTURNS AT\nMIDNIGHT.", attributes: [
                .font: UIFont.boldSystemFont(ofSize: 22), .foregroundColor: ink])
            text.draw(in: CGRect(x: 95, y: 60, width: 180, height: 110))
            for y in stride(from: 220, to: 430, by: 7) {
                for x in stride(from: 20, to: 280, by: 7) {
                    ink.setFill(); UIBezierPath(ovalIn: CGRect(x: x, y: y, width: 3, height: 3)).fill()
                }
            }
        }
        let data = try XCTUnwrap(page.jpegData(compressionQuality: quality))
        return try XCTUnwrap(UIImage(data: data)?.cgImage)
    }
    private func grey(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self), count: width * height))
    }
    private func sharpness(_ g: [UInt8], width: Int, height: Int) -> Double {
        var total = 0.0
        for y in 1..<(height - 1) { for x in 1..<(width - 1) {
            let i = y * width + x
            total += abs(Double(g[i + 1]) - Double(g[i - 1])) + abs(Double(g[i + width]) - Double(g[i - width]))
        } }
        return total / Double(width * height)
    }

    /// Edge-setting variants on two hard cases, printed as crops for checking by eye: thin serif lettering
    /// on a black-and-white scan, and bold lettering on a heavily compressed colour page.
    private func printTuningVariants() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        func jpeg(_ image: UIImage, _ quality: CGFloat) throws -> CGImage {
            try XCTUnwrap(UIImage(data: try XCTUnwrap(image.jpegData(compressionQuality: quality)))?.cgImage)
        }
        let serif = try jpeg(UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { _ in
            UIColor(white: 0.87, alpha: 1).setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 400, height: 300))
            let ink = UIColor(white: 0.12, alpha: 1)
            let font = UIFont(name: "Georgia", size: 15) ?? .systemFont(ofSize: 15)
            NSAttributedString(string: "The lantern burns\nlow beneath a\nsilver evening.", attributes: [.font: font, .foregroundColor: ink])
                .draw(in: CGRect(x: 40, y: 50, width: 200, height: 100))
            for y in stride(from: 190, to: 290, by: 3) { for x in stride(from: 220, to: 390, by: 3) {
                ink.setFill(); UIBezierPath(ovalIn: CGRect(x: x, y: y, width: 1.4, height: 1.4)).fill()
            } }
        }, 0.7)
        let colour = try jpeg(UIGraphicsImageRenderer(size: CGSize(width: 600, height: 450), format: format).image { _ in
            UIColor.white.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 600, height: 450))
            UIColor(red: 0.93, green: 0.59, blue: 0.63, alpha: 1).setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 210, height: 450))
            UIColor.white.setFill(); UIBezierPath(ovalIn: CGRect(x: 130, y: 60, width: 420, height: 340)).fill()
            UIColor(white: 0.1, alpha: 1).setStroke()
            let bubble = UIBezierPath(ovalIn: CGRect(x: 130, y: 60, width: 420, height: 340)); bubble.lineWidth = 2; bubble.stroke()
            NSAttributedString(string: "WHEN DOES THE\nLAST TRAIN\nLEAVE TONIGHT?", attributes: [
                .font: UIFont.boldSystemFont(ofSize: 28), .foregroundColor: UIColor(white: 0.08, alpha: 1)])
                .draw(in: CGRect(x: 230, y: 165, width: 260, height: 120))
        }, 0.2)
        typealias Edge = PageEnhancer.Edge
        let greys: [(String, Edge)] = [
            ("g-old", Edge(denoise: 0.03, smoothing: 0.45, curve: 0.07, sharpenRadius: 0.6, sharpenAmount: 0.55)),
            ("g-std", PageEnhancer.Tuning.standard.grey),
            ("g-lighter", Edge(denoise: 0.03, smoothing: 0.1, curve: 0.17, sharpenRadius: 0.4, sharpenAmount: 0.3)),
        ]
        let colours: [(String, Edge)] = [
            ("c-old", Edge(denoise: 0.03, smoothing: 0.45, curve: 0.21, sharpenRadius: 0.6, sharpenAmount: 0.5)),
            ("c-std", PageEnhancer.Tuning.standard.colour),
            ("c-clean", Edge(denoise: 0.09, smoothing: 0.35, curve: 0.2, sharpenRadius: 0.5, sharpenAmount: 0.15)),
            ("c-soft", Edge(denoise: 0.06, smoothing: 0.45, curve: 0.22, sharpenRadius: 0.5, sharpenAmount: 0.1)),
        ]
        func crop(_ image: CGImage, _ rect: CGRect, _ name: String) throws {
            let cropped = try XCTUnwrap(image.cropping(to: rect))
            print("CHECK|image|\(name)|" + (try XCTUnwrap(UIImage(cgImage: cropped).pngData())).base64EncodedString())
        }
        for (name, edge) in greys {
            var tuning = PageEnhancer.Tuning.standard; tuning.grey = edge
            let out = try XCTUnwrap(PageEnhancer.enhance(serif, targetLongSide: 1200, tuning: tuning))
            try crop(out, CGRect(x: 120, y: 180, width: 720, height: 360), name)
        }
        for (name, edge) in colours {
            var tuning = PageEnhancer.Tuning.standard; tuning.colour = edge
            let out = try XCTUnwrap(PageEnhancer.enhance(colour, targetLongSide: 1440, tuning: tuning))
            try crop(out, CGRect(x: 520, y: 360, width: 720, height: 420), name)
        }
    }

    /// The enhancer upscales a soft scan to the target, makes paper white and ink black, sharpens
    /// lettering, keeps black-and-white pages grey (8-bit), and leaves clean full-size pages alone.
    func testEnhancerCleansAndUpscalesScans() throws {
        let scan = try scanFixture()
        let out = try XCTUnwrap(PageEnhancer.enhance(scan, targetLongSide: 1800))
        XCTAssertEqual(out.height, 1800)
        XCTAssertEqual(out.width, 1200)
        XCTAssertEqual(out.bitsPerPixel, 8, "black-and-white pages should be rendered as grey")
        let w = 1200, h = 1800
        let after = try grey(out, width: w, height: h)
        let before = try grey(scan, width: w, height: h)
        // Paper: a blank strip above the bubble. Ink: the darkest percent.
        func paper(_ g: [UInt8]) -> Double { (0..<(w * 60)).map { Double(g[$0 + w * 10]) }.reduce(0, +) / Double(w * 60) }
        func ink(_ g: [UInt8]) -> Double { let s = g.sorted(); return s.prefix(s.count / 100).map(Double.init).reduce(0, +) / Double(s.count / 100) }
        print("CHECK|enhance|paper \(paper(before)) → \(paper(after)); ink \(ink(before)) → \(ink(after)); sharpness \(sharpness(before, width: w, height: h)) → \(sharpness(after, width: w, height: h))")
        XCTAssertGreaterThan(paper(after), 245, "grey paper should come out white")
        XCTAssertLessThan(ink(after), 20, "washed-out ink should come out black")
        XCTAssertGreaterThan(sharpness(after, width: w, height: h), sharpness(before, width: w, height: h) * 1.15)
        try printTuningVariants()
        // A before/after crop of the lettering, for checking by eye in the log.
        let crop = CGRect(x: 300, y: 150, width: 640, height: 420)
        for (name, image) in [("before", before), ("after", after)] {
            let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            image.withUnsafeBytes { ctx.data?.copyMemory(from: $0.baseAddress!, byteCount: w * h) }
            let cropped = try XCTUnwrap(ctx.makeImage()?.cropping(to: crop))
            let png = try XCTUnwrap(UIImage(cgImage: cropped).pngData())
            print("CHECK|image|\(name)|" + png.base64EncodedString())
        }

        // Already clean and big enough: untouched.
        let clean = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 400, height: 600), format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
            UIColor.black.setFill(); ctx.fill(CGRect(x: 100, y: 100, width: 200, height: 200))
        }.cgImage)
        XCTAssertNil(PageEnhancer.enhance(clean, targetLongSide: 600))

        // Colour art keeps its colour.
        let colour = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 200, height: 300), format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { ctx in
            UIColor(red: 0.85, green: 0.3, blue: 0.25, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 150))
            UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 150, width: 200, height: 150))
        }.cgImage)
        let colourOut = try XCTUnwrap(PageEnhancer.enhance(colour, targetLongSide: 600))
        XCTAssertGreaterThan(colourOut.bitsPerPixel, 8, "colour pages must stay in colour")
        XCTAssertEqual(colourOut.height, 600)
    }

    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.isHidden = true; $0.rootViewController = nil }
        windows = []
    }

    private func model() -> LibraryModel { LibraryModel.current ?? LibraryModel() }

    /// Shows a SwiftUI screen in its own window at a given size, the way the app would.
    private func show<V: View>(_ view: V, size: CGSize) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIHostingController(rootView: view)
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        windows.append(window)
        return window
    }
    private func all<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        var found: [T] = []
        if let match = view as? T { found.append(match) }
        for child in view.subviews { found += all(type, in: child) }
        return found
    }
    private func labels(in view: UIView) -> [String] {
        var out: [String] = []
        if let label = view.accessibilityLabel, !label.isEmpty { out.append(label) }
        for child in view.subviews { out += labels(in: child) }
        return out
    }
    /// Polls until the condition holds or time runs out.
    private func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return condition()
    }
    private func attachScreenshot(_ window: UIWindow, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCatalogBookCanJoinLibraryWithoutDownloading() throws {
        let model = model()
        let original = model.state
        defer { model.state = original; model.save() }
        let page = try XCTUnwrap(URL(string: "https://example.org/book"))
        let epub = page.appendingPathExtension("epub")
        let book = FreeBook(id: "fixture", title: "Fixture", author: nil, cover: nil,
                            download: epub, page: page, detail: nil, source: "Fixture")
        let preview = model.previewBook(book, page: page, download: epub)
        XCTAssertFalse(preview.isLibraryMember)
        XCTAssertTrue(model.addToLibrary(preview).isLibraryMember)
        let saved = model.previewBook(book, page: page, download: epub)
        XCTAssertTrue(saved.isCatalogBookPreview)
        XCTAssertEqual(saved.url, page)
        XCTAssertNil(BookLink.file(of: saved.url))
        XCTAssertTrue(saved.chapters.isEmpty)
        XCTAssertEqual(model.librarySeries.filter { $0.id == saved.id }.count, 1)
    }

    func testPreviewProgressAndExplicitLibraryAddition() async throws {
        let model = model()
        let original = model.state
        defer { model.state = original; model.save() }
        let url = URL(string: "https://catalog.example/series")!
        let chapter = Chapter(url: url.appendingPathComponent("1"), title: "One", number: "1")
        let found = LinkInspection(title: "Fixture", cover: nil, pages: [], chapters: [chapter])
        guard case .series(let preview, _) = model.commit(url, found, addToShelf: false) else {
            return XCTFail("Expected series details")
        }
        XCTAssertFalse(model.librarySeries.contains { $0.id == preview.id })
        XCTAssertFalse(model.isFavorite(preview))
        XCTAssertFalse(model.isDownloaded(chapter))
        model.record(chapter, page: 1, count: 3)
        XCTAssertEqual(model.chapterIndex[chapter.id]?.0.id, preview.id)
        XCTAssertFalse(model.librarySeries.contains { $0.id == preview.id })
        _ = try await model.addLink(url.absoluteString)
        _ = model.addToLibrary(preview)
        XCTAssertEqual(model.librarySeries.filter { $0.id == preview.id }.count, 1)
        XCTAssertEqual(model.allSeries.filter { $0.id == preview.id }.count, 1)
        XCTAssertNotNil(model.state.progress[chapter.id])
    }

    // MARK: Books

    /// Every page of every section is accounted for: pagination never drops text.
    func testCatalogDownloadsJoinLibraryAndOpen() async throws {
        let library = model()
        let original = library.state
        defer { library.state = original; library.save() }
        let samples = [
            ("Frankenstein", Self.books[0].1),
            ("Alice", "https://www.gutenberg.org/ebooks/11.epub3.images"),
            ("Pan Tadeusz", "https://wolnelektury.pl/media/book/epub/pan-tadeusz.epub")
        ]
        for (title, address) in samples {
            let url = try XCTUnwrap(URL(string: address))
            let book = FreeBook(id: address, title: title, author: nil, cover: nil, download: url, page: url, detail: nil, source: "")
            let preview = library.previewBook(book, page: url, download: url)
            let saved = try await library.downloadBook(url)
            XCTAssertEqual(saved.id, preview.id)
            XCTAssertTrue(saved.isLibraryMember)
            let again = try await library.downloadBook(url)
            XCTAssertEqual(again.id, saved.id)
            XCTAssertEqual(library.librarySeries.filter { $0.id == saved.id }.count, 1)
            let chapter = try XCTUnwrap(saved.chapters.first)
            let window = show(BookReaderView(chapter: chapter).environmentObject(library), size: CGSize(width: 390, height: 844))
            let readable = await wait(30) { self.all(BookPageView.self, in: window).contains { $0.text.length > 0 } }
            window.isHidden = true
            XCTAssertTrue(readable, title)
        }
    }

    func testImportedFileJoinsLibraryAndOpens() async throws {
        let library = model()
        let original = library.state
        defer { library.state = original; library.save() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try "Once upon a time, a reader opened a book.".write(to: url, atomically: true, encoding: .utf8)
        let saved = try await library.importFiles([url], copy: true)
        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(library.librarySeries.contains { $0.id == saved.id })
        let chapter = try XCTUnwrap(saved.chapters.first)
        let window = show(BookReaderView(chapter: chapter).environmentObject(library), size: CGSize(width: 390, height: 844))
        let readable = await wait(30) { self.all(BookPageView.self, in: window).contains { $0.text.length > 0 } }
        window.isHidden = true
        XCTAssertTrue(readable)
    }

    func testRealBooksTypesetCompletely() async throws {
        let library = model()
        for (name, address) in Self.books {
            let file = try await WebsiteHTTPClient().downloadFile(URL(string: address)!)
            let series = try await library.importBook(file)
            guard let stored = BookLink.file(of: series.url) else { return XCTFail("\(name): no file") }
            let document = try await BookStore.shared.document(stored)
            var images: [String: Data] = [:]
            for section in document.sections {
                for case .image(let path) in section.blocks where images[path] == nil {
                    if let data = await BookStore.shared.image(stored, path: path) { images[path] = data }
                }
            }
            let pictures = images
            for size in [CGSize(width: 330, height: 700), CGSize(width: 250, height: 560), CGSize(width: 470, height: 820)] {
                let start = Date()
                let style = BookStyle(font: .newYork, size: 19, spacing: 1.4, margin: 1, justify: true, theme: .night)
                let book = await Task.detached { BookTypesetter.typeset(document, images: pictures, style: style, pageSize: size) }.value
                let seconds = Date().timeIntervalSince(start)
                print("CHECK|book|\(name)|\(Int(size.width))x\(Int(size.height))|\(book.pages.count) pages|\(String(format: "%.1fs", seconds))")
                XCTAssertGreaterThan(book.pages.count, 40, "\(name) at \(size): too few pages")
                XCTAssertLessThan(seconds, 25, "\(name) at \(size): typesetting too slow")
                for (index, text) in book.sections.enumerated() {
                    let covered = book.pages.filter { $0.section == index }.reduce(0) { $0 + $1.range.length }
                    XCTAssertEqual(covered, text.length, "\(name): section \(index) lost text in pagination")
                }
            }
            XCTAssertFalse((series.summary ?? "").contains("<"), "\(name): description shows HTML tags")
        }
    }

    /// Opens each book in the real reader screen and waits for typeset pages (no endless "Setting type…").
    func testBooksOpenInTheReader() async throws {
        let library = model()
        for (name, address) in Self.books.prefix(2) {
            let file = try await WebsiteHTTPClient().downloadFile(URL(string: address)!)
            let series = try await library.importBook(file)
            for size in [CGSize(width: 390, height: 844), CGSize(width: 300, height: 640)] {
                let window = show(BookReaderView(chapter: series.chapters[0]).environmentObject(library), size: size)
                let opened = await wait(30) { self.all(BookPageView.self, in: window).contains { $0.text.length > 0 } }
                attachScreenshot(window, "\(name) \(Int(size.width))pt")
                XCTAssertTrue(opened, "\(name) never showed a page at \(size) (labels: \(labels(in: window).prefix(8)))")
                // Turn a page with the reader's own controls and make sure text follows.
                if opened {
                    XCTAssertTrue(series.chapters.contains { $0.id == library.state.lastChapterID }, "Opening a book must update the recommendation seed before a page turn")
                    NotificationCenter.default.post(name: PageTurnInput.notification, object: nil, userInfo: ["forward": true])
                    try? await Task.sleep(for: .seconds(1))
                    XCTAssertTrue(all(BookPageView.self, in: window).contains { $0.text.length > 0 }, "\(name): blank after turning")
                }
                window.isHidden = true
            }
        }
    }

    // MARK: Manga

    /// A real chapter from each connected site opens in the manga reader and shows its first picture.
    func testChaptersOpenInTheReader() async throws {
        let library = model()
        let sources: [(String, SearchSource, String)] = [
            ("MangaDex", SearchSource(name: "MangaDex", kind: .mangaDex), "Chainsaw Man"),
            ("WeebCentral", SearchSource(name: "WeebCentral", kind: .weebCentral), "Jujutsu Kaisen"),
            ("WEBTOON", SearchSource(name: "WEBTOON", kind: .webtoons), "Tower of God"),
            ("Asura Scans", SearchSource(name: "Asura", kind: .site(URL(string: "https://asurascans.com/comics")!)), "murim login"),
            ("MangaDot", SearchSource(name: "MangaDot", kind: .site(URL(string: "https://mangadot.net/")!)), "Solo Leveling"),
        ]
        for (name, source, query) in sources {
            let hits: [DiscoverItem]
            do { hits = try await GlobalSearch.search(source, query: query) } catch { XCTFail("\(name): search failed: \(error)"); continue }
            guard let hit = hits.first else { XCTFail("\(name): no search results"); continue }
            let found = try await library.inspect(hit.url)
            guard let chapter = found.chapters.first else { XCTFail("\(name): no chapters"); continue }
            let window = show(ReaderView(chapter: chapter).environmentObject(library), size: CGSize(width: 390, height: 844))
            let shown = await wait(30) {
                self.all(UIImageView.self, in: window).contains { ($0.image?.size.width ?? 0) > 200 && !$0.isHidden && $0.alpha > 0 }
            }
            attachScreenshot(window, "\(name) chapter")
            print("CHECK|manga|\(name)|\(shown ? "page shown" : "NO PAGE")|\(chapter.url.absoluteString)")
            XCTAssertTrue(shown, "\(name): \(chapter.url) showed no page")
            window.isHidden = true
        }
    }

    /// Covers on the library home (Discover, Because you read) and search results load as pictures.
    func testCoversLoad() async throws {
        let library = model()
        let items = try await Discover.mangaDex(limit: 4)
        XCTAssertFalse(items.isEmpty)
        for item in items {
            guard let cover = item.cover else { XCTFail("\(item.title): no cover address"); continue }
            let data = try await library.pipeline.data(for: MangaPage(url: cover, label: "Cover"), chapter: Chapter(url: cover, title: "", number: ""))
            XCTAssertNotNil(UIImage(data: data), "\(item.title): cover isn't a picture")
        }
    }

    // MARK: Series with nothing to read

    /// Jujutsu Kaisen on MangaDex only links to the publisher: adding it must bring the chapters from another site.
    func testLicensedMangaDexSeriesIsAddedFromAnotherSite() async throws {
        let library = model()
        var request = URLRequest(url: URL(string: "https://api.mangadex.org/manga?title=Jujutsu%20Kaisen&limit=10&order%5Brelevance%5D=desc")!)
        request.setValue(WebsiteHTTPClient.appAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let list = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]]) ?? []
        print("CHECK|licensed|MangaDex titles: " + list.compactMap { ($0["attributes"] as? [String: Any]).flatMap(MangaDex.displayTitle) }.joined(separator: " | "))
        let id = try XCTUnwrap(list.first {
            ($0["attributes"] as? [String: Any]).flatMap(MangaDex.displayTitle).map { Discover.sameTitle($0, "Jujutsu Kaisen") } ?? false
        }?["id"] as? String)
        let readableHere = await MangaDex.hasReadableChapters(id, http: WebsiteHTTPClient())
        print("CHECK|licensed|MangaDex readable: \(String(describing: readableHere))")
        guard case .series(let series, _) = try await library.addLink("https://mangadex.org/title/\(id)") else {
            return XCTFail("Jujutsu Kaisen wasn't added as a series")
        }
        print("CHECK|licensed|added from \(series.url.absoluteString)|\(series.chapters.count) chapters|\(library.notice?.text ?? "-")")
        if readableHere == false {
            XCTAssertFalse(series.url.host?.contains("mangadex") ?? true, "a series with nothing to read was added from MangaDex")
        }
        XCTAssertGreaterThan(series.chapters.count, 100)
    }

    /// Neko-style merge: a MangaDex entry with nothing to read gets its chapters filled from another site.
    func testMissingChaptersAreFilledFromAnotherSite() async throws {
        let library = model()
        let series = MangaSeries(id: "check-merge-jjk", url: URL(string: "https://mangadex.org/title/c52b2ce3-7f95-469c-96b0-479524fb7a1a")!,
                                 title: "Jujutsu Kaisen", kind: .web, chapters: [])
        library.state.series = (library.state.series ?? []).filter { $0.id != series.id } + [series]
        defer { library.state.series = library.state.series?.filter { $0.id != series.id } }
        let result = await library.fillMissing(series)
        let after = library.state.series?.first { $0.id == series.id }
        print("CHECK|merge|\(result.map { "\($0.count) from \($0.host)" } ?? "none")|merged \(after?.merged?.absoluteString ?? "-")")
        XCTAssertGreaterThan(result?.count ?? 0, 100, "no chapters were filled in")
        XCTAssertNotNil(after?.merged)
        XCTAssertTrue(after?.chapters.allSatisfy { !($0.url.host ?? "").contains("mangadex") } ?? false)
    }

    /// Discover and "Because you read" only recommend titles MangaDex can actually show.
    func testRecommendationsAreReadable() async throws {
        let http = WebsiteHTTPClient()
        let popular = try await Discover.mangaDex(limit: 12)
        let similar = try await Discover.similar(to: "Vinland Saga", limit: 8)
        print("CHECK|recommend|popular: \(popular.map(\.title).joined(separator: ", "))")
        print("CHECK|recommend|because: \(similar.map(\.title).joined(separator: ", "))")
        XCTAssertFalse(popular.isEmpty)
        for item in popular + similar {
            let readable = await MangaDex.hasReadableChapters(item.id, http: http)
            XCTAssertNotEqual(readable, false, "\(item.title) has nothing to read but was recommended")
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Rapid page turns, a re-layout in the middle of a turn, and a jump: what crashed a few pages into a book.
    /// Kept synchronous on purpose: the page curl runs on the run loop below, with no async test frame
    /// alive around it (an async test frame here tripped XCTest's own task allocator).
    func testBookPagerSurvivesTurnsDuringRelayout() throws {
        let library = model()
        let style = BookStyle(font: .newYork, size: 19, spacing: 1.4, margin: 1, justify: true, theme: .night)
        let books = Holder<(TypesetBook, TypesetBook)>()
        let ready = expectation(description: "book typeset")
        Task { @MainActor in
            defer { ready.fulfill() }
            do {
                let file = try await WebsiteHTTPClient().downloadFile(URL(string: Self.books[0].1)!)
                let series = try await library.importBook(file)
                guard let stored = BookLink.file(of: series.url) else { return }
                let document = try await BookStore.shared.document(stored)
                books.value = (BookTypesetter.typeset(document, images: [:], style: style, pageSize: CGSize(width: 330, height: 700)),
                               BookTypesetter.typeset(document, images: [:], style: style, pageSize: CGSize(width: 330, height: 660)))
            } catch {
                books.failure = "\(error)"
            }
        }
        wait(for: [ready], timeout: 180)
        guard let (first, second) = books.value else { return XCTFail("couldn't open the book: \(books.failure ?? "no file")") }
        let pager = BookPagerController()
        let reported = Counter()
        pager.changed = { _ in reported.count += 1 }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = pager
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        windows.append(window)
        pager.configure(book: first, style: style, insets: UIEdgeInsets(top: 60, left: 30, bottom: 84, right: 30),
                        twoUp: false, curl: true, title: "Frankenstein", page: 0)
        func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        pump(0.3)
        for round in 0..<12 {
            pager.turn(forward: true)
            if round % 3 == 1 {
                // A re-layout arriving mid-turn (the status bar hiding used to do this).
                pager.configure(book: round % 2 == 0 ? first : second, style: style,
                                insets: UIEdgeInsets(top: round % 2 == 0 ? 60 : 40, left: 30, bottom: 84, right: 30),
                                twoUp: false, curl: true, title: "Frankenstein", page: pager.current)
            }
            if round % 4 == 2 { pager.jump(to: pager.current + 3, animated: true) }
            pump(round % 2 == 0 ? 0.06 : 0.45)
        }
        pump(1.5)
        pager.changed = nil
        print("CHECK|pager|turns reported \(reported.count), now on page \(pager.current + 1)")
        XCTAssertGreaterThan(pager.current, 3, "pages didn't advance")
        XCTAssertTrue(all(BookPageView.self, in: window).contains { $0.text.length > 0 }, "blank page after turning")
    }

    /// The whole reader on screen, turning pages while the safe area changes under it, the way hiding
    /// the status bar does. This re-laid out the book mid-turn and crashed a few pages in.
    func testBookReaderTurnsWhileTheStatusBarHides() async throws {
        let library = model()
        let file = try await WebsiteHTTPClient().downloadFile(URL(string: Self.books[1].1)!)
        let series = try await library.importBook(file)
        let host = UIHostingController(rootView: AnyView(BookReaderView(chapter: series.chapters[0]).environmentObject(library)))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        windows.append(window)
        let opened = await wait(40) { self.all(BookPageView.self, in: window).contains { $0.text.length > 0 } }
        XCTAssertTrue(opened, "the book never opened")
        guard opened else { return }
        let start = Date()
        for round in 0..<24 {
            NotificationCenter.default.post(name: PageTurnInput.notification, object: nil, userInfo: ["forward": true])
            // Status bar hiding and showing: the top safe area shrinks and grows mid-turn.
            host.additionalSafeAreaInsets.top = round % 3 == 0 ? 0 : 20
            try? await Task.sleep(for: .milliseconds(round % 2 == 0 ? 120 : 500))
        }
        try? await Task.sleep(for: .seconds(2))
        let pages = all(BookPageView.self, in: window)
        let folio = pages.first { $0.text.length > 0 }?.folio ?? "?"
        print("CHECK|reader|24 turns with the safe area changing in \(String(format: "%.1fs", Date().timeIntervalSince(start))), now on page \(folio)")
        XCTAssertTrue(pages.contains { $0.text.length > 0 }, "blank after turning")
        XCTAssertGreaterThan(Int(folio) ?? 0, 6, "pages didn't advance")
        attachScreenshot(window, "after turning")
    }
}

/// A reference counter for closures that outlive a test's own frame.
final class Counter { var count = 0 }
final class Holder<T> { var value: T?; var failure: String? }
