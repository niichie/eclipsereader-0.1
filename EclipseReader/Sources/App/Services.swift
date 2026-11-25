import SwiftUI
import Network
import LocalAuthentication
import CoreImage

/// Whether the connection is "expensive" (cellular or a personal hotspot), for Wi-Fi-only downloads.
@MainActor
final class NetworkWatch {
    static let shared = NetworkWatch()
    private(set) var expensive = false
    /// Called on the main actor whenever the connection type changes.
    var onChange: (() -> Void)?
    private let monitor = NWPathMonitor()
    private init() {
        monitor.pathUpdateHandler = { path in
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor in NetworkWatch.shared.update(expensive) }
        }
        monitor.start(queue: DispatchQueue(label: "eclipsereader.network"))
    }
    private func update(_ value: Bool) {
        guard value != expensive else { return }
        expensive = value
        onChange?()
    }
}

/// Face ID / Touch ID / passcode check. Nonisolated: the system prompt runs on its own.
enum Biometrics {
    static func unlock(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
    static var symbol: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "lock.fill"
        }
    }
}

/// Covers the app while locked; unlocks with Face ID, Touch ID or the passcode.
struct LockScreen: View {
    let unlock: () -> Void
    @State private var trying = false
    var body: some View {
        ZStack {
            EclipseBackground()
            VStack(spacing: 22) {
                EclipseMark(size: 72)
                EclipseWordmark(size: 26)
                Button {
                    attempt()
                } label: {
                    Label("Unlock", systemImage: Biometrics.symbol).font(.headline)
                        .padding(.horizontal, 26).frame(height: 50)
                        .background(Eclipse.highlight, in: Capsule()).foregroundStyle(.black)
                }
                .buttonStyle(PressableStyle())
                .disabled(trying)
            }
        }
        .task { attempt() }
    }
    private func attempt() {
        guard !trying else { return }
        trying = true
        Task {
            let ok = await Biometrics.unlock(reason: "Unlock eclipsereader")
            trying = false
            if ok { unlock() }
        }
    }
}

