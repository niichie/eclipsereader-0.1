#if DEBUG
import UIKit

struct ReaderTestFixture: MangaSource, HTTPTransport {
    static let chapter = Chapter(url: URL(string: "https://example.invalid/fixture")!, title: "Layout test", number: "1")
    let image: Data
    @MainActor init() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: 400, height: 660)
        image = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setStroke()
            context.cgContext.stroke(CGRect(x: 8, y: 8, width: 384, height: 644), width: 4)
        }
    }
    func chapters() async throws -> [Chapter] { [Self.chapter] }
    func pages(for chapter: Chapter) async throws -> [MangaPage] {
        (0..<8).map { MangaPage(url: chapter.url.appendingPathComponent(String($0)), label: "Fixture page \($0 + 1)", width: 400, height: 660) }
    }
    func fetch(_ url: URL, referer: URL?, image: Bool) async throws -> Data { self.image }
}
#endif
