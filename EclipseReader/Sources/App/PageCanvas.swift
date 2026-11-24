import UIKit
import ImageIO

private struct DecodedImage: @unchecked Sendable {
    let image: UIImage
    let sourceRegion: CGRect
    let needsTiles: Bool
    let ratio: Double
}
/// Picks how many pixels to decode per page for this device: its screen's real pixel size,
/// headroom for zooming, its memory, and Low Power Mode.
@MainActor
enum DisplayQuality {
    static func longSide(_ quality: ImageQuality) -> Double {
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.nativeBounds.size
            ?? CGSize(width: 1290, height: 2796)
        let long = Double(max(screen.width, screen.height))
        let roomy = ProcessInfo.processInfo.physicalMemory >= 7_500_000_000
        switch quality {
        case .dataSaver:
            return min(max(long, 1600), 2560)
        case .maximum:
            return roomy ? 8192 : 6144
        case .automatic:
            var factor = roomy ? 2.0 : 1.5          // room to zoom in before detail runs out
            if ProcessInfo.processInfo.isLowPowerModeEnabled { factor = 1.2 }
            return min(max(long * factor, 2048), roomy ? 6144 : 4096)
        }
    }
}

private actor PageDecoder {
    static let shared = PageDecoder()
    func render(_ data: Data, trim: Bool, limit: Double, enhance: Bool, strength: Double, half: MangaPage.Half?) throws -> DecodedImage {
        try Task.checkCancellation()
        return try Self.decode(data, trim: trim, limit: limit, enhance: enhance, strength: strength, half: half)
    }
    func panels(_ source: PanelSource, rtl: Bool) throws -> [PanelRect] {
        try Task.checkCancellation()
        return PanelSource.detect(source, rightToLeft: rtl)
    }
    func tile(_ data: Data, region: CGRect, pixels: CGSize, strength: Double?) throws -> UIImage? {
        try Task.checkCancellation()
        guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let bounds = source.extent
        let rect = CGRect(x: bounds.minX + region.minX * bounds.width, y: bounds.maxY - region.maxY * bounds.height,
                          width: region.width * bounds.width, height: region.height * bounds.height)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let scale = min(pixels.width / rect.width, pixels.height / rect.height, 2,
                        sqrt(4_000_000 / (rect.width * rect.height)))
        var content = source
        if let strength { content = content.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": strength, "inputSharpness": 0]) }
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let output = content.transformed(by: transform)
        guard let cg = PageEnhancer.context.createCGImage(output, from: rect.applying(transform).integral) else { return nil }
        return UIImage(cgImage: cg)
    }
    /// Normal pages decode to the device's quality limit on the long side. Webtoon strips (tall and
    /// narrow) keep their full width so text stays sharp, up to 16384 px tall.
    static func maxPixels(width: Double, height: Double, limit: Double = 4096) -> Double {
        let long = max(width, height)
        if height > width * 2.5 && width <= 1600 { return min(long, 16384) }
        return min(long, limit)
    }
    static func decode(_ data: Data, trim: Bool = true, limit: Double = 4096, enhance: Bool = false, strength: Double = 0.035,
                       half: MangaPage.Half? = nil) throws -> DecodedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0, width * height <= 120_000_000,
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true,
                 kCGImageSourceCreateThumbnailWithTransform: true,
                 kCGImageSourceShouldCacheImmediately: true,
                 kCGImageSourceThumbnailMaxPixelSize: min(maxPixels(width: width, height: height, limit: limit), max(width, height) * sqrt(8_000_000 / (width * height)))] as CFDictionary)
        else { throw SourceError.invalidImage }
        var base = cg
        var left = 0.0
        if let half, cg.width > 1 {
            let mid = cg.width / 2
            let rect = half == .left ? CGRect(x: 0, y: 0, width: mid, height: cg.height)
                                     : CGRect(x: mid, y: 0, width: cg.width - mid, height: cg.height)
            if let cropped = cg.cropping(to: rect) { base = cropped; left = rect.minX }
        }
        let full = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let crop = trim ? (cropMargins(base) ?? full) : full
        var final = base.cropping(to: crop) ?? base
        let region = CGRect(x: (left + crop.minX) / CGFloat(cg.width), y: crop.minY / CGFloat(cg.height),
                            width: crop.width / CGFloat(cg.width), height: crop.height / CGFloat(cg.height))
        if enhance {
            let target = final.height > final.width * 3
                ? 1440 * Double(final.height) / Double(final.width)
                : limit * 0.66
            final = PageEnhancer.enhance(final, targetLongSide: target, strength: strength) ?? final
        }
        return DecodedImage(image: UIImage(cgImage: final), sourceRegion: region, needsTiles: width * height > 8_000_000, ratio: Double(final.width) / Double(final.height))
    }
    /// Removes plain white or black scan margins (the bars beside single pages).
    /// Conservative: an edge row/column is trimmed only when ~98% of it is blank,
    /// and never more than 15% per side, so artwork is not cut.
    static func cropMargins(_ image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        guard w > 32, h > 32 else { return nil }
        let scale = min(1, 400.0 / Double(max(w, h)))
        let sw = max(1, Int(Double(w) * scale)), sh = max(1, Int(Double(h) * scale))
        var pixels = [UInt8](repeating: 0, count: sw * sh)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: sw,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: sw, height: sh))
            return true
        }
        guard drawn else { return nil }
        // Row 0 of the buffer is the top of the image.
        func blank(_ values: [UInt8], white: Bool) -> Bool {
            let hits = values.reduce(0) { $0 + ((white ? $1 >= 225 : $1 <= 30) ? 1 : 0) }
            return Double(hits) >= Double(values.count) * 0.98
        }
        func column(_ x: Int) -> [UInt8] { (0..<sh).map { pixels[$0 * sw + x] } }
        func row(_ y: Int) -> [UInt8] { Array(pixels[(y * sw)..<(y * sw + sw)]) }
        func edge(count: Int, line: (Int) -> [UInt8], reversed: Bool) -> Int {
            let limit = Int(Double(count) * 0.15)
            var best = 0
            for white in [true, false] {
                var n = 0
                while n < limit, blank(line(reversed ? count - 1 - n : n), white: white) { n += 1 }
                best = max(best, n)
            }
            return best
        }
        // Keep a little paper around the art so text never sits flush against the screen edge.
        let padX = max(1, Int(Double(sw) * 0.018)), padY = max(1, Int(Double(sh) * 0.012))
        let left = max(0, edge(count: sw, line: column, reversed: false) - padX)
        let right = max(0, edge(count: sw, line: column, reversed: true) - padX)
        let top = max(0, edge(count: sh, line: row, reversed: false) - padY)
        let bottom = max(0, edge(count: sh, line: row, reversed: true) - padY)
        guard left + right + top + bottom > 0 else { return nil }
        let fx = Double(w) / Double(sw), fy = Double(h) / Double(sh)
        let rect = CGRect(x: Double(left) * fx, y: Double(top) * fy,
                          width: Double(sw - left - right) * fx, height: Double(sh - top - bottom) * fy).integral
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard rect.width > Double(w) * 0.6, rect.height > Double(h) * 0.6 else { return nil }
        return rect
    }
}