/// Daily backup into a folder the user picked (iCloud Drive or anywhere in Files). Keeps the last 7.
@MainActor
enum AutoBackup {
    private static let bookmarkKey = "autoBackupFolder"
    private static let lastKey = "autoBackupLast"
    static var folderName: String? {
        guard let url = resolve() else { return nil }
        return url.lastPathComponent
    }
    static var lastBackup: Date? { UserDefaults.standard.object(forKey: lastKey) as? Date }
    static func setFolder(_ url: URL?) {
        guard let url else { UserDefaults.standard.removeObject(forKey: bookmarkKey); return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
    }
    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
    /// Writes today's backup if the last one is more than a day old (or `force`). Returns an error message.
    @discardableResult
    static func runIfDue(_ model: LibraryModel, force: Bool = false) -> String? {
        guard let folder = resolve() else { return nil }
        if !force, let last = lastBackup, Date().timeIntervalSince(last) < 20 * 3600 { return nil }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        do {
            let file = try model.backupFile()
            let target = folder.appendingPathComponent(file.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: file, to: target)
            UserDefaults.standard.set(Date(), forKey: lastKey)
            // Keep the newest seven.
            let old = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
                .filter { $0.lastPathComponent.hasPrefix("eclipsereader-backup-") && $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
            for url in old.dropFirst(7) { try? FileManager.default.removeItem(at: url) }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// A colour taken from a cover, for tinting the series page around it (like Apple Music).
struct CoverTint: Sendable, Equatable {
    let red: Double, green: Double, blue: Double
    var color: Color { Color(red: red, green: green, blue: blue) }
    /// Bright enough that white text on it is hard to read.
    var isLight: Bool { 0.2126 * red + 0.7152 * green + 0.0722 * blue > 0.58 }

    /// The cover's most vivid colour, brightened so it reads well on black. Nil for grey covers.
    static func from(_ data: Data) -> CoverTint? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                           kCGImageSourceThumbnailMaxPixelSize: 48] as CFDictionary)
        else { return nil }
        let w = 24, h = 24
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        // Hue histogram of saturated, mid-bright pixels; the busiest hue wins.
        var buckets = [Double](repeating: 0, count: 24)
        var sums = [(Double, Double, Double)](repeating: (0, 0, 0), count: 24)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            let maxC = max(r, g, b), minC = min(r, g, b)
            let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
            guard saturation > 0.28, maxC > 0.22 else { continue }
            var hue: Double
            if maxC == r { hue = (g - b) / (maxC - minC) } else if maxC == g { hue = 2 + (b - r) / (maxC - minC) } else { hue = 4 + (r - g) / (maxC - minC) }
            hue = (hue < 0 ? hue + 6 : hue) / 6
            let k = min(23, Int(hue * 24))
            let weight = saturation * maxC
            buckets[k] += weight
            sums[k] = (sums[k].0 + r * weight, sums[k].1 + g * weight, sums[k].2 + b * weight)
        }
        guard let best = buckets.indices.max(by: { buckets[$0] < buckets[$1] }), buckets[best] > 1.2 else { return nil }
        var (r, g, b) = (sums[best].0 / buckets[best], sums[best].1 / buckets[best], sums[best].2 / buckets[best])
        // Lift dark colours so the glow is visible on black.
        let peak = max(r, g, b, 0.001)
        let lift = min(1.6, 0.85 / peak)
        r = min(1, r * lift); g = min(1, g * lift); b = min(1, b * lift)
        return CoverTint(red: r, green: g, blue: b)
    }
}

/// Scan cleanup and upscaling for manga, manhwa and comic pages.
///
/// 1. Levels: grey, yellowed paper becomes white and washed-out ink becomes black (measured per page,
///    and only when the page really has paper and ink, so dark or painted pages are left alone).
/// 2. JPEG cleanup at the source size (chroma noise dropped on black-and-white pages).
/// 3. Lanczos upscale toward the size the page is shown at (up to 4×). Upscaling only 2× and letting
///    the screen stretch the rest left lettering soft.
/// 4. Edges re-defined at that size: a gentle contrast curve and an unsharp mask scaled to the
///    enlargement, so lines and lettering come out solid instead of blurred or haloed.
/// Black-and-white pages are rendered as 8-bit grey, a quarter of the memory of colour.
enum PageEnhancer {
    nonisolated(unsafe) private static let context = CIContext(options: [.cacheIntermediates: false])

    struct Analysis: Equatable {
        /// Darkest common tone (ink) and brightest common tone (paper), 0...1.
        var ink: Double
        var paper: Double
        var grayscale: Bool
    }

    /// Measures a small copy of the page: ink and paper levels, and whether it is black and white.
    static func analyse(_ image: CGImage) -> Analysis? {
        let scale = min(1, 256.0 / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var histogram = [Int](repeating: 0, count: 256)
        var colourful = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            histogram[(r * 54 + g * 183 + b * 19) >> 8] += 1
            if max(r, g, b) - min(r, g, b) > 40 { colourful += 1 }
        }
        let total = w * h
        func percentile(_ p: Double) -> Double {
            let wanted = Int(Double(total) * p)
            var seen = 0
            for (value, count) in histogram.enumerated() {
                seen += count
                if seen > wanted { return Double(value) / 255 }
            }
            return 1
        }
        // Paper is the most common tone among the lighter part of the page. The brightest few percent
        // sit above it (JPEG noise), which left grey paper grey.
        let lighter = Int(percentile(0.6) * 255)
        let paperBin = (lighter...255).max { histogram[$0] < histogram[$1] } ?? 255
        return Analysis(ink: percentile(0.008), paper: Double(paperBin) / 255, grayscale: Double(colourful) < Double(total) * 0.04)
    }

    /// The levels stretch for a page: (scale, bias) so that ink maps to 0 and paper to 1.
    /// Only real paper (bright) and real ink (dark) are moved, and never by more than 1.6×.
    static func levels(_ a: Analysis) -> (scale: Double, bias: Double) {
        let ink = a.ink < 0.35 ? a.ink : 0
        let paper = a.paper > 0.6 ? a.paper : 1
        guard paper - ink > 0.2 else { return (1, 0) }
        let scale = min(1.6, 1 / (paper - ink))
        return (scale, -ink * scale)
    }

