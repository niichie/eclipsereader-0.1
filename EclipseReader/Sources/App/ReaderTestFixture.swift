#if DEBUG
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Offline stand-in for websites, used by UI tests (`--reader-regression`) and the screenshot
/// tour (`--demo-library`). Every image is drawn on the fly, so nothing copyrighted is bundled.
struct ReaderTestFixture: MangaSource, HTTPTransport {
    static let chapter = Chapter(url: URL(string: "https://example.invalid/fixture")!, title: "Layout test", number: "1")
    static var demo: Bool { ProcessInfo.processInfo.arguments.contains("--demo-library") }
    init() {}

    func chapters() async throws -> [Chapter] {
        guard Self.demo else { return [Self.chapter] }
        return (1...42).map { Chapter(url: URL(string: "https://example.invalid/berserk/\($0)")!, title: "Episode \($0)", number: "\($0)",
                                      published: "Mar \($0 % 28 + 1), 2024") }
    }
    func pages(for chapter: Chapter) async throws -> [MangaPage] {
        let path = chapter.url.path
        if path.contains("strip") {
            return (0..<10).map { MangaPage(url: chapter.url.appendingPathComponent("s\($0)"), label: "Page \($0 + 1)", width: 800, height: 2400) }
        }
        let small = path.contains("fixture")
        return (0..<(small ? 8 : 18)).map {
            MangaPage(url: chapter.url.appendingPathComponent(String($0)), label: "Page \($0 + 1)",
                      width: small ? 400 : 800, height: small ? 660 : 1180)
        }
    }
    func fetch(_ url: URL, referer: URL?, image: Bool) async throws -> Data { Self.render(url) }

    // MARK: Drawing

