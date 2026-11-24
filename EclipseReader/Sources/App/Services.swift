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
    private static func resolve() -> URL? {
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

/// Clean low-contrast noise at source resolution so enlargement does not amplify it.
enum PageEnhancer {
    nonisolated(unsafe) static let context = CIContext(options: [.cacheIntermediates: false])

    static func enhance(_ image: CGImage, targetLongSide: Double, strength: Double = 0.035) -> CGImage? {
        let width = Double(image.width)
        let height = Double(image.height)
        let long = max(width, height)
        let pixels = width * height
        // Bound the extra decoded surface, including long strips held by the scroll reader.
        guard pixels <= 8_000_000, long <= 16_384 else { return nil }
        let scale = min(2, max(1, targetLongSide / long), sqrt(8_000_000 / pixels), 16_384 / long)
        let input = CIImage(cgImage: image)
        let clean = input.clampedToExtent()
            .applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": strength, "inputSharpness": 0.0])
        let output = scale > 1 ? clean.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0
        ]) : clean
        let bounds = CGRect(x: 0, y: 0, width: floor(width * scale), height: floor(height * scale))
        return context.createCGImage(output, from: bounds)
    }
}