/// Hands a decoded page to the panel finder at a small, fast size.
private struct PanelSource: @unchecked Sendable {
    let image: CGImage
    static func detect(_ source: PanelSource, rightToLeft: Bool) -> [PanelRect] {
        let image = source.image
        let scale = min(1, 420.0 / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        var gray = [UInt8](repeating: 255, count: w * h)
        let drawn: Bool = gray.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return [] }
        return PanelDetector.panels(gray: gray, width: w, height: h, rightToLeft: rightToLeft)
    }
}

@MainActor
final class ZoomPageView: UIView, UIScrollViewDelegate {
    let scroll = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let retry = UIButton(type: .system)
    private let message = UILabel()
    private var work: Task<Void, Never>?
    private let detail = UIImageView()
    private var detailWork: Task<Void, Never>?
    private var originalData: Data?
    private var sourceRegion = CGRect.zero
    private var needsTiles = false
    private var comparing = false
    private var lastSize = CGSize.zero
    private var baseScale: CGFloat = 1
    private var preference = ReaderPreferences()
    private var start: (() -> Void)?
    enum Alignment { case center, leftEdge, rightEdge }
    var alignment: Alignment = .center
    /// Single tap, with where it landed across the screen (0 = left edge, 1 = right edge).
    var tapped: ((CGFloat) -> Void)?
    /// Part of a continuous vertical strip: pinned to the top, sub-pixel overflow ignored.
    var seamless = false
    private(set) var pageIndex = 0
    /// Guided view: the page's panels in reading order, and which one is showing (-1 = the whole page).
    private var panels: [PanelRect] = []
    private var panelIndex = -1
    private var panelWork: Task<Void, Never>?
    /// Posted with the page index when "Set as cover" is chosen from a page's long-press menu.
    static let useAsCover = Notification.Name("EclipseUsePageAsCover")
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        scroll.delegate = self; scroll.backgroundColor = .black
        scroll.showsVerticalScrollIndicator = false; scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.bouncesZoom = true; scroll.alwaysBounceHorizontal = false; scroll.alwaysBounceVertical = false; scroll.isDirectionalLockEnabled = true
        imageView.contentMode = .scaleAspectFit
        imageView.addSubview(detail)
        let compare = UILongPressGestureRecognizer(target: self, action: #selector(compareOriginal(_:)))
        compare.numberOfTouchesRequired = 2
        scroll.addGestureRecognizer(compare)
        // Smooth downscaling (mipmapped) keeps screentones and crosshatching free of shimmering moiré.
        imageView.layer.minificationFilter = .trilinear
        imageView.layer.magnificationFilter = .linear
        addSubview(scroll); scroll.addSubview(imageView)
        addSubview(spinner); addSubview(message); addSubview(retry)
        message.textColor = .lightGray; message.font = .preferredFont(forTextStyle: .subheadline)
        message.numberOfLines = 0; message.textAlignment = .center
        retry.setTitle("Retry page", for: .normal); retry.tintColor = .white
        retry.addTarget(self, action: #selector(retryPage), for: .touchUpInside)
        retry.isHidden = true
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(zoom(_:)))
        doubleTap.numberOfTapsRequired = 2; scroll.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(toggleControls(_:)))
        singleTap.require(toFail: doubleTap); scroll.addGestureRecognizer(singleTap)
        scroll.accessibilityLabel = "Manga page. Pinch or double tap to zoom."
        scroll.addInteraction(UIContextMenuInteraction(delegate: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    deinit { work?.cancel() }
    func configure(page: MangaPage, index: Int, chapter: Chapter, pipeline: ImagePipeline,
                   preferences: ReaderPreferences, loaded: @escaping (Int, Double) -> Void) {
        preference = preferences
        pageIndex = index
        imageView.accessibilityIdentifier = "art-\(index)"
        imageView.accessibilityLabel = page.label; imageView.isAccessibilityElement = false
        start = { [weak self] in
            guard let self else { return }
            clearDetail(); work?.cancel(); imageView.image = nil; imageView.isAccessibilityElement = false; message.text = nil; retry.isHidden = true; spinner.startAnimating()
            let trim = preferences.trimMargins ?? true
            let enhance = preferences.enhance ?? false
            let limit = DisplayQuality.longSide(preferences.quality ?? .automatic)
            work = Task { [weak self] in
                do {
                    let data = try await pipeline.data(for: page, chapter: chapter)
                    try Task.checkCancellation()
                    let half = page.half
                    let decoded = try await PageDecoder.shared.render(data, trim: trim, limit: limit, enhance: enhance,
                                                                      strength: preferences.cleanupStrength ?? 0.035, half: half)
                    try Task.checkCancellation()
                    guard let self else { return }
                    originalData = data; sourceRegion = decoded.sourceRegion; needsTiles = decoded.needsTiles
                    spinner.stopAnimating(); imageView.image = decoded.image
                    resetFit(); loaded(index, decoded.ratio)
                    findPanels(rightToLeft: preferences.direction == .rightToLeft)
                } catch is CancellationError { }
                catch let e as URLError where e.code == .cancelled { }
                catch {
                    guard let self, !Task.isCancelled else { return }
                    if error as? SourceError == .invalidImage { await pipeline.cache.remove(page.url) }
                    spinner.stopAnimating(); message.text = error.localizedDescription
                    retry.isHidden = false
                }
            }
        }
        start?()
    }
    func cancel() { clearDetail(); work?.cancel(); work = nil; panelWork?.cancel(); start = nil; imageView.image = nil }

    // MARK: Guided view
    private func findPanels(rightToLeft: Bool) {
        panels = []; panelIndex = -1; panelWork?.cancel()
        guard preference.guided == true, preference.mode == .paged, let cg = imageView.image?.cgImage else { return }
        let box = PanelSource(image: cg)
        panelWork = Task { [weak self] in
            let found = (try? await PageDecoder.shared.panels(box, rtl: rightToLeft)) ?? []
            guard !Task.isCancelled, let self else { return }
            self.panels = found
        }
    }
    /// Moves to the next or previous panel. Returns false when the page should turn instead.
    func stepPanel(forward: Bool) -> Bool {
        guard preference.guided == true, panels.count >= 2, imageView.image != nil else { return false }
        if forward {
            guard panelIndex < panels.count - 1 else { panelIndex = -1; return false }
            panelIndex += 1
        } else {
            guard panelIndex >= 0 else { return false }
            panelIndex -= 1
        }
        showPanel()
        return true
    }
    private func showPanel() {
        let animated = !UIAccessibility.isReduceMotionEnabled
        guard panels.indices.contains(panelIndex), let image = imageView.image else {
            UIView.animate(withDuration: animated ? 0.35 : 0) { self.scroll.setZoomScale(self.baseScale, animated: false); self.centerImage() }
            return
        }
        let panel = panels[panelIndex]
        let size = image.size
        // A little paper around the panel, then fit it to the screen's shape.
        var rect = CGRect(x: panel.x * size.width, y: panel.y * size.height, width: panel.width * size.width, height: panel.height * size.height)
            .insetBy(dx: -size.width * 0.015, dy: -size.height * 0.015)
            .intersection(CGRect(origin: .zero, size: size))
        let aspect = bounds.width / max(1, bounds.height)
        if rect.width / rect.height > aspect {
            let h = rect.width / aspect; rect = rect.insetBy(dx: 0, dy: -(h - rect.height) / 2)
        } else {
            let w = rect.height * aspect; rect = rect.insetBy(dx: -(w - rect.width) / 2, dy: 0)
        }
        UIView.animate(withDuration: animated ? 0.38 : 0, delay: 0, options: [.curveEaseInOut]) {
            self.scroll.zoom(to: rect, animated: false)
        }
    }
    func suspend() { clearDetail(); panelWork?.cancel(); work?.cancel(); work = nil; imageView.image = nil }
    func resume() { if imageView.image == nil && work == nil { start?() } }
    func updatePreferences(_ preferences: ReaderPreferences) {
        let changedFit = preference.fit != preferences.fit
        let changedTrim = (preference.trimMargins ?? true) != (preferences.trimMargins ?? true)
        preference = preferences
        if changedTrim { start?() } else if changedFit { resetFit() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let previousCenter = imageView.convert(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), from: scroll)
        let relative = scroll.zoomScale / max(0.001, baseScale)
        scroll.frame = bounds
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        message.frame = CGRect(x: 16, y: bounds.midY - 70, width: max(0, bounds.width - 32), height: 110)
        retry.frame = CGRect(x: 16, y: bounds.midY + 45, width: max(0, bounds.width - 32), height: 50)
        if lastSize != bounds.size {
            let restore = lastSize != .zero && relative > 1.01
            lastSize = bounds.size
            resetFit()
            if restore {
                let zoom = min(scroll.maximumZoomScale, baseScale * relative)
                let size = CGSize(width: bounds.width / zoom, height: bounds.height / zoom)
                scroll.zoom(to: CGRect(x: previousCenter.x - size.width / 2, y: previousCenter.y - size.height / 2,
                                       width: size.width, height: size.height), animated: false)
            }
        }
        scheduleDetail()
    }
    private func resetFit() {
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0 else { return }
        panelIndex = -1
        scroll.minimumZoomScale = 0.001; scroll.maximumZoomScale = 8
        scroll.zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: image.size); scroll.contentSize = image.size
        let width = bounds.width / image.size.width
        let height = bounds.height / image.size.height
        baseScale = preference.fit == .width ? width : min(width, height)
        scroll.minimumZoomScale = baseScale
        scroll.maximumZoomScale = max(baseScale * 6, 2)
        scroll.setZoomScale(baseScale, animated: false)
        centerImage()
        imageView.isAccessibilityElement = true
        scroll.contentOffset = .zero
    }
    private func centerImage() {
        // Center by positioning the image view itself. contentInset/contentOffset
        // centering was clamped by UIScrollView and left pages stranded at an edge.
        scroll.contentInset = .zero
        let size = imageView.frame.size
        let spareX = max(0, bounds.width - size.width)
        let x: CGFloat
        switch alignment {
        case .center: x = spareX * 0.5
        case .leftEdge: x = 0
        case .rightEdge: x = spareX
        }
        imageView.frame.origin = CGPoint(x: x, y: seamless ? 0 : max(0, bounds.height - size.height) * 0.5)
        let slack: CGFloat = seamless ? 2 : 0.5
        scroll.panGestureRecognizer.isEnabled = size.width > bounds.width + slack || size.height > bounds.height + slack
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }
    private func clearDetail() {
        detailWork?.cancel(); detail.image = nil; originalData = nil; comparing = false
    }
    @objc private func compareOriginal(_ gesture: UILongPressGestureRecognizer) {
        comparing = gesture.state == .began || gesture.state == .changed
        scheduleDetail()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { scheduleDetail() }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { scheduleDetail() }
    private func scheduleDetail() {
        detailWork?.cancel()
        guard let data = originalData, scroll.zoomScale > baseScale * 1.05 || comparing || needsTiles else {
            detail.image = nil
            return
        }
        let box = imageView.bounds
        let visible = imageView.convert(scroll.bounds, from: scroll).intersection(box)
        guard !visible.isEmpty, !visible.isNull, box.width > 0, box.height > 0 else { return }
        let region = CGRect(x: sourceRegion.minX + visible.minX / box.width * sourceRegion.width,
                            y: sourceRegion.minY + visible.minY / box.height * sourceRegion.height,
                            width: visible.width / box.width * sourceRegion.width,
                            height: visible.height / box.height * sourceRegion.height)
        let density = scroll.zoomScale * traitCollection.displayScale
        let pixels = CGSize(width: visible.width * density, height: visible.height * density)
        let strength = !comparing && preference.enhance == true ? preference.cleanupStrength ?? 0.035 : nil
        detailWork = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                let tile = try await PageDecoder.shared.tile(data, region: region, pixels: pixels, strength: strength)
                try Task.checkCancellation()
                self?.detail.frame = visible
                self?.detail.image = tile
            } catch {}
        }
    }
    @objc private func retryPage() { start?() }
    @objc private func toggleControls(_ recognizer: UITapGestureRecognizer) {
        let width = window?.bounds.width ?? bounds.width
        let x = recognizer.location(in: window ?? self).x
        tapped?(width > 0 ? min(1, max(0, x / width)) : 0.5)
    }
    @objc private func zoom(_ recognizer: UITapGestureRecognizer) {
        guard imageView.image != nil else { return }
        if scroll.zoomScale > baseScale * 1.05 { scroll.setZoomScale(baseScale, animated: !UIAccessibility.isReduceMotionEnabled) }
        else {
            let scale = min(scroll.maximumZoomScale, baseScale * preference.doubleTapZoom)
            let point = recognizer.location(in: imageView)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
                        animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }
}

@MainActor
final class PageCanvasController: UIViewController {
    let groupIndex: Int
    let group: PageGroup
    private var canvases: [ZoomPageView] = []
    private let pages: [MangaPage]
    private let chapter: Chapter
    private let pipeline: ImagePipeline
    private let preferences: ReaderPreferences
    private let tapped: (CGFloat) -> Void
    private let dimensions: (Int, Double) -> Void
    init(groupIndex: Int, group: PageGroup, pages: [MangaPage], chapter: Chapter,
         pipeline: ImagePipeline, preferences: ReaderPreferences, tap: @escaping (CGFloat) -> Void,
         dimensions: @escaping (Int, Double) -> Void) {
        self.groupIndex = groupIndex; self.group = group; self.pages = pages; self.chapter = chapter
        self.pipeline = pipeline; self.preferences = preferences; tapped = tap; self.dimensions = dimensions
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    private var ratios: [Double] = []
    override func loadView() {
        view = UIView(); view.backgroundColor = .black
        let order = group.displayOrder(preferences.direction)
        for (slot, index) in order.enumerated() {
            let canvas = ZoomPageView(frame: .zero); canvas.alignment = .center
            canvas.tapped = tapped; view.addSubview(canvas); canvases.append(canvas)
            let page = pages[index]
            if let w = page.width, let h = page.height, w > 0, h > 0 { ratios.append(w / h) } else { ratios.append(0.707) }
            canvas.configure(page: page, index: index, chapter: chapter, pipeline: pipeline, preferences: preferences) { [weak self] i, ratio in
                guard let self else { return }
                if abs(self.ratios[slot] - ratio) > 0.001 { self.ratios[slot] = ratio; self.view.setNeedsLayout() }
                self.dimensions(i, ratio)
            }
        }
    }
    // Facing pages are laid out as one book-like unit: both pages share a height,
    // sit flush at the spine, and the pair is centered in the viewport. This keeps
    // pages from being stranded at the screen edges with a black gap in between.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, !canvases.isEmpty else { return }
        if canvases.count == 1 { canvases[0].frame = bounds; return }
        let total = ratios.reduce(0, +)
        let height = min(bounds.height, bounds.width / max(0.01, total))
        var x = (bounds.width - height * total) / 2
        let y = (bounds.height - height) / 2
        for (canvas, ratio) in zip(canvases, ratios) {
            let width = height * ratio
            canvas.frame = CGRect(x: x, y: y, width: width, height: height).integral
            x += width
        }
    }
    func releaseImages() { canvases.forEach { $0.suspend() } }
    /// Guided view works on single pages; spreads turn as usual.
    func stepPanel(forward: Bool) -> Bool { canvases.count == 1 ? canvases[0].stepPanel(forward: forward) : false }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); canvases.forEach { $0.resume() }
    }
    // UIKit may reuse this canvas immediately during a reverse turn. Its decoded
    // image lives with the controller and can be reclaimed under memory pressure.
}

/// Long-press a page: share it, save it to Photos, or make it the series cover.
extension ZoomPageView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let image = imageView.image else { return nil }
        let index = pageIndex
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let share = UIAction(title: "Share page", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                self?.present(UIActivityViewController(activityItems: [image], applicationActivities: nil))
            }
            let save = UIAction(title: "Save to Photos", image: UIImage(systemName: "square.and.arrow.down")) { _ in
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            }
            let cover = UIAction(title: "Set as cover", image: UIImage(systemName: "photo")) { _ in
                NotificationCenter.default.post(name: ZoomPageView.useAsCover, object: nil, userInfo: ["index": index])
            }
            var actions = [share, save, cover]
            if let self, self.panelIndex >= 0 {
                actions.append(UIAction(title: "Show whole page") { [weak self] _ in self?.panelIndex = -1; self?.showPanel() })
                actions.append(UIAction(title: "Skip panel") { [weak self] _ in _ = self?.stepPanel(forward: true) })
            }
            return UIMenu(children: actions)
        }
    }
    private func present(_ controller: UIViewController) {
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
        }
        top?.present(controller, animated: true)
    }
}
