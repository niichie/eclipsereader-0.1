import Foundation

/// A comic panel, as a fraction of the page (0…1 on both axes, origin top-left).
public struct PanelRect: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}

/// Finds panels by their gutters (the plain white or black strips between them), cutting the page
/// into rows and then columns, recursively. Reading order: rows top to bottom; within a row,
/// right to left for manga, left to right for comics. Pages without clear gutters return no panels,
/// and the reader then shows the whole page.
public enum PanelDetector {
    private struct Region { var x0: Int, y0: Int, x1: Int, y1: Int
        var width: Int { x1 - x0 }; var height: Int { y1 - y0 }
    }

    /// `gray` is one byte per pixel, row 0 at the top. Works best at 300–500 px on the long side.
    public static func panels(gray: [UInt8], width: Int, height: Int, rightToLeft: Bool) -> [PanelRect] {
        guard width >= 40, height >= 40, gray.count >= width * height else { return [] }
        let white = backgroundIsWhite(gray, width: width, height: height)
        func blank(_ v: UInt8) -> Bool { white ? v >= 215 : v <= 40 }
        func rowBlank(_ y: Int, _ r: Region) -> Bool {
            var hits = 0
            let base = y * width
            for x in r.x0..<r.x1 where blank(gray[base + x]) { hits += 1 }
            return Double(hits) >= Double(r.width) * 0.985
        }
        func columnBlank(_ x: Int, _ r: Region) -> Bool {
            var hits = 0
            for y in r.y0..<r.y1 where blank(gray[y * width + x]) { hits += 1 }
            return Double(hits) >= Double(r.height) * 0.985
        }
        func trim(_ r: Region) -> Region? {
            var r = r
            while r.height > 0, rowBlank(r.y0, r) { r.y0 += 1 }
            while r.height > 0, rowBlank(r.y1 - 1, r) { r.y1 -= 1 }
            while r.width > 0, columnBlank(r.x0, r) { r.x0 += 1 }
            while r.width > 0, columnBlank(r.x1 - 1, r) { r.x1 -= 1 }
            return r.width > 4 && r.height > 4 ? r : nil
        }
        let minGap = max(2, Int(Double(min(width, height)) * 0.008))
        let minRun = Double(min(width, height)) * 0.05
        /// Content runs between gutters along one axis.
        func segments(count: Int, start: Int, isBlank: (Int) -> Bool) -> [(Int, Int)] {
            var result: [(Int, Int)] = []
            var runStart: Int?
            var gap = 0
            for i in start..<(start + count) {
                if isBlank(i) {
                    gap += 1
                    if gap >= minGap, let s = runStart { result.append((s, i - gap + 1)); runStart = nil }
                } else {
                    if runStart == nil { runStart = i }
                    gap = 0
                }
            }
            if let s = runStart {
                var end = start + count
                while end > s, isBlank(end - 1) { end -= 1 }
                result.append((s, end))
            }
            return result.filter { Double($0.1 - $0.0) >= minRun }
        }
        func cut(_ region: Region, depth: Int) -> [Region] {
            guard let r = trim(region) else { return [] }
            guard depth < 7 else { return [r] }
            let rows = segments(count: r.height, start: r.y0) { rowBlank($0, r) }
            if rows.count > 1 {
                return rows.flatMap { cut(Region(x0: r.x0, y0: $0.0, x1: r.x1, y1: $0.1), depth: depth + 1) }
            }
            let columns = segments(count: r.width, start: r.x0) { columnBlank($0, r) }
            if columns.count > 1 {
                let ordered = rightToLeft ? Array(columns.reversed()) : columns
                return ordered.flatMap { cut(Region(x0: $0.0, y0: r.y0, x1: $0.1, y1: r.y1), depth: depth + 1) }
            }
            return [r]
        }
        let page = Double(width * height)
        let found = cut(Region(x0: 0, y0: 0, x1: width, y1: height), depth: 0)
            .filter { Double($0.width * $0.height) >= page * 0.02 }
        guard found.count >= 2, found.count <= 16 else { return [] }
        return found.map {
            PanelRect(x: Double($0.x0) / Double(width), y: Double($0.y0) / Double(height),
                      width: Double($0.width) / Double(width), height: Double($0.height) / Double(height))
        }
    }

    /// Gutters match the page's border colour: white for most print, black for some.
    static func backgroundIsWhite(_ gray: [UInt8], width: Int, height: Int) -> Bool {
        var white = 0, black = 0
        let band = max(1, min(width, height) / 50)
        func count(_ v: UInt8) { if v >= 215 { white += 1 } else if v <= 40 { black += 1 } }
        for y in 0..<height where y < band || y >= height - band {
            for x in 0..<width { count(gray[y * width + x]) }
        }
        for y in band..<(height - band) {
            for x in 0..<band { count(gray[y * width + x]); count(gray[y * width + width - 1 - x]) }
        }
        return white >= black
    }
}