    static func render(_ url: URL) -> Data {
        let path = url.path
        let seed = path.utf8.reduce(UInt64(5381)) { ($0 << 5) &+ $0 &+ UInt64($1) }
        if path.contains("/cover/") { return png(width: 420, height: 600) { cover($0, $1, seed) } }
        if path.contains("strip") { return png(width: 800, height: 2400) { strip($0, $1, seed, index: Int(path.split(separator: "s").last ?? "0") ?? 0) } }
        if path.contains("fixture") {
            return png(width: 400, height: 660) { context, size in
                context.setFillColor(UIColor.white.cgColor); context.fill(CGRect(origin: .zero, size: size))
                context.setStrokeColor(UIColor.black.cgColor); context.setLineWidth(4)
                context.stroke(CGRect(x: 8, y: 8, width: 384, height: 644))
            }
        }
        return png(width: 800, height: 1180) { page($0, $1, seed) }
    }
    private static func png(width: Int, height: Int, draw: (CGContext, CGSize) -> Void) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return Data() }
        // Draw with a top-left origin like UIKit.
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        draw(context, CGSize(width: width, height: height))
        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
    private static func color(_ seed: UInt64, _ shift: UInt64, saturation: CGFloat = 0.6, brightness: CGFloat = 0.55) -> CGColor {
        let hue = CGFloat((seed >> shift) % 360) / 360
        return UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1).cgColor
    }
    private static func cover(_ c: CGContext, _ size: CGSize, _ seed: UInt64) {
        let colors = [color(seed, 3, brightness: 0.35), color(seed, 11, saturation: 0.7, brightness: 0.75)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            c.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
        // A silhouette-like eclipse and diagonal speed lines.
        c.setFillColor(UIColor(white: 0, alpha: 0.85).cgColor)
        let r = size.width * 0.32
        c.fillEllipse(in: CGRect(x: size.width * 0.5 - r, y: size.height * 0.3 - r, width: r * 2, height: r * 2))
        c.setStrokeColor(UIColor(white: 1, alpha: 0.75).cgColor); c.setLineWidth(5)
        c.strokeEllipse(in: CGRect(x: size.width * 0.5 - r - 6, y: size.height * 0.3 - r - 6, width: r * 2 + 12, height: r * 2 + 12))
        c.setStrokeColor(UIColor(white: 1, alpha: 0.12).cgColor); c.setLineWidth(3)
        for i in stride(from: -600, through: 600, by: 26) {
            c.move(to: CGPoint(x: CGFloat(i), y: size.height)); c.addLine(to: CGPoint(x: CGFloat(i) + 500, y: size.height * 0.45))
        }
        c.strokePath()
        c.setFillColor(UIColor(white: 1, alpha: 0.9).cgColor)
        c.fill(CGRect(x: 30, y: size.height - 120, width: size.width * 0.7, height: 26))
        c.fill(CGRect(x: 30, y: size.height - 80, width: size.width * 0.45, height: 18))
    }
    private static func page(_ c: CGContext, _ size: CGSize, _ seed: UInt64) {
        c.setFillColor(UIColor.white.cgColor); c.fill(CGRect(origin: .zero, size: size))
        let m: CGFloat = 40, gap: CGFloat = 16
        let rows = 3 + Int(seed % 2)
        let h = (size.height - 2 * m - CGFloat(rows - 1) * gap) / CGFloat(rows)
        for row in 0..<rows {
            let y = m + CGFloat(row) * (h + gap)
            let split = 0.35 + CGFloat((seed >> UInt64(row * 3)) % 30) / 100
            let panels = (seed >> UInt64(row)) % 3 == 0 ? [CGRect(x: m, y: y, width: size.width - 2 * m, height: h)]
                : [CGRect(x: m, y: y, width: (size.width - 2 * m - gap) * split, height: h),
                   CGRect(x: m + (size.width - 2 * m - gap) * split + gap, y: y, width: (size.width - 2 * m - gap) * (1 - split), height: h)]
            for panel in panels {
                c.setFillColor(UIColor(white: 0.93 - CGFloat(row) * 0.05, alpha: 1).cgColor); c.fill(panel)
                c.setFillColor(UIColor(white: 0.25, alpha: 1).cgColor)
                c.fillEllipse(in: CGRect(x: panel.midX - 30, y: panel.midY - 30, width: 60, height: 60))
                c.setFillColor(UIColor.white.cgColor)
                c.fillEllipse(in: CGRect(x: panel.minX + 14, y: panel.minY + 14, width: min(150, panel.width * 0.5), height: 54))
                c.setStrokeColor(UIColor.black.cgColor); c.setLineWidth(2)
                c.strokeEllipse(in: CGRect(x: panel.minX + 14, y: panel.minY + 14, width: min(150, panel.width * 0.5), height: 54))
                c.setLineWidth(5); c.stroke(panel)
            }
        }
    }
    private static func strip(_ c: CGContext, _ size: CGSize, _ seed: UInt64, index: Int) {
        // Continuous gradient across strips: each strip continues the previous one's colour, so any seam would show.
        let top = UIColor(hue: CGFloat(index % 10) / 10, saturation: 0.45, brightness: 0.55, alpha: 1).cgColor
        let bottom = UIColor(hue: CGFloat((index + 1) % 10) / 10, saturation: 0.45, brightness: 0.55, alpha: 1).cgColor
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1]) {
            c.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
        c.setFillColor(UIColor.white.cgColor)
        c.fillEllipse(in: CGRect(x: 80, y: 300, width: 360, height: 140))
        c.setStrokeColor(UIColor.black.cgColor); c.setLineWidth(4)
        c.strokeEllipse(in: CGRect(x: 80, y: 300, width: 360, height: 140))
        c.setFillColor(UIColor(white: 0, alpha: 0.75).cgColor)
        c.fill(CGRect(x: 120, y: 900, width: 560, height: 700))
    }

    // MARK: Demo library

    @MainActor static func demoState() -> LibraryState {
        var state = LibraryState()
        state.showsBerserk = true
        state.defaultsVersion = 4
        state.chapters = (1...42).map { Chapter(url: URL(string: "https://example.invalid/berserk/\($0)")!, title: "Episode \($0)", number: "\($0)",
                                                published: "Mar \($0 % 28 + 1), 2024") }
        state.covers = ["berserk": URL(string: "https://example.invalid/cover/berserk")!]
        func series(_ slug: String, _ title: String, count: Int, strip: Bool = false, ago: Double) -> MangaSeries {
            let chapters = (1...count).map { n in
                Chapter(url: URL(string: "https://example.invalid/\(slug)/\(strip ? "strip-" : "")\(n)")!,
                        title: "Chapter \(n) Mar \(n % 28 + 1), 2024", number: "\(n)")
            }
            return MangaSeries(id: "web-demo-\(slug)", url: URL(string: "https://example.invalid/\(slug)")!, title: title,
                               cover: URL(string: "https://example.invalid/cover/\(slug)")!, kind: .web, chapters: chapters,
                               added: Date().addingTimeInterval(-ago))
        }
        let list = [
            series("solo", "Shadow Ascendant: The Lone Hunter Who Levelled Up", count: 201, strip: true, ago: 100),
            series("moon", "Moonlit Blade", count: 64, ago: 200),
            series("step", "Step by Step", count: 23, strip: true, ago: 300),
            series("crow", "Crow’s Requiem", count: 12, ago: 400),
            series("tide", "The Tide Archive", count: 88, ago: 500),
            series("ember", "Ember Saint", count: 5, ago: 600),
        ]
        state.series = list
        state.detectedStyles = ["web-demo-solo": .manhwa, "web-demo-step": .manhwa, "web-demo-tide": .comic]
        for chapter in list[1].chapters.prefix(20) { state.record(chapter, page: 17, count: 18, completed: true) }
        state.record(list[1].chapters[20], page: 6, count: 18)
        for chapter in state.chapters.prefix(9) { state.record(chapter, page: 17, count: 18, completed: true) }
        state.record(list[0].chapters[2], page: 4, count: 10)
        state.newChapterIDs = list[0].chapters.suffix(3).map(\.id) + list[3].chapters.suffix(1).map(\.id)
        state.lastUpdateCheck = Date()
        return state
    }
}
#endif
