import XCTest
@testable import ReaderCore

final class PanelDetectorTests: XCTestCase {
    /// A white page with dark panels drawn at the given pixel rectangles.
    private func page(_ w: Int, _ h: Int, _ panels: [(Int, Int, Int, Int)]) -> [UInt8] {
        var gray = [UInt8](repeating: 250, count: w * h)
        for (x, y, pw, ph) in panels {
            for yy in y..<(y + ph) { for xx in x..<(x + pw) { gray[yy * w + xx] = 60 } }
        }
        return gray
    }

    func testGridReadsRightToLeftForManga() {
        let gray = page(200, 300, [(10, 10, 85, 135), (105, 10, 85, 135), (10, 155, 85, 135), (105, 155, 85, 135)])
        let manga = PanelDetector.panels(gray: gray, width: 200, height: 300, rightToLeft: true)
        XCTAssertEqual(manga.count, 4)
        XCTAssertEqual(manga.map { $0.x > 0.4 }, [true, false, true, false])     // right, left, right, left
        XCTAssertEqual(manga.map { $0.y > 0.4 }, [false, false, true, true])     // top row first
        let comic = PanelDetector.panels(gray: gray, width: 200, height: 300, rightToLeft: false)
        XCTAssertEqual(comic.map { $0.x > 0.4 }, [false, true, false, true])
        XCTAssertEqual(manga[0].width, 85.0 / 200, accuracy: 0.01)
    }

    func testTallPanelBesideTwoStacked() {
        // Right: one tall panel. Left: two stacked. Manga reads the tall one first.
        let gray = page(200, 300, [(110, 10, 80, 280), (10, 10, 90, 135), (10, 155, 90, 135)])
        let panels = PanelDetector.panels(gray: gray, width: 200, height: 300, rightToLeft: true)
        XCTAssertEqual(panels.count, 3)
        XCTAssertGreaterThan(panels[0].x, 0.5)
        XCTAssertGreaterThan(panels[0].height, 0.9)
        XCTAssertLessThan(panels[1].y, panels[2].y)
    }

    func testBorderlessArtHasNoPanels() {
        let gray = page(200, 300, [(0, 0, 200, 300)])
        XCTAssertEqual(PanelDetector.panels(gray: gray, width: 200, height: 300, rightToLeft: true), [])
    }
}
