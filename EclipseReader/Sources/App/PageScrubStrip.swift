import SwiftUI
import ImageIO

/// While the page slider is held: the page you'd land on, with two pages either side of it, so
/// you can see where you are in the chapter rather than one picture with no context.
/// Pages run in reading order (right to left for manga, like the pages themselves).
struct PageScrubStrip: View {
    let pages: [MangaPage]
    let target: Int
    let chapter: Chapter
    let pipeline: ImagePipeline
    let rightToLeft: Bool
    /// Pages shown either side of the target.
    static let reach = 2

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(-Self.reach...Self.reach, id: \.self) { offset in
                let index = target + offset
                let centre = offset == 0
                VStack(spacing: 4) {
                    Group {
                        if let page = pages[safe: index] {
                            ScrubThumbnail(page: page, chapter: chapter, pipeline: pipeline)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: centre ? 78 : 56, height: centre ? 110 : 80)
                    .clipShape(RoundedRectangle(cornerRadius: centre ? 7 : 5))
                    .overlay {
                        if centre && pages.indices.contains(index) {
                            RoundedRectangle(cornerRadius: 7).stroke(Eclipse.highlight, lineWidth: 2)
                        }
                    }
                    Text(pages.indices.contains(index) ? "\(index + 1)" : " ")
                        .font(.caption2.weight(centre ? .bold : .medium)).monospacedDigit()
                        .foregroundStyle(centre ? Eclipse.highlight : .white.opacity(0.7))
                }
                .opacity(centre ? 1 : 0.8)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
        .animation(.snappy(duration: 0.15), value: target)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(target + 1) of \(pages.count)")
    }
}

/// A small, quickly decoded picture of one page (from the page cache when it's there).
private struct ScrubThumbnail: View {
    let page: MangaPage
    let chapter: Chapter
    let pipeline: ImagePipeline
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Eclipse.surfaceHigh
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ProgressView().controlSize(.mini).tint(.white.opacity(0.6))
            }
        }
        .task(id: page.id) {
            if let cached = ScrubThumbnails.cache.object(forKey: page.id as NSString) { image = cached; return }
            image = nil
            guard let data = try? await pipeline.data(for: page, chapter: chapter), !Task.isCancelled else { return }
            let half = page.half
            let made = await Task.detached(priority: .userInitiated) { ScrubThumbnails.make(data, half: half) }.value
            guard let made, !Task.isCancelled else { return }
            ScrubThumbnails.cache.setObject(made, forKey: page.id as NSString)
            image = made
        }
    }
}

enum ScrubThumbnails {
    @MainActor static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()
    /// Decodes straight to a small size (fast, little memory); a split spread shows its own half.
    static func make(_ data: Data, half: MangaPage.Half?) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: half == nil ? 260 : 520,
        ]
        guard var cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        if let half {
            let width = cg.width / 2
            let rect = CGRect(x: half == .left ? 0 : cg.width - width, y: 0, width: width, height: cg.height)
            if let cropped = cg.cropping(to: rect) { cg = cropped }
        }
        return UIImage(cgImage: cg)
    }
}