    /// Edge settings. `smoothing` is a blur (in source pixels) after enlarging that rounds off JPEG
    /// blocks before the curve firms the edge up again; without it 3-4x enlargements look ragged.
    /// Edge settings for one kind of page. `smoothing` is a blur (in source pixels) after enlarging that
    /// rounds off JPEG blocks before the curve firms the edge up again; `curve` is how far the tone curve
    /// pulls the darker and lighter quarter-tones toward black and white.
    struct Edge: Sendable {
        var denoise: Double
        var smoothing: Double
        var curve: Double
        var sharpenRadius: Double
        var sharpenAmount: Double
    }
    struct Tuning: Sendable {
        /// Black-and-white scans. Kept light: a firm curve with more smoothing thickened thin serif
        /// lettering (Hellsing) and filled the small holes in letters like e and a.
        var grey = Edge(denoise: 0.03, smoothing: 0.15, curve: 0.15, sharpenRadius: 0.45, sharpenAmount: 0.35)
        /// Colour pages (manhwa, webtoons): often heavily compressed, so more cleanup and gentle
        /// sharpening, which otherwise sharpens the JPEG grit around lettering along with it.
        /// No contrast curve (0.18 leaves the tones as they are): on low-resolution colour pages it
        /// flattened colours into blotches.
        var colour = Edge(denoise: 0.08, smoothing: 0.4, curve: 0.18, sharpenRadius: 0.5, sharpenAmount: 0.1)
        static let standard = Tuning()
    }

    /// Returns nil when the page doesn't need to change (already clean and large enough).
    static func enhance(_ image: CGImage, targetLongSide: Double, tuning: Tuning = .standard) -> CGImage? {
        let long = Double(max(image.width, image.height))
        guard long > 0, let analysis = analyse(image) else { return nil }
        let area = Double(image.width) * Double(image.height)
        // Memory ceiling per page (tall colour webtoon strips are the large ones).
        let budget = (analysis.grayscale ? 24_000_000.0 : 12_000_000.0) / area
        let scale = min(4.0, sqrt(budget), max(1.0, targetLongSide / long))
        let (gain, bias) = levels(analysis)
        let upscaling = scale > 1.05
        guard upscaling || gain > 1.02 || bias < -0.005 else { return nil }

        var page = CIImage(cgImage: image)
        if analysis.grayscale {
            page = page.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
        }
        if gain != 1 || bias != 0 {
            let g = CGFloat(gain), b = CGFloat(bias)
            page = page.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: g, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: g, w: 0),
                "inputBiasVector": CIVector(x: b, y: b, z: b, w: 0),
            ]).applyingFilter("CIColorClamp")
        }
        // Edge pixels repeat outward so the filters below don't darken the page border.
        page = page.clampedToExtent()
        // JPEG blocking and speckle, at the source size where it is one or two pixels wide.
        let edge = analysis.grayscale ? tuning.grey : tuning.colour
        page = page.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": edge.denoise, "inputSharpness": 0.4])
        let extent = CIImage(cgImage: image).extent
        if upscaling {
            page = page.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
        }
        let output = extent.applying(CGAffineTransform(scaleX: upscaling ? scale : 1, y: upscaling ? scale : 1)).integral
        if upscaling, edge.smoothing > 0 {
            page = page.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: edge.smoothing * scale])
        }
        // Solid ink and clean edges: black-and-white pages get a firmer curve than colour art.
        let curve: [CGFloat] = [CGFloat(edge.curve), 1 - CGFloat(edge.curve)]
        page = page.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0),
            "inputPoint1": CIVector(x: 0.18, y: curve[0]),
            "inputPoint2": CIVector(x: 0.5, y: 0.5),
            "inputPoint3": CIVector(x: 0.82, y: curve[1]),
            "inputPoint4": CIVector(x: 1, y: 1),
        ])
        page = page.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: max(0.8, edge.sharpenRadius * scale),
            kCIInputIntensityKey: edge.sharpenAmount,
        ]).cropped(to: output)
        if analysis.grayscale {
            return context.createCGImage(page, from: output, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        }
        return context.createCGImage(page, from: output)
    }
}
